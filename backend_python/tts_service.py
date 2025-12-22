"""
TTS (Text-to-Speech) 서비스
ElevenLabs API 스트리밍 사용
"""
import logging
import os
import numpy as np
from dotenv import load_dotenv
from elevenlabs.client import ElevenLabs
from typing import AsyncIterator

logger = logging.getLogger(__name__)


class TTSService:
    """TTS 서비스 클래스"""
    
    def __init__(self):
        api_key = os.getenv("ELEVENLABS_API_KEY")
        if not api_key:
            logger.warning("ELEVENLABS_API_KEY not found. TTS will be disabled.")
            self.enabled = False
            return
        
        self.enabled = True
        self.client = ElevenLabs(api_key=api_key)
        
        # 음성 설정
        if self.enabled:
            self.voice_id = os.getenv("ELEVENLABS_VOICE_ID", "21m00Tcm4TlvDq8ikWAM")  # 기본 음성
            self.model_id = os.getenv("ELEVENLABS_MODEL_ID", "eleven_turbo_v2_5")  # 빠른 모델
        self.sample_rate = 16000  # 16kHz
    
    async def stream_synthesize(self, text: str) -> AsyncIterator[np.ndarray]:
        """
        텍스트를 오디오로 변환 (스트리밍)
        
        Args:
            text: 변환할 텍스트
            
        Yields:
            오디오 청크 (numpy 배열, 16kHz, mono, int16)
        """
        if not self.enabled:
            logger.warning("TTS is disabled. Returning empty audio.")
            # 빈 오디오 반환 (테스트용)
            yield np.zeros(1600, dtype=np.int16)
            return
        
        try:
            # ElevenLabs 스트리밍 생성 (최신 API 사용)
            # text_to_speech 메서드 사용
            audio_stream = self.client.text_to_speech.convert(
                voice_id=self.voice_id,
                text=text,
                model_id=self.model_id,
                output_format="pcm_16000"  # 16kHz PCM
            )
            
            # 스트림을 numpy 배열로 변환
            chunk_size = 1600  # 100ms chunks (16kHz * 0.1s = 1600 samples)
            buffer = bytearray()
            
            for chunk in audio_stream:
                buffer.extend(chunk)
                
                # 충분한 데이터가 모이면 yield
                while len(buffer) >= chunk_size * 2:  # int16 = 2 bytes
                    chunk_bytes = bytes(buffer[:chunk_size * 2])
                    buffer = buffer[chunk_size * 2:]
                    
                    # bytes → numpy int16 배열
                    audio_array = np.frombuffer(chunk_bytes, dtype=np.int16)
                    yield audio_array
            
            # 남은 데이터 처리
            if len(buffer) > 0:
                audio_array = np.frombuffer(bytes(buffer), dtype=np.int16)
                yield audio_array
                
        except Exception as e:
            logger.error(f"TTS error: {e}", exc_info=True)
            # 에러 시 빈 오디오 반환
            yield np.zeros(1600, dtype=np.int16)

