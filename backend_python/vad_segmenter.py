"""
VADSegmenter - 상태 머신 기반 VAD 세그먼터

목표: append는 끊지 않고 commit만 지연하여 STT 입력이 중간에 잘리지 않게 함

상태: IDLE, SPEECH, HANGOVER
- clear는 IDLE→SPEECH 최초 진입에서만 1회 호출
- append는 SPEECH와 HANGOVER 동안 모두 계속 호출 (is_speech=False라도)
- HANGOVER에서 is_speech=True가 다시 들어오면 새 발화로 취급하지 않음 (세그먼트 유지)
- commit은 hangover_ms 경과 후에도 재발화가 없을 때만 시도
- commit 조건: appended_ms >= min_commit_ms
"""
import asyncio
import logging
from typing import Optional, Callable, Awaitable
from enum import Enum
import time

logger = logging.getLogger(__name__)


class VADState(Enum):
    """VAD 상태 머신 상태"""
    IDLE = "IDLE"  # 말 안 함
    SPEECH = "SPEECH"  # 말 중
    HANGOVER = "HANGOVER"  # 말 끝 후 대기 (append는 계속)


class VADSegmenter:
    """VAD 기반 오디오 세그먼터 (상태 머신)"""
    
    def __init__(
        self,
        on_clear: Optional[Callable[[], Awaitable[None]]] = None,
        on_append: Optional[Callable[[bytes], Awaitable[None]]] = None,
        on_commit: Optional[Callable[[], Awaitable[None]]] = None,
        on_get_buffered_ms: Optional[Callable[[], int]] = None,  # STT 클라이언트의 buffered_ms 조회
        hangover_ms: int = 500,
        min_commit_ms: int = 100  # 최소 100ms (STT 클라이언트 기준)
    ):
        """
        Args:
            on_clear: clear 콜백 (IDLE→SPEECH 최초 진입 시 1회만 호출)
            on_append: append 콜백 (SPEECH와 HANGOVER 동안 모두 호출, bytes: 960 bytes)
            on_commit: commit 콜백 (appended_ms >= min_commit_ms일 때 호출)
            hangover_ms: hangover 시간 (300~800ms, 기본 500ms)
            min_commit_ms: 최소 commit 길이 (기본 700ms)
        """
        self.on_clear = on_clear
        self.on_append = on_append
        self.on_commit = on_commit
        self.on_get_buffered_ms = on_get_buffered_ms  # STT 클라이언트의 buffered_ms 조회
        
        self.hangover_ms = max(300, min(800, hangover_ms))
        self.min_commit_ms = min_commit_ms
        self.chunk_ms = 20  # 20ms per chunk
        
        # 상태 머신
        self.state = VADState.IDLE
        
        # 카운터 (세그먼트 단위로 유지)
        self.appended_chunks = 0  # 현재 세그먼트에서 실제로 append한 chunk 수
        self.last_speech_time = 0.0  # 마지막 speech 감지 시각 (ms)
        
        # Hangover 태스크 (세그먼트 단위로 1개만 유지)
        self._hangover_task: Optional[asyncio.Task] = None
        self._lock = asyncio.Lock()
        
        # 세그먼트 추적
        self._segment_start_time = 0.0  # 세그먼트 시작 시각 (ms)
        self._segment_id = 0  # 세그먼트 ID (로깅용)
    
    async def process_chunk(self, pcm16_bytes: bytes, is_speech: bool, metadata: Optional[dict] = None):
        """
        오디오 청크 처리 (VAD 결과 기반)
        
        Args:
            pcm16_bytes: PCM16 오디오 데이터 (960 bytes, 20ms @ 24kHz)
            is_speech: VAD 결과 (True=speech, False=silence)
            metadata: 디버깅용 메타데이터 (선택적)
        """
        async with self._lock:
            current_time = time.time() * 1000  # ms
            
            if self.state == VADState.IDLE:
                if is_speech:
                    # IDLE → SPEECH 전환 (새 세그먼트 시작)
                    self.state = VADState.SPEECH
                    self.appended_chunks = 0
                    self.last_speech_time = current_time
                    self._segment_start_time = current_time
                    self._segment_id += 1
                    
                    # 세그먼트 시작 시 상세 로깅 (디버깅 체크리스트)
                    if metadata and 'upstream_info' in metadata:
                        upstream = metadata['upstream_info']
                        peak = metadata.get('peak', 0)
                        rms = metadata.get('rms', 0.0)
                        zero_ratio = metadata.get('zero_ratio', 0.0)
                        
                        logger.info(f"🎙️ [Segment {self._segment_id}] Speech start")
                        logger.info(f"   Upstream: sr={upstream.get('sample_rate')}, "
                                  f"format={upstream.get('format')}, "
                                  f"dtype={upstream.get('dtype')}, "
                                  f"shape={upstream.get('shape')}")
                        logger.info(f"   Mono: peak={upstream.get('mono_peak')}, "
                                  f"rms={upstream.get('mono_rms', 0):.4f}, "
                                  f"range={upstream.get('mono_range')}")
                        logger.info(f"   24k final: len={len(pcm16_bytes)} bytes, "
                                  f"peak={peak}, rms={rms:.4f}, zero_ratio={zero_ratio:.2%}")
                    else:
                        logger.info(f"🎙️ [Segment {self._segment_id}] Speech start")
                    
                    # clear는 IDLE→SPEECH 최초 진입에서만 1회 호출
                    if self.on_clear:
                        try:
                            await self.on_clear()
                        except Exception as e:
                            logger.error(f"Error in on_clear callback: {e}", exc_info=True)
                    
                    # 첫 청크 append
                    if self.on_append:
                        try:
                            await self.on_append(pcm16_bytes)
                            self.appended_chunks += 1
                        except Exception as e:
                            logger.error(f"Error in on_append callback: {e}", exc_info=True)
                # else: IDLE 상태에서 무음은 무시 (append 안 함)
            
            elif self.state == VADState.SPEECH:
                if is_speech:
                    # SPEECH 유지: append만 수행
                    self.last_speech_time = current_time
                    
                    if self.on_append:
                        try:
                            await self.on_append(pcm16_bytes)
                            self.appended_chunks += 1
                        except Exception as e:
                            logger.error(f"Error in on_append callback: {e}", exc_info=True)
                else:
                    # SPEECH → HANGOVER 전환 (append는 계속)
                    self.state = VADState.HANGOVER
                    appended_ms = self.appended_chunks * self.chunk_ms
                    logger.info(f"🛑 [Segment {self._segment_id}] Speech end → Hangover (chunks={self.appended_chunks}, {appended_ms}ms)")
                    
                    # Hangover 태스크 시작 (기존 태스크가 있으면 취소)
                    if self._hangover_task:
                        self._hangover_task.cancel()
                    
                    self._hangover_task = asyncio.create_task(
                        self._wait_for_hangover()
                    )
                    
                    # HANGOVER 상태에서도 append 계속 (침묵 구간도 세그먼트에 포함)
                    if self.on_append:
                        try:
                            await self.on_append(pcm16_bytes)
                            self.appended_chunks += 1
                        except Exception as e:
                            logger.error(f"Error in on_append callback: {e}", exc_info=True)
            
            elif self.state == VADState.HANGOVER:
                # HANGOVER 상태에서는 is_speech 여부와 관계없이 append 계속
                if self.on_append:
                    try:
                        await self.on_append(pcm16_bytes)
                        self.appended_chunks += 1
                    except Exception as e:
                        logger.error(f"Error in on_append callback: {e}", exc_info=True)
                
                if is_speech:
                    # HANGOVER → SPEECH 복귀 (새 발화가 아님, 세그먼트 유지)
                    if self._hangover_task:
                        self._hangover_task.cancel()
                        self._hangover_task = None
                    
                    self.state = VADState.SPEECH
                    self.last_speech_time = current_time
                    
                    appended_ms = self.appended_chunks * self.chunk_ms
                    logger.info(f"🎙️ [Segment {self._segment_id}] Speech resume (chunks={self.appended_chunks}, {appended_ms}ms)")
                    # clear 호출 금지, appended_chunks 리셋 금지
                # else: HANGOVER 상태에서 무음은 계속 대기 (append는 이미 위에서 수행)
    
    async def _wait_for_hangover(self):
        """Hangover 대기 후 commit 확인"""
        try:
            # Hangover 시간 동안 대기
            await asyncio.sleep(self.hangover_ms / 1000.0)
            
            async with self._lock:
                # 대기 중 새 발화가 시작되었는지 확인 (SPEECH로 복귀했는지)
                if self.state != VADState.HANGOVER:
                    # SPEECH로 복귀했거나 다른 상태로 전환됨
                    return
                
                # commit 조건 확인: STT 클라이언트의 buffered_ms 기준
                if self.on_get_buffered_ms:
                    stt_buffered_ms = self.on_get_buffered_ms()
                else:
                    # 폴백: 내부 카운터 사용
                    stt_buffered_ms = self.appended_chunks * self.chunk_ms
                
                if stt_buffered_ms >= self.min_commit_ms:
                    # commit 수행
                    segment_duration = time.time() * 1000 - self._segment_start_time
                    logger.info(f"✅ [Segment {self._segment_id}] Commit (STT buffered: {stt_buffered_ms}ms, chunks={self.appended_chunks}, duration={segment_duration:.0f}ms)")
                    
                    if self.on_commit:
                        try:
                            await self.on_commit()
                        except Exception as e:
                            logger.error(f"Error in on_commit callback: {e}", exc_info=True)
                else:
                    logger.warning(f"⚠️ [Segment {self._segment_id}] Skip commit (STT buffered: {stt_buffered_ms}ms < {self.min_commit_ms}ms minimum)")
                
                # HANGOVER → IDLE 전환
                self.state = VADState.IDLE
                self.appended_chunks = 0
                self._hangover_task = None
        
        except asyncio.CancelledError:
            # speech 재진입으로 인한 취소는 정상 동작
            pass
        except Exception as e:
            logger.error(f"VAD: Hangover error: {e}", exc_info=True)
    
    async def cleanup(self):
        """리소스 정리"""
        async with self._lock:
            if self._hangover_task:
                self._hangover_task.cancel()
                try:
                    await self._hangover_task
                except asyncio.CancelledError:
                    pass
                self._hangover_task = None
            
            self.state = VADState.IDLE
            self.appended_chunks = 0

