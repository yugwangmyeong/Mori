"""
WebRTC 연결 및 오디오 처리 핸들러
"""
import asyncio
import logging
import numpy as np
from typing import Optional, List, Callable
from collections import deque
from fastapi import WebSocket
from aiortc import RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, MediaStreamTrack, RTCDataChannel
from aiortc.contrib.media import MediaPlayer, MediaRelay
from aiortc.sdp import candidate_from_sdp
import json
import wave
import os
import time
from datetime import datetime

from audio_encoder import AudioEncoder, encode_audio_frame_for_vad
from realtime_stt_client import RealtimeSttClient
from vad_segmenter import VADSegmenter
import webrtcvad

logger = logging.getLogger(__name__)


# AudioChunkBuffer는 AudioEncoder 클래스로 대체됨


class AudioTrackReceiver(MediaStreamTrack):
    """WebRTC에서 받은 오디오 트랙을 처리하는 클래스 (로컬 VAD 모드: VAD로 말 끝 감지 후 commit)"""
    kind = "audio"
    
    def __init__(self, track, stt_client: Optional[RealtimeSttClient], mic_enabled_callback: Optional[Callable[[], bool]] = None, digital_gain_db: float = 6.0):
        super().__init__()
        self.track = track
        self.stt_client = stt_client  # STT 클라이언트
        self.mic_enabled_callback = mic_enabled_callback  # 마이크 상태 확인 콜백
        
        # 오디오 인코더 (버퍼 기반, 24kHz, 20ms 청크)
        # digital_gain_db: 입력 음량 증가 (peak 3000~15000 범위로 조정)
        self.audio_encoder = AudioEncoder(digital_gain_db=digital_gain_db)
        
        # VAD (Voice Activity Detection) - 16kHz용
        self.vad = webrtcvad.Vad(2)  # 모드 2 (0-3, 2가 적당)
        
        # VADSegmenter (말 끝 감지 후 commit)
        self.vad_segmenter: Optional[VADSegmenter] = None
        if stt_client:
            self.vad_segmenter = VADSegmenter(
                on_clear=lambda: stt_client.clear(),
                on_append=lambda chunk: stt_client.append_audio(chunk),
                on_commit=lambda: stt_client.commit(),
                on_get_buffered_ms=lambda: stt_client.get_stats().get('buffered_ms', 0),
                hangover_ms=500,
                min_commit_ms=100
            )
        
        # 통계 추적 (5초마다 로그)
        self._stats = {
            'peak_sum': 0,
            'rms_sum': 0.0,
            'zero_ratio_sum': 0.0,
            'clipped_ratio_sum': 0.0,
            'chunk_count': 0,
            'last_log_time': time.time()
        }
        
        # WebRTC 프레임 정보 추적 (첫 프레임만 상세 로그)
        self._first_frame_logged = False
        self._append_count = 0  # append 호출 카운터
        
    async def recv(self):
        """오디오 프레임 수신 - 서버 VAD 모드: append만 연속 전송"""
        frame = await self.track.recv()
        
        # STT 클라이언트가 없으면 프레임만 반환
        if not self.stt_client:
            return frame
        
        # 마이크가 꺼져 있으면 STT 처리 건너뛰기
        if self.mic_enabled_callback and not self.mic_enabled_callback():
            return frame
        
        # WebRTC 프레임 정보 로깅 (첫 프레임만 상세)
        if not self._first_frame_logged:
            upstream_info = {}
            try:
                audio = frame.to_ndarray()
                upstream_info = {
                    'sample_rate': frame.sample_rate,
                    'format': str(frame.format) if hasattr(frame, 'format') else 'unknown',
                    'samples': frame.samples if hasattr(frame, 'samples') else 0,
                    'dtype': str(audio.dtype),
                    'shape': audio.shape
                }
            except:
                pass
            logger.info(f"🎤 First WebRTC frame: sr={upstream_info.get('sample_rate')}Hz, "
                      f"shape={upstream_info.get('shape')}, dtype={upstream_info.get('dtype')}")
            self._first_frame_logged = True
        
        # STT용 24kHz 변환 및 20ms 청크 생성 (버퍼 기반)
        stt_chunks, stt_metadata = self.audio_encoder.process_frame(frame)
        
        if not stt_chunks:
            return frame
        
        # 오디오 에너지가 매우 낮으면 마이크가 꺼진 것으로 간주
        rms = stt_metadata.get('rms', 0.0)
        peak = stt_metadata.get('peak', 0)
        if rms < 0.001 and peak < 100:  # 매우 낮은 에너지
            return frame
        
        # 통계 업데이트
        self._update_stats(stt_metadata)
        
        # VAD용 16kHz 오디오 생성 (VAD 판단용)
        vad_bytes, vad_metadata = encode_audio_frame_for_vad(frame)
        is_speech = False
        if vad_bytes and len(vad_bytes) == 640:  # 16kHz, 20ms = 640 bytes
            try:
                is_speech = self.vad.is_speech(vad_bytes, 16000)
            except Exception as e:
                logger.debug(f"VAD detection error: {e}")
        
        # VADSegmenter로 처리 (말 끝 감지 시 자동 commit)
        if self.vad_segmenter and stt_chunks:
            for chunk_bytes in stt_chunks:
                # chunk_bytes 검증 (960 bytes @ 24kHz)
                if len(chunk_bytes) != 960:
                    logger.error(f"❌ Invalid chunk size: {len(chunk_bytes)} bytes (expected 960)")
                    continue
                
                # VADSegmenter에 전달 (말 끝 감지 시 commit 호출)
                await self.vad_segmenter.process_chunk(chunk_bytes, is_speech, stt_metadata)
        
        return frame
    
    def _update_stats(self, metadata: dict):
        """통계 업데이트 (5초마다 로그 - 로봇톤/정확도 체크리스트)"""
        if not metadata:
            return
        
        self._stats['peak_sum'] += metadata.get('peak', 0)
        self._stats['rms_sum'] += metadata.get('rms', 0.0)
        self._stats['zero_ratio_sum'] += metadata.get('zero_ratio', 0.0)
        self._stats['clipped_ratio_sum'] += metadata.get('clipped_ratio', 0.0)
        self._stats['chunk_count'] += 1
        
        # 5초마다 요약 로그 (로봇톤/정확도 체크리스트)
        current_time = time.time()
        if current_time - self._stats['last_log_time'] >= 5.0:
            if self._stats['chunk_count'] > 0:
                avg_peak = self._stats['peak_sum'] / self._stats['chunk_count']
                avg_rms = self._stats['rms_sum'] / self._stats['chunk_count']
                avg_zero_ratio = self._stats['zero_ratio_sum'] / self._stats['chunk_count']
                avg_clipped_ratio = self._stats['clipped_ratio_sum'] / self._stats['chunk_count']
                
                # 로봇톤/정확도 체크리스트 로그
                upstream_info = metadata.get('upstream_info', {})
                upstream_shape = upstream_info.get('shape', 'unknown')
                resampled_samples = metadata.get('resampled_samples', 0)
                
                logger.info(f"📊 Audio stats (5s): peak={avg_peak:.0f} (recommended: 3000~15000), "
                          f"rms={avg_rms:.4f}, zero_ratio={avg_zero_ratio:.2%}, "
                          f"clipped_ratio={avg_clipped_ratio:.2%}")
                logger.debug(f"   Upstream: shape={upstream_shape}, resampled_samples={resampled_samples}")
                
                # peak 권장 범위 체크
                if avg_peak < 3000:
                    logger.warning(f"⚠️ Low input level: peak={avg_peak:.0f} < 3000 (recommended: 3000~15000) → STT accuracy may drop")
                elif avg_peak > 15000:
                    logger.warning(f"⚠️ High input level: peak={avg_peak:.0f} > 15000 (may cause clipping)")
            
            # 통계 리셋
            self._stats = {
                'peak_sum': 0,
                'rms_sum': 0.0,
                'zero_ratio_sum': 0.0,
                'clipped_ratio_sum': 0.0,
                'chunk_count': 0,
                'last_log_time': current_time
            }
    

class AudioTrackSender(MediaStreamTrack):
    """TTS 오디오를 WebRTC로 송출하는 클래스"""
    kind = "audio"
    
    def __init__(self):
        super().__init__()
        self._queue = asyncio.Queue()
        self._closed = False
        
    async def recv(self):
        """오디오 프레임 송출 (20ms 단위)"""
        if self._closed:
            raise Exception("Track closed")
        
        # 큐에서 오디오 데이터 가져오기
        audio_data = await self._queue.get()
        return audio_data
    
    async def push_audio(self, audio_frame):
        """TTS에서 생성된 오디오를 큐에 추가"""
        if not self._closed:
            await self._queue.put(audio_frame)
    
    def close(self):
        """트랙 종료"""
        self._closed = True


class WebRTCHandler:
    """WebRTC 연결 및 오디오 처리 핸들러"""
    
    def __init__(self, session_id: str, websocket: Optional[WebSocket] = None, enable_stt: bool = True):
        self.session_id = session_id
        self.websocket = websocket  # WebSocket은 선택적 (DataChannel 사용 시 None)
        self.enable_stt = enable_stt  # STT 활성화 여부
        self.pc: Optional[RTCPeerConnection] = None
        self.data_channel: Optional[RTCDataChannel] = None  # DataChannel
        
        # STT 클라이언트 (Realtime Transcription)
        self.stt_client: Optional[RealtimeSttClient] = None
        self.receiver_task: Optional[asyncio.Task] = None
        
        # 서버 VAD 모드: VADSegmenter 사용 안 함
        
        # WAV 덤프 (디버깅용)
        self.debug_dump_wav = True  # 개발용 플래그
        self.stt_dump_seq = 0  # WAV 덤프 시퀀스 번호
        self.stt_accum_pcm16 = bytearray()  # WAV 덤프용 누적 버퍼
        
        # 카운터 검증
        self.queued_chunks = 0  # 큐에 넣은 청크 수
        self.sent_chunks = 0  # 실제로 전송한 청크 수
        self.appended_chunks = 0  # append한 청크 수
        
        # 오디오 송출 트랙
        self.audio_sender: Optional[AudioTrackSender] = None
        
        # 상태 관리
        self.is_speaking = False  # AI가 말하고 있는지
        self.current_turn_cancelled = False  # Barge-in 플래그
        self.mic_enabled = True  # 마이크 활성화 상태 (기본값: True)
        
    async def handle_connection(self):
        """WebRTC 연결 처리"""
        self.pc = RTCPeerConnection()
        
        # 오디오 송출 트랙 생성
        self.audio_sender = AudioTrackSender()
        self.pc.addTrack(self.audio_sender)
        
        # ICE candidate 처리
        @self.pc.on("icecandidate")
        async def on_icecandidate(candidate):
            if candidate:
                # WebSocket이 있으면 WebSocket으로, 없으면 DataChannel로
                # 하지만 ICE candidates는 연결 전에 발생하므로 여기서는 무시
                # (ICE candidates는 이미 SDP에 포함되어 있음)
                pass
        
        # 연결 상태 변경
        @self.pc.on("connectionstatechange")
        async def on_connectionstatechange():
            logger.info(f"Connection state: {self.pc.connectionState}")
            if self.pc.connectionState == "failed":
                await self.cleanup()
        
        # DataChannel 이벤트 핸들러 설정
        self._setup_datachannel_handlers()
        
        # 오디오 트랙 수신 처리
        @self.pc.on("track")
        async def on_track(track):
            if track.kind == "audio":
                logger.info("Audio track received")
                # STT 클라이언트가 있으면 AudioTrackReceiver 생성 (서버 VAD 모드)
                if self.stt_client:
                    receiver = AudioTrackReceiver(
                        track, 
                        self.stt_client,
                        mic_enabled_callback=lambda: self.mic_enabled,
                        digital_gain_db=6.0  # 입력 게인 6dB (peak 3000~15000 범위로 조정)
                    )
                    asyncio.create_task(self._audio_receive_loop(receiver))
                else:
                    logger.warning("STT client not initialized, audio processing skipped")
        
        # WebSocket이 있는 경우에만 시그널링 메시지 처리 (이전 방식)
        if self.websocket:
            while True:
                try:
                    message = await self.websocket.receive_json()
                    await self._handle_signaling(message)
                except Exception as e:
                    logger.error(f"Signaling error: {e}", exc_info=True)
                    break
    
    async def _audio_receive_loop(self, receiver: AudioTrackReceiver):
        """오디오 수신 루프"""
        frame_count = 0
        last_log_time = 0
        try:
            while True:
                frame = await receiver.recv()
                frame_count += 1
                
                # 1초마다 프레임 수신 상태 로그 (디버깅용)
                import time
                current_time = time.time()
                if current_time - last_log_time >= 1.0:
            
                    last_log_time = current_time
                
                # recv() 내부에서 이미 처리됨
        except Exception as e:
            logger.error(f"Audio receive loop error: {e}")
            logger.info(f"📊 오디오 수신 루프 종료 (총 {frame_count}개 프레임 수신됨)")
    
    async def _handle_ice_candidate(self, msg: dict):
        """
        ICE candidate 처리
        msg can be:
          {type:'ice-candidate', candidate:'candidate:...', sdpMid:'0', sdpMLineIndex:0}
        or
          {type:'ice-candidate', candidate:{candidate:'candidate:...', sdpMid:'0', sdpMLineIndex:0}}
        """
        c = msg.get("candidate")
        if not c:
            logger.debug("ICE candidate message missing candidate field")
            return

        # normalize nested format
        if isinstance(c, dict):
            candidate_sdp = c.get("candidate")
            sdp_mid = c.get("sdpMid")
            sdp_mline_index = c.get("sdpMLineIndex")
        else:
            candidate_sdp = c
            sdp_mid = msg.get("sdpMid")
            sdp_mline_index = msg.get("sdpMLineIndex")

        if not candidate_sdp:
            logger.warning("ICE candidate message missing candidate SDP string")
            return

        # PeerConnection이 유효한지 확인
        if not self.pc or self.pc.connectionState == "closed":
            logger.debug("PeerConnection not available or closed, skipping ICE candidate")
            return

        try:
            # candidate_from_sdp로 파싱
            cand = candidate_from_sdp(candidate_sdp)
            if sdp_mid is not None:
                cand.sdpMid = sdp_mid
            if sdp_mline_index is not None:
                cand.sdpMLineIndex = sdp_mline_index
            
            await self.pc.addIceCandidate(cand)
            logger.info("ICE candidate added (mid=%s, mline=%s)", sdp_mid, sdp_mline_index)
        except Exception as e:
            # candidate 처리 실패해도 세션을 끊지 않음
            logger.warning("Failed to add ICE candidate: %s | msg=%s", e, msg)
    
    async def handle_offer(self, sdp_offer: str) -> str:
        """
        HTTP POST로 받은 offer를 처리하고 answer를 반환
        """
        # PeerConnection 생성
        self.pc = RTCPeerConnection()
        
        # 오디오 송출 트랙 생성
        self.audio_sender = AudioTrackSender()
        self.pc.addTrack(self.audio_sender)
        
        # DataChannel 이벤트 핸들러 설정
        self._setup_datachannel_handlers()
        
        # 연결 상태 변경
        @self.pc.on("connectionstatechange")
        async def on_connectionstatechange():
            logger.info(f"Connection state: {self.pc.connectionState}")
            if self.pc.connectionState == "failed":
                await self.cleanup()
        
        # STT 파이프라인 먼저 초기화 (오디오 트랙 핸들러 등록 전에)
        if self.enable_stt:
            try:
                await self._setup_stt_pipeline()
            except Exception as e:
                logger.error(f"Failed to setup STT during handle_offer: {e}", exc_info=True)
                # STT 실패해도 WebRTC 연결은 계속 진행
        else:
            logger.info("STT is disabled for this session - WebRTC call only")
        
        # 오디오 트랙 수신 처리 (STT 파이프라인 초기화 후)
        @self.pc.on("track")
        async def on_track(track):
            if track.kind == "audio":
                logger.info("✅ Audio track received from client")
                # STT 클라이언트가 있으면 AudioTrackReceiver 생성 (서버 VAD 모드)
                if self.stt_client:
                    receiver = AudioTrackReceiver(
                        track, 
                        self.stt_client,
                        mic_enabled_callback=lambda: self.mic_enabled,
                        digital_gain_db=6.0  # 입력 게인 6dB (peak 3000~15000 범위로 조정)
                    )
                    asyncio.create_task(self._audio_receive_loop(receiver))
                else:
                    logger.warning("STT client not initialized, audio processing skipped")
        
        # offer 설정
        offer = RTCSessionDescription(sdp=sdp_offer, type="offer")
        await self.pc.setRemoteDescription(offer)
        
        # answer 생성
        answer = await self.pc.createAnswer()
        await self.pc.setLocalDescription(answer)
        
        logger.info("✅ WebRTC answer 생성 완료")
        
        return self.pc.localDescription.sdp
    
    async def _wait_for_connection(self):
        """연결 완료 대기 (백그라운드 작업)"""
        try:
            # ICE 연결 완료 대기 (최대 10초)
            for _ in range(100):  # 100 * 0.1초 = 10초
                if self.pc and self.pc.connectionState == "connected":
                    logger.info("✅ WebRTC connection established")
                    break
                await asyncio.sleep(0.1)
        except Exception as e:
            logger.error(f"Error waiting for connection: {e}")
    
    def _setup_datachannel_handlers(self):
        """DataChannel 이벤트 핸들러 설정"""
        @self.pc.on("datachannel")
        def on_datachannel(channel: RTCDataChannel):
            logger.info(f"DataChannel received: {channel.label}")
            self.data_channel = channel
            
            @channel.on("message")
            def on_message(message):
                try:
                    if isinstance(message, str):
                        data = json.loads(message)
                        logger.debug(f"DataChannel message received: {data}")
                        # 마이크 상태 메시지 처리
                        asyncio.create_task(self._handle_datachannel_message(data))
                except Exception as e:
                    logger.error(f"Error processing DataChannel message: {e}")
            
            @channel.on("open")
            def on_open():
                logger.info("✅ DataChannel opened")
            
            @channel.on("close")
            def on_close():
                logger.info("DataChannel closed")
    
    async def _handle_datachannel_message(self, data: dict):
        """DataChannel 메시지 처리"""
        msg_type = data.get("type")
        
        if msg_type == "mic.enabled" or msg_type == "mic.on":
            self.mic_enabled = True
            logger.info("🎤 Microphone enabled")
        elif msg_type == "mic.disabled" or msg_type == "mic.off":
            self.mic_enabled = False
            logger.info("🔇 Microphone disabled")
            # 마이크가 꺼지면 STT 클라이언트 버퍼 정리 (server_vad 모드에서는 clear 사용 안 함)
            # server_vad 모드에서는 서버가 자동으로 처리하므로 별도 작업 불필요
        elif msg_type == "mic.toggle":
            self.mic_enabled = not self.mic_enabled
            logger.info(f"🎤 Microphone toggled: {'ON' if self.mic_enabled else 'OFF'}")
        # 기타 메시지는 무시
    
    async def _send_datachannel_message(self, message: dict):
        """DataChannel로 메시지 전송"""
        if self.data_channel and self.data_channel.readyState == "open":
            try:
                message_str = json.dumps(message)
                self.data_channel.send(message_str)
                logger.debug(f"📤 DataChannel sent: {message.get('type', 'unknown')}")
            except Exception as e:
                logger.error(f"❌ Error sending DataChannel message: {e}", exc_info=True)
        else:
            logger.warning(f"⚠️ DataChannel is not open (state: {self.data_channel.readyState if self.data_channel else 'None'}), cannot send message: {message.get('type', 'unknown')}")
    
    async def _handle_signaling(self, message: dict):
        """WebRTC 시그널링 메시지 처리 (WebSocket 방식용)"""
        msg_type = message.get("type")
        
        if msg_type == "offer":
            # 클라이언트로부터 offer 받음
            offer = RTCSessionDescription(
                sdp=message["sdp"],
                type="offer"
            )
            await self.pc.setRemoteDescription(offer)
            
            # answer 생성
            answer = await self.pc.createAnswer()
            await self.pc.setLocalDescription(answer)
            
            # answer 전송 (WebSocket)
            if self.websocket:
                await self.websocket.send_json({
                    "type": "answer",
                    "sdp": self.pc.localDescription.sdp
                })
            
        elif msg_type == "ice-candidate":
            # ICE candidate 처리
            await self._handle_ice_candidate(message)
    
    async def _setup_stt_pipeline(self):
        """STT 파이프라인 초기화 (로컬 VAD 모드: VAD로 말 끝 감지 후 commit)"""
        if not self.enable_stt:
            return
        
        logger.info(f"[STT Setup] Starting STT pipeline setup for session: {self.session_id} (Local VAD mode)")
        
        try:
            # STT 클라이언트 생성 및 연결
            self.stt_client = RealtimeSttClient(self.session_id)
            await self.stt_client.connect()
            logger.info("✅ [STT Setup] STT client connected (Local VAD mode)")
            
            # 로컬 VAD 모드: VADSegmenter가 말 끝을 감지하면 commit 호출
            
            # Receiver 워커 시작
            self.receiver_task = asyncio.create_task(
                self._stt_receiver_worker()
            )
            logger.info("✅ [STT Setup] STT receiver worker started")
            
        except Exception as e:
            logger.error(f"❌ [STT Setup] Failed to setup STT pipeline: {e}", exc_info=True)
            self.stt_client = None
    
    # 서버 VAD 모드: clear/commit 콜백 제거 (append만 연속 전송)
    
    async def _dump_wav_file(self):
        """WAV 덤프 저장 (OpenAI로 보내는 최종 24kHz PCM16)"""
        try:
            if len(self.stt_accum_pcm16) == 0:
                return
            
            # 디렉토리 생성
            dump_dir = "stt_dumps"
            os.makedirs(dump_dir, exist_ok=True)
            
            # 파일명 생성
            self.stt_dump_seq += 1
            stt_stats = self.stt_client.get_stats() if self.stt_client else {}
            sample_rate = stt_stats.get('sample_rate', 24000)  # 24kHz 기본
            duration_ms = self.appended_chunks * 20  # 20ms per chunk
            filename = f"{dump_dir}/stt_session_{self.session_id}_{self.stt_dump_seq:04d}_{duration_ms}ms_{sample_rate//1000}k.wav"
            
            # WAV 파일 저장 (24kHz 기준) - 재생 시 24kHz로 설정해야 정상 음성처럼 들림
            with wave.open(filename, 'wb') as wav_file:
                wav_file.setnchannels(1)  # mono
                wav_file.setsampwidth(2)  # 16-bit = 2 bytes
                wav_file.setframerate(sample_rate)  # 24kHz (중요: 재생 시 같은 rate로 설정)
                wav_file.writeframes(bytes(self.stt_accum_pcm16))
            
            if os.path.exists(filename):
                file_size = os.path.getsize(filename)
                logger.debug(f"WAV dumped: {filename} ({duration_ms}ms, {file_size} bytes, {sample_rate}Hz)")
        
        except Exception as e:
            logger.error(f"STT: Error dumping WAV: {e}", exc_info=True)
    
    async def _stt_receiver_worker(self):
        """STT 결과 수신 워커 (partial/final 전사 결과 처리)"""
        if not self.stt_client:
            return
        
        # STT 통계 모니터링 태스크 시작 (10초마다 확인)
        async def monitor_stt_stats():
            while True:
                await asyncio.sleep(10.0)
                if self.stt_client:
                    stats = self.stt_client.get_stats()
                    appended_chunks = stats.get('appended_chunks', 0)
                    buffered_ms = stats.get('buffered_ms', 0)
                    if appended_chunks == 0:
                        logger.warning(f"⚠️ STT stats check: appended_chunks=0 (no audio sent to STT!)")
                    else:
                        logger.info(f"📊 STT stats: {appended_chunks} chunks appended, {buffered_ms}ms buffered")
        
        monitor_task = asyncio.create_task(monitor_stt_stats())
        
        try:
            await self.stt_client.start_receiver_loop(
                on_partial=self._on_stt_partial,
                on_final=self._on_stt_final,
                on_error=self._on_stt_error
            )
        except asyncio.CancelledError:
            logger.debug("STT receiver worker cancelled")
            monitor_task.cancel()
        except Exception as e:
            logger.error(f"STT receiver worker error: {e}", exc_info=True)
            monitor_task.cancel()
    
    async def _on_stt_partial(self, text: str):
        """STT partial 결과 처리"""
        if not text or not text.strip():
            return
        
        text_clean = text.strip()
        logger.info(f"📝 STT partial: {text_clean}")
        
        await self._send_datachannel_message({
            "type": "stt.partial",
            "text": text_clean
        })
    
    async def _on_stt_final(self, text: str):
        """STT final 결과 처리"""
        if not text or not text.strip():
            return
        
        text_clean = text.strip()
        logger.info(f"✅ STT final: {text_clean}")
        
        await self._send_datachannel_message({
            "type": "stt.final",
            "text": text_clean
        })
    
    async def _on_stt_error(self, error: Exception):
        """STT 에러 처리"""
        logger.error(f"STT error: {error}", exc_info=True)
        await self._send_datachannel_message({
            "type": "stt.error",
            "message": str(error)
        })
    
    async def cleanup(self):
        """리소스 정리"""
        logger.info(f"Cleaning up session: {self.session_id}")
        
        # 서버 VAD 모드: VADSegmenter 사용 안 함
        
        # STT 워커 정리
        if self.receiver_task:
            self.receiver_task.cancel()
            try:
                await self.receiver_task
            except asyncio.CancelledError:
                pass
            self.receiver_task = None
        
        # STT 클라이언트 종료
        if self.stt_client:
            try:
                await self.stt_client.close()
            except Exception as e:
                logger.warning(f"Error closing STT client: {e}")
            self.stt_client = None
        
        # WebRTC 연결 종료
        if self.pc:
            try:
                # 연결 상태 확인 후 안전하게 종료
                if self.pc.connectionState != "closed":
                    await self.pc.close()
            except Exception as e:
                logger.warning(f"Error closing PeerConnection: {e}")
            finally:
                self.pc = None
        
        # 오디오 송출 트랙 종료
        if self.audio_sender:
            try:
                self.audio_sender.close()
            except Exception as e:
                logger.warning(f"Error closing audio sender: {e}")
            finally:
                self.audio_sender = None
