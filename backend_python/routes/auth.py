"""
인증 라우트 (Express.js에서 이전)
"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import httpx
import jwt
from typing import Optional

router = APIRouter(prefix="/api/auth", tags=["auth"])


class AuthRequest(BaseModel):
    accessToken: str


class AuthResponse(BaseModel):
    success: bool
    user: Optional[dict] = None
    token: Optional[str] = None
    message: Optional[str] = None


@router.post("/", response_model=AuthResponse)
async def authenticate(request: AuthRequest):
    """
    카카오 인증 처리
    Express.js의 /api/auth를 FastAPI로 이전
    """
    try:
        # 카카오 사용자 정보 가져오기
        async with httpx.AsyncClient() as client:
            response = await client.get(
                "https://kapi.kakao.com/v2/user/me",
                headers={"Authorization": f"Bearer {request.accessToken}"}
            )
            
            if response.status_code != 200:
                raise HTTPException(status_code=401, detail="Invalid access token")
            
            kakao_user = response.json()
        
        # TODO: Prisma를 사용하여 사용자 저장/조회
        # 현재는 간단한 응답만 반환
        
        return AuthResponse(
            success=True,
            user={
                "id": str(kakao_user.get("id")),
                "email": kakao_user.get("kakao_account", {}).get("email"),
                "name": kakao_user.get("kakao_account", {}).get("profile", {}).get("nickname"),
                "profileImageUrl": kakao_user.get("kakao_account", {}).get("profile", {}).get("profile_image_url"),
                "provider": "kakao"
            }
        )
        
    except httpx.HTTPError:
        raise HTTPException(status_code=500, detail="Failed to verify token with Kakao")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))




