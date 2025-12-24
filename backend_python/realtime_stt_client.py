"""
OpenAI Realtime Transcription WebSocket 클라이언트
STT 전용 (TTS는 별도 유지)

요구사항:
- append_audio(bytes960)만 받는다(24kHz mono PCM16 LE, 20ms = 960 bytes)
- 실제 append 성공 시에만 buffered_ms 증가
- commit()은 buffered_ms>=100ms일 때만 전송
- clear()는 state 머신에서만 호출 (세그먼트 시작 1회만)
"""
import asyncio
import json
import base64
import logging
import os
from typing import Optional, Callable, Awaitable
import websockets
from websockets.exceptions import ConnectionClosed, ConnectionClosedOK, WebSocketException

logger = logging.getLogger(__name__)


class RealtimeSttClient:
    """OpenAI Realtime Transcription WebSocket 클라이언트"""
    
    # Realtime API WebSocket URL (transcription intent 사용)
    REALTIME_API_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
    
    def __init__(self, session_id: str, sample_rate: int = 24000):
        self.session_id = session_id
        self.api_key = os.getenv("OPENAI_API_KEY")
        if not self.api_key:
            raise ValueError("OPENAI_API_KEY environment variable is required")
        
        self.sample_rate = sample_rate  # 24kHz 고정 (Realtime Transcription은 24k만 지원)
        self.chunk_ms = 20  # 20ms per chunk
        self.expected_bytes = int(self.sample_rate * (self.chunk_ms / 1000.0) * 2)  # 960 for 24k
        
        self.ws: Optional[websockets.WebSocketCommonProtocol] = None
        self._connected = False
        self._receiver_task: Optional[asyncio.Task] = None
        
        # 콜백 함수
        self._on_partial: Optional[Callable[[str], Awaitable[None]]] = None
        self._on_final: Optional[Callable[[str], Awaitable[None]]] = None
        self._on_error: Optional[Callable[[Exception], Awaitable[None]]] = None
        self._on_speech_started: Optional[Callable[[], Awaitable[None]]] = None
        self._on_speech_stopped: Optional[Callable[[], Awaitable[None]]] = None
        
        # 내부 버퍼링 추적 (실제 append 성공 시에만 증가)
        self._buffered_ms = 0  # 현재 버퍼에 쌓인 오디오 길이 (밀리초)
        self._appended_chunks = 0  # 실제로 append 성공한 chunk 수
        self._pending_appends = 0  # 전송 대기 중인 append 개수 (commit empty 방지)
    
    async def connect(self):
        """WebSocket 연결 및 세션 설정"""
        if self._connected:
            logger.warning("Already connected, skipping")
            return
        
        try:
            headers = {
                "Authorization": f"Bearer {self.api_key}",
                "OpenAI-Beta": "realtime=v1"
            }
            
            self.ws = await websockets.connect(
                self.REALTIME_API_URL,
                additional_headers=headers
            )
            
            self._connected = True
            
            # 세션 설정 (STT만 활성화)
            await self._configure_session()
            
        except Exception as e:
            logger.error(f"Failed to connect Realtime STT: {e}", exc_info=True)
            self._connected = False
            raise
    
    async def _configure_session(self):
        """
        세션 설정 - server_vad 방식 (Realtime STT가 턴을 판단)
        
        중요:
        - transcription_session.update 이벤트 타입 사용
        - turn_detection에 server_vad 설정
        - 서버가 speech_started/speech_stopped 이벤트로 턴을 판단
        """
        # server_vad 방식: 서버가 턴 판단 (과민 끊김 완화 설정)
        config = {
            "type": "transcription_session.update",
            "session": {
                "input_audio_format": "pcm16",  # 16-bit little-endian PCM (24kHz)
                "input_audio_transcription": {
                    "model": "gpt-4o-transcribe",
                    "language": "ko"
                },
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": 0.6,  # 덜 민감 (과민 끊김 완화)
                    "prefix_padding_ms": 500,
                    "silence_duration_ms": 800  # 끊김 완화 핵심
                },
                "input_audio_noise_reduction": {
                    "type": "near_field"
                },
                "include": []
            }
        }
        
        await self.send_event(config)
    
    async def close(self):
        """WebSocket 연결 종료"""
        if self._receiver_task:
            self._receiver_task.cancel()
            try:
                await self._receiver_task
            except asyncio.CancelledError:
                pass
            self._receiver_task = None
        
        if self.ws:
            try:
                await self.ws.close()
            except Exception as e:
                logger.warning(f"Error closing WebSocket: {e}")
            self.ws = None
        
        self._connected = False
    
    async def send_event(self, payload: dict):
        """이벤트 전송"""
        if not self._connected or not self.ws:
            raise RuntimeError("Not connected")
        
        try:
            message = json.dumps(payload)
            event_type = payload.get("type", "unknown")
            
            await self.ws.send(message)
        except (ConnectionClosedOK, ConnectionClosed, WebSocketException) as e:
            # WebSocket 종료 감지 시 연결 상태 업데이트
            logger.debug(f"WebSocket closed during send: {e}")
            self._connected = False
            raise
        except Exception as e:
            logger.error(f"Error sending event: {e}", exc_info=True)
            raise
    
    async def append_audio(self, pcm16_bytes: bytes) -> bool:
        """
        오디오 청크 추가 (20ms PCM16)
        
        실제 append 성공 시에만 buffered_ms 증가
        
        Args:
            pcm16_bytes: PCM16 오디오 (960 bytes @ 24kHz)
        
        Returns:
            bool: append 성공 여부
        """
        # WebSocket 종료 시 즉시 중단 (append 스팸 방지)
        if not self._connected or not self.ws:
            return False
        
        try:
            # 입력 데이터 검증 (세션 sample_rate 기준으로 강제)
            actual_size = len(pcm16_bytes)
            
            if actual_size != self.expected_bytes:
                logger.error(f"❌ STT append_audio: CRITICAL - Chunk size mismatch!")
                logger.error(f"❌ Expected {self.expected_bytes} bytes ({self.sample_rate}Hz 20ms), got {actual_size} bytes")
                raise ValueError(f"Chunk size must be {self.expected_bytes} bytes ({self.sample_rate}Hz), got {actual_size}")
            
            # base64 인코딩 (raw PCM16 little-endian bytes)
            audio_b64 = base64.b64encode(pcm16_bytes).decode('utf-8')
            
            # base64 인코딩 검증
            if not isinstance(audio_b64, str):
                logger.error(f"❌ STT append: base64 encoding failed - not a string")
                return False
            
            payload = {
                "type": "input_audio_buffer.append",
                "audio": audio_b64  # base64 인코딩된 raw PCM16 little-endian bytes
            }
            
            # pending_appends 증가 (전송 전)
            self._pending_appends += 1
            
            # 실제 WS 전송 성공 (send_event 내부에서 ws.send 호출)
            await self.send_event(payload)
            
            # WS send 성공한 append 개수로만 buffered_ms 계산
            self._appended_chunks += 1
            self._pending_appends -= 1  # 전송 완료
            self._buffered_ms = self._appended_chunks * self.chunk_ms
            
            return True
            
        except (ConnectionClosedOK, ConnectionClosed, WebSocketException) as e:
            # WebSocket 종료 시 연결 상태 업데이트하고 조용히 실패 처리
            self._connected = False
            return False
        except Exception as e:
            logger.error(f"Error appending audio: {e}", exc_info=True)
            if self._on_error:
                await self._on_error(e)
            return False
    
    async def flush(self):
        """append 전송 완료 대기 (commit empty 방지)"""
        # pending_appends가 0이 될 때까지 대기 (최대 1초)
        max_wait = 1.0
        wait_interval = 0.01
        waited = 0.0
        
        while self._pending_appends > 0 and waited < max_wait:
            await asyncio.sleep(wait_interval)
            waited += wait_interval
        
    
    async def commit(self):
        """
        오디오 버퍼 커밋 (로컬 VAD 모드)
        
        로컬 VAD가 말 끝을 감지하면 자동으로 commit 호출
        """
        if not self._connected or not self.ws:
            return
        
        # commit 조건 확인: buffered_ms >= 100ms
        if self._buffered_ms < 100:
            return
        
        # pending_appends 체크: commit 전에 append가 충분히 전송되었는지 확인
        pending_ms = self._pending_appends * self.chunk_ms
        if pending_ms >= 100:
            return
        
        # append 전송 완료 대기
        await self.flush()
        
        try:
            payload = {
                "type": "input_audio_buffer.commit"
            }
            await self.send_event(payload)
            
            # commit 후 버퍼 길이 리셋
            self._appended_chunks = 0
            self._buffered_ms = 0
        except Exception as e:
            logger.error(f"Error committing audio: {e}", exc_info=True)
            if self._on_error:
                await self._on_error(e)
    
    async def clear(self):
        """
        오디오 버퍼 초기화 (로컬 VAD 모드)
        
        로컬 VAD가 말 시작을 감지하면 clear 호출
        """
        if not self._connected or not self.ws:
            return
        
        try:
            payload = {
                "type": "input_audio_buffer.clear"
            }
            await self.send_event(payload)
            
            # 버퍼 길이 리셋
            self._appended_chunks = 0
            self._buffered_ms = 0
            self._pending_appends = 0
        except Exception as e:
            logger.error(f"Error clearing buffer: {e}", exc_info=True)
    
    def get_stats(self) -> dict:
        """현재 상태 반환 (로깅/검증용)"""
        return {
            'appended_chunks': self._appended_chunks,
            'buffered_ms': self._buffered_ms,
            'pending_appends': self._pending_appends,
            'sample_rate': self.sample_rate,
            'expected_bytes': self.expected_bytes
        }
    
    async def start_receiver_loop(
        self,
        on_partial: Optional[Callable[[str], Awaitable[None]]] = None,
        on_final: Optional[Callable[[str], Awaitable[None]]] = None,
        on_error: Optional[Callable[[Exception], Awaitable[None]]] = None,
        on_speech_started: Optional[Callable[[], Awaitable[None]]] = None,
        on_speech_stopped: Optional[Callable[[], Awaitable[None]]] = None
    ):
        """
        이벤트 수신 루프 시작
        
        Args:
            on_partial: partial transcript 콜백
            on_final: final transcript 콜백
            on_error: 에러 콜백
            on_speech_started: speech_started 이벤트 콜백 (server_vad)
            on_speech_stopped: speech_stopped 이벤트 콜백 (server_vad)
        """
        self._on_partial = on_partial
        self._on_final = on_final
        self._on_error = on_error
        self._on_speech_started = on_speech_started
        self._on_speech_stopped = on_speech_stopped
        
        if self._receiver_task:
            return
        
        self._receiver_task = asyncio.create_task(self._receiver_loop())
    
    async def _receiver_loop(self):
        """이벤트 수신 루프"""
        if not self.ws:
            return
        
        try:
            async for message in self.ws:
                try:
                    event = json.loads(message)
                    await self._handle_event(event)
                except json.JSONDecodeError as e:
                    logger.error(f"Failed to parse event: {e}")
                except Exception as e:
                    logger.error(f"Error handling event: {e}", exc_info=True)
                    if self._on_error:
                        await self._on_error(e)
        
        except ConnectionClosed:
            self._connected = False
        except Exception as e:
            logger.error(f"Receiver loop error: {e}", exc_info=True)
            self._connected = False
            if self._on_error:
                await self._on_error(e)
    
    async def _handle_event(self, event: dict):
        """이벤트 핸들링 - transcription 이벤트 처리"""
        event_type = event.get("type")
        
        # transcription 이벤트 타입들 처리
        # 1. transcription.delta (partial 결과)
        if event_type == "transcription.delta":
            delta = event.get("delta", "")
            if delta and self._on_partial:
                await self._on_partial(delta)
        
        # 2. transcription.completed (final 결과)
        elif event_type == "transcription.completed":
            transcript = event.get("transcript", "")
            if transcript and self._on_final:
                await self._on_final(transcript)
        
        # 3. conversation.item.input_audio_transcription.delta (대화형 transcription)
        elif event_type == "conversation.item.input_audio_transcription.delta":
            delta = event.get("delta", "")
            if delta and self._on_partial:
                await self._on_partial(delta)
        
        # 4. conversation.item.input_audio_transcription.completed (대화형 transcription)
        elif event_type == "conversation.item.input_audio_transcription.completed":
            transcript = event.get("transcript", "")
            if transcript and self._on_final:
                await self._on_final(transcript)
        
        # 5. input_audio_buffer.cleared 이벤트 (clear() 요청에 대한 ACK)
        elif event_type == "input_audio_buffer.cleared":
            pass
        
        # 6. input_audio_buffer.committed 이벤트 (commit() 요청에 대한 ACK)
        elif event_type == "input_audio_buffer.committed":
            pass
        
        # 6-1. input_audio_buffer.speech_started 이벤트 (server_vad)
        elif event_type == "input_audio_buffer.speech_started":
            if self._on_speech_started:
                await self._on_speech_started()
        
        # 6-2. input_audio_buffer.speech_stopped 이벤트 (server_vad)
        elif event_type == "input_audio_buffer.speech_stopped":
            if self._on_speech_stopped:
                await self._on_speech_stopped()
        
        # 7. conversation.item.created 이벤트 (정상: input_audio 아이템 생성, transcript는 이후 이벤트로 옴)
        elif event_type == "conversation.item.created":
            return
        
        # 8. session.created / transcription_session.created 이벤트
        elif event_type in ("transcription_session.created", "session.created"):
            pass
        
        # 9. transcription_session.updated 이벤트
        elif event_type == "transcription_session.updated":
            pass
        
        # 10. session.updated 이벤트
        elif event_type == "session.updated":
            pass
        
        # 11. error 이벤트 (상세 로깅)
        elif event_type == "error":
            error_obj = event.get("error", {})
            error_msg = error_obj.get("message", "Unknown error")
            error_type = error_obj.get("type", "unknown")
            logger.error(f"❌ Realtime API error [{error_type}]: {error_msg}")
            # 전체 이벤트 출력 (원인 파악용)
            logger.error(f"Error event details:\n{json.dumps(event, indent=2)[:800]}")
            if self._on_error:
                await self._on_error(Exception(f"{error_type}: {error_msg}"))
        
        # 12. 기타 이벤트는 무시
        else:
            pass
