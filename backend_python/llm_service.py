"""
LLM 서비스
OpenAI GPT API 스트리밍 사용
"""
import logging
import os
from typing import AsyncIterator
from typing import Optional, Callable, Awaitable
from openai import OpenAI

logger = logging.getLogger(__name__)


class LLMService:
    """LLM 서비스 클래스"""
    
    def __init__(self):
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise ValueError("OPENAI_API_KEY environment variable is required")
        
        self.client = OpenAI(api_key=api_key)
        self.model = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
        
        # 대화 히스토리
        self.conversation_history = []
    
    async def stream_response(self, user_message: str) -> AsyncIterator[str]:
        """
        LLM 스트리밍 응답 생성
        
        Args:
            user_message: 사용자 메시지
            
        Yields:
            토큰 (delta)
        """
        import asyncio
        
        # 대화 히스토리에 추가
        self.conversation_history.append({
            "role": "user",
            "content": user_message
        })
        
        try:
            # 시스템 프롬프트
            messages = [
                {
                    "role": "system",
                    "content": "당신은 친근하고 도움이 되는 AI 어시스턴트 'Mori'입니다. 자연스럽고 대화하듯이 답변해주세요. 답변은 간결하고 명확하게 해주세요."
                }
            ]
            messages.extend(self.conversation_history[-10:])  # 최근 10개만 사용
            
            # 스트리밍 요청 (동기식 client를 async로 실행)
            loop = asyncio.get_event_loop()
            stream = await loop.run_in_executor(
                None,
                lambda: self.client.chat.completions.create(
                    model=self.model,
                    messages=messages,
                    stream=True,
                    temperature=0.7,
                    max_tokens=500
                )
            )
            
            assistant_response = ""
            
            # 스트림을 async로 처리
            for chunk in stream:
                await asyncio.sleep(0)  # 이벤트 루프에 제어권 양보
                if chunk.choices[0].delta.content:
                    token = chunk.choices[0].delta.content
                    assistant_response += token
                    yield token
            
            # 응답을 히스토리에 추가
            if assistant_response:
                self.conversation_history.append({
                    "role": "assistant",
                    "content": assistant_response
                })
                
        except Exception as e:
            logger.error(f"LLM error: {e}", exc_info=True)
            yield "죄송합니다. 오류가 발생했습니다."
    
    def reset_history(self):
        """대화 히스토리 리셋"""
        self.conversation_history = []

