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

from audio_processor import AudioProcessor
# TODO: 다음 단계에서 활성화
# from vad_processor import VADProcessor
# from stt_service import STTService
# from llm_service import LLMService
# from tts_service import TTSService

logger = logging.getLogger(__name__)


class AudioTrackReceiver(MediaStreamTrack):
    """WebRTC에서 받은 오디오 트랙을 처리하는 클래스 (VAD 기반 상태머신)"""
    kind = "audio"
    
    # 상태머신 상태
    STATE_IDLE = "IDLE"  # 말 안 함
    STATE_IN_SPEECH = "IN_SPEECH"  # 말 중
    
    def __init__(self, track, audio_processor: AudioProcessor, on_speech_end=None):
        super().__init__()
        self.track = track
        self.audio_processor = audio_processor
        self.on_speech_end = on_speech_end  # 말 끝 콜백 (audio_bytes: bytes) -> None
        
        # VAD 프레임 정규화 파라미터
        self.VAD_SR = 16000  # VAD 샘플레이트 (webrtcvad는 16kHz만 지원)
        self.VAD_FRAME_MS = 20  # VAD 프레임 길이 (10/20/30ms만 지원)
        self.VAD_BYTES = int(self.VAD_SR * (self.VAD_FRAME_MS / 1000.0) * 2)  # 640 bytes (16kHz * 20ms * 2 bytes/sample)
        self._vad_buf = bytearray()  # VAD 프레임 버퍼 (20ms 단위로 쪼개기 위해)
        
        # 상태머신 상태
        self._vad_state = self.STATE_IDLE
        self._speech_buf = bytearray()  # speech 구간 오디오 버퍼 (PCM16 bytes)
        
        # VAD 윈도우 (최근 400ms, 20프레임 * 20ms = 400ms)
        self._vad_window = deque(maxlen=20)  # 각 프레임의 speech 여부 (1=speech, 0=silence)
        
    async def recv(self):
        """오디오 프레임 수신 - VAD 기반 상태머신 (20ms 프레임 정규화)"""
        frame = await self.track.recv()
        
        # 검증 로그 (일시적, 디버깅용)
        try:
            x = frame.to_ndarray()
            logger.debug(f"[FRAME] dtype={x.dtype}, shape={x.shape}, sr={frame.sample_rate}")
        except:
            pass
        
        # VAD 판단용 PCM16 변환 (가볍게, 항상 640 bytes 반환)
        pcm16_bytes = self.audio_processor.to_pcm16_16k_mono(frame)
        
        if pcm16_bytes is None:
            # 변환 실패 시 프레임만 반환 (처리 없음)
            return frame
        
        # VAD 프레임 버퍼에 추가
        self._vad_buf.extend(pcm16_bytes)
        
        # 20ms 프레임(640 bytes) 단위로 쪼개서 VAD 처리
        while len(self._vad_buf) >= self.VAD_BYTES:
            # 20ms 프레임 추출
            vad_frame = bytes(self._vad_buf[:self.VAD_BYTES])
            del self._vad_buf[:self.VAD_BYTES]
            
            # VAD 디버그 로그 (검증용 - 일시적)
            logger.debug(f"[VAD FRAME] sr={self.VAD_SR}, bytes={len(vad_frame)}, samples={len(vad_frame)//2}")
            
            # VAD로 speech 여부 판단 (반드시 16000 샘플레이트 전달, 640 bytes)
            try:
                is_speech = self.audio_processor.vad.is_speech(vad_frame, self.VAD_SR)
            except Exception as e:
                logger.error(f"VAD error: {e}", exc_info=True)
                # 에러 발생 시 이 프레임은 스킵하고 다음 프레임 처리
                break
            
            # VAD 윈도우에 추가 (1=speech, 0=silence)
            self._vad_window.append(1 if is_speech else 0)
            
            # 상태머신 처리
            if len(self._vad_window) < self._vad_window.maxlen:
                # 윈도우가 채워지지 않았으면 상태 전환하지 않음
                continue
            
            # speech ratio 계산
            ratio = sum(self._vad_window) / len(self._vad_window)
            
            if self._vad_state == self.STATE_IDLE:
                # IDLE 상태: 말 시작 조건 확인
                if ratio >= 0.4:  # 40% 이상 speech면 말 시작
                    self._vad_state = self.STATE_IN_SPEECH
                    logger.info("🎙️ speech_start")
                    self._speech_buf.extend(vad_frame)  # 시작 프레임 포함
                else:
                    # 무음이면 여기서 끝 - 버퍼/인코딩/로그/STT 없음
                    continue
                
            elif self._vad_state == self.STATE_IN_SPEECH:
                # IN_SPEECH 상태: 오디오 버퍼에 추가
                self._speech_buf.extend(vad_frame)
                
                # 말 끝 조건: 400ms 동안 거의 무음 (10% 이하)
                if ratio <= 0.1:
                    logger.info("🛑 speech_end")
                    
                    # speech 구간 오디오 확정
                    audio_for_stt = bytes(self._speech_buf)
                    self._speech_buf.clear()
                    self._vad_state = self.STATE_IDLE
                    self._vad_window.clear()
                    
                    # speech_end에서만 "인코딩 완료 / STT 전송" 로그 출력
                    logger.info(f"✅ speech segment bytes={len(audio_for_stt)} (16kHz mono PCM16)")
                    
                    # TODO: 여기서만 STT 호출 or 큐 enqueue
                    if self.on_speech_end:
                        try:
                            # bytes를 numpy array로 변환하여 콜백에 전달
                            audio_array = np.frombuffer(audio_for_stt, dtype=np.int16)
                            await self.on_speech_end(audio_array)
                        except Exception as e:
                            logger.error(f"Error in on_speech_end callback: {e}", exc_info=True)
        
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
    
    def __init__(self, session_id: str, websocket: Optional[WebSocket] = None):
        self.session_id = session_id
        self.websocket = websocket  # WebSocket은 선택적 (DataChannel 사용 시 None)
        self.pc: Optional[RTCPeerConnection] = None
        self.data_channel: Optional[RTCDataChannel] = None  # DataChannel
        
        # 오디오 처리 컴포넌트
        self.audio_processor = AudioProcessor()
        # TODO: 다음 단계에서 활성화
        # self.vad_processor = VADProcessor(
        #     on_speech_end=self._on_speech_end,
        #     on_speech_start=self._on_speech_start
        # )
        # self.stt_service = STTService()
        # self.llm_service = LLMService()
        # self.tts_service = TTSService()
        
        # 오디오 송출 트랙
        self.audio_sender: Optional[AudioTrackSender] = None
        
        # 상태 관리
        self.is_speaking = False  # AI가 말하고 있는지
        self.current_turn_cancelled = False  # Barge-in 플래그
        
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
                # VAD 기반 상태머신으로 오디오 수신
                receiver = AudioTrackReceiver(
                    track, 
                    self.audio_processor, 
                    on_speech_end=self._on_speech_end
                )
                # 트랙을 유지하기 위해 루프 실행
                asyncio.create_task(self._audio_receive_loop(receiver))
        
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
                    logger.info(f"📊 오디오 프레임 수신 중... (총 {frame_count}개 프레임 수신됨)")
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
        
        # 오디오 트랙 수신 처리
        @self.pc.on("track")
        async def on_track(track):
            if track.kind == "audio":
                logger.info("✅ Audio track received from client")
                # VAD 기반 상태머신으로 오디오 수신
                receiver = AudioTrackReceiver(
                    track, 
                    self.audio_processor, 
                    on_speech_end=self._on_speech_end
                )
                asyncio.create_task(self._audio_receive_loop(receiver))
        
        # 연결 상태 변경
        @self.pc.on("connectionstatechange")
        async def on_connectionstatechange():
            logger.info(f"Connection state: {self.pc.connectionState}")
            if self.pc.connectionState == "failed":
                await self.cleanup()
        
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
                        # 필요시 메시지 처리 (예: ICE candidates 등)
                except Exception as e:
                    logger.error(f"Error processing DataChannel message: {e}")
            
            @channel.on("open")
            def on_open():
                logger.info("✅ DataChannel opened")
            
            @channel.on("close")
            def on_close():
                logger.info("DataChannel closed")
    
    async def _send_datachannel_message(self, message: dict):
        """DataChannel로 메시지 전송"""
        if self.data_channel and self.data_channel.readyState == "open":
            try:
                message_str = json.dumps(message)
                self.data_channel.send(message_str)
            except Exception as e:
                logger.error(f"Error sending DataChannel message: {e}")
        else:
            logger.warning("DataChannel is not open, cannot send message")
    
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
    
    async def _on_speech_end(self, audio_buffer: np.ndarray):
        """사용자가 말을 끝냄 (VAD 무음 400ms 감지) - 말 끝에서만 STT 호출"""
        logger.info(f"🎤 Speech ended, audio length: {len(audio_buffer)} samples")
        
        # TODO: STT 처리 (다음 단계에서 활성화)
        # try:
        #     transcript = await self.stt_service.transcribe(audio_buffer)
        #     if not transcript or transcript.strip() == "":
        #         logger.warning("Empty transcript")
        #         return
        #     
        #     logger.info(f"STT result: {transcript}")
        #     
        #     # 클라이언트에 transcript 전송 (DataChannel)
        #     await self._send_datachannel_message({
        #         "type": "transcript",
        #         "transcript": transcript
        #     })
        #     
        #     # LLM 스트리밍 처리
        #     await self._process_llm_response(transcript)
        #     
        # except Exception as e:
        #     logger.error(f"Error processing speech: {e}", exc_info=True)
    
    # TODO: 다음 단계에서 활성화
    # async def _process_llm_response(self, user_message: str):
    #     """LLM 스트리밍 응답 처리"""
    #     self.is_speaking = True
    #     text_buffer = ""
    #     sentence_buffer = ""
    #     
    #     try:
    #         # LLM 스트리밍 요청
    #         async for token in self.llm_service.stream_response(user_message):
    #             if self.current_turn_cancelled:
    #                 break
    #             
    #             text_buffer += token
    #             sentence_buffer += token
    #             
    #             # 문장 분할 규칙 확인
    #             if self._is_sentence_complete(sentence_buffer):
    #                 # 문장 완성 → TTS로 전달
    #                 sentence = sentence_buffer.strip()
    #                 if sentence:
    #                     await self._send_to_tts(sentence)
    #                 sentence_buffer = ""
    #         
    #         # 남은 텍스트 처리
    #         if sentence_buffer.strip() and not self.current_turn_cancelled:
    #             await self._send_to_tts(sentence_buffer.strip())
    #             
    #     except Exception as e:
    #         logger.error(f"LLM processing error: {e}", exc_info=True)
    #     finally:
    #         self.is_speaking = False
    #         # 클라이언트에 idle phase 전송
    #         await self._send_datachannel_message({
    #             "type": "phase",
    #             "phase": "idle"
    #         })
    # 
    # def _is_sentence_complete(self, text: str) -> bool:
    #     """문장 완성 여부 판단"""
    #     if len(text) < 20:  # 최소 길이
    #         return False
    #     
    #     # 문장 경계 확인: . ? ! … \n
    #     sentence_endings = ['.', '?', '!', '…', '\n']
    #     if any(text.rstrip().endswith(ending) for ending in sentence_endings):
    #         return True
    #     
    #     # 최대 길이 초과 시 강제 분할
    #     if len(text) > 200:
    #         # 마지막 공백이나 구두점에서 분할
    #         for i in range(len(text) - 1, max(0, len(text) - 50), -1):
    #             if text[i] in [' ', '.', ',', '!', '?']:
    #                 return True
    #         return True
    #     
    #     return False
    # 
    # async def _send_to_tts(self, text: str):
    #     """TTS로 텍스트 전달 및 스트리밍"""
    #     try:
    #         # TTS가 비활성화된 경우 로그만 출력
    #         if not hasattr(self.tts_service, 'enabled') or not self.tts_service.enabled:
    #             logger.warning(f"TTS disabled. Would say: {text}")
    #             return
    #         
    #         # ElevenLabs TTS 스트리밍
    #         async for audio_chunk in self.tts_service.stream_synthesize(text):
    #             if self.current_turn_cancelled:
    #                 break
    #             
    #             # 오디오를 WebRTC 형식으로 변환 (16kHz → 48kHz 리샘플링)
    #             webrtc_frame = await self.audio_processor.prepare_output_frame(audio_chunk)
    #             
    #             # WebRTC로 송출
    #             if self.audio_sender:
    #                 await self.audio_sender.push_audio(webrtc_frame)
    #                 
    #     except Exception as e:
    #         logger.error(f"TTS error: {e}", exc_info=True)
    # 
    # async def _cancel_current_turn(self):
    #     """현재 턴 취소 (Barge-in)"""
    #     logger.info("Cancelling current turn")
    #     # LLM/TTS 작업 취소는 플래그로 처리 (실제 취소는 각 서비스에서 처리)
    #     # 오디오 큐 flush
    #     if self.audio_sender:
    #         # 큐 비우기
    #         while not self.audio_sender._queue.empty():
    #             try:
    #                 self.audio_sender._queue.get_nowait()
    #             except:
    #                 break
    
    async def cleanup(self):
        """리소스 정리"""
        logger.info(f"Cleaning up session: {self.session_id}")
        
        try:
            # TODO: 다음 단계에서 활성화
            # VAD 정리
            # await self.vad_processor.cleanup()
            pass
        except Exception as e:
            logger.warning(f"Error cleaning up VAD processor: {e}")
        
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

