"""
VAD (Voice Activity Detection) 처리 모듈
- 무음 300-500ms 지속 시 "말 끝" 판단
- 오디오 버퍼링
"""
import asyncio
import logging
from typing import List, Optional
import numpy as np
import webrtcvad

logger = logging.getLogger(__name__)


class VADProcessor:
    """VAD 처리 클래스"""
    
    def __init__(
        self,
        on_speech_end,
        on_speech_start=None,
        silence_duration_ms: int = 400,
        frame_duration_ms: int = 20
    ):
        """
        Args:
            on_speech_end: 말 끝 콜백 (audio_buffer: np.ndarray) -> None
            on_speech_start: 말 시작 콜백 (optional)
            silence_duration_ms: 무음 지속 시간 (기본 400ms)
            frame_duration_ms: 프레임 길이 (기본 20ms)
        """
        self.vad = webrtcvad.Vad(2)  # 모드 2 (0-3, 2가 적당)
        self.on_speech_end = on_speech_end
        self.on_speech_start = on_speech_start
        
        self.silence_duration_ms = silence_duration_ms
        self.frame_duration_ms = frame_duration_ms
        self.sample_rate = 16000  # VAD는 16kHz 필요
        
        # 버퍼 관리
        self.audio_buffer: List[np.ndarray] = []
        self.silence_frames = 0
        self.speech_detected = False
        self.min_speech_frames = 2  # 최소 말하기 프레임 (노이즈 방지)
        self.speech_frames = 0
        
        # 비동기 작업
        self._check_task: Optional[asyncio.Task] = None
        self._lock = asyncio.Lock()
    
    async def add_audio(self, audio_data: np.ndarray):
        """
        오디오 프레임 추가 및 VAD 처리
        
        Args:
            audio_data: PCM16 오디오 데이터 (16kHz, mono)
        """
        async with self._lock:
            # 버퍼에 추가
            self.audio_buffer.append(audio_data.copy())
            
            # VAD 처리
            is_speech = self._detect_speech(audio_data)
            
            if is_speech:
                self.speech_frames += 1
                
                # 말하기 시작 감지
                if not self.speech_detected and self.speech_frames >= self.min_speech_frames:
                    self.speech_detected = True
                    self.silence_frames = 0
                    if self.on_speech_start:
                        await self.on_speech_start()
                    logger.debug("Speech started")
            else:
                if self.speech_detected:
                    # 말하고 있었는데 무음 감지
                    self.silence_frames += 1
                    
                    # 무음 지속 시간 확인
                    silence_duration = self.silence_frames * self.frame_duration_ms
                    if silence_duration >= self.silence_duration_ms:
                        # 말 끝 판단
                        await self._trigger_speech_end()
                else:
                    # 말하지 않았으면 버퍼 비우기 (노이즈 제거)
                    if len(self.audio_buffer) > 10:  # 최대 200ms 유지
                        self.audio_buffer = self.audio_buffer[-10:]
    
    def _detect_speech(self, audio_data: np.ndarray) -> bool:
        """
        VAD로 음성 감지
        
        Args:
            audio_data: PCM16 오디오 데이터
            
        Returns:
            True if speech detected
        """
        try:
            # webrtcvad는 bytes 형식 필요
            audio_bytes = audio_data.tobytes()
            
            # VAD 처리 (10ms, 20ms, 30ms 프레임만 지원)
            # 20ms 프레임 사용
            is_speech = self.vad.is_speech(audio_bytes, self.sample_rate)
            return is_speech
            
        except Exception as e:
            logger.error(f"VAD detection error: {e}")
            # 에러 시 보수적으로 speech로 판단
            return True
    
    async def _trigger_speech_end(self):
        """말 끝 트리거"""
        if len(self.audio_buffer) == 0:
            return
        
        # 버퍼 합치기
        full_audio = np.concatenate(self.audio_buffer)
        
        # 말 끝 콜백 호출
        await self.on_speech_end(full_audio)
        
        # 상태 리셋
        self.audio_buffer = []
        self.speech_detected = False
        self.silence_frames = 0
        self.speech_frames = 0
        
        logger.debug(f"Speech ended, audio length: {len(full_audio)} samples")
    
    async def cleanup(self):
        """리소스 정리"""
        async with self._lock:
            if self._check_task:
                self._check_task.cancel()
                try:
                    await self._check_task
                except asyncio.CancelledError:
                    pass

