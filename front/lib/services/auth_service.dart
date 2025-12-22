import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/user.dart' as models;

class AuthService {
  // 개발 환경 설정 (.env 파일에서 읽기)
  // 
  // .env 파일 설정 예시:
  // - Android 에뮬레이터: BACKEND_URL=10.0.2.2 (또는 비워두기)
  // - Android 실제 기기: BACKEND_URL=172.20.10.5 (컴퓨터의 IP 주소)
  // - iOS 시뮬레이터: BACKEND_URL=localhost (또는 비워두기)
  // - iOS 실제 기기: BACKEND_URL=172.20.10.5 (컴퓨터의 IP 주소)
  //
  // 참고: IP 주소만 입력하세요 (포트 제외, 코드에서 자동 추가)
  static String _getServerBaseUrl() {
    final envUrl = dotenv.get('BACKEND_URL', fallback: '').trim();
    
    print('🔧 [DEBUG] .env에서 읽은 BACKEND_URL: "$envUrl"');
    
    // .env에 설정이 없거나 비어있으면 플랫폼별 기본값 사용
    if (envUrl.isEmpty) {
      if (Platform.isAndroid) {
        final defaultValue = '10.0.2.2'; // Android 에뮬레이터 기본값
        print('🔧 [DEBUG] .env가 비어있음. Android 기본값 사용: $defaultValue');
        return defaultValue;
      } else if (Platform.isIOS) {
        final defaultValue = 'localhost'; // iOS 시뮬레이터 기본값
        print('🔧 [DEBUG] .env가 비어있음. iOS 기본값 사용: $defaultValue');
        return defaultValue;
      }
    }
    
    // localhost:3000 같은 형식이면 localhost만 추출
    if (envUrl.contains('localhost')) {
      print('⚠️ [WARNING] localhost를 사용하고 있습니다. 실제 기기에서는 컴퓨터 IP 주소(예: 172.20.10.5)를 사용해야 합니다!');
      return 'localhost';
    }
    
    // IP:포트 형식이면 IP만 추출 (예: 172.30.1.29:8000 -> 172.30.1.29)
    if (envUrl.contains(':')) {
      final ipOnly = envUrl.split(':').first;
      print('🔧 [DEBUG] IP:포트 형식에서 IP만 추출: $ipOnly');
      return ipOnly;
    }
    
    // IP만 있는 경우 그대로 사용
    print('🔧 [DEBUG] 최종 서버 주소: $envUrl');
    return envUrl;
  }
  
  // 개발 환경에서 플랫폼에 따라 자동으로 적절한 URL 사용
  static String get _baseUrl {
    if (kDebugMode) {
      final serverIp = _getServerBaseUrl();
      
      // 개발 모드: FastAPI 서버 사용 (포트 8000)
      // Express.js (포트 3000)에서 FastAPI (포트 8000)로 전환
      return 'http://$serverIp:8000/api/auth';
    }
    // 프로덕션 모드: 실제 서버 URL
    return 'https://your-production-server.com/api/auth'; //나중에 배포할때 사용
  }
  
  // 백엔드 서버 연결 테스트
  static Future<bool> checkBackendConnection() async {
    try {
      final serverUrl = _baseUrl.replaceAll('/api/auth', '');
      final healthUrl = '$serverUrl/health';
      
      print('═══════════════════════════════════════════════════════');
      print('🔍 Testing backend connection...');
      print('   Server URL: $serverUrl');
      print('   Health Check URL: $healthUrl');
      print('   Backend IP from .env: ${_getServerBaseUrl()}');
      print('   Platform: ${Platform.operatingSystem}');
      print('   Timestamp: ${DateTime.now().toIso8601String()}');
      print('═══════════════════════════════════════════════════════');
      
      print('📡 Health check 요청 전송 중...');
      final stopwatch = Stopwatch()..start();
      final response = await http.get(
        Uri.parse(healthUrl),
        headers: {
          'Accept': 'application/json',
          'Connection': 'keep-alive',
        },
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          stopwatch.stop();
          print('⏱️ Connection timeout after 15 seconds');
          print('   This usually means the server is not reachable');
          print('   Elapsed time: ${stopwatch.elapsedMilliseconds}ms');
          throw Exception('Connection timeout: 서버가 응답하지 않습니다.');
        },
      );
      
      stopwatch.stop();
      print('📡 Backend health check response received!');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('   Response Time: ${stopwatch.elapsedMilliseconds}ms');
      
      if (response.statusCode == 200) {
        print('✅ Backend server is connected and running!');
        print('   Server: FastAPI (포트 8000)');
        print('═══════════════════════════════════════════════════════');
        return true;
      } else {
        print('⚠️ Backend server responded with error status: ${response.statusCode}');
        print('═══════════════════════════════════════════════════════');
        return false;
      }
    } on SocketException catch (e) {
      print('═══════════════════════════════════════════════════════');
      print('❌ Backend connection failed! (Socket Exception)');
      print('   Error: $e');
      print('   Error Message: ${e.message}');
      print('   Address: ${e.address}');
      print('   Port: ${e.port}');
      print('═══════════════════════════════════════════════════════');
      print('💡 Troubleshooting:');
      print('   1. FastAPI 서버가 실행 중인지 확인: cd backend_python && python main.py');
      print('   2. 서버 IP 주소 확인: ${_getServerBaseUrl()}:8000');
      print('   3. 같은 Wi-Fi 네트워크에 연결되어 있는지 확인');
      print('   4. 방화벽이 포트 8000을 차단하지 않는지 확인');
      print('   5. Windows 방화벽: 포트 8000 인바운드 규칙 추가 필요');
      print('   6. 브라우저에서 http://${_getServerBaseUrl()}:8000/health 접속 테스트');
      print('   7. AndroidManifest.xml에 usesCleartextTraffic="true" 추가 확인');
      print('   8. 서버가 0.0.0.0으로 바인딩되어 있는지 확인 (host=0.0.0.0)');
      print('═══════════════════════════════════════════════════════');
      return false;
    } on HttpException catch (e) {
      print('═══════════════════════════════════════════════════════');
      print('❌ Backend connection failed! (HTTP Exception)');
      print('   Error: $e');
      print('   Message: ${e.message}');
      print('═══════════════════════════════════════════════════════');
      return false;
    } catch (e) {
      print('═══════════════════════════════════════════════════════');
      print('❌ Backend connection failed!');
      print('   Error: $e');
      print('   Error Type: ${e.runtimeType}');
      if (e.toString().contains('Failed host lookup')) {
        print('   → DNS 조회 실패: IP 주소를 확인하세요');
      } else if (e.toString().contains('Connection refused')) {
        print('   → 연결 거부: 서버가 실행 중인지 확인하세요');
      } else if (e.toString().contains('Network is unreachable')) {
        print('   → 네트워크 도달 불가: Wi-Fi 연결을 확인하세요');
      }
      print('═══════════════════════════════════════════════════════');
      print('💡 Troubleshooting:');
      print('   1. FastAPI 서버가 실행 중인지 확인: cd backend_python && python main.py');
      print('   2. 서버 IP 주소 확인: ${_getServerBaseUrl()}:8000');
      print('   3. 같은 Wi-Fi 네트워크에 연결되어 있는지 확인');
      print('   4. 방화벽이 포트 8000을 차단하지 않는지 확인');
      print('   5. Windows 방화벽: 포트 8000 인바운드 규칙 추가 필요');
      print('   6. 브라우저에서 http://${_getServerBaseUrl()}:8000/health 접속 테스트');
      print('   7. 서버가 0.0.0.0으로 바인딩되어 있는지 확인 (host=0.0.0.0)');
      print('   7. AndroidManifest.xml에 usesCleartextTraffic="true" 추가 확인');
      print('═══════════════════════════════════════════════════════');
      return false;
    }
  }
  static const String _tokenKey = 'auth_token';
  static const String _userKey = 'user_data';

  // 카카오 로그인 (카카오톡 실패 시 카카오 계정으로 fallback)
  static Future<Map<String, dynamic>?> loginWithKakao() async {
    OAuthToken token;
    
    try {
      // 백엔드 연결 확인
      print('🔗 Checking backend connection...');
      final isConnected = await checkBackendConnection();
      if (!isConnected) {
        print('⚠️ Backend connection check failed, but continuing with login attempt...');
      }
      
      // 먼저 카카오톡 로그인 시도
      try {
        token = await UserApi.instance.loginWithKakaoTalk();
      } catch (e) {
        // 카카오톡 로그인 실패 시 카카오 계정 로그인으로 fallback
        print('KakaoTalk login failed, trying KakaoAccount: $e');
        token = await UserApi.instance.loginWithKakaoAccount();
      }
      
      // 액세스 토큰으로 백엔드 인증
      print('🌐 Sending request to: $_baseUrl/kakao');
      print('📤 Request payload: { accessToken: ${token.accessToken.substring(0, 20)}... }');
      final response = await http.post(
        Uri.parse('$_baseUrl/kakao'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'accessToken': token.accessToken,
        }),
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          print('⏱️ Request timeout after 15 seconds');
          throw Exception('Request timeout: 서버에 연결할 수 없습니다. 백엔드 서버가 실행 중인지 확인하세요.');
        },
      );

      print('📥 Response received!');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');
      
      if (response.statusCode == 200) {
        print('✅ Backend responded successfully!');
      } else {
        print('⚠️ Backend responded with error status: ${response.statusCode}');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        if (data['success'] == true) {
          print('✅ Login successful');
          print('💾 Saving user data to local storage...');
          
          // 토큰 저장
          await _saveToken(data['token'] as String);
          print('✅ Token saved');
          
          // 사용자 정보 저장
          if (data['user'] != null) {
            final user = models.AppUser.fromJson(data['user'] as Map<String, dynamic>);
            await _saveUser(user);
            print('✅ User data saved: ${user.id} - ${user.name ?? user.email ?? "No name"}');
          }
          
          return data;
        } else {
          print('❌ Login failed: ${data['error']}');
        }
      } else {
        print('❌ Backend authentication failed: ${response.statusCode} - ${response.body}');
        try {
          final errorData = jsonDecode(response.body) as Map<String, dynamic>;
          throw Exception(errorData['error'] as String? ?? '서버 오류가 발생했습니다.');
        } catch (e) {
          throw Exception('서버 오류: ${response.statusCode}');
        }
      }
      
      return null;
    } catch (e) {
      print('═══════════════════════════════════════════════════════');
      print('❌ Kakao login error occurred!');
      print('   Error: $e');
      print('   Error Type: ${e.runtimeType}');
      print('═══════════════════════════════════════════════════════');
      
      if (e is Exception) {
        rethrow;
      }
      return null;
    }
  }

  // 로그아웃
  static Future<void> logout() async {
    try {
      // 카카오 로그아웃
      await UserApi.instance.logout();
    } catch (e) {
      print('Kakao logout error: $e');
    }
    
    // 로컬 저장소에서 토큰 및 사용자 정보 삭제
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }

  // 현재 사용자 정보 조회
  static Future<models.AppUser?> getCurrentUser() async {
    try {
      final token = await getToken();
      if (token == null) return null;

      final response = await http.get(
        Uri.parse('$_baseUrl/me'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true && data['user'] != null) {
          final user = models.AppUser.fromJson(data['user'] as Map<String, dynamic>);
          await _saveUser(user);
          return user;
        }
      }
      
      return null;
    } catch (e) {
      print('Get current user error: $e');
      return null;
    }
  }

  // 저장된 사용자 정보 조회
  static Future<models.AppUser?> getSavedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString(_userKey);
      if (userJson != null) {
        return models.AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('Get saved user error: $e');
      return null;
    }
  }

  // 토큰 조회
  static Future<String?> getToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_tokenKey);
    } catch (e) {
      print('Get token error: $e');
      return null;
    }
  }

  // 토큰 저장
  static Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  // 사용자 정보 저장
  static Future<void> _saveUser(models.AppUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
  }

  // 로그인 상태 확인
  static Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null;
  }
}

