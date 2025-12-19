import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../services/realtime_service.dart';
import 'service_providers.dart';


// 채팅 상태 모델
class ChatState {
  final List<ChatMessage> messages;
  final bool isPaused;
  final bool isLoading;
  final bool isConnected;

  ChatState({
    this.messages = const [],
    this.isPaused = false, // 기본값은 대화 활성화
    this.isLoading = false,
    this.isConnected = false,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isPaused,
    bool? isLoading,
    bool? isConnected,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isPaused: isPaused ?? this.isPaused,
      isLoading: isLoading ?? this.isLoading,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

// 채팅 상태 관리 Provider
class ChatNotifier extends StateNotifier<ChatState> {
  final RealtimeService _realtimeService;
  StreamSubscription? _audioSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _userTranscriptSubscription;
  StreamSubscription? _aiResponseSubscription;
  StreamSubscription? _aiAudioSubscription;
  StreamSubscription? _messageSubscription;
  Timer? _audioTimer;
  bool _initialized = false;
  bool _isReconnecting = false;
  bool _userHangup = false; // 사용자가 수동으로 종료한 경우 자동 재연결 금지
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  String _currentAiResponse = ''; // 실시간 응답 텍스트 누적용

  ChatNotifier(this._realtimeService) : super(ChatState()) {
    _initializeRealtime();
  }

  // Realtime 서비스 초기화
  Future<void> _initializeRealtime() async {
    if (_initialized) return;
    _initialized = true;

    // 연결 상태 리스너
    _connectionSubscription = _realtimeService.connectionStatus.listen((status) {
      state = state.copyWith(isConnected: status == 'connected');
      
      // 연결 성공 시 재연결 시도 횟수 리셋 및 마이크 상태 동기화
      if (status == 'connected') {
        _reconnectAttempts = 0;
        _isReconnecting = false;
        print('🔄 연결 성공 - 현재 pause 상태 유지: ${state.isPaused}');
        // 연결 시점에 pause 상태를 RealtimeService에 반영 (강제 해제 금지)
        _realtimeService.setPaused(state.isPaused);
      }
      
      // 연결이 끊어진 경우 자동 재연결 시도
      // 단, 사용자가 수동으로 종료한 경우(_userHangup == true)는 재연결하지 않음
      if ((status == 'disconnected' || status == 'error') && 
          !_isReconnecting && 
          !_userHangup && // 사용자 Hangup 시 재연결 금지
          _reconnectAttempts < _maxReconnectAttempts &&
          status != 'connecting') {
        print('⚠️ 연결 끊어짐 감지 (시도 횟수: $_reconnectAttempts/$_maxReconnectAttempts)');
        // 약간의 지연 후 재연결 (기존 연결이 완전히 정리되도록)
        Future.delayed(const Duration(seconds: 3), () {
          if (!_realtimeService.isConnected && !_isReconnecting && !_userHangup) {
            _reconnect();
          }
        });
      } else if (_reconnectAttempts >= _maxReconnectAttempts) {
        print('❌ 최대 재연결 시도 횟수 초과. 수동으로 연결해주세요.');
      } else if (_userHangup) {
        print('⏸️ 자동 재연결 건너뜀: 사용자가 수동으로 종료함');
      }
    });

    // 사용자 음성 전사 리스너
    _userTranscriptSubscription = _realtimeService.userTranscript.listen((transcript) {
      // 사용자 메시지 추가
      final userMessage = ChatMessage(text: transcript, isUser: true);
      state = state.copyWith(
        messages: [...state.messages, userMessage],
        isLoading: true,
      );
    });

    // AI 응답 텍스트 리스너 (실시간 delta 누적)
    _aiResponseSubscription = _realtimeService.aiResponseText.listen((response) {
      // 실시간 응답 텍스트 누적
      _currentAiResponse += response;
      
      // 기존 AI 메시지가 있으면 업데이트, 없으면 새로 추가
      final messages = List<ChatMessage>.from(state.messages);
      final lastMessageIndex = messages.length - 1;
      
      if (lastMessageIndex >= 0 && !messages[lastMessageIndex].isUser) {
        // 마지막 메시지가 AI 메시지면 업데이트
        messages[lastMessageIndex] = ChatMessage(
          text: _currentAiResponse,
          isUser: false,
        );
      } else {
        // 새 AI 메시지 추가
        messages.add(ChatMessage(
          text: _currentAiResponse,
          isUser: false,
        ));
      }
      
      state = state.copyWith(
        messages: messages,
        isLoading: false,
      );
    });
    
    // 응답 완료 이벤트 리스너 (다음 응답을 위해 리셋)
    _messageSubscription = _realtimeService.messages.listen((message) {
      if (message['type'] == 'response.done') {
        _currentAiResponse = ''; // 다음 응답을 위해 리셋
        print('🔄 AI 응답 완료, 다음 응답 준비');
      }
    });

    // AI 오디오 응답 리스너 (WebRTC 방식)
    // 주의: flutter_webrtc는 원격 스트림을 자동으로 재생하지만,
    // 플랫폼/오디오 라우팅에 따라 재생되지 않을 수 있으므로 상태를 확인해야 함
    _aiAudioSubscription = _realtimeService.aiAudioTrack.listen((audioTrack) {
      print('🔊 [ChatNotifier] AI 오디오 트랙 수신: ${audioTrack.id}');
      print('   → 트랙 활성화: ${audioTrack.enabled}');
      print('   → 트랙 음소거: ${audioTrack.muted}');
      print('   → 트랙 종류: ${audioTrack.kind}');
      
      // 트랙이 활성화되어 있는지 확인
      if (!audioTrack.enabled) {
        print('⚠️ [ChatNotifier] 오디오 트랙이 비활성화되어 있습니다. 활성화 중...');
        audioTrack.enabled = true;
      }
      
      // 트랙 상태 모니터링
      audioTrack.onEnded = () {
        print('⚠️ [ChatNotifier] AI 오디오 트랙 종료됨: ${audioTrack.id}');
      };
      
      // 주기적으로 트랙 상태 확인 (재생이 안 되고 있는지 확인)
      Timer.periodic(const Duration(seconds: 5), (timer) {
        if (!_realtimeService.isConnected) {
          timer.cancel();
          return;
        }
        print('📊 [ChatNotifier] 원격 오디오 트랙 상태:');
        print('   → enabled: ${audioTrack.enabled}');
        print('   → muted: ${audioTrack.muted}');
        
        // 트랙이 비활성화되어 있으면 재활성화
        if (!audioTrack.enabled) {
          print('   ⚠️ 트랙이 비활성화됨 - 재활성화');
          audioTrack.enabled = true;
        }
      });
    });

    // 자동 연결
    await _realtimeService.connect();
  }

  // 연결 확인 및 재연결
  Future<void> ensureConnection() async {
    if (!_realtimeService.isConnected) {
      print('🔌 연결되지 않음, 연결 시도...');
      await _realtimeService.connect();
    }
  }

  // 재연결 시도
  Future<void> _reconnect() async {
    print('RECONNECT requested, userHangup=$_userHangup, attempts=$_reconnectAttempts');
    
    if (_userHangup) {
      print('⏸️ 재연결 건너뜀: 사용자가 수동으로 종료함');
      return;
    }
    
    if (_isReconnecting) {
      print('⏳ 이미 재연결 중입니다...');
      return;
    }

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      print('❌ 최대 재연결 시도 횟수 초과. 수동으로 연결해주세요.');
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;

    try {
      // 기존 연결이 완전히 정리될 때까지 충분히 대기
      print('⏳ 기존 연결 정리 대기 중... (3초)');
      await Future.delayed(const Duration(seconds: 3));
      
      // 연결 상태 다시 확인
      if (!_realtimeService.isConnected) {
        print('🔄 재연결 시도 중... (${_reconnectAttempts}/$_maxReconnectAttempts)');
        await _realtimeService.connect();
        
        // 연결 성공 확인을 위해 잠시 대기
        await Future.delayed(const Duration(seconds: 2));
        
        if (_realtimeService.isConnected) {
          print('✅ 재연결 성공!');
          _isReconnecting = false;
        } else {
          throw Exception('재연결 실패: 연결되지 않음');
        }
      } else {
        print('✅ 이미 연결되어 있습니다.');
        _isReconnecting = false;
      }
    } catch (e) {
      print('❌ 재연결 실패: $e');
      
      // 재연결 실패 시 5초 후 다시 시도 (최대 시도 횟수 내에서만)
      if (_reconnectAttempts < _maxReconnectAttempts) {
        Future.delayed(const Duration(seconds: 5), () {
          _isReconnecting = false;
          if (!_realtimeService.isConnected && _reconnectAttempts < _maxReconnectAttempts) {
            _reconnect();
          }
        });
      } else {
        _isReconnecting = false;
        print('❌ 최대 재연결 시도 횟수 초과. 앱을 재시작하거나 수동으로 연결해주세요.');
      }
    }
  }

  // 메시지 전송
  void sendMessage(String text) {
    if (text.trim().isEmpty) return;

    // 사용자 메시지 추가
    final userMessage = ChatMessage(text: text.trim(), isUser: true);
    state = state.copyWith(
      messages: [...state.messages, userMessage],
      isLoading: true,
    );

    // 챗봇 응답 시뮬레이션 (나중에 실제 API로 교체)
    Future.delayed(const Duration(milliseconds: 500), () {
      final botMessage = ChatMessage(
        text: '응답이 여기에 표시됩니다.',
        isUser: false,
      );
      state = state.copyWith(
        messages: [...state.messages, botMessage],
        isLoading: false,
      );
    });
  }

  // 마이크 음소거/해제 토글
  Future<void> togglePause() async {
    final next = !state.isPaused;
    print('👆 pause/resume tapped: before=${state.isPaused} after=$next');

    if (!state.isConnected) {
      print('⚠️ 연결되지 않았습니다. pause 상태만 갱신합니다.');
      state = state.copyWith(isPaused: next);
      _realtimeService.setPaused(next);
      return;
    }

    _realtimeService.setPaused(next);
    state = state.copyWith(isPaused: next);
  }

  Future<void> pauseConversation() async {
    if (state.isPaused) return;
    _realtimeService.setPaused(true);
    state = state.copyWith(isPaused: true);
  }

  Future<void> resumeConversation() async {
    if (!state.isPaused) return;
    _realtimeService.setPaused(false);
    state = state.copyWith(isPaused: false);
  }

  // 메시지 삭제
  void deleteMessage(int index) {
    final messages = List<ChatMessage>.from(state.messages);
    if (index >= 0 && index < messages.length) {
      messages.removeAt(index);
      state = state.copyWith(messages: messages);
    }
  }

  // 전체 메시지 삭제
  void clearMessages() {
    state = state.copyWith(messages: []);
  }

  // 연결 종료 (hangup 호출)
  Future<void> disconnect() async {
    print('🔌 ChatProvider: 연결 종료 중...');
    _userHangup = true; // 사용자 종료 플래그 설정
    try {
      await _realtimeService.hangupCall();
      await _realtimeService.disconnect();
      print('✅ ChatProvider: 연결 종료 완료');
    } catch (e) {
      print('❌ ChatProvider: 연결 종료 오류: $e');
    }
  }
  
  // 다시 시작 (사용자가 수동으로 재연결)
  Future<void> restartConnection() async {
    print('🔄 사용자 재연결 요청');
    _userHangup = false; // 플래그 리셋
    _reconnectAttempts = 0; // 재시도 횟수 리셋
    await _realtimeService.connect();
  }

  @override
  void dispose() {
    // 연결 종료 (hangup 호출)
    disconnect();
    
    _audioSubscription?.cancel();
    _connectionSubscription?.cancel();
    _userTranscriptSubscription?.cancel();
    _aiResponseSubscription?.cancel();
    _aiAudioSubscription?.cancel();
    _messageSubscription?.cancel();
    _audioTimer?.cancel();
    super.dispose();
  }
}

// Provider 선언
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final realtimeService = ref.watch(realtimeServiceProvider);
  return ChatNotifier(realtimeService);
});

