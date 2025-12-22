"""
STT (Speech-to-Text) 서비스
OpenAI Whisper API 사용
"""
import logging
import os
import base64
import io
import wave
import numpy as np
from openai import OpenAI

logger = logging.getLogger(__name__)


class STTService:
    """STT 서비스 클래스"""
    
    def __init__(self):
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise ValueError("OPENAI_API_KEY environment variable is required")
        
        self.client = OpenAI(api_key=api_key)
        self.sample_rate = 16000  # Whisper는 16kHz 권장
    
    async def transcribe(self, audio_data: np.ndarray) -> str:
        """
        오디오를 텍스트로 변환
        
        Args:
            audio_data: PCM16 오디오 데이터 (16kHz, mono)
            
        Returns:
            전사된 텍스트
        """
        try:
            # numpy 배열을 WAV 형식으로 변환
            wav_buffer = self._numpy_to_wav(audio_data)
            
            # OpenAI Whisper API 호출
            wav_buffer.seek(0)
            transcript = self.client.audio.transcriptions.create(
                model="whisper-1",
                file=("audio.wav", wav_buffer, "audio/wav"),
                language="ko"  # 한국어 지정 (선택사항)
            )
            
            text = transcript.text.strip()
            logger.info(f"STT result: {text}")
            return text
            
        except Exception as e:
            logger.error(f"STT error: {e}", exc_info=True)
            return ""
    
    def _numpy_to_wav(self, audio_data: np.ndarray) -> io.BytesIO:
        """
        numpy 배열을 WAV 파일로 변환
        
        Args:
            audio_data: PCM16 오디오 데이터
            
        Returns:
            WAV 파일 bytes buffer
        """
        buffer = io.BytesIO()
        
        with wave.open(buffer, 'wb') as wav_file:
            wav_file.setnchannels(1)  # mono
            wav_file.setsampwidth(2)  # 16-bit (2 bytes)
            wav_file.setframerate(self.sample_rate)
            wav_file.writeframes(audio_data.tobytes())
        
        buffer.seek(0)
        return buffer

