"""
채팅 라우트 (Express.js에서 이전)
"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional

router = APIRouter(prefix="/api/chat", tags=["chat"])


class ChatRequest(BaseModel):
    message: str
    userId: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    messageId: Optional[str] = None


@router.post("/", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """
    채팅 메시지 처리
    Express.js의 /api/chat을 FastAPI로 이전
    """
    if not request.message:
        raise HTTPException(status_code=400, detail="Message is required")
    
    # TODO: 실제 챗봇 로직 구현
    # TODO: Prisma를 사용하여 채팅 메시지 저장
    
    bot_response = "응답이 여기에 표시됩니다."
    
    return ChatResponse(
        response=bot_response,
        messageId=None  # TODO: 저장된 메시지 ID 반환
    )





