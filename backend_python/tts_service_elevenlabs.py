"""
ElevenLabs TTS 서비스
MP3 음성 합성 API
"""
import logging
import os
from typing import Optional
import httpx

logger = logging.getLogger(__name__)


class ElevenLabsTTSService:
    """ElevenLabs TTS 서비스 클래스"""
    
    def __init__(self):
        self.api_key = os.getenv("ELEVENLABS_API_KEY")
        if not self.api_key:
            raise ValueError("ELEVENLABS_API_KEY environment variable is required")
        
        self.voice_id = os.getenv("ELEVENLABS_VOICE_ID", "4JJwo477JUAx3HV0T7n7")  
        self.model = os.getenv("ELEVENLABS_MODEL", "eleven_multilingual_v2")
        
        # API endpoint
        self.base_url = "https://api.elevenlabs.io/v1"
        
        logger.info(f"✅ ElevenLabs TTS initialized: voice_id={self.voice_id}, model={self.model}")
    
    async def synthesize_mp3(self, text: str) -> Optional[bytes]:
        """
        텍스트를 MP3 음성으로 변환
        
        Args:
            text: 변환할 텍스트
            
        Returns:
            MP3 바이트 데이터 (실패 시 None)
        """
        if not text or not text.strip():
            logger.warning("TTS: Empty text provided")
            return None
        
        # 텍스트는 이미 10자로 제한되어 들어옴
        text_clean = text.strip()
        
        try:
            url = f"{self.base_url}/text-to-speech/{self.voice_id}"
            
            headers = {
                "xi-api-key": self.api_key,
                "Content-Type": "application/json"
            }
            
            payload = {
                "text": text_clean,
                "model_id": self.model,
                "voice_settings": {
                    "stability": 0.5,
                    "similarity_boost": 0.75
                }
            }
            
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(url, json=payload, headers=headers)
                
                if response.status_code == 200:
                    mp3_bytes = response.content
                    logger.debug(f"TTS: Successfully generated MP3, size={len(mp3_bytes)} bytes")
                    return mp3_bytes
                else:
                    error_text = response.text[:200]
                    logger.error(f"TTS: API error {response.status_code}: {error_text}")
                    return None
                    
        except httpx.TimeoutException:
            logger.error("TTS: Request timeout (30s)")
            return None
        except Exception as e:
            logger.error(f"TTS: Synthesis error: {e}", exc_info=True)
            return None

