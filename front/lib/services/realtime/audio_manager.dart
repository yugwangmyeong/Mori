part of '../realtime_service.dart';

// 오디오 관리 관련 로직
extension RealtimeAudioManager on RealtimeService {
  // 마이크 오디오 스트림 시작
  Future<bool> startAudioCapture() async {
    try {
      if (_peerConnection == null) {
        print('⚠️ PeerConnection이 없음. 먼저 연결하세요.');
        return false;
      }

      // 이미 오디오 스트림이 있고 트랙이 활성화되어 있으면 그대로 사용
      if (_localStream != null) {
        final audioTracks = _localStream!.getAudioTracks();
        if (audioTracks.isNotEmpty) {
          // 트랙이 이미 PeerConnection에 추가되어 있는지 확인
          final senders = await _peerConnection!.getSenders();
          final hasAudioSender = senders.any((sender) => sender.track?.kind == 'audio');
          
          if (hasAudioSender) {
            print('✅ 이미 오디오 스트림이 활성화되어 있고 PeerConnection에 추가되어 있습니다.');
            // 트랙 활성화 확인 (연결 후 마이크 제어는 track.enabled로만)
            for (var track in audioTracks) {
              if (!track.enabled) {
                track.enabled = true;
                print('   → 트랙 활성화: ${track.id}');
              }
            }
            return true;
          } else {
            // 연결 후에는 addTrack를 하지 않음
            print('⚠️ 오디오 트랙이 PeerConnection에 추가되지 않음. connect()에서 추가되어야 합니다.');
            // 연결 후에는 track.enabled만 제어
            for (var track in audioTracks) {
              track.enabled = true;
              print('   → 트랙 활성화만 수행 (addTrack 없음): ${track.id}');
            }
            return false; // 트랙이 추가되지 않았으므로 false 반환
          }
        }
      }

      // 오디오 스트림이 없으면 새로 생성
      print('🎤 마이크 오디오 스트림 시작...');

      final Map<String, dynamic> mediaConstraints = {
        'audio': {
          'sampleRate': 24000,
          'channelCount': 1,
          'echoCancellation': true,
          'noiseSuppression': true,
        },
      };
      
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);

      // 오디오 트랙 상태 확인 및 모니터링
      final audioTracks = _localStream!.getAudioTracks();
      if (audioTracks.isEmpty) {
        print('❌ 오디오 트랙을 찾을 수 없습니다.');
        return false;
      }

      print('🎤 오디오 트랙 정보:');
      for (var track in audioTracks) {
        print('   - 트랙 ID: ${track.id}');
        print('   - 활성화 상태: ${track.enabled}');
        print('   - 음소거 상태: ${track.muted}');
        print('   - 종류: ${track.kind}');
        
        track.onEnded = () {
          print('⚠️ 오디오 트랙이 종료되었습니다.');
        };
      }

      // 오디오 트랙을 PeerConnection에 추가
      // 트랙은 connect()에서 offer 만들기 전에 추가되어야 함
      final senders = await _peerConnection!.getSenders();
      final hasAudioSender = senders.any((sender) => sender.track?.kind == 'audio');
      
      if (!hasAudioSender) {
        // 연결 후에는 addTrack를 하지 않음
        print('⚠️ 오디오 트랙이 PeerConnection에 추가되지 않음. connect()에서 추가되어야 합니다.');
        for (var track in audioTracks) {
          track.enabled = true;
          print('   → 트랙 활성화만 수행 (addTrack 없음): ${track.id}');
        }
        return false;
      } else {
        print('✅ 오디오 트랙이 이미 PeerConnection에 추가되어 있습니다.');
        for (var track in audioTracks) {
          if (!track.enabled) {
            track.enabled = true;
            print('   → 트랙 활성화: ${track.id}');
          }
        }
      }
      
      // 트랙이 제대로 추가되었는지 확인
      final finalSenders = await _peerConnection!.getSenders();
      for (var sender in finalSenders) {
        if (sender.track?.kind == 'audio') {
          print('   ✓ RTCRtpSender 확인: ${sender.track?.id}');
          print('   ✓ 트랙 활성화: ${sender.track?.enabled}');
        }
      }

      // 주기적으로 오디오 전송 상태 확인
      _startAudioMonitoring();

      print('✅ 오디오 스트림이 WebRTC를 통해 Realtime API로 전송 중입니다.');
      print('   → VAD가 말을 감지하면 speech_stopped 이벤트를 받고 자동으로 응답 생성됩니다.');
      
      return true;
    } catch (e) {
      print('❌ 오디오 스트림 시작 오류: $e');
      return false;
    }
  }

  // 오디오 모니터링 시작
  void _startAudioMonitoring() {
    _audioMonitoringTimer?.cancel();
    _audioMonitoringTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_localStream == null || _peerConnection == null) {
        timer.cancel();
        return;
      }

      try {
        final audioTracks = _localStream!.getAudioTracks();
        if (audioTracks.isEmpty) {
          print('⚠️ [오디오 모니터링] 오디오 트랙이 없습니다.');
          return;
        }

        final senders = await _peerConnection!.getSenders();
        final audioSenders = senders.where((s) => s.track?.kind == 'audio').toList();
        final activeSenders = audioSenders.where((s) => s.track?.enabled == true).toList();
        
        print('📊 [오디오 모니터링] 상태:');
        print('   - 로컬 트랙 수: ${audioTracks.length}');
        print('   - 전송 중인 트랙 수: ${audioSenders.length}');
        print('   - 활성화된 전송 트랙 수: ${activeSenders.length}');
        
        for (var track in audioTracks) {
          print('   - 트랙 ${track.id}: enabled=${track.enabled}, muted=${track.muted}');
        }
        
        for (var sender in audioSenders) {
          final isActive = sender.track?.enabled == true;
          print('   - Sender 트랙 ${sender.track?.id}: enabled=${sender.track?.enabled} ${isActive ? "✅ 전송 중" : "❌ 비활성"}');
        }
        
        if (activeSenders.isEmpty) {
          print('⚠️ [경고] 활성화된 오디오 전송 트랙이 없습니다!');
        } else {
          print('✅ [확인] ${activeSenders.length}개의 오디오 트랙이 전송 중입니다.');
        }
      } catch (e) {
        print('❌ [오디오 모니터링] 오류: $e');
      }
    });
  }

  // 오디오 모니터링 중지
  void _stopAudioMonitoring() {
    _audioMonitoringTimer?.cancel();
    _audioMonitoringTimer = null;
  }

  // 원격 오디오 재생 보장
  void _ensureRemoteAudioPlayback(MediaStreamTrack audioTrack) {
    try {
      // 트랙이 활성화되어 있는지 확인
      if (!audioTrack.enabled) {
        audioTrack.enabled = true;
        print('   ✅ 원격 오디오 트랙 활성화');
      }
      
      // 원격 스트림이 제대로 저장되어 있는지 확인
      if (_remoteStream != null) {
        final tracks = _remoteStream!.getAudioTracks();
        print('   📊 원격 스트림에 ${tracks.length}개의 오디오 트랙이 있음');
        for (var track in tracks) {
          print('      → 트랙 ${track.id}: enabled=${track.enabled}, muted=${track.muted}');
        }
      } else {
        print('   ⚠️ 원격 스트림이 저장되지 않음');
      }
      
      // Android에서 스피커폰 설정 강제
      if (Platform.isAndroid) {
        try {
          // flutter_webrtc는 기본적으로 스피커폰으로 라우팅됨
          // 추가 설정이 필요하면 Helper 사용 가능
          print('   📱 [Android] 스피커폰 활성화 (flutter_webrtc 기본 동작)');
          print('   📱 [Android] 오디오 라우팅: 스피커폰');
        } catch (e) {
          print('   ⚠️ [Android] 오디오 라우팅 설정 오류: $e');
        }
      }
      
      print('   ✅ 원격 오디오 재생 준비 완료');
    } catch (e) {
      print('   ❌ 원격 오디오 재생 확인 오류: $e');
    }
  }

  // 마이크 토글은 더 이상 사용하지 않음 (대화 일시정지로 대체)
  Future<void> toggleMute() async {
    print('⚠️ toggleMute()는 deprecated입니다. setPaused(true/false) 사용');
  }

  Future<void> mute() async {
    print('⚠️ mute()는 deprecated입니다. 마이크는 항상 on, setPaused(true) 사용');
  }

  Future<void> unmute() async {
    print('⚠️ unmute()는 deprecated입니다. 마이크는 항상 on, setPaused(false) 사용');
  }

  // 오디오 스트림 중지
  Future<void> stopAudioCapture() async {
    try {
      _stopAudioMonitoring();
      
      if (_localStream != null) {
        // 오디오 트랙 비활성화
        for (var track in _localStream!.getAudioTracks()) {
          await track.stop();
        }
        await _localStream!.dispose();
        _localStream = null;
        print('🛑 오디오 스트림 중지');
      }
    } catch (e) {
      print('❌ 오디오 스트림 중지 오류: $e');
    }
  }
}

