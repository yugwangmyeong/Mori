"""
WebRTC 연결 테스트 스크립트
서버가 제대로 작동하는지 확인
"""
import asyncio
import logging
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.contrib.media import MediaPlayer

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def test_peer_connection():
    """PeerConnection 생성 테스트"""
    try:
        pc = RTCPeerConnection()
        logger.info("✅ PeerConnection 생성 성공")
        
        # Offer 생성 테스트
        offer = await pc.createOffer()
        logger.info(f"✅ Offer 생성 성공: {offer.type}")
        
        await pc.setLocalDescription(offer)
        logger.info("✅ setLocalDescription 성공")
        
        # Answer 생성 테스트
        answer = await pc.createAnswer()
        logger.info(f"✅ Answer 생성 성공: {answer.type}")
        
        await pc.close()
        logger.info("✅ PeerConnection 종료 성공")
        
        return True
    except Exception as e:
        logger.error(f"❌ 테스트 실패: {e}", exc_info=True)
        return False


if __name__ == "__main__":
    result = asyncio.run(test_peer_connection())
    if result:
        print("\n✅ WebRTC 기본 기능 테스트 통과!")
    else:
        print("\n❌ WebRTC 기본 기능 테스트 실패!")

