"""
LLM 서비스
OpenAI GPT API 스트리밍 사용
"""
import logging
import os
from typing import AsyncIterator
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
            logger.info(f"LLM: Preparing request for message length={len(user_message)}")
            
            # 시스템 프롬프트
            # 시스템 프롬프트
            messages = [
                {
                    "role": "system",
                    "content": (
                        "너는 사용자의 대화상대인 AI 'Mori'다. 사용자는 음성으로 말하고, "
                        "그 내용이 STT를 통해 텍스트로 전달되므로 일부 오인식이나 문장 끊김이 있을 수 있다.\n\n"

                        "대화 목표:\n"
                        "- 사용자의 말에 자연스럽게 반응하고 대화를 끊기지 않게 이어간다.\n"
                        "- 조언이나 말하기 교정은 사용자가 직접 요청할 때만 한다.\n"
                        "- 기본 역할은 편안한 대화상대이며, 공감과 질문으로 대화를 이어간다.\n\n"

                        "대화 규칙:\n"
                        "1) 항상 한국어로 대화한다.\n"
                        "2) 답변은 보통 1~3문장으로 간결하게 한다.\n"
                        "3) 매 응답마다 질문은 최대 1개만 한다.\n"
                        "4) 입력이 애매하거나 짧게 끊긴 경우, 추측으로 단정하지 말고 "
                        "자연스럽게 확인하거나 선택지를 제시해 대화를 이어간다.\n"
                        "   예: '그러니까 요지는 ~~ 맞아?' / '지금 얘기한 게 A야, B야?'\n"
                        "5) 잘 못 들었을 때도 딱딱하게 사과하지 말고 부드럽게 되묻는다.\n\n"

                        "응답 스타일:\n"
                        "- 먼저 짧게 리액션이나 공감을 하고, 그 다음 한 가지 질문을 덧붙인다.\n"
                        "- 말투는 친근하고 따뜻하게, 과도한 이모지는 사용하지 않는다."
                    )
                }
            ]

            messages.extend(self.conversation_history[-10:])  # 최근 10개만 사용
            
            logger.debug(f"LLM: Sending request with {len(messages)} messages")
            
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
            chunk_count = 0
            
            # 스트림을 async로 처리
            for chunk in stream:
                await asyncio.sleep(0)  # 이벤트 루프에 제어권 양보
                
                if chunk.choices and len(chunk.choices) > 0:
                    if chunk.choices[0].delta.content:
                        token = chunk.choices[0].delta.content
                        assistant_response += token
                        chunk_count += 1
                        yield token
            
            logger.info(f"LLM: Response complete, total_chunks={chunk_count}, response_length={len(assistant_response)}")
            
            # 응답을 히스토리에 추가
            if assistant_response:
                self.conversation_history.append({
                    "role": "assistant",
                    "content": assistant_response
                })
            else:
                logger.warning("LLM: Received empty response")
                
        except Exception as e:
            logger.error(f"LLM error: {e}", exc_info=True)
            yield "죄송합니다. 오류가 발생했습니다."
    
    def reset_history(self):
        """대화 히스토리 리셋"""
        self.conversation_history = []

