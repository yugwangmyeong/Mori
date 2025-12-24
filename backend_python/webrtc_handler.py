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

from audio_encoder import AudioEncoder
from realtime_stt_client import RealtimeSttClient
from llm_service import LLMService
from typing import Optional, Callable, Awaitable
logger = logging.getLogger(__name__)


# AudioChunkBuffer는 AudioEncoder 클래스로 대체됨


class AudioTrackReceiver(MediaStreamTrack):
    """WebRTC에서 받은 오디오 트랙을 처리하는 클래스 (server_vad 모드: 계속 append만 수행)"""
    kind = "audio"
    
    def __init__(self, track, stt_client: Optional[RealtimeSttClient], mic_enabled_callback: Optional[Callable[[], bool]] = None, digital_gain_db: float = 6.0):
        super().__init__()
        self.track = track
        self.stt_client = stt_client  # STT 클라이언트
        self.mic_enabled_callback = mic_enabled_callback  # 마이크 상태 확인 콜백
        
        # 오디오 인코더 (버퍼 기반, 24kHz, 20ms 청크)
        # digital_gain_db: 입력 음량 증가 (peak 3000~15000 범위로 조정)
        self.audio_encoder = AudioEncoder(digital_gain_db=digital_gain_db)
    
    async def recv(self):
        """오디오 프레임 수신 - server_vad 모드: 계속 append만 수행 (commit 없음)"""
        frame = await self.track.recv()
        
        # STT 클라이언트가 없으면 프레임만 반환
        if not self.stt_client:
            return frame
        
        # 마이크가 꺼져 있으면 STT 처리 건너뛰기
        if self.mic_enabled_callback and not self.mic_enabled_callback():
            return frame
        
        # STT용 24kHz 변환 및 20ms 청크 생성 (버퍼 기반)
        stt_chunks, stt_metadata = self.audio_encoder.process_frame(frame)
        
        if not stt_chunks:
            return frame
        
        # 오디오 에너지가 매우 낮으면 마이크가 꺼진 것으로 간주
        rms = stt_metadata.get('rms', 0.0)
        peak = stt_metadata.get('peak', 0)
        if rms < 0.001 and peak < 100:  # 매우 낮은 에너지
            return frame
        
        # server_vad 모드: 계속 append만 수행 (서버가 턴 판단)
        if stt_chunks:
            for chunk_bytes in stt_chunks:
                # chunk_bytes 검증 (960 bytes @ 24kHz)
                if len(chunk_bytes) != 960:
                    continue
                
                # append만 수행 (commit은 서버가 판단)
                await self.stt_client.append_audio(chunk_bytes)
        
        return frame
    
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
        
        # 로컬 VAD 모드: VADSegmenter가 말 끝을 감지하면 commit 호출
        
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
        
        # LLM 서비스
        self.llm_service: Optional[LLMService] = None
        
        # 턴 상태 머신 (server_vad 기반)
        self.turn_id = 0  # 현재 턴 ID (증가값)
        self.in_speech = False  # 현재 발화 중인지
        self.turn_text_buffer = ""  # 현재 턴 누적 텍스트
        self.awaiting_final = False  # speech_stopped 이후 final/completed 기다리는 상태
        self.final_timeout_task: Optional[asyncio.Task] = None  # final 타임아웃 태스크
        self._turn_lock = asyncio.Lock()  # 턴 상태 접근 락
        
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
                # STT 클라이언트가 있으면 AudioTrackReceiver 생성 (server_vad 모드)
                if self.stt_client:
                    receiver = AudioTrackReceiver(
                        track, 
                        self.stt_client,
                        mic_enabled_callback=lambda: self.mic_enabled,
                        digital_gain_db=6.0,  # 입력 게인 6dB (peak 3000~15000 범위로 조정)
                        on_segment_commit=self._handle_segment_commit
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
            # 정상 종료인 경우 (트랙 종료, 연결 종료 등)
            error_type = type(e).__name__
            error_msg = str(e) if str(e) else f"{error_type} (no message)"
            
            # 정상 종료로 보이는 예외는 에러가 아닌 정보 로그로 처리
            if error_type in ("MediaStreamError", "ConnectionClosed", "ConnectionClosedOK") or \
               "closed" in error_msg.lower() or "ended" in error_msg.lower():
                logger.info(f"Audio receive loop ended: {error_type} - {error_msg}")
            else:
                # 실제 에러인 경우만 에러 로그
                logger.error(f"Audio receive loop error: {error_type} - {error_msg}", exc_info=True)
            
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
                # STT 클라이언트가 있으면 AudioTrackReceiver 생성 (server_vad 모드)
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
    
    async def send_json(self, payload: dict):
        """
        DataChannel로 JSON 메시지 전송
        
        Args:
            payload: 전송할 딕셔너리 (JSON으로 직렬화됨)
        
        Returns:
            bool: 전송 성공 여부
        """
        # DataChannel 존재 확인
        if not self.data_channel:
            logger.warning(f"DC_SEND_SKIP channel_not_exist type={payload.get('type', 'unknown')}")
            return False
        
        # readyState 확인
        if self.data_channel.readyState != "open":
            state = self.data_channel.readyState
            logger.warning(f"DC_SEND_SKIP channel_not_open state={state} type={payload.get('type', 'unknown')}")
            return False
        
        try:
            # JSON 직렬화
            message_str = json.dumps(payload)
            message_bytes = len(message_str.encode('utf-8'))
            
            # 전송
            self.data_channel.send(message_str)
            
            # 성공 로그
            msg_type = payload.get('type', 'unknown')
            turn_id = payload.get('turn_id')
            if turn_id is not None:
                logger.info(f"DC_SEND_OK type={msg_type} turn_id={turn_id} bytes={message_bytes}")
            else:
                logger.info(f"DC_SEND_OK type={msg_type} bytes={message_bytes}")
            
            return True
            
        except Exception as e:
            msg_type = payload.get('type', 'unknown')
            logger.error(f"DC_SEND_ERR type={msg_type} error={str(e)}", exc_info=True)
            return False
    
    async def _send_datachannel_message(self, message: dict):
        """DataChannel로 메시지 전송 (기존 호환성 유지, 내부적으로 send_json 사용)"""
        await self.send_json(message)
    
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
        """STT 파이프라인 초기화 (server_vad 모드: Realtime STT가 턴을 판단)"""
        if not self.enable_stt:
            return
        
        logger.info(f"[STT Setup] Starting STT pipeline setup for session: {self.session_id} (server_vad mode)")
        
        try:
            # LLM 서비스 초기화
            self.llm_service = LLMService()
            logger.info("✅ [STT Setup] LLM service initialized")
            
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
    
    # server_vad 모드: Realtime STT가 턴을 판단
    
    async def _on_speech_started(self):
        """server_vad speech_started 이벤트 처리"""
        async with self._turn_lock:
            self.turn_id += 1
            self.in_speech = True
            self.turn_text_buffer = ""
            self.awaiting_final = False
            
            # 타임아웃 태스크 취소 (이전 턴의 타임아웃이 남아있을 수 있음)
            if self.final_timeout_task and not self.final_timeout_task.done():
                self.final_timeout_task.cancel()
                self.final_timeout_task = None
            
            logger.info(f"🔊 VAD_START turn_id={self.turn_id}")
            
            # 클라이언트로 전송
            await self.send_json({
                "type": "vad.speech_started",
                "turn_id": self.turn_id
            })
    
    async def _on_speech_stopped(self):
        """server_vad speech_stopped 이벤트 처리"""
        async with self._turn_lock:
            self.in_speech = False
            self.awaiting_final = True
            
            logger.info(f"🔇 VAD_STOP turn_id={self.turn_id} buffer_len={len(self.turn_text_buffer)}")
            
            # 클라이언트로 전송
            await self.send_json({
                "type": "vad.speech_stopped",
                "turn_id": self.turn_id
            })
            
            # final 타임아웃 시작 (2.0초)
            self.final_timeout_task = asyncio.create_task(self._handle_final_timeout())
    
    async def _handle_final_timeout(self):
        """speech_stopped 이후 final 타임아웃 처리 (2.0초 후 LLM 호출)"""
        try:
            await asyncio.sleep(2.0)
            
            async with self._turn_lock:
                # 이미 final이 왔으면 스킵
                if not self.awaiting_final:
                    return
                
                # 최종 텍스트 결정
                final_text = self.turn_text_buffer.strip()
                if not final_text:
                    final_text = "[inaudible]"
                
                text_len = len(final_text)
                logger.info(f"✅ STT_FINAL turn_id={self.turn_id} text_len={text_len} (timeout) text=\"{final_text}\"")
                
                # 클라이언트로 final 전송
                await self.send_json({
                    "type": "stt.final",
                    "turn_id": self.turn_id,
                    "text": final_text
                })
                
                self.awaiting_final = False
                current_turn_id = self.turn_id
            
            # 락 해제 후 LLM 호출
            await self._call_llm_for_turn(current_turn_id, final_text)
            
        except asyncio.CancelledError:
            # final이 와서 취소된 경우 정상 동작
            pass
        except Exception as e:
            logger.error(f"Final timeout error for turn {self.turn_id}: {e}", exc_info=True)
    
    async def _call_llm_for_turn(self, turn_id: int, transcript_text: str):
        """턴에 대해 LLM 호출 및 응답 전송"""
        if not self.llm_service:
            logger.warning(f"LLM service not available for turn {turn_id}")
            return
        
        try:
            logger.info(f"🤖 LLM_REQ turn_id={turn_id} input_chars={len(transcript_text)} input=\"{transcript_text}\"")
            
            # LLM 호출 (간단한 1회 요청)
            response_text = ""
            async for token in self.llm_service.stream_response(transcript_text):
                response_text += token
            
            logger.info(f"🤖 LLM_RESP turn_id={turn_id} output_chars={len(response_text)} output=\"{response_text}\"")
            
            # DataChannel로 응답 전송
            await self.send_json({
                "type": "llm.response",
                "turn_id": turn_id,
                "text": response_text
            })
            
        except Exception as e:
            logger.error(f"LLM call error for turn {turn_id}: {e}", exc_info=True)
            await self.send_json({
                "type": "llm.error",
                "turn_id": turn_id,
                "message": str(e)
            })
    
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
                on_error=self._on_stt_error,
                on_speech_started=self._on_speech_started,
                on_speech_stopped=self._on_speech_stopped
            )
        except asyncio.CancelledError:
            logger.debug("STT receiver worker cancelled")
            monitor_task.cancel()
        except Exception as e:
            logger.error(f"STT receiver worker error: {e}", exc_info=True)
            monitor_task.cancel()
    
    async def _on_stt_partial(self, text: str):
        """STT partial/delta 결과 처리 (턴 상태 머신 기반)"""
        if not text or not text.strip():
            return
        
        text_clean = text.strip()
        
        async with self._turn_lock:
            # in_speech 또는 awaiting_final 상태일 때만 누적
            if self.in_speech or self.awaiting_final:
                self.turn_text_buffer += text_clean
                total_len = len(self.turn_text_buffer)
                logger.info(f"📝 STT_DELTA turn_id={self.turn_id} delta=\"{text_clean}\" total_len={total_len} total=\"{self.turn_text_buffer}\"")
                
                # 프론트엔드로 partial 전송
                await self.send_json({
                    "type": "stt.partial",
                    "turn_id": self.turn_id,
                    "delta": text_clean,
                    "text": self.turn_text_buffer
                })
    
    async def _on_stt_final(self, text: str):
        """STT final/completed 결과 처리 (턴 상태 머신 기반, LLM 호출)"""
        text_clean = text.strip() if text else ""
        
        async with self._turn_lock:
            # awaiting_final 상태가 아니면 무시 (이미 처리된 턴)
            if not self.awaiting_final:
                logger.debug(f"STT final received but not awaiting_final, turn_id={self.turn_id}")
                return
            
            # 타임아웃 태스크 취소
            if self.final_timeout_task and not self.final_timeout_task.done():
                self.final_timeout_task.cancel()
                self.final_timeout_task = None
            
            # 최종 텍스트 결정 (final 텍스트 우선, 없으면 누적 버퍼 사용)
            final_text = text_clean if text_clean else self.turn_text_buffer.strip()
            if not final_text:
                final_text = "[inaudible]"
            
            text_len = len(final_text)
            logger.info(f"✅ STT_FINAL turn_id={self.turn_id} text_len={text_len} text=\"{final_text}\"")
            
            # awaiting_final 플래그 해제
            self.awaiting_final = False
            current_turn_id = self.turn_id
            
            # 프론트엔드로 final 전송
            await self.send_json({
                "type": "stt.final",
                "turn_id": current_turn_id,
                "text": final_text
            })
        
        # 락 해제 후 LLM 호출
        await self._call_llm_for_turn(current_turn_id, final_text)
    
    async def _on_stt_error(self, error: Exception):
        """STT 에러 처리"""
        logger.error(f"STT error: {error}", exc_info=True)
        await self.send_json({
            "type": "stt.error",
            "message": str(error)
        })
    
    async def cleanup(self):
        """리소스 정리"""
        logger.info(f"Cleaning up session: {self.session_id}")
        
        # 턴 상태 정리 (타임아웃 태스크 취소)
        async with self._turn_lock:
            if self.final_timeout_task and not self.final_timeout_task.done():
                self.final_timeout_task.cancel()
                try:
                    await self.final_timeout_task
                except asyncio.CancelledError:
                    pass
                self.final_timeout_task = None
        
        # server_vad 모드: Realtime STT가 턴을 판단
        
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
