import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user.dart' as models;
import '../services/auth_service.dart';

class AuthState {
  final models.AppUser? user;
  final bool isLoading;
  final String? error;

  AuthState({
    this.user,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    models.AppUser? user,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  bool get isAuthenticated => user != null;
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(AuthState()) {
    _loadUser();
  }

  Future<void> _loadUser() async {
    state = state.copyWith(isLoading: true);
    try {
      final user = await AuthService.getSavedUser();
      if (user != null) {
        // 저장된 사용자 정보로 상태 업데이트
        state = state.copyWith(user: user, isLoading: false);
        
        // 서버에서 최신 정보 확인
        final currentUser = await AuthService.getCurrentUser();
        if (currentUser != null) {
          state = state.copyWith(user: currentUser);
        }
      } else {
        state = state.copyWith(isLoading: false);
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  Future<bool> loginWithKakao() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await AuthService.loginWithKakao();
      if (result != null && result['success'] == true) {
        final user = models.AppUser.fromJson(result['user'] as Map<String, dynamic>);
        state = state.copyWith(user: user, isLoading: false);
        return true;
      } else {
        final errorMsg = result?['error'] as String? ?? '로그인에 실패했습니다.';
        state = state.copyWith(
          isLoading: false,
          error: errorMsg,
        );
        return false;
      }
    } catch (e) {
      String errorMessage = '로그인 중 오류가 발생했습니다.';
      final errorStr = e.toString();
      
      // 사용자가 취소한 경우
      if (errorStr.contains('CANCELED') || errorStr.contains('User canceled') || errorStr.contains('canceled')) {
        // 사용자가 취소한 경우는 에러 메시지를 표시하지 않음
        state = state.copyWith(
          isLoading: false,
          error: null, // 에러 메시지 없음
        );
        return false;
      } else if (errorStr.contains('NotSupportError')) {
        errorMessage = '카카오톡이 설치되어 있지 않거나 카카오 계정이 연결되지 않았습니다.';
      } else if (errorStr.contains('KOE101') || errorStr.contains('KOE')) {
        errorMessage = '카카오 로그인 설정 오류입니다. 네이티브 앱 키와 AndroidManifest.xml 설정을 확인해주세요.';
      } else if (errorStr.contains('SocketException') || 
                 errorStr.contains('Failed host lookup') ||
                 errorStr.contains('Connection refused')) {
        errorMessage = '서버에 연결할 수 없습니다. 백엔드 서버가 실행 중인지 확인해주세요. (IP: 172.20.10.5:3000)';
      } else if (errorStr.contains('timeout')) {
        errorMessage = '서버 응답 시간이 초과되었습니다. 네트워크 연결을 확인해주세요.';
      } else if (errorStr.contains('서버 오류')) {
        errorMessage = errorStr;
      } else if (errorStr.contains('PlatformException')) {
        // PlatformException이지만 취소가 아닌 경우
        errorMessage = '카카오 로그인에 실패했습니다. 다시 시도해주세요.';
      } else {
        errorMessage = '로그인 실패: ${e.toString()}';
      }
      
      print('❌ Auth error: $errorMessage');
      state = state.copyWith(
        isLoading: false,
        error: errorMessage,
      );
      return false;
    }
  }

  Future<void> logout() async {
    state = state.copyWith(isLoading: true);
    try {
      await AuthService.logout();
      state = AuthState(isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});

