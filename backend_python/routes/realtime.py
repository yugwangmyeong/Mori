"""
WebRTC Realtime API 엔드포인트
HTTP POST를 통한 WebRTC offer/answer 교환
"""
import asyncio
import logging
from typing import Dict
from fastapi import APIRouter, Request, Response
from fastapi.responses import PlainTextResponse
import uuid

from webrtc_handler import WebRTCHandler

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/realtime", tags=["realtime"])

# 활성 세션 관리 (session_id -> handler)
active_sessions: Dict[str, WebRTCHandler] = {}


@router.post("/calls")
async def create_call(request: Request):
    """
    WebRTC offer를 받아 answer를 반환
    클라이언트에서 WebRTC offer SDP를 POST로 보내면, answer SDP를 반환
    
    Query Parameters:
        - enable_stt: STT 활성화 여부 (기본값: true)
            - true: Realtime STT 활성화 (기본값)
            - false: STT 없이 WebRTC call만 연결
    """
    try:
        # SDP offer를 텍스트로 받음
        sdp_offer = await request.body()
        sdp_offer_text = sdp_offer.decode('utf-8')
        
        if not sdp_offer_text or len(sdp_offer_text) == 0:
            return Response(
                content="SDP offer is required",
                status_code=400,
                media_type="text/plain"
            )
        
        # STT 활성화 여부 확인 (쿼리 파라미터 또는 헤더)
        enable_stt = True  # 기본값: 활성화
        query_params = dict(request.query_params)
        if "enable_stt" in query_params:
            enable_stt_str = query_params["enable_stt"].lower()
            enable_stt = enable_stt_str in ("true", "1", "yes", "on")
        
        # 헤더에서도 확인 (쿼리 파라미터 우선)
        if "X-Enable-STT" in request.headers:
            enable_stt_str = request.headers["X-Enable-STT"].lower()
            enable_stt = enable_stt_str in ("true", "1", "yes", "on")
        
        # 세션 ID 생성
        session_id = f"session_{uuid.uuid4().hex[:16]}"
        
        logger.info(f"📡 WebRTC offer 수신 - Session: {session_id}")
        logger.info(f"   SDP 길이: {len(sdp_offer_text)} bytes")
        logger.info(f"   STT 활성화: {enable_stt}")
        
        # WebRTC 핸들러 생성 (WebSocket 없이, DataChannel 사용)
        handler = WebRTCHandler(session_id, None, enable_stt=enable_stt)
        active_sessions[session_id] = handler
        
        # offer를 처리하고 answer 생성
        answer_sdp = await handler.handle_offer(sdp_offer_text)
        
        # 백그라운드에서 연결 완료 대기 (ICE 연결 등)
        asyncio.create_task(handler._wait_for_connection())
        
        # answer를 반환 (SDP 텍스트)
        response = PlainTextResponse(
            content=answer_sdp,
            media_type="application/sdp"
        )
        response.headers["X-Session-Id"] = session_id
        response.headers["X-Call-Id"] = session_id  # 호환성을 위해
        
        logger.info(f"✅ WebRTC answer 생성 완료 - Session: {session_id}")
        logger.info(f"   Answer SDP 길이: {len(answer_sdp)} bytes")
        
        return response
        
    except Exception as e:
        logger.error(f"❌ WebRTC call 생성 오류: {e}", exc_info=True)
        return Response(
            content=f"Error: {str(e)}",
            status_code=500,
            media_type="text/plain"
        )


@router.post("/calls/{session_id}/hangup")
async def hangup_call(session_id: str):
    """
    WebRTC 세션 종료
    """
    try:
        if session_id in active_sessions:
            handler = active_sessions[session_id]
            await handler.cleanup()
            del active_sessions[session_id]
            logger.info(f"✅ Session 종료: {session_id}")
            return {"status": "ok", "message": "Session closed"}
        else:
            logger.warning(f"⚠️ Session을 찾을 수 없음: {session_id}")
            return Response(
                content="Session not found",
                status_code=404,
                media_type="text/plain"
            )
    except Exception as e:
        logger.error(f"❌ Hangup 오류: {e}", exc_info=True)
        return Response(
            content=f"Error: {str(e)}",
            status_code=500,
            media_type="text/plain"
        )
