part of '../realtime_service.dart';

// WebRTC 연결 관련 로직
extension RealtimeWebRTCConnection on RealtimeService {
  // WebRTC 연결 (공식 문서 방식)
  Future<bool> connect({String voice = 'echo'}) async {
    // 중복 호출 방지 가드
    if (_callState == CallState.connecting || _callState == CallState.connected) {
      print('⏭️ connect() ignored: state=$_callState');
      return _callState == CallState.connected;
    }
    
    print('CONNECT requested, state=$_callState');
    _callState = CallState.connecting;
    try {
      print('🔌 WebRTC 연결 시도...');
      
      // 기존 연결 정리
      await _cleanupExistingConnection();
      
      // 기존 스트림 정리
      if (_localStream != null) {
        try {
          await stopAudioCapture();
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          print('⚠️ 기존 스트림 정리 중 오류 (무시): $e');
        }
      }
      
      _connectionStatusController.add('connecting');

      // RTCPeerConnection 생성
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      };

      _peerConnection = await createPeerConnection(configuration);
      
      // 마이크 오디오 스트림 준비 및 추가
      await _setupLocalAudioStream();
      
      // 이벤트 리스너 설정
      _setupPeerConnectionListeners();
      
      // DataChannel 생성 및 설정
      await _setupDataChannel();
      
      // WebRTC offer 생성 및 전송
      await _createAndSendOffer(voice);
      
      // DataChannel 열림 대기
      await _waitForDataChannel();
      
      // ⚠️ 이번 단계에서는 연결 성공만 확인
      // 세션 준비 대기는 다음 단계에서 진행
      // await _waitForSessionReady();
      
      // 연결 완료 후 마이크 활성화
      _activateMicrophoneForCall();
      
      // 마이크 stats 폴링 시작
      _startMicStatsProbe();
      
      _callState = CallState.connected;
      return true;
    } catch (e) {
      print('❌ WebRTC 연결 오류: $e');
      _isConnected = false;
      _callState = CallState.idle;
      _connectionStatusController.add('error');
      return false;
    }
  }

  // 기존 연결 정리
  Future<void> _cleanupExistingConnection() async {
    if (_peerConnection == null) return;
    
    print('🔄 기존 연결 정리 중...');
    try {
      // DataChannel 정리
      if (_dataChannel != null) {
        try {
          await _dataChannel!.close();
        } catch (e) {
          // 무시
        }
        _dataChannel = null;
      }
      
      // PeerConnection 상태 확인 및 정리
      final signalingState = _peerConnection!.signalingState;
      print('📊 기존 연결 signaling state: $signalingState');
      
      // PeerConnection 정리
      await _peerConnection!.close();
      
      // 정리 완료 대기 (상태가 closed가 될 때까지)
      int waitCount = 0;
      while (waitCount < 20) {
        final state = _peerConnection!.signalingState;
        if (state == RTCSignalingState.RTCSignalingStateClosed) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }
      
      // 추가 대기 (완전히 정리되도록)
      await Future.delayed(const Duration(milliseconds: 2000));
    } catch (e) {
      print('⚠️ 기존 연결 정리 중 오류 (무시): $e');
    }
    _peerConnection = null;
  }

  // 로컬 오디오 스트림 설정
  Future<void> _setupLocalAudioStream() async {
    // 이미 스트림이 있고 트랙이 PeerConnection에 추가되어 있으면 재생성하지 않음
    if (_localStream != null && _peerConnection != null) {
      final senders = await _peerConnection!.getSenders();
      final hasAudioSender = senders.any((sender) => sender.track?.kind == 'audio');
      if (hasAudioSender) {
        print('✅ 이미 오디오 스트림이 PeerConnection에 추가되어 있습니다.');
        return;
      }
    }
    
    print('🎤 마이크 오디오 스트림 준비 중...');
    try {
      // 기존 스트림이 있으면 먼저 정리
      if (_localStream != null) {
        try {
          for (var track in _localStream!.getAudioTracks()) {
            await track.stop();
          }
          await _localStream!.dispose();
        } catch (e) {
          print('⚠️ 기존 스트림 정리 중 오류 (무시): $e');
        }
        _localStream = null;
      }
      
      final Map<String, dynamic> mediaConstraints = {
        'audio': {
          'sampleRate': 24000,
          'channelCount': 1,
          'echoCancellation': true,
          'noiseSuppression': true,
        },
      };
      
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      final audioTracks = _localStream!.getAudioTracks();
      
      if (audioTracks.isNotEmpty) {
        // 첫 번째 오디오 트랙만 추가하고 sender 저장 (중복 방지)
        final track = audioTracks.first;
        _audioSender = await _peerConnection!.addTrack(track, _localStream!);
        print('✅ 마이크 오디오 트랙을 PeerConnection에 추가 (연결 전): ${track.id}');
        print('   → RTCRtpSender 저장: ${_audioSender?.track?.id}');
        await _logLocalAudioSender();
      } else {
        print('⚠️ 마이크 오디오 트랙을 찾을 수 없습니다.');
      }
    } catch (e) {
      print('⚠️ 마이크 권한 오류: $e');
      // 마이크 권한이 없으면 연결 후에 추가할 수 있도록 계속 진행
    }
  }

  // PeerConnection 이벤트 리스너 설정
  void _setupPeerConnectionListeners() {
    // 연결 상태 이벤트 리스너
    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      _iceState = state;
      _logNoisy('ICE state: $state');
      
      // 모든 ICE 상태 변경 시 ready 상태 업데이트 (Checking 포함)
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _isConnected = true;
        _connectionStatusController.add('connected');
        _logFlow('connected=true ice=$state');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                 state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _isConnected = false;
        _connectionStatusController.add('disconnected');
      }
      
      // 모든 상태 변경 시 ready 상태 갱신 (Checking도 포함)
      _updateConversationReady();
    };

    // 원격 스트림 추가 리스너
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      print('📥 원격 트랙 수신: ${event.track.kind} (${event.track.id})');
      if (event.track.kind == 'audio') {
        _handleRemoteAudioTrack(event);
      }
    };
  }

  // 원격 오디오 트랙 처리
  void _handleRemoteAudioTrack(RTCTrackEvent event) {
    // 원격 스트림 저장
    if (event.streams.isNotEmpty) {
      _remoteStream = event.streams[0];
      print('   → 원격 스트림 ID: ${_remoteStream!.id}');
      print('   → 원격 스트림 오디오 트랙 수: ${_remoteStream!.getAudioTracks().length}');
    } else {
      print('   ⚠️ 원격 스트림이 이벤트에 포함되지 않음');
    }
    
    final audioTrack = event.track;
    print('🔊 AI 오디오 트랙 수신: ${audioTrack.id}');
    print('   → 트랙 활성화: ${audioTrack.enabled}');
    print('   → 트랙 음소거: ${audioTrack.muted}');
    
    // 트랙 활성화 확인 및 설정
    if (!audioTrack.enabled) {
      audioTrack.enabled = true;
      print('   → 트랙 활성화됨');
    }
    
    // 원격 오디오 재생 보장 (Android 오디오 라우팅 강제 포함)
    _ensureRemoteAudioPlayback(audioTrack);
    
    // 트랙 상태 모니터링
    audioTrack.onEnded = () {
      print('⚠️ 원격 오디오 트랙 종료됨: ${audioTrack.id}');
    };
    
    // 트랙 상태 변경 모니터링
    Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isConnected || _peerConnection == null) {
        timer.cancel();
        return;
      }
      print('📊 [원격 오디오 모니터링] 트랙 ${audioTrack.id}:');
      print('   → enabled: ${audioTrack.enabled}');
      print('   → muted: ${audioTrack.muted}');
      
      // 트랙이 비활성화되어 있으면 다시 활성화
      if (!audioTrack.enabled) {
        print('   ⚠️ 트랙이 비활성화됨 - 재활성화 시도');
        audioTrack.enabled = true;
      }
    });
    
    _aiAudioTrackController.add(audioTrack);
  }

  // DataChannel 설정
  Future<void> _setupDataChannel() async {
    // DataChannel 생성 (JSON 메시지용)
    final dataChannelInit = RTCDataChannelInit();
    dataChannelInit.ordered = true;
    _dataChannel = await _peerConnection!.createDataChannel('messages', dataChannelInit);
    
    // DataChannel 메시지 핸들러
    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      try {
        final data = jsonDecode(message.text) as Map<String, dynamic>;
        final type = data['type'] as String?;
        
        // 디버깅: 모든 메시지 타입 로그 (TTS 메시지 포함)
        if (type != null) {
          // TTS 메시지는 항상 로그
          if (type.startsWith('tts.')) {
            print('📨 [DataChannel TTS] type: $type');
            print('   → Full data: ${jsonEncode(data)}');
          }
          // 중요한 이벤트는 상세 로그
          else if (type.contains('transcription') || 
              type.contains('response') || 
              type.contains('conversation') ||
              type.contains('error') ||
              type.contains('session')) {
            print('📨 [DataChannel 메시지] type: $type');
            if (kDebugMode && type.contains('transcription')) {
              print('   → 데이터: ${jsonEncode(data)}');
            }
          } 
          // Python 백엔드 메시지 (vad, stt, llm)
          else if (type.startsWith('vad.') || type.startsWith('stt.') || type.startsWith('llm.')) {
            print('📨 [DataChannel Python] type: $type');
          }
          else {
            // 기타 메시지는 간단히만 로그
            if (kDebugMode) {
              print('📨 [DataChannel 메시지] type: $type');
            }
          }
        }
        
        _messageController.add(data);
        _handleMessage(data);
      } catch (e) {
        print('⚠️ 메시지 파싱 오류: $e');
        print('   → 원본 메시지: ${message.text}');
      }
    };
  }

  // WebRTC offer 생성 및 전송
  Future<void> _createAndSendOffer(String voice) async {
    // WebRTC offer 생성
    final offer = await _peerConnection!.createOffer();
    
    // setLocalDescription 완료 대기
    await _peerConnection!.setLocalDescription(offer);
    
    // setLocalDescription이 완전히 처리될 때까지 대기
    int retryCount = 0;
    while (retryCount < 10) {
      final signalingState = _peerConnection!.signalingState;
      if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
      retryCount++;
    }

    print('📤 WebRTC offer 생성 완료 (signaling state: ${_peerConnection!.signalingState})');

    // 백엔드를 통해 OpenAI에 offer 전송
    final offerResponse = await http.post(
        Uri.parse('${RealtimeService._baseUrl}/api/realtime/calls?voice=$voice'),
      headers: {
        'Content-Type': 'application/sdp',
      },
      body: offer.sdp ?? '',
    );

    if (offerResponse.statusCode != 200 && offerResponse.statusCode != 201) {
      print('❌ WebRTC offer 전송 실패: ${offerResponse.statusCode} - ${offerResponse.body}');
      _connectionStatusController.add('error');
      throw Exception('Offer 전송 실패');
    }

    // call_id 추출 (백엔드에서 X-Call-Id 헤더로 전달)
    final callId = offerResponse.headers['x-call-id'] ??
        offerResponse.headers['X-Call-Id'] ??
        offerResponse.headers['X-CALL-ID'];
    if (callId != null && callId.isNotEmpty && callId != 'calls') {
      _callId = callId.trim();
      print('✅ call_id stored: $_callId');
    } else {
      print('⚠️ call_id missing in response headers');
    }

    // OpenAI가 SDP answer를 텍스트로 반환
    final answerSdp = offerResponse.body;
    print('📥 WebRTC answer 수신');

    // 원격 설명 설정
    await _setRemoteDescription(answerSdp);
  }

  // 원격 설명 설정
  Future<void> _setRemoteDescription(String answerSdp) async {
    // signaling state 확인
    final currentState = _peerConnection!.signalingState;
    print('📊 현재 signaling state: $currentState');
    
    // HaveLocalOffer 상태가 아니면 대기 (offer 재생성하지 않음 - m-line 순서 오류 방지)
    if (currentState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      print('⚠️ signaling state가 HaveLocalOffer가 아님: $currentState - 대기 중...');
      // 상태가 올바를 때까지 대기 (최대 2초)
      int waitCount = 0;
      while (waitCount < 20) {
        final state = _peerConnection!.signalingState;
        if (state == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }
      print('📊 최종 signaling state: ${_peerConnection!.signalingState}');
    }

    // 원격 설명 설정
    final answer = RTCSessionDescription(answerSdp, 'answer');
    try {
      final finalState = _peerConnection!.signalingState;
      if (finalState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        throw Exception('signaling state가 올바르지 않음: $finalState (HaveLocalOffer가 아님)');
      }
      await _peerConnection!.setRemoteDescription(answer);
      print('✅ setRemoteDescription 성공');
      
      // ICE 연결 상태 확인 (연결 성공 기준)
      print('⏳ ICE 연결 상태 확인 중...');
      final completer = Completer<void>();
      Timer? timeoutTimer;
      
      // 현재 상태 확인
      final currentIceState = _peerConnection!.iceConnectionState;
      print('📊 현재 ICE 상태: $currentIceState');
      
      if (currentIceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          currentIceState == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        print('✅ ICE 연결 완료 (이미 Connected/Completed)');
        completer.complete();
      } else {
        // ICE 상태 변경 대기
        final iceStateListener = (RTCIceConnectionState state) {
          print('🔌 ICE 연결 상태 변경: $state');
          if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
            if (!completer.isCompleted) {
              print('✅ ICE 연결 완료 (Connected/Completed)');
              completer.complete();
            }
          } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                     state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
            if (!completer.isCompleted) {
              completer.completeError('ICE 연결 실패: $state');
            }
          }
        };
        
        _peerConnection!.onIceConnectionState = iceStateListener;
        
        // 타임아웃 설정 (10초)
        timeoutTimer = Timer(const Duration(seconds: 10), () {
          if (!completer.isCompleted) {
            final currentState = _peerConnection!.iceConnectionState;
            print('⏰ ICE 연결 타임아웃 (10초) - 현재 상태: $currentState');
            completer.completeError('ICE 연결 타임아웃');
          }
        });
        
        // 연결 완료 대기
        try {
          await completer.future;
          print('✅ 연결 성공: setRemoteDescription + ICE Connected/Completed');
        } catch (e) {
          print('❌ 연결 실패: $e');
          rethrow;
        } finally {
          timeoutTimer.cancel();
        }
      }
    } catch (e) {
      print('❌ setRemoteDescription 오류: $e');
      print('📊 오류 발생 시 signaling state: ${_peerConnection!.signalingState}');
      print('📊 오류 발생 시 ICE state: ${_peerConnection!.iceConnectionState}');
      rethrow;
    }
  }

  // DataChannel 열림 대기
  Future<void> _waitForDataChannel() async {
    final dataChannelCompleter = Completer<void>();
    _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
      _logFlow('DataChannel state=$state');
      if (state == RTCDataChannelState.RTCDataChannelOpen && !dataChannelCompleter.isCompleted) {
        _logFlow('DataChannel open');
        dataChannelCompleter.complete();
        _updateConversationReady();
      } else if (state != RTCDataChannelState.RTCDataChannelOpen) {
        _updateConversationReady();
      }
    };
    
    print('⏳ DataChannel 열림 대기 중...');
    try {
      await dataChannelCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          print('⚠️ DataChannel 열림 타임아웃 (5초)');
        },
      );
      print('✅ DataChannel 열림 완료');
    } catch (e) {
      print('⚠️ DataChannel 열림 대기 오류: $e');
    }
  }



  // 연결 완료 후 마이크 활성화
  void _activateMicrophoneForCall() {
    if (_localStream != null) {
      final audioTracks = _localStream!.getAudioTracks();
      for (var track in audioTracks) {
        if (!track.enabled) {
          track.enabled = true;
          print('✅ 마이크 트랙 활성화 (통화 상태): ${track.id}');
        }
      }
      print('✅ 마이크가 항상 켜져 있는 통화 상태로 설정됨');
    } else {
      print('⚠️ 마이크 스트림이 없습니다. 연결 전에 추가되어야 합니다.');
    }
  }

  // 연결 종료 (로컬 정리만, hangup은 별도 호출)
  Future<void> disconnect() async {
    // 중복 호출 방지 가드
    if (_callState == CallState.disconnecting || _callState == CallState.idle) {
      print('⏭️ disconnect() ignored: state=$_callState');
      return;
    }
    
    _callState = CallState.disconnecting;
    print('🔌 WebRTC 연결 종료 중...');
    
    // 로컬 리소스 정리
    await _cleanupLocalResources();
  }
  
  // Hangup 호출 (서버 라우트 호출 + 로컬 정리)
  Future<void> hangupCall() async {
    if (_callId == null) {
      print('⚠️ hangupCall skipped: callId is null');
      return;
    }
    
    final url = Uri.parse('${RealtimeService._baseUrl}/api/realtime/calls/$_callId/hangup');
    try {
      final r = await http.post(url);
      print('📞 hangup result: ${r.statusCode} ${r.body}');
      
      // hangup 성공 후 클라이언트 로컬 정리 보장
      if (r.statusCode == 200 || r.statusCode == 204) {
        print('✅ hangup 성공, 로컬 정리 시작...');
        await _cleanupLocalResources();
      }
    } catch (e) {
      print('❌ hangupCall 오류: $e');
      // 오류가 나도 로컬 정리는 수행
      await _cleanupLocalResources();
    }
  }
  
  // 로컬 리소스 정리 (hangup 후 필수)
  Future<void> _cleanupLocalResources() async {
    print('🧹 로컬 리소스 정리 중...');
    
    // 1. DataChannel 정리
    try {
      await _dataChannel?.close();
      print('   ✅ DataChannel closed');
    } catch (e) {
      print('   ⚠️ DataChannel close 오류: $e');
    }
    _dataChannel = null;
    
    // 2. PeerConnection 정리
    try {
      await _peerConnection?.close();
      print('   ✅ PeerConnection closed');
    } catch (e) {
      print('   ⚠️ PeerConnection close 오류: $e');
    }
    _peerConnection = null;
    
    // 3. 로컬 스트림 정리
    if (_localStream != null) {
      try {
        for (var track in _localStream!.getAudioTracks()) {
          await track.stop();
        }
        await _localStream!.dispose();
        print('   ✅ Local stream disposed');
      } catch (e) {
        print('   ⚠️ Local stream dispose 오류: $e');
      }
      _localStream = null;
    }
    
    // 4. 원격 스트림 정리
    if (_remoteStream != null) {
      try {
        for (var track in _remoteStream!.getAudioTracks()) {
          await track.stop();
        }
        await _remoteStream!.dispose();
        print('   ✅ Remote stream disposed');
      } catch (e) {
        print('   ⚠️ Remote stream dispose 오류: $e');
      }
      _remoteStream = null;
    }
    
    // 5. 상태 플래그 리셋
    _isConnected = false;
    _callId = null;
    _callState = CallState.idle;
    _connectionStatusController.add('disconnected');
    
    print('✅ 로컬 리소스 정리 완료');
  }
}

