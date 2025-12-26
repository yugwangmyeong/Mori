import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/ui_phase.dart';

part 'realtime/webrtc_connection.dart';
part 'realtime/message_handler.dart';
part 'realtime/audio_manager.dart';

// Call 상태 머신
enum CallState {
  idle,        // 초기 상태, 연결 없음
  connecting,  // 연결 시도 중
  connected,   // 연결 완료
  disconnecting, // 연결 종료 중
}

class RealtimeService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream; // AI 오디오 스트림
  RTCRtpSender? _audioSender; // 오디오 sender 저장 (replaceTrack용)
  bool _isConnected = false;
  bool _sessionReady = false;
  CallState _callState = CallState.idle; // Call 상태 머신
  bool _isPaused = false; // 대화 일시정지 상태
  String? _callId; // OpenAI call_id 저장
  Timer? _audioMonitoringTimer;
  bool _responseInFlight = false; // VAD speech_stopped 중복 방지 플래그
  Timer? _speechStopDebounce; // speech_stopped 디바운스 타이머
  Map<String, dynamic>? _lastSessionUpdatePayload; // 최근 session.update 페이로드
  RTCIceConnectionState? _iceState; // ICE 연결 상태
  Timer? _statsTimer; // 마이크 stats 폴링 타이머
  int? _lastAudioBytesSent; // 마지막 오디오 bytesSent 값
  
  // TTS 버퍼 (turn_id -> chunks)
  final Map<int, List<List<int>>> _ttsBuffers = {};
  
  // TTS 재생용 AudioPlayer
  AudioPlayer? _ttsPlayer;
  
  final StreamController<String> _connectionStatusController = StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> _userTranscriptController = StreamController<String>.broadcast();
  final StreamController<String> _aiResponseTextController = StreamController<String>.broadcast();
  final StreamController<MediaStreamTrack> _aiAudioTrackController = StreamController<MediaStreamTrack>.broadcast();
  final StreamController<UiPhase> _uiPhaseController = StreamController<UiPhase>.broadcast();
  
  UiPhase _currentUiPhase = UiPhase.idle;

  // 로그 레벨 설정
  final bool _enableEventLogs = true; // EVENT 기본 on
  bool _enableNoisyLogs = false; // NOISY 기본 off

  void _logFlow(String message) {
    print('FLOW | $message');
  }

  void _logEvent(String message, {Map<String, dynamic>? data}) {
    if (!_enableEventLogs) return;
    if (data != null) {
      print('EVENT | $message | data=${jsonEncode(data)}');
    } else {
      print('EVENT | $message');
    }
  }

  void _logNoisy(String message) {
    if (_enableNoisyLogs && kDebugMode) {
      print('NOISY | $message');
    }
  }

  void _logMic(String message) {
    print('MIC | $message');
  }

  // 연결 판정 getter
  bool get isRtcConnected =>
      _iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
      _iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted;

  bool get isDcOpen =>
      _dataChannel != null &&
      _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen;

  bool get isConversationReady =>
      isRtcConnected && isDcOpen && _sessionReady;

  // 연결 준비 상태 업데이트 및 로그
  void _updateConversationReady() {
    // 실제 값들 확인
    final dcState = _dataChannel?.state?.toString() ?? 'null';
    final iceStateStr = _iceState?.toString() ?? 'null';
    final dcOpen = isDcOpen;
    final rtcConnected = isRtcConnected;
    
    // 디버그: ready 계산 직전 실제 값들 출력
    _logFlow('ready check: dcState=$dcState dcOpen=$dcOpen iceState=$iceStateStr rtcConnected=$rtcConnected sessionReady=$_sessionReady');
    
    final ready = isConversationReady;
    final iceStr = _iceState?.toString() ?? 'null';
    final dcStr = isDcOpen ? 'open' : 'closed';
    final sessionStr = _sessionReady ? 'true' : 'false';
    _logFlow('ready=$ready ice=$iceStr dc=$dcStr sessionReady=$sessionStr');
  }

  // 연결 상태 스트림
  Stream<String> get connectionStatus => _connectionStatusController.stream;
  
  // 메시지 스트림
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  // 사용자 음성 전사 스트림
  Stream<String> get userTranscript => _userTranscriptController.stream;

  // AI 응답 텍스트 스트림
  Stream<String> get aiResponseText => _aiResponseTextController.stream;

  // AI 오디오 트랙 스트림 (WebRTC)
  Stream<MediaStreamTrack> get aiAudioTrack => _aiAudioTrackController.stream;

  // UI 상태 스트림
  Stream<UiPhase> get uiPhase => _uiPhaseController.stream;
  UiPhase get currentUiPhase => _currentUiPhase;

  // UI 상태 업데이트
  void _updateUiPhase(UiPhase phase) {
    if (_currentUiPhase != phase) {
      _currentUiPhase = phase;
      _uiPhaseController.add(phase);
    }
  }

  bool get isConnected => _isConnected;
  bool get isCallActive => _callState == CallState.connected;
  String? get callId => _callId;
  bool get isPaused => _isPaused;

  void setPaused(bool value) {
    _isPaused = value;
    _logFlow('paused=$_isPaused');
    if (_isPaused) {
      // Pause 시점에는 VAD 후처리 타이머와 플래그를 리셋해 재개 시 stuck 방지
      _speechStopDebounce?.cancel();
      _responseInFlight = false;
      _logFlow('pause cleanup: debounce cleared, responseInFlight reset');
    }
  }

  void togglePause() {
    setPaused(!_isPaused);
  }
  
  bool get isMuted {
    if (_localStream == null) return true;
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) return true;
    // 모든 트랙이 음소거되어 있으면 muted
    return audioTracks.every((track) => !track.enabled);
  }
  
  // 하위 호환성을 위한 getter (deprecated)
  @Deprecated('Use isMuted instead')
  bool get isRecording => !isMuted;

  // 백엔드 서버 URL 가져오기
  static String _getServerBaseUrl() {
    final envUrl = dotenv.get('BACKEND_URL', fallback: '').trim();
    
    if (envUrl.isEmpty) {
      if (Platform.isAndroid) {
        return '10.0.2.2'; // Android 에뮬레이터 기본값
      } else if (Platform.isIOS) {
        return 'localhost'; // iOS 시뮬레이터 기본값
      }
    }
    
    if (envUrl.contains('localhost')) {
      return 'localhost';
    }
    
    if (envUrl.contains(':')) {
      return envUrl.split(':').first;
    }
    
    return envUrl;
  }

  static String get _baseUrl {
    if (kDebugMode) {
      final serverIp = _getServerBaseUrl();
      return 'http://$serverIp:3000';
    }
    return 'https://your-production-server.com';
  }

  // 세션 생성은 더 이상 필요 없음 (공식 문서 방식에서는 직접 연결)

  // 로컬 오디오 송신자 로그
  Future<void> _logLocalAudioSender() async {
    if (_peerConnection == null) return;
    try {
      final senders = await _peerConnection!.getSenders();
      final audioSenders = senders.where((s) => s.track?.kind == 'audio').toList();
      if (audioSenders.isNotEmpty) {
        final first = audioSenders.first;
        _logMic('senderCount=${audioSenders.length} '
            'trackId=${first.track?.id} '
            'enabled=${first.track?.enabled}');
      } else {
        _logMic('senderCount=0 (no audio sender)');
      }
    } catch (e) {
      _logMic('sender check error: $e');
    }
  }

  // 마이크 stats 폴링 시작
  void _startMicStatsProbe() {
    _statsTimer?.cancel();
    _lastAudioBytesSent = null;
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_peerConnection == null) return;
      try {
        final stats = await _peerConnection!.getStats();
        final bytes = _extractAudioBytesSent(stats);
        if (bytes != null) {
          final delta = (_lastAudioBytesSent == null)
              ? 0
              : (bytes - _lastAudioBytesSent!);
          _lastAudioBytesSent = bytes;
          _logMic('STATS audio bytesSent=$bytes delta=$delta');
        }
      } catch (_) {
        // stats 실패 시 조용히 무시
      }
    });
  }

  void _stopMicStatsProbe() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastAudioBytesSent = null;
  }

  int? _extractAudioBytesSent(dynamic stats) {
    int? bytes;

    void handleMap(Map report) {
      final type = report['type'];
      final kind = report['kind'] ?? report['mediaType'];
      if (type == 'outbound-rtp' && kind == 'audio') {
        final v = report['bytesSent'];
        if (v is int) {
          bytes = (bytes == null) ? v : (v > bytes! ? v : bytes);
        } else if (v is num) {
          final vi = v.toInt();
          bytes = (bytes == null) ? vi : (vi > bytes! ? vi : bytes);
        }
      }
    }

    if (stats is Map) {
      for (final report in stats.values) {
        if (report is Map) handleMap(report);
      }
    } else if (stats is List) {
      for (final report in stats) {
        if (report is Map) {
          handleMap(report);
        } else {
          try {
            final type = report.type;
            final values = report.values as Map?;
            if (type == 'outbound-rtp' && values != null) {
              final kind = values['kind'] ?? values['mediaType'];
              if (kind == 'audio') {
                final v = values['bytesSent'];
                if (v is int) {
                  bytes = (bytes == null) ? v : (v > bytes! ? v : bytes);
                } else if (v is num) {
                  final vi = v.toInt();
                  bytes = (bytes == null) ? vi : (vi > bytes! ? vi : bytes);
                }
              }
            }
          } catch (_) {
            // 무시
          }
        }
      }
    }

    return bytes;
  }
  
  Future<void> dispose() async {
    _stopAudioMonitoring();
    _stopMicStatsProbe();
    _speechStopDebounce?.cancel();
    
    // TTS 플레이어 정리
    if (_ttsPlayer != null) {
      await _ttsPlayer!.stop();
      await _ttsPlayer!.dispose();
      _ttsPlayer = null;
    }
    
    await disconnect();
    _connectionStatusController.close();
    _messageController.close();
    _userTranscriptController.close();
    _aiResponseTextController.close();
    _aiAudioTrackController.close();
    _uiPhaseController.close();
  }
}
