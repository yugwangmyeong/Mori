"""
AudioEncoder - 버퍼 기반 청크 생성기
WebRTC AudioFrame을 OpenAI Realtime STT 입력 형식으로 변환

입력: av.AudioFrame (48kHz s16 mono/stereo, 가변 길이)
출력: List[bytes] (각각 960 bytes = 480 samples * 2 bytes), 메타(peak, rms, zero_ratio)
규격: 24kHz mono PCM16 LE, 20ms 단위 (480 samples = 960 bytes)

핵심 원칙:
- 프레임마다 강제로 자르지 않고, 링버퍼에 누적
- 정확히 20ms(480 samples)가 쌓일 때마다 청크 방출
- 연속성 유지 (프레임 경계를 넘어서 연속된 스트림)
"""
import logging
import numpy as np
from av import AudioFrame
from scipy.signal import resample_poly
from math import gcd
from typing import Tuple, Optional, List
from collections import deque

logger = logging.getLogger(__name__)


class AudioEncoder:
    """
    버퍼 기반 오디오 인코더 (24kHz, 20ms 청크)
    
    프레임을 받아서 버퍼에 누적하고, 정확히 20ms(480 samples)가 쌓일 때마다 청크를 방출합니다.
    연속성을 유지하여 프레임 경계를 넘어서 연속된 스트림을 생성합니다.
    """
    
    TARGET_SAMPLE_RATE = 24000
    CHUNK_SAMPLES = 480  # 20ms @ 24kHz = 480 samples
    CHUNK_BYTES = 960  # 480 samples * 2 bytes
    
    def __init__(self, digital_gain_db: float = 0.0):
        """
        Args:
            digital_gain_db: 디지털 게인 (dB). peak가 3000~15000 범위로 조정하기 위해 사용
        """
        self.buffer = np.array([], dtype=np.int16)  # int16 버퍼 (링버퍼)
        self.digital_gain = 10.0 ** (digital_gain_db / 20.0)  # dB → linear gain
    
    def process_frame(self, frame: AudioFrame) -> Tuple[List[bytes], dict]:
        """
        AudioFrame을 처리하고, 20ms 청크가 완성되면 반환
        
        Args:
            frame: WebRTC AudioFrame (48kHz s16 mono/stereo, 가변 길이)
        
        Returns:
            (chunks, metadata)
            - chunks: List[bytes] - 완성된 20ms 청크 리스트 (각각 960 bytes)
            - metadata: dict - 오디오 메타데이터
        """
        try:
            # 1. 업스트림 프레임 정보 수집 (디버깅용)
            upstream_info = {
                'sample_rate': frame.sample_rate,
                'format': str(frame.format) if hasattr(frame, 'format') else 'unknown',
                'samples': frame.samples if hasattr(frame, 'samples') else 0
            }
            
            # 2. frame.to_ndarray() 결과를 shape 기반으로 mono 1D로 정규화
            audio = frame.to_ndarray()
            upstream_info['dtype'] = str(audio.dtype)
            upstream_info['shape'] = audio.shape
            
            mono_audio = _to_mono(audio)
            upstream_info['mono_samples'] = len(mono_audio)
            
            # 3. int16 변환 및 게인 적용
            if mono_audio.dtype == np.int16:
                # int16인 경우: 스케일링 절대 금지, float로 변환 후 리샘플
                audio_float = mono_audio.astype(np.float32) / 32768.0
                mono_peak = int(np.max(np.abs(mono_audio))) if len(mono_audio) > 0 else 0
            elif mono_audio.dtype in (np.float32, np.float64):
                # float인 경우: clip(-1,1) 후 처리
                audio_float = np.clip(mono_audio, -1.0, 1.0)
                pcm16_temp = (audio_float * 32767.0).astype(np.int16)
                audio_float = pcm16_temp.astype(np.float32) / 32768.0
                mono_peak = int(np.max(np.abs(pcm16_temp))) if len(pcm16_temp) > 0 else 0
            else:
                # 기타 타입: int16로 변환 후 처리
                pcm16_temp = _to_int16(mono_audio)
                audio_float = pcm16_temp.astype(np.float32) / 32768.0
                mono_peak = int(np.max(np.abs(pcm16_temp))) if len(pcm16_temp) > 0 else 0
            
            upstream_info['mono_peak'] = mono_peak
            upstream_info['mono_rms'] = float(np.sqrt(np.mean((audio_float) ** 2))) if len(audio_float) > 0 else 0.0
            upstream_info['mono_range'] = [int(np.min(mono_audio)), int(np.max(mono_audio))] if len(mono_audio) > 0 else [0, 0]
            
            # 4. 디지털 게인 적용 (입력 음량 증가)
            if self.digital_gain != 1.0:
                audio_float = audio_float * self.digital_gain
                audio_float = np.clip(audio_float, -1.0, 1.0)  # 클리핑 방지
            
            # 5. 리샘플링 (48k→24k: up=1 down=2)
            if frame.sample_rate == 48000:
                resampled_float = _resample_audio(audio_float, 48000, 24000)
            elif frame.sample_rate == 24000:
                resampled_float = audio_float
            else:
                logger.warning(f"Unexpected sample rate: {frame.sample_rate}, expected 48000 or 24000")
                return [], {'upstream_info': upstream_info}
            
            # 6. int16로 변환 (리샘플 후)
            resampled_float = np.clip(resampled_float, -1.0, 1.0)
            pcm16_24k = (resampled_float * 32767.0).astype(np.int16)
            
            # 7. 버퍼에 추가
            self.buffer = np.concatenate([self.buffer, pcm16_24k])
            
            # 8. 20ms 청크 추출 (버퍼에 충분히 쌓일 때마다)
            chunks = []
            while len(self.buffer) >= self.CHUNK_SAMPLES:
                # 480 samples 추출 (20ms @ 24kHz)
                chunk_samples = self.buffer[:self.CHUNK_SAMPLES]
                chunk_bytes = chunk_samples.tobytes()
                chunks.append(chunk_bytes)
                
                # 버퍼에서 제거
                self.buffer = self.buffer[self.CHUNK_SAMPLES:]
            
            # 9. 메타데이터 계산 (리샘플된 전체 데이터 기준)
            if len(pcm16_24k) > 0:
                metadata = _calculate_metadata(pcm16_24k)
            else:
                metadata = {
                    'peak': 0,
                    'rms': 0.0,
                    'zero_ratio': 0.0,
                    'clipped_ratio': 0.0
                }
            
            metadata['upstream_info'] = upstream_info
            metadata['resampled_samples'] = len(pcm16_24k)
            
            return chunks, metadata
            
        except Exception as e:
            logger.error(f"Error encoding audio frame: {e}", exc_info=True)
            return [], {}
    
    def clear(self):
        """버퍼 초기화"""
        self.buffer = np.array([], dtype=np.int16)


# 하위 호환성을 위한 함수 (기존 코드용)
_global_encoder = None

def encode_audio_frame(frame: AudioFrame) -> Tuple[Optional[bytes], dict]:
    """
    레거시 함수: AudioFrame을 24kHz mono PCM16 LE로 변환 (가변 길이)
    
    주의: 이 함수는 하위 호환성을 위해 유지됩니다.
    새로운 코드는 AudioEncoder 클래스를 직접 사용하는 것을 권장합니다.
    
    Args:
        frame: WebRTC AudioFrame (48kHz s16 mono/stereo, 가변 길이)
    
    Returns:
        (bytes, metadata) 또는 (None, metadata)
        - bytes: 가변 길이 (24kHz mono PCM16 LE, 프레임 길이에 따라 다름)
        - metadata: {
            'peak': int,      # 최대 진폭
            'rms': float,     # RMS 에너지
            'zero_ratio': float,  # 제로 샘플 비율
            'clipped_ratio': float,  # 클리핑 비율
            'upstream_info': dict,  # 업스트림 프레임 정보 (디버깅용)
            'resampled_samples': int  # 리샘플 후 샘플 수
          }
    """
    try:
        # 1. 업스트림 프레임 정보 수집 (디버깅용)
        upstream_info = {
            'sample_rate': frame.sample_rate,
            'format': str(frame.format) if hasattr(frame, 'format') else 'unknown',
            'samples': frame.samples if hasattr(frame, 'samples') else 0
        }
        
        # 2. frame.to_ndarray() 결과를 shape 기반으로 mono 1D로 정규화
        audio = frame.to_ndarray()
        upstream_info['dtype'] = str(audio.dtype)
        upstream_info['shape'] = audio.shape
        
        mono_audio = _to_mono(audio)
        upstream_info['mono_samples'] = len(mono_audio)
        
        # 3. 핵심 원칙: int16이면 절대 스케일링 금지
        # - int16이면 그대로 mono만 만들고, 리샘플은 float로 변환해서 수행, 마지막에만 int16로 변환
        # - float면 clip(-1,1) * 32767 → int16
        
        if mono_audio.dtype == np.int16:
            # int16인 경우: 스케일링 절대 금지, float로 변환 후 리샘플
            # int16 범위 [-32768, 32767]를 [-1.0, 1.0]으로 정규화 (스케일링 아님, 단순 변환)
            audio_float = mono_audio.astype(np.float32) / 32768.0
            # mono 변환 후 peak/rms 확인 (디버깅용, 원본 int16 기준)
            mono_peak = int(np.max(np.abs(mono_audio))) if len(mono_audio) > 0 else 0
            mono_rms = float(np.sqrt(np.mean((audio_float) ** 2))) if len(audio_float) > 0 else 0.0
        elif mono_audio.dtype in (np.float32, np.float64):
            # float인 경우: clip(-1,1) 후 int16로 변환, 그 다음 리샘플
            audio_float = np.clip(mono_audio, -1.0, 1.0)
            # float를 int16로 변환 (리샘플 전에)
            pcm16_temp = (audio_float * 32767.0).astype(np.int16)
            # 다시 float로 변환 (리샘플용)
            audio_float = pcm16_temp.astype(np.float32) / 32768.0
            mono_peak = int(np.max(np.abs(pcm16_temp))) if len(pcm16_temp) > 0 else 0
            mono_rms = float(np.sqrt(np.mean((audio_float) ** 2))) if len(audio_float) > 0 else 0.0
        else:
            # 기타 타입: int16로 변환 후 처리
            pcm16_temp = _to_int16(mono_audio)
            audio_float = pcm16_temp.astype(np.float32) / 32768.0
            mono_peak = int(np.max(np.abs(pcm16_temp))) if len(pcm16_temp) > 0 else 0
            mono_rms = float(np.sqrt(np.mean((audio_float) ** 2))) if len(audio_float) > 0 else 0.0
        
        upstream_info['mono_peak'] = mono_peak
        upstream_info['mono_rms'] = mono_rms
        upstream_info['mono_range'] = [int(np.min(mono_audio)), int(np.max(mono_audio))] if len(mono_audio) > 0 else [0, 0]
        
        # 4. 리샘플링 (48k→24k: up=1 down=2)
        # 리샘플은 float(-1~1)에서만 수행
        if frame.sample_rate == 48000:
            resampled_float = _resample_audio(audio_float, 48000, 24000)
        elif frame.sample_rate == 24000:
            resampled_float = audio_float
        else:
            logger.warning(f"Unexpected sample rate: {frame.sample_rate}, expected 48000 or 24000")
            return None, {'upstream_info': upstream_info}
        
        # 마지막에만 int16로 변환 (리샘플 후)
        resampled_float = np.clip(resampled_float, -1.0, 1.0)
        pcm16_24k = (resampled_float * 32767.0).astype(np.int16)
        
        # 5. 리샘플 결과를 그대로 반환 (길이 조정 금지)
        # 버퍼 기반 청크화에서 20ms 단위로 추출할 예정
        # 프레임 길이가 40ms면 960 samples가 나와야 함 (480으로 자르면 절반 증발)
        
        # 6. 메타데이터 계산 (리샘플된 전체 데이터 기준)
        metadata = _calculate_metadata(pcm16_24k)
        metadata['upstream_info'] = upstream_info
        metadata['resampled_samples'] = len(pcm16_24k)  # 리샘플 후 샘플 수
        
        # 7. 최종 bytes는 little-endian PCM16 (가변 길이)
        result_bytes = pcm16_24k.tobytes()
        
        return result_bytes, metadata
        
    except Exception as e:
        logger.error(f"Error encoding audio frame: {e}", exc_info=True)
        return None, {}


def _to_mono(audio: np.ndarray) -> np.ndarray:
    """
    오디오 배열을 mono 1D로 변환 (shape 처리 단순화)
    
    aiortc/av의 frame.to_ndarray()는 (channels, samples) 형태로 오는 경우가 많음
    
    Args:
        audio: numpy array (다양한 shape 가능)
    
    Returns:
        1D numpy array (mono)
    """
    x = audio
    
    if x.ndim == 1:
        # 이미 mono
        return x
    elif x.ndim == 2:
        # 2D 배열: (channels, samples) 형태로 안전하게 맞춘 뒤 처리
        # aiortc/av는 보통 (channels, samples) 형태
        if x.shape[0] <= 2 and x.shape[1] > x.shape[0] * 10:
            # (channels, samples) 형태
            if x.shape[0] >= 2:
                return np.mean(x, axis=0)  # 채널 평균
            else:
                return x[0]
        elif x.shape[1] <= 2 and x.shape[0] > x.shape[1] * 10:
            # (samples, channels) 형태
            if x.shape[1] >= 2:
                return np.mean(x, axis=1)  # 채널 평균
            else:
                return x[:, 0]
        else:
            # 애매한 경우: shape[0]이 더 작으면 (channels, samples)로 가정
            if x.shape[0] < x.shape[1]:
                # (channels, samples)
                if x.shape[0] >= 2:
                    return np.mean(x, axis=0)
                else:
                    return x[0]
            else:
                # (samples, channels)
                if x.shape[1] >= 2:
                    return np.mean(x, axis=1)
                else:
                    return x[:, 0]
    else:
        # 예상치 못한 shape는 조용히 flatten
        return x.flatten()


# 경고 로그를 한 번만 출력하기 위한 플래그
_upstream_warning_logged = False

def _to_int16(audio: np.ndarray) -> np.ndarray:
    """
    오디오 배열을 int16으로 안전하게 변환
    
    규칙:
    - dtype=int16이면 스케일링 절대 금지(그대로)
    - float이면 clip(-1,1)*32767로 int16 변환
    - int32이면 정규화 후 int16
    
    Args:
        audio: numpy array (다양한 dtype 가능)
    
    Returns:
        int16 numpy array
    """
    global _upstream_warning_logged
    x = audio
    
    if x.dtype == np.int16:
        # int16인데 값이 -1~1인 비정상 케이스 체크
        x_max_abs = np.max(np.abs(x))
        if x_max_abs <= 1.0:
            # 원본이 이미 망가진 상태 - 복구하지 말고 그대로 둠
            # 경고는 한 번만 출력
            if not _upstream_warning_logged:
                logger.warning(f"Upstream audio quantized (int16 in [-1,1]). Fix capture pipeline.")
                _upstream_warning_logged = True
            return x.copy()
        else:
            # 정상 int16: 그대로 사용
            return x.copy()
    elif x.dtype in (np.float32, np.float64):
        # float 타입: -1.0~1.0 범위로 클리핑 후 스케일
        x = np.clip(x, -1.0, 1.0)
        return (x * 32767.0).astype(np.int16)
    elif x.dtype == np.int32:
        # int32: 범위 확인 후 안전한 int16 캐스팅
        x_max_abs = np.max(np.abs(x))
        if x_max_abs > 32767:
            # 스케일 다운 필요: int32 → float → normalize → int16
            x_float = x.astype(np.float32) / 2147483647.0
            x_float = np.clip(x_float, -1.0, 1.0)
            return (x_float * 32767.0).astype(np.int16)
        else:
            # 범위 내면 직접 캐스팅
            return x.astype(np.int16)
    else:
        # 기타 타입: float32로 변환 후 처리 (조용히)
        x = x.astype(np.float32)
        # 범위를 추정하여 정규화
        x_max_abs = np.max(np.abs(x))
        if x_max_abs > 1.0:
            x = x / x_max_abs
        x = np.clip(x, -1.0, 1.0)
        return (x * 32767.0).astype(np.int16)


def _resample_audio(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    """
    오디오 리샘플링 (float32 입력/출력)
    
    리샘플은 float32(-1~1)에서만 수행(resample_poly)
    48k→24k: up=1 down=2
    
    Args:
        x: 입력 오디오 배열 (float32, -1.0~1.0 범위)
        sr_in: 입력 샘플레이트
        sr_out: 출력 샘플레이트
    
    Returns:
        리샘플된 오디오 배열 (float32, -1.0~1.0 범위)
    """
    if sr_in == sr_out:
        return x
    
    g = gcd(sr_in, sr_out)
    up = sr_out // g
    down = sr_in // g
    return resample_poly(x, up, down)


def encode_audio_frame_for_vad(frame: AudioFrame) -> Tuple[Optional[bytes], dict]:
    """
    AudioFrame을 VAD용 16kHz 형식으로 변환 (webrtcvad는 16kHz만 지원)
    
    Args:
        frame: WebRTC AudioFrame (48kHz s16 mono/stereo)
    
    Returns:
        (bytes, metadata) 또는 (None, metadata)
        - bytes: 640 bytes (16kHz mono PCM16 LE, 320 samples)
        - metadata: dict (VAD용 메타데이터)
    """
    try:
        # 1. frame.to_ndarray() 결과를 shape 기반으로 mono 1D로 정규화
        audio = frame.to_ndarray()
        mono_audio = _to_mono(audio)
        
        # 2. dtype 기반 안전한 int16 변환
        pcm16 = _to_int16(mono_audio)
        
        # 3. 리샘플링 (48k→16k: up=1 down=3)
        if frame.sample_rate == 48000:
            # float32(-1~1)로 변환 후 리샘플
            pcm16_float = pcm16.astype(np.float32) / 32768.0
            resampled_float = _resample_audio(pcm16_float, 48000, 16000)
            # int16로 변환
            resampled_float = np.clip(resampled_float, -1.0, 1.0)
            pcm16_16k = (resampled_float * 32767.0).astype(np.int16)
        elif frame.sample_rate == 16000:
            pcm16_16k = pcm16
        else:
            logger.warning(f"VAD: Unexpected sample rate: {frame.sample_rate}, expected 48000 or 16000")
            return None, {}
        
        # 4. 리샘플 결과 길이를 반드시 320 samples로 고정 (20ms @ 16kHz)
        pcm16_320 = _ensure_320_samples(pcm16_16k)
        
        # 5. 메타데이터 계산
        metadata = _calculate_metadata(pcm16_320)
        
        # 6. 최종 bytes는 little-endian PCM16로 640 bytes 보장
        result_bytes = pcm16_320.tobytes()
        
        if len(result_bytes) != 640:
            logger.error(f"VAD: CRITICAL - Output size mismatch! Expected 640 bytes, got {len(result_bytes)}")
            return None, metadata
        
        return result_bytes, metadata
        
    except Exception as e:
        logger.error(f"VAD: Error encoding audio frame: {e}", exc_info=True)
        return None, {}


def _ensure_320_samples(pcm16: np.ndarray) -> np.ndarray:
    """
    리샘플 결과 길이를 반드시 320 samples로 고정(자르기/패딩) - VAD용
    
    Args:
        pcm16: PCM16 numpy array (16kHz)
    
    Returns:
        320 samples로 고정된 PCM16 array
    """
    target = 320  # 20ms @ 16kHz = 320 samples
    n = len(pcm16)
    
    if n == target:
        return pcm16
    elif n > target:
        return pcm16[:target]
    else:
        out = np.zeros(target, dtype=np.int16)
        out[:n] = pcm16
        return out


def _ensure_480_samples(pcm16: np.ndarray) -> np.ndarray:
    """
    리샘플 결과 길이를 반드시 480 samples로 고정(자르기/패딩)
    
    WebRTC 프레임은 보통 10ms이므로:
    - 48kHz 입력: 480 samples → 24kHz 리샘플: 240 samples
    - 24kHz 입력: 240 samples
    
    우리는 20ms (480 samples)가 필요하므로:
    - 240 samples면 zero-padding으로 480 samples로 확장
    - 480 samples 이상이면 자르기
    
    Args:
        pcm16: PCM16 numpy array (24kHz)
    
    Returns:
        480 samples로 고정된 PCM16 array
    """
    target = 480  # 20ms @ 24kHz = 480 samples
    n = len(pcm16)
    
    if n == target:
        return pcm16
    elif n > target:
        # 길이가 더 길면 앞부분만 사용 (또는 중간 부분)
        # 일관성을 위해 앞부분 사용
        return pcm16[:target]
    else:
        # n < target: zero-padding (뒤에 패딩)
        # 이는 WebRTC 10ms 프레임을 20ms로 확장하는 경우
        out = np.zeros(target, dtype=np.int16)
        out[:n] = pcm16
        return out


def _calculate_metadata(pcm16: np.ndarray) -> dict:
    """
    오디오 메타데이터 계산
    
    Args:
        pcm16: PCM16 numpy array (480 samples)
    
    Returns:
        {
            'peak': int,
            'rms': float,
            'zero_ratio': float,
            'clipped_ratio': float
        }
    """
    peak = int(np.max(np.abs(pcm16)))
    
    # RMS 계산
    pcm16_float = pcm16.astype(np.float32) / 32767.0
    rms = float(np.sqrt(np.mean(pcm16_float ** 2)))
    
    # Zero ratio 계산
    zero_count = np.sum(pcm16 == 0)
    zero_ratio = float(zero_count / len(pcm16))
    
    # Clipped ratio 계산
    clipped_count = np.sum(np.abs(pcm16) >= 32767)
    clipped_ratio = float(clipped_count / len(pcm16))
    
    return {
        'peak': peak,
        'rms': rms,
        'zero_ratio': zero_ratio,
        'clipped_ratio': clipped_ratio
    }

