/// WebRTC 기반 Voice AI 서비스
/// HTTP POST로 시그널링하고 DataChannel로 메시지 교환
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/ui_phase.dart';

class WebRTCVoiceService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  List<MediaStreamTrack>? _audioTracks; // 오디오 트랙 저장
  RTCRtpSender? _audioSender; // 오디오 sender 저장 (중복 방지)
  String? _audioTrackId; // 오디오 트랙 ID 저장 (sender 찾기용)
  
  bool _isConnected = false;
  String? _sessionId;
  bool _isMicEnabled = true; // 마이크 활성화 상태
  
  // 스트림 컨트롤러
  final StreamController<UiPhase> _uiPhaseController = 
      StreamController<UiPhase>.broadcast();
  final StreamController<String> _connectionStatusController = 
      StreamController<String>.broadcast();
  final StreamController<String> _transcriptController = 
      StreamController<String>.broadcast();
  final StreamController<bool> _micEnabledController = 
      StreamController<bool>.broadcast();
  
  UiPhase _currentPhase = UiPhase.idle;
  
  // 서버 URL
  static String get _baseUrl {
    if (kDebugMode) {
      final serverIp = _getServerBaseUrl();
      return 'http://$serverIp:8000';
    }
    return 'https://your-production-server.com';
  }
  
  static String _getServerBaseUrl() {
    final envUrl = dotenv.get('BACKEND_URL', fallback: '').trim();
    
    // .env에 BACKEND_URL이 설정되어 있으면 사용
    if (envUrl.isNotEmpty) {
      if (envUrl.contains(':')) {
        return envUrl.split(':').first;
      }
      return envUrl;
    }
    
    // 기본값: 백엔드 서버 IP
    return '172.30.1.29';
  }
  
  // Getters
  Stream<UiPhase> get uiPhase => _uiPhaseController.stream;
  Stream<String> get connectionStatus => _connectionStatusController.stream;
  Stream<String> get transcript => _transcriptController.stream;
  Stream<bool> get micEnabled => _micEnabledController.stream;
  bool get isConnected => _isConnected;
  bool get isMicEnabled => _isMicEnabled;
  UiPhase get currentPhase => _currentPhase;
  
  void _updatePhase(UiPhase phase) {
    if (_currentPhase != phase) {
      _currentPhase = phase;
      _uiPhaseController.add(phase);
    }
  }
  
  /// WebRTC 연결 시작 (HTTP POST + DataChannel)
  Future<void> connect() async {
    try {
      _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
      
      print('🔌 [WebRTC] 연결 시도: $_baseUrl/api/realtime/calls');
      print('🔌 [WebRTC] 서버 IP: ${_getServerBaseUrl()}');
      print('🔌 [WebRTC] 포트: 8000');
      
      // WebRTC PeerConnection 생성
      await _createPeerConnection();
      
      // 로컬 미디어 스트림 가져오기 (마이크)
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        }
      });
      
      // 오디오 트랙 저장
      _audioTracks = _localStream!.getAudioTracks();
      
      // 로컬 스트림을 PeerConnection에 추가
      for (final track in _audioTracks!) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      
      // sender 개수 확인 및 저장
      final allSenders = await _peerConnection!.getSenders();
      final audioSenders = allSenders.where((s) => s.track?.kind == 'audio').toList();
      print('📊 총 sender 개수: ${allSenders.length}, 오디오 sender 개수: ${audioSenders.length}');
      
      // 모든 sender 정보 출력
      for (var i = 0; i < allSenders.length; i++) {
        final sender = allSenders[i];
        print('   - sender[$i]: track=${sender.track?.id ?? "null"}, kind=${sender.track?.kind ?? "null"}');
      }
      
      if (audioSenders.length > 1) {
        print('⚠️ 경고: 오디오 sender가 ${audioSenders.length}개입니다! 중복 가능성 있음');
      }
      if (audioSenders.isNotEmpty) {
        _audioSender = audioSenders.first;
        _audioTrackId = _audioSender!.track?.id;
        print('🎤 오디오 sender 저장: track=${_audioTrackId ?? "null"}');
      }
      
      // DataChannel 생성
      await _createDataChannel();
      
      // Offer 생성
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      
      // HTTP POST로 offer 전송
      final response = await http.post(
        Uri.parse('$_baseUrl/api/realtime/calls'),
        headers: {
          'Content-Type': 'application/sdp',
        },
        body: offer.sdp,
      );
      
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('Offer 전송 실패: ${response.statusCode} - ${response.body}');
      }
      
      // Session ID 저장
      final sessionIdHeader = response.headers['x-session-id'] ?? response.headers['X-Session-Id'];
      if (sessionIdHeader != null) {
        _sessionId = sessionIdHeader;
        print('✅ Session ID 저장: $_sessionId');
      }
      
      // Answer SDP 받기
      final answerSdp = response.body;
      
      // Answer 설정
      final answer = RTCSessionDescription(answerSdp, 'answer');
      await _peerConnection!.setRemoteDescription(answer);
      
      _updateConnectionStatus('connecting');
      _updatePhase(UiPhase.idle);
      
    } catch (e) {
      print('Connection error: $e');
      _updateConnectionStatus('error');
      rethrow;
    }
  }
  
  /// DataChannel 생성
  Future<void> _createDataChannel() async {
    final dataChannelInit = RTCDataChannelInit();
    dataChannelInit.ordered = true;
    _dataChannel = await _peerConnection!.createDataChannel('messages', dataChannelInit);
    
    // DataChannel 이벤트 핸들러
    _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
      print('DataChannel state: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        print('✅ DataChannel opened');
      }
    };
    
    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      try {
        final data = jsonDecode(message.text) as Map<String, dynamic>;
        _handleDataChannelMessage(data);
      } catch (e) {
        print('Error handling DataChannel message: $e');
      }
    };
  }
  
  /// WebRTC PeerConnection 생성
  Future<void> _createPeerConnection() async {
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
    
    _peerConnection = await createPeerConnection(configuration);
    
    // 연결 상태 변경
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      print('PeerConnection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _isConnected = true;
        _updateConnectionStatus('connected');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
                 state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _isConnected = false;
        _updateConnectionStatus('disconnected');
      }
    };
    
    // 원격 트랙 수신
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio') {
        print('Remote audio track received');
        _remoteStream = event.streams[0];
        _updatePhase(UiPhase.speaking);
        
        // 오디오 재생 (자동으로 재생됨)
      }
    };
  }
  
  /// DataChannel 메시지 처리
  void _handleDataChannelMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    
    if (type == 'transcript') {
      // STT transcript 수신
      final transcript = data['transcript'] as String?;
      if (transcript != null && transcript.isNotEmpty) {
        _transcriptController.add(transcript);
      }
    } else if (type == 'phase') {
      // UI phase 업데이트 수신
      final phaseStr = data['phase'] as String?;
      if (phaseStr != null) {
        UiPhase? phase;
        switch (phaseStr) {
          case 'idle':
            phase = UiPhase.idle;
            break;
          case 'listening':
            phase = UiPhase.listening;
            break;
          case 'speaking':
            phase = UiPhase.speaking;
            break;
        }
        if (phase != null) {
          _updatePhase(phase);
        }
      }
    }
  }
  
  void _updateConnectionStatus(String status) {
    _connectionStatusController.add(status);
  }
  
  /// 마이크 토글 (켜기/끄기)
  Future<void> toggleMicrophone() async {
    if (_peerConnection == null) {
      print('⚠️ PeerConnection이 없습니다.');
      return;
    }
    
    // sender 확인 및 저장
    if (_audioSender == null) {
      final senders = await _peerConnection!.getSenders();
      
      print('📊 현재 sender 상태:');
      print('   - 총 sender 개수: ${senders.length}');
      
      // 모든 sender 정보 출력
      for (var i = 0; i < senders.length; i++) {
        final sender = senders[i];
        print('   - sender[$i]: track=${sender.track?.id ?? "null"}, kind=${sender.track?.kind ?? "null"}');
      }
      
      // track ID로 sender 찾기 (이전에 저장한 track ID가 있으면)
      if (_audioTrackId != null) {
        _audioSender = senders.firstWhere(
          (s) => s.track?.id == _audioTrackId,
          orElse: () => senders.firstWhere(
            (s) => s.track?.kind == 'audio',
            orElse: () => throw Exception('No audio sender found'),
          ),
        );
        print('🎤 저장된 track ID로 sender 찾기: ${_audioTrackId}');
      } else {
        // track ID가 없으면 kind로 찾기
        final audioSenders = senders.where((s) => s.track?.kind == 'audio').toList();
        if (audioSenders.isEmpty) {
          print('❌ 오디오 sender를 찾을 수 없습니다.');
          return;
        }
        if (audioSenders.length > 1) {
          print('⚠️ 경고: 오디오 sender가 ${audioSenders.length}개입니다! 첫 번째 sender 사용');
        }
        _audioSender = audioSenders.first;
        _audioTrackId = _audioSender!.track?.id;
      }
      
      print('🎤 오디오 sender 저장: track=${_audioTrackId ?? "null"}');
    }
    
    _isMicEnabled = !_isMicEnabled;
    
    // 현재 sender 상태 확인
    print('🔍 replaceTrack 전 상태:');
    print('   - sender.track: ${_audioSender!.track?.id ?? "null"}');
    print('   - sender.track?.kind: ${_audioSender!.track?.kind ?? "null"}');
    print('   - sender.track?.enabled: ${_audioSender!.track?.enabled ?? "null"}');
    
    if (_isMicEnabled) {
      // 마이크 켜기: 새 트랙을 가져와서 교체
      if (_localStream == null) {
        // 스트림이 없으면 새로 가져오기
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          }
        });
        _audioTracks = _localStream!.getAudioTracks();
      }
      
      // 트랙을 PeerConnection에 교체
      if (_audioTracks != null && _audioTracks!.isNotEmpty) {
        await _audioSender!.replaceTrack(_audioTracks!.first);
        _audioTrackId = _audioTracks!.first.id; // track ID 업데이트
        print('🎤 마이크 ON: ${_audioTracks!.first.id}');
        print('   - replaceTrack 후 sender.track: ${_audioSender!.track?.id ?? "null"}');
      }
    } else {
      // 마이크 끄기: 트랙을 null로 교체하여 오디오 전송 완전 중지
      print('🛑 replaceTrack(null) 호출 중...');
      await _audioSender!.replaceTrack(null);
      print('✅ replaceTrack(null) 완료');
      print('   - replaceTrack 후 sender.track: ${_audioSender!.track?.id ?? "null"}');
      
      // 로컬 트랙 중지
      if (_audioTracks != null) {
        _audioTracks!.forEach((track) {
          track.stop();
          print('🎤 마이크 OFF: ${track.id}');
        });
      }
      
      // 스트림 정리
      _localStream?.getTracks().forEach((track) => track.stop());
      _localStream?.dispose();
      _localStream = null;
      _audioTracks = null;
    }
    
    // 최종 sender 상태 확인
    final finalSenders = await _peerConnection!.getSenders();
    final finalAudioSenders = finalSenders.where((s) => s.track?.kind == 'audio').toList();
    print('📊 replaceTrack 후 최종 상태:');
    print('   - 총 sender 개수: ${finalSenders.length}');
    print('   - 오디오 sender 개수 (track이 있는): ${finalAudioSenders.length}');
    
    // 모든 sender 정보 출력 (track이 null이어도)
    for (var i = 0; i < finalSenders.length; i++) {
      final sender = finalSenders[i];
      final isOurSender = sender == _audioSender;
      print('   - sender[$i]: track=${sender.track?.id ?? "null"}, kind=${sender.track?.kind ?? "null"} ${isOurSender ? "← 우리 sender" : ""}');
    }
    
    // 우리가 사용하는 sender의 최종 상태
    if (_audioSender != null) {
      print('   - 우리 sender.track: ${_audioSender!.track?.id ?? "null"}');
      print('   - 우리 sender.track?.kind: ${_audioSender!.track?.kind ?? "null"}');
    }
    
    _micEnabledController.add(_isMicEnabled);
    print('✅ 마이크 상태 변경: ${_isMicEnabled ? "ON" : "OFF"}');
  }
  
  /// 마이크 켜기
  Future<void> enableMicrophone() async {
    if (!_isMicEnabled) {
      await toggleMicrophone();
    }
  }
  
  /// 마이크 끄기
  Future<void> disableMicrophone() async {
    if (_isMicEnabled) {
      await toggleMicrophone();
    }
  }
  
  /// 연결 종료
  Future<void> disconnect() async {
    try {
      // Hangup 요청 (선택적)
      if (_sessionId != null) {
        try {
          await http.post(
            Uri.parse('$_baseUrl/api/realtime/calls/$_sessionId/hangup'),
          );
        } catch (e) {
          print('Hangup request error (ignored): $e');
        }
      }
      
      // DataChannel 종료
      await _dataChannel?.close();
      _dataChannel = null;
      
      // 로컬 스트림 정리
      _localStream?.getTracks().forEach((track) {
        track.stop();
      });
      _localStream?.dispose();
      _localStream = null;
      
      // 원격 스트림 정리
      _remoteStream?.dispose();
      _remoteStream = null;
      
      // PeerConnection 종료
      await _peerConnection?.close();
      _peerConnection = null;
      _audioSender = null; // sender도 초기화
      _audioTrackId = null; // track ID도 초기화
      
      _isConnected = false;
      _sessionId = null;
      _updateConnectionStatus('disconnected');
      _updatePhase(UiPhase.idle);
      
    } catch (e) {
      print('Disconnect error: $e');
    }
  }
  
  /// 리소스 정리
  Future<void> dispose() async {
    await disconnect();
    await _uiPhaseController.close();
    await _connectionStatusController.close();
    await _transcriptController.close();
    await _micEnabledController.close();
  }
}