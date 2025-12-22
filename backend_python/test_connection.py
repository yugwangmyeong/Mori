"""
서버 연결 테스트 스크립트
FastAPI 서버가 정상적으로 실행 중인지 확인
"""
import requests
import sys

def test_health_check():
    """Health check 엔드포인트 테스트"""
    server_url = "http://172.30.1.29:8000"
    health_url = f"{server_url}/health"
    
    print("=" * 60)
    print("🔍 FastAPI 서버 연결 테스트")
    print(f"   Server URL: {server_url}")
    print(f"   Health Check URL: {health_url}")
    print("=" * 60)
    
    try:
        print("\n📡 Health check 요청 전송 중...")
        response = requests.get(health_url, timeout=5)
        
        print(f"\n✅ 응답 수신!")
        print(f"   Status Code: {response.status_code}")
        print(f"   Response: {response.json()}")
        
        if response.status_code == 200:
            print("\n✅ 서버가 정상적으로 실행 중입니다!")
            return True
        else:
            print(f"\n⚠️ 서버가 응답했지만 상태 코드가 {response.status_code}입니다.")
            return False
            
    except requests.exceptions.ConnectionError:
        print("\n❌ 연결 실패!")
        print("   서버가 실행 중이지 않거나 접근할 수 없습니다.")
        print("\n💡 해결 방법:")
        print("   1. 서버 실행: cd backend_python && python main.py")
        print("   2. 서버가 0.0.0.0으로 바인딩되어 있는지 확인")
        print("   3. 방화벽이 포트 8000을 차단하지 않는지 확인")
        return False
    except requests.exceptions.Timeout:
        print("\n❌ 타임아웃!")
        print("   서버가 응답하지 않습니다.")
        return False
    except Exception as e:
        print(f"\n❌ 오류 발생: {e}")
        return False

if __name__ == "__main__":
    success = test_health_check()
    sys.exit(0 if success else 1)


