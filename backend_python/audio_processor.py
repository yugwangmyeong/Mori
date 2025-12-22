"""
오디오 인코딩 처리 모듈
- WebRTC 프레임 (20ms) 처리
- stereo → mono 변환
- 48kHz → 16kHz 리샘플링
- float → PCM16 변환
"""
import logging
from typing import Optional
import numpy as np
from av import AudioFrame 
from scipy.signal import resample_poly
from math import gcd
import webrtcvad
# import resampy  # TTS 출력용 리샘플링
logger = logging.getLogger(__name__)


class AudioProcessor:
    """오디오 프레임 처리 클래스"""
    
    def __init__(self):
        self.input_sample_rate = 48000  # WebRTC 기본 샘플레이트
        self.output_sample_rate = 16000  # STT용 샘플레이트
        self.frame_duration_ms = 20  # WebRTC 프레임 길이
        self.vad = webrtcvad.Vad(2)  # VAD 모드 2 (0-3, 2가 적당)
        self.vad_frame_samples = 320  # 20ms @ 16kHz = 320 samples
        self.vad_frame_bytes = 640  # 320 samples * 2 bytes = 640 bytes
        
    def _to_mono_pcm16(self, frame: AudioFrame) -> np.ndarray:
        """
        AudioFrame을 mono PCM16으로 변환 (dtype 안전 처리)
        
        Args:
            frame: WebRTC AudioFrame
            
        Returns:
            PCM16 numpy array (mono, int16)
        """
        x = frame.to_ndarray()
        
        # (channels, samples) -> (samples,)
        if x.ndim == 2:
            if x.shape[0] >= 2:
                x = x.mean(axis=0)
            else:
                x = x[0]
        
        # dtype 안전 처리
        if x.dtype == np.int16:
            pcm16 = x
        elif x.dtype in (np.float32, np.float64):
            x = np.clip(x, -1.0, 1.0)
            pcm16 = (x * 32767.0).astype(np.int16)
        else:
            x = x.astype(np.float32)
            x = np.clip(x, -1.0, 1.0)
            pcm16 = (x * 32767.0).astype(np.int16)
        
        return pcm16
    
    def _ensure_20ms_16k(self, pcm16_16k: np.ndarray) -> np.ndarray:
        """
        16kHz PCM16 배열을 20ms(320 samples)로 고정
        
        Args:
            pcm16_16k: PCM16 numpy array (16kHz)
            
        Returns:
            320 samples로 고정된 PCM16 array
        """
        target = self.vad_frame_samples  # 320 samples (20ms @ 16kHz)
        n = len(pcm16_16k)
        
        if n == target:
            return pcm16_16k
        elif n > target:
            return pcm16_16k[:target]
        else:
            # n < target: zero-padding
            out = np.zeros(target, dtype=np.int16)
            out[:n] = pcm16_16k
            return out
    
    async def process_frame(self, frame: AudioFrame) -> Optional[np.ndarray]:
        """
        WebRTC 오디오 프레임 처리 (STT용)
        - stereo → mono
        - 48kHz → 16kHz
        - float32 → int16 (PCM16)
        
        Returns:
            PCM16 오디오 데이터 (16kHz, mono) 또는 None
        """
        try:
            # dtype 안전하게 mono PCM16 변환
            pcm16 = self._to_mono_pcm16(frame)
            
            # 48kHz → 16kHz 리샘플링
            if frame.sample_rate == self.input_sample_rate:
                resampled = self.resample_audio(
                    pcm16.astype(np.float32),
                    self.input_sample_rate,
                    self.output_sample_rate
                )
                return resampled.astype(np.int16)
            else:
                # 이미 16kHz인 경우
                return pcm16
                
        except Exception as e:
            logger.error(f"Error processing audio frame: {e}", exc_info=True)
            return None
    
    async def prepare_output_frame(self, audio_data: np.ndarray) -> AudioFrame:
        """
        TTS 오디오를 WebRTC 출력 형식으로 변환
        - 16kHz → 48kHz 리샘플링
        - int16 → float32
        - mono → stereo (필요시)
        
        Args:
            audio_data: TTS 오디오 (16kHz, mono, int16)
            
        Returns:
            WebRTC AudioFrame (48kHz, stereo, float32)
        """
        try:
            # int16 → float32 변환
            audio_float = audio_data.astype(np.float32) / 32767.0
            audio_float = np.clip(audio_float, -1.0, 1.0)
            
            # 16kHz → 48kHz 리샘플링
            if len(audio_float) > 0:
                resampled = resampy.resample(
                    audio_float,
                    self.output_sample_rate,
                    self.input_sample_rate
                )
            else:
                resampled = audio_float
            
            # mono → stereo 변환
            if len(resampled.shape) == 1:
                stereo = np.stack([resampled, resampled])
            else:
                stereo = resampled
            
            # AudioFrame 생성
            frame = AudioFrame.from_ndarray(
                stereo,
                layout="stereo",
                sample_rate=self.input_sample_rate
            )
            
            return frame
            
        except Exception as e:
            logger.error(f"Error preparing output frame: {e}", exc_info=True)
            # 빈 프레임 반환
            empty_audio = np.zeros((2, int(self.input_sample_rate * self.frame_duration_ms / 1000)), dtype=np.float32)
            return AudioFrame.from_ndarray(
                empty_audio,
                layout="stereo",
                sample_rate=self.input_sample_rate
            )

    def to_pcm16_16k_mono(self, frame: AudioFrame) -> Optional[bytes]:
        """
        VAD 판단용 최소 변환 (가볍게)
        - WebRTC 프레임을 16kHz mono PCM16 bytes로 변환
        - 항상 20ms(320 samples = 640 bytes)로 정규화
        
        Returns:
            PCM16 bytes (16kHz, mono, 20ms = 640 bytes) 또는 None
        """
        try:
            # dtype 안전하게 mono PCM16 변환
            pcm16 = self._to_mono_pcm16(frame)
            
            # 48kHz → 16kHz 리샘플링
            if frame.sample_rate == self.input_sample_rate:
                resampled = self.resample_audio(
                    pcm16.astype(np.float32),
                    self.input_sample_rate,
                    self.output_sample_rate
                )
                pcm16_16k = resampled.astype(np.int16)
            else:
                # 이미 16kHz인 경우
                pcm16_16k = pcm16
            
            # 20ms(320 samples)로 길이 고정
            pcm16_20ms = self._ensure_20ms_16k(pcm16_16k)
            
            # bytes로 변환 (항상 640 bytes)
            return pcm16_20ms.tobytes()
                
        except Exception as e:
            logger.error(f"Error converting frame to PCM16: {e}", exc_info=True)
            return None
    
    @staticmethod
    def resample_audio(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
        if sr_in == sr_out:
            return x
        g = gcd(sr_in, sr_out)
        up = sr_out // g
        down = sr_in // g
        return resample_poly(x, up, down)
