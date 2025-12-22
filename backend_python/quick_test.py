"""
빠른 테스트 스크립트
서버가 정상적으로 작동하는지 확인
"""
import asyncio
import sys
import requests
from datetime import datetime

def test_health_check():
    """Health check 테스트"""
    print("=" * 60)
    print("🏥 Health Check 테스트")
    print("=" * 60)
    
    url = "http://172.30.1.29:8000/health"
    try:
        response = requests.get(url, timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"✅ 서버 정상 작동")
            print(f"   Status: {data.get('status')}")
            print(f"   Active Sessions: {data.get('active_sessions')}")
            print(f"   Server: {data.get('server')}")
            return True
        else:
            print(f"❌ 서버 응답 오류: {response.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        print("❌ 서버에 연결할 수 없습니다")
        print("   서버가 실행 중인지 확인하세요: python main.py")
        return False
    except Exception as e:
        print(f"❌ 오류 발생: {e}")
        return False

def test_root_endpoint():
    """Root 엔드포인트 테스트"""
    print("\n" + "=" * 60)
    print("🏠 Root Endpoint 테스트")
    print("=" * 60)
    
    url = "http://172.30.1.29:8000/"
    try:
        response = requests.get(url, timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"✅ Root 엔드포인트 정상")
            print(f"   Message: {data.get('message')}")
            return True
        else:
            print(f"❌ 응답 오류: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ 오류 발생: {e}")
        return False

def test_websocket_endpoint():
    """WebSocket 엔드포인트 확인 (연결 테스트는 실제 WebSocket 클라이언트 필요)"""
    print("\n" + "=" * 60)
    print("🔌 WebSocket 엔드포인트 확인")
    print("=" * 60)
    
    url = "ws://172.30.1.29:8000/ws/webrtc"
    print(f"   WebSocket URL: {url}")
    print("   ⚠️  WebSocket 연결 테스트는 Flutter 앱에서 수행하세요")
    print("   또는 websocket-client 라이브러리 사용 필요")
    return True

def main():
    print("\n" + "=" * 60)
    print("🚀 FastAPI WebRTC 서버 빠른 테스트")
    print(f"   시간: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    results = []
    
    # Health check 테스트
    results.append(("Health Check", test_health_check()))
    
    # Root endpoint 테스트
    results.append(("Root Endpoint", test_root_endpoint()))
    
    # WebSocket 확인
    results.append(("WebSocket", test_websocket_endpoint()))
    
    # 결과 요약
    print("\n" + "=" * 60)
    print("📊 테스트 결과 요약")
    print("=" * 60)
    
    for name, result in results:
        status = "✅ 통과" if result else "❌ 실패"
        print(f"   {name}: {status}")
    
    all_passed = all(result for _, result in results)
    
    print("\n" + "=" * 60)
    if all_passed:
        print("✅ 모든 기본 테스트 통과!")
        print("   이제 Flutter 앱에서 WebRTC 연결을 테스트하세요")
    else:
        print("❌ 일부 테스트 실패")
        print("   서버가 정상적으로 실행 중인지 확인하세요")
    print("=" * 60)
    
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())


