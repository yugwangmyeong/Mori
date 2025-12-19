import { Router, Request, Response } from 'express';
import axios from 'axios';
import prisma from '../lib/prisma';
import jwt from 'jsonwebtoken';

const router = Router();

interface KakaoUserInfo {
  id: number;
  kakao_account?: {
    email?: string;
    profile?: {
      nickname?: string;
      profile_image_url?: string;
    };
  };
}

interface AuthRequest {
  accessToken: string;
}

interface AuthResponse {
  success: boolean;
  user?: {
    id: string;
    email: string | null;
    name: string | null;
    profileImageUrl: string | null;
    provider: string;
  };
  token?: string;
  error?: string;
}

// 카카오 사용자 정보 조회
async function getKakaoUserInfo(accessToken: string): Promise<KakaoUserInfo | null> {
  try {
    const response = await axios.get('https://kapi.kakao.com/v2/user/me', {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      },
    });
    return response.data;
  } catch (error: any) {
    if (error.response) {
      console.error('❌ Kakao API Error:', {
        status: error.response.status,
        statusText: error.response.statusText,
        data: error.response.data,
      });
    } else if (error.request) {
      console.error('❌ Kakao API Request Error:', 'No response received');
    } else {
      console.error('❌ Kakao API Error:', error.message);
    }
    return null;
  }
}

// POST /api/auth/kakao - 카카오 OAuth2 로그인
router.post('/kakao', async (req: Request<{}, AuthResponse, AuthRequest>, res: Response<AuthResponse>) => {
  try {
    console.log('═══════════════════════════════════════');
    console.log('📥 Kakao OAuth request received');
    console.log('   From IP:', req.ip || req.socket.remoteAddress);
    console.log('   User-Agent:', req.get('user-agent'));
    console.log('   Timestamp:', new Date().toISOString());
    console.log('═══════════════════════════════════════');
    
    const { accessToken } = req.body;

    if (!accessToken) {
      console.error('❌ Access token is missing');
      return res.status(400).json({
        success: false,
        error: 'Access token is required',
      });
    }

    console.log('🔍 Fetching user info from Kakao API...');
    // 카카오 API로 사용자 정보 조회
    const kakaoUserInfo = await getKakaoUserInfo(accessToken);

    if (!kakaoUserInfo) {
      console.error('❌ Failed to fetch Kakao user info');
      return res.status(401).json({
        success: false,
        error: 'Invalid access token or failed to fetch user info',
      });
    }

    console.log('✅ Kakao user info fetched:', { id: kakaoUserInfo.id, email: kakaoUserInfo.kakao_account?.email });

    const kakaoId = kakaoUserInfo.id.toString();
    const email = kakaoUserInfo.kakao_account?.email || null;
    const name = kakaoUserInfo.kakao_account?.profile?.nickname || null;
    const profileImageUrl = kakaoUserInfo.kakao_account?.profile?.profile_image_url || null;

    // 기존 사용자 조회 또는 새 사용자 생성
    let user = await prisma.user.findUnique({
      where: { kakaoId },
    });

    if (user) {
      // 기존 사용자 정보 업데이트
      console.log('🔄 Updating existing user:', user.id);
      user = await prisma.user.update({
        where: { id: user.id },
        data: {
          email: email || user.email,
          name: name || user.name,
          profileImageUrl: profileImageUrl || user.profileImageUrl,
          accessToken, // 실제 운영 환경에서는 암호화 권장
          updatedAt: new Date(),
        },
      });
      console.log('✅ User updated in database:', user.id);
    } else {
      // 새 사용자 생성
      console.log('➕ Creating new user with kakaoId:', kakaoId);
      user = await prisma.user.create({
        data: {
          kakaoId,
          email,
          name,
          profileImageUrl,
          provider: 'kakao',
          accessToken, // 실제 운영 환경에서는 암호화 권장
        },
      });
      console.log('✅ New user created in database:', user.id);
    }

    // JWT 토큰 생성
    const jwtSecret = process.env.JWT_SECRET || 'your-secret-key-change-in-production';
    const token = jwt.sign(
      {
        userId: user.id,
        kakaoId: user.kakaoId,
        provider: user.provider,
      },
      jwtSecret,
      { expiresIn: '7d' }
    );

    console.log('✅ Sending success response to client');
    console.log('   User ID:', user.id);
    console.log('   User Name:', user.name || 'No name');
    console.log('   User Email:', user.email || 'No email');
    console.log('═══════════════════════════════════════');
    
    res.json({
      success: true,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        profileImageUrl: user.profileImageUrl,
        provider: user.provider,
      },
      token,
    });
  } catch (error) {
    console.error('Error in Kakao OAuth:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error',
    });
  }
});

// GET /api/auth/me - 현재 사용자 정보 조회 (JWT 토큰 필요)
router.get('/me', async (req: Request, res: Response) => {
  try {
    const authHeader = req.headers.authorization;
    
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({
        success: false,
        error: 'No token provided',
      });
    }

    const token = authHeader.substring(7);
    const jwtSecret = process.env.JWT_SECRET || 'your-secret-key-change-in-production';

    try {
      const decoded = jwt.verify(token, jwtSecret) as { userId: string };
      const user = await prisma.user.findUnique({
        where: { id: decoded.userId },
        select: {
          id: true,
          email: true,
          name: true,
          profileImageUrl: true,
          provider: true,
          createdAt: true,
        },
      });

      if (!user) {
        return res.status(404).json({
          success: false,
          error: 'User not found',
        });
      }

      res.json({
        success: true,
        user,
      });
    } catch (jwtError) {
      return res.status(401).json({
        success: false,
        error: 'Invalid token',
      });
    }
  } catch (error) {
    console.error('Error fetching user info:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error',
    });
  }
});

export default router;

