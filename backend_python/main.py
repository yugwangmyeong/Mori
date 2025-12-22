"""
FastAPI WebRTC Voice AI Server
OpenAI Realtime API를 사용하지 않고 일반 API를 스트리밍으로 사용
"""
import asyncio
import os
import logging
from typing import Dict, Optional
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from datetime import datetime
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import uvicorn

from webrtc_handler import WebRTCHandler
from routes import auth, chat

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# aioice 로거 레벨을 WARNING으로 설정 (169.254.* 바인딩 로그 억제)
logging.getLogger("aioice").setLevel(logging.WARNING)

app = FastAPI(title="Mori Voice AI WebRTC Server")

# CORS 설정
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 프로덕션에서는 특정 origin만 허용
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# WebRTC 세션 관리
active_sessions: Dict[str, WebRTCHandler] = {}

# 라우터 등록 (Express.js에서 이전)
app.include_router(auth.router)
app.include_router(chat.router)

# WebRTC Realtime API 라우터 추가
from routes import realtime
app.include_router(realtime.router)


@app.get("/")
async def root():
    return {"message": "Mori Voice AI WebRTC Server", "status": "running"}


@app.get("/health")
async def health(request: Request):
    """헬스체크 엔드포인트 - 연결 상태 확인"""
    client_ip = request.client.host if request.client else "unknown"
    user_agent = request.headers.get("user-agent", "unknown")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    logger.info("=" * 60)
    logger.info("🏥 Health check 요청 수신")
    logger.info(f"   Client IP: {client_ip}")
    logger.info(f"   User-Agent: {user_agent}")
    logger.info(f"   Timestamp: {timestamp}")
    logger.info(f"   Active WebRTC sessions: {len(active_sessions)}")
    logger.info(f"   Server IP: 172.30.1.29")
    logger.info(f"   Port: 8000")
    logger.info("=" * 60)
    
    return {
        "status": "healthy",
        "active_sessions": len(active_sessions),
        "server": "FastAPI WebRTC Server",
        "port": 8000,
        "timestamp": timestamp
    }


@app.websocket("/ws/webrtc")
async def webrtc_endpoint(websocket: WebSocket):
    """
    WebRTC 시그널링 엔드포인트
    Flutter 클라이언트와 WebRTC 연결을 설정
    """
    await websocket.accept()
    session_id = None
    
    try:
        # 초기 메시지에서 session_id 받기
        init_message = await websocket.receive_json()
        session_id = init_message.get("session_id") or f"session_{id(websocket)}"
        
        logger.info(f"WebRTC session started: {session_id}")
        
        # WebRTC 핸들러 생성
        handler = WebRTCHandler(session_id, websocket)
        active_sessions[session_id] = handler
        
        # WebRTC 연결 처리
        await handler.handle_connection()
        
    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected: {session_id}")
    except Exception as e:
        logger.error(f"WebRTC error for {session_id}: {e}", exc_info=True)
    finally:
        if session_id and session_id in active_sessions:
            await active_sessions[session_id].cleanup()
            del active_sessions[session_id]
            logger.info(f"Session cleaned up: {session_id}")


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8000))
    # host를 0.0.0.0으로 설정하여 모든 네트워크 인터페이스에서 접근 가능하게 함
    # 특정 IP로 바인딩하면 해당 IP로만 접근 가능하여 연결 문제 발생 가능
    host = os.getenv("HOST", "0.0.0.0")
    
    logger.info("=" * 60)
    logger.info("🚀 FastAPI 서버 시작")
    logger.info(f"   Host: {host}")
    logger.info(f"   Port: {port}")
    logger.info(f"   Server will be accessible at: http://{host}:{port}")
    logger.info(f"   Health check: http://{host}:{port}/health")
    logger.info("=" * 60)
    
    uvicorn.run(
        "main:app",
        host=host,
        port=port,
        log_level="info",
        reload=True
    )

