import express, { Router, Request, Response } from 'express';

const router = Router();

// SDP 텍스트를 받기 위한 미들웨어 (공식 문서 방식)
router.use(express.text({
  type: ['application/sdp', 'text/plain'],
  limit: '10mb' // SDP는 큰 경우가 있음
}));

// OpenAI Realtime API 설정
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

if (!OPENAI_API_KEY) {
  console.warn('⚠️  OPENAI_API_KEY가 설정되지 않았습니다. .env 파일을 확인하세요.');
}

// POST /api/realtime/calls - WebRTC offer 처리 (공식 문서 방식)
// 클라이언트에서 SDP offer를 받아 OpenAI Realtime API로 전달
router.post('/calls', async (req: Request, res: Response) => {
  try {
    if (!OPENAI_API_KEY) {
      return res.status(500).json({
        error: 'OpenAI API key가 설정되지 않았습니다'
      });
    }

    // 클라이언트에서 SDP를 텍스트로 받음 (application/sdp 또는 text/plain)
    const sdp = req.body;
    const voice = req.query?.voice as string || 'alloy'; // OpenAI 표준 voice 사용

    if (!sdp || typeof sdp !== 'string') {
      return res.status(400).json({
        error: 'SDP가 필요합니다'
      });
    }

    console.log('📡 WebRTC offer 수신 - OpenAI에 전달...');
    console.log(`   Voice: ${voice}`);
    console.log(`   SDP 길이: ${sdp.length} bytes`);

    // 세션 설정 (최소 필드만 포함 - modalities 제거)
    // ⚠️ modalities, input_audio_transcription, turn_detection 등은 제거
    const sessionConfig = {
      type: "realtime",
      model: "gpt-4o-realtime-preview", 
      audio: {
        output: { voice }, // "alloy" 등
      },
    };
    const sessionConfigString = JSON.stringify(sessionConfig);

    // OpenAI 요청 전 로그
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('📤 OpenAI calls 요청 전송:');
    console.log(`   URL: https://api.openai.com/v1/realtime/calls`);
    console.log(`   Voice: ${voice}`);
    console.log(`   Offer SDP 길이: ${sdp.length} bytes`);
    console.log(`   Session JSON: ${sessionConfigString}`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    // FormData 생성 (multipart/form-data)
    const formData = new FormData();
    formData.set('sdp', sdp);
    formData.set('session', sessionConfigString);

    // OpenAI Realtime API의 /v1/realtime/calls 엔드포인트 호출
    const response = await fetch('https://api.openai.com/v1/realtime/calls', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        // FormData를 사용하면 Content-Type을 설정하지 않음 (자동으로 multipart/form-data 설정됨)
      },
      body: formData,
    });

    // OpenAI 응답 처리
    if (!response.ok) {
      const errorText = await response.text();
      let errorDetails: any = {};
      try {
        errorDetails = JSON.parse(errorText);
      } catch {
        errorDetails = { message: errorText };
      }

      console.error('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      console.error('❌ OpenAI calls 오류:');
      console.error(`   Status: ${response.status}`);
      console.error(`   Error message: ${errorDetails.message || errorText}`);
      if (errorDetails.param) {
        console.error(`   Error param: ${errorDetails.param}`);
      }
      console.error(`   Error body: ${errorText}`);
      console.error('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      return res.status(response.status).json({
        error: 'OpenAI WebRTC call 오류',
        details: errorText
      });
    } 

    // Location 헤더에서 call_id 추출 및 Flutter로 전달 (split 사용)
    const locationHeader = response.headers.get('Location');
    console.log(`📍 OpenAI Location header: ${locationHeader ?? 'null'}`);

    let callId: string | null = null;
    if (locationHeader) {
      const segments = locationHeader.split('/').filter((seg) => seg.trim().length > 0);
      if (segments.length > 0) {
        callId = segments[segments.length - 1].trim();
      }
    }

    // call_id 검증: 'calls' 이거나 빈 값이면 에러 처리
    if (!callId || callId.length === 0 || callId === 'calls') {
      console.error('❌ call_id 추출 실패 - 잘못된 값입니다.');
      console.error(`   Location 헤더 전체: ${locationHeader ?? 'null'}`);
      return res.status(502).json({
        error: 'Invalid call_id from OpenAI',
        location: locationHeader ?? '',
      });
    }

    // 유효한 call_id를 헤더로 전달
    res.setHeader('X-Call-Id', callId);
    console.log(`📋 OpenAI call_id 추출: ${callId}`);

    // OpenAI가 SDP answer를 텍스트로 반환
    const answerSdp = await response.text();

    // OpenAI 응답 후 로그
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('✅ OpenAI calls 응답 수신:');
    console.log(`   Status: ${response.status}`);
    console.log(`   Answer SDP 길이: ${answerSdp.length} bytes`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    // SDP answer를 텍스트로 반환 (공식 문서 방식)
    res.setHeader('Content-Type', 'application/sdp');
    res.setHeader('X-Call-Id', callId);
    console.log(`📋 X-Call-Id 헤더 설정: ${callId}`);
    res.send(answerSdp);
  } catch (error) {
    console.error('❌ WebRTC call 처리 오류:', error);
    res.status(500).json({
      error: 'WebRTC call 처리 실패',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
});

// ✅ POST /api/realtime/calls/:callId/hangup - OpenAI 통화 종료
router.post('/calls/:callId/hangup', async (req: Request, res: Response) => {
  try {
    if (!OPENAI_API_KEY) {
      return res.status(500).json({
        error: 'OpenAI API key가 설정되지 않았습니다'
      });
    }

    const callId = req.params.callId;

    if (!callId) {
      return res.status(400).json({
        error: 'call_id가 필요합니다'
      });
    }

    const url = `https://api.openai.com/v1/realtime/calls/${callId}/hangup`;
    console.log('📞 OpenAI hangup 요청 전송:', url);

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
      },
    });

    const text = await response.text();
    if (!response.ok) {
      console.error('❌ OpenAI hangup 오류:', response.status, text);
      return res.status(response.status).send(text);
    }
    console.log('✅ OpenAI hangup 성공:', response.status);
    return res.status(200).send(text);
  } catch (error) {
    console.error('❌ Hangup 처리 오류:', error);
    res.status(500).json({
      error: 'Hangup 처리 실패',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
});

export default router;

