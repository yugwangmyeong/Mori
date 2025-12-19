part of '../realtime_service.dart';

// 메시지 처리 관련 로직
extension RealtimeMessageHandler on RealtimeService {
  // 메시지 처리
  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    
    switch (type) {
      case 'session.created':
        _logEvent('session.created');
        _sessionReady = false;
        // session.created 직후 통화 설정 session.update 전송 (session.updated 수신 후 ready)
        _sendSessionUpdate();
        break;
      case 'session.update':
        _logEvent('session.update');
        break;
      case 'session.updated':
        _logEvent('session.updated');
        _sessionReady = true;
        _logFlow('sessionReady=true');
        _updateConversationReady();
        break;
      case 'conversation.item.input_audio_transcription.completed':
        final transcript = message['item']?['input_audio_transcription']?['transcript'] ?? 
                          message['transcript'] ?? '';
        if (transcript.isNotEmpty) {
          final preview = transcript.length > 30 ? transcript.substring(0, 30) : transcript;
          _logMic('TRANSCRIBE completed len=${transcript.length} preview="$preview"');
          _userTranscriptController.add(transcript);
        } else {
          _logMic('TRANSCRIBE completed len=0');
        }
        break;
      case 'conversation.item.input_audio_transcription.failed':
        _logEvent('conversation.item.input_audio_transcription.failed', data: {'error': message['error']});
        break;
      case 'conversation.item.created':
        _logEvent('conversation.item.created');
        break;
      case 'conversation.item.input_audio_transcription.started':
        _logEvent('conversation.item.input_audio_transcription.started');
        break;
      case 'conversation.item.input_audio_transcription.updated':
        _logEvent('conversation.item.input_audio_transcription.updated');
        break;
      case 'conversation.item.done':
        _logEvent('conversation.item.done');
        // create_response=false일 때 수동으로 response.create 전송
        if (!_isPaused && !_responseInFlight && isConversationReady) {
          createResponse();
        }
        break;
      case 'input_audio_buffer.committed':
        _logMic('VAD committed');
        _updateUiPhase(UiPhase.thinking);
        if (!_isPaused && !_responseInFlight && isConversationReady) {
          createResponse();
        }
        break;
      case 'input_audio_buffer.speech_stopped':
      case 'speech_stopped':
        if (_isPaused) {
          _logMic('VAD speech_stopped (ignored: paused)');
          return;
        }
        _logMic('VAD speech_stopped');
        // create_response=true이면 자동 응답 생성되므로 수동 호출 불필요
        // create_response=false일 때만 디바운스 후 수동 호출
        // 현재는 create_response=true이므로 이 부분은 주석 처리하거나 제거 가능
        // _speechStopDebounce?.cancel();
        // _speechStopDebounce = Timer(const Duration(milliseconds: 250), () {
        //   if (_responseInFlight) {
        //     _logEvent('response.create ignored (in flight)');
        //     return;
        //   }
        //   createResponse();
        // });
        break;
      case 'input_audio_buffer.speech_started':
      case 'speech_started':
        if (_isPaused) {
          _logMic('VAD speech_started (ignored: paused)');
          return;
        }
        _logMic('VAD speech_started');
        _updateUiPhase(UiPhase.listening);
        break;
      case 'response.created':
        _logEvent('response.created');
        _updateUiPhase(UiPhase.speaking);
        break;
      case 'response.output_item.added':
        _logEvent('response.output_item.added');
        break;
      case 'response.output_item.done':
        _logEvent('response.output_item.done');
        break;
      case 'response.audio_transcript.delta':
        final delta = message['delta'] ?? '';
        if (delta.isNotEmpty) {
          _aiResponseTextController.add(delta);
        }
        break;
      case 'response.audio_transcript.done':
        _logEvent('response.audio_transcript.done');
        break;
      case 'response.audio.delta':
        _logNoisy('response.audio.delta');
        break;
      case 'response.done':
        _logEvent('response.done');
        _responseInFlight = false;
        _logFlow('responseInFlight=false');
        _updateUiPhase(UiPhase.idle);
        break;
      case 'error':
        _sessionReady = false;
        _logEvent('error', data: {'error': message['error']});
        if (_lastSessionUpdatePayload != null) {
          _logEvent('last session.update payload', data: _lastSessionUpdatePayload);
        }
        _updateConversationReady();
        break;
      default:
        _logNoisy('message: $type');
    }
  }

  // 응답 생성 요청
  void createResponse() {
    if (!isConversationReady) {
      _logFlow('response.create blocked (ready=$isConversationReady)');
      return;
    }

    if (_isPaused) {
      _logEvent('response.create skipped (paused)');
      return;
    }

    // 이미 응답이 진행 중이면 무시
    if (_responseInFlight) {
      _logEvent('response.create ignored (in flight)');
      return;
    }

    _responseInFlight = true;
    _logFlow('responseInFlight=true');
    _sendMessage({
      'type': 'response.create',
    });
    _logEvent('response.create sent');
  }

  // 세션 업데이트 전송 (통화 설정)
  void _sendSessionUpdate() {
    final payload = {
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'model': 'gpt-realtime',
        'instructions': '당신은 친절하고 도움이 되는 AI 어시스턴트입니다. 모든 대화는 한국어로 진행됩니다. 자연스럽고 친근한 톤으로 대화하세요.',
        'audio': {
          'input': {
            'turn_detection': {
              'type': 'server_vad',
              'threshold': 0.5,
              'prefix_padding_ms': 300,
              'silence_duration_ms': 800,
              'create_response': true,
            },
            'transcription': {
              'model': 'gpt-4o-mini-transcribe',
            },
          },
        },
      },
    };

    _lastSessionUpdatePayload = payload;
    _sessionReady = false;
    _logEvent('session.update send', data: payload);
    _sendMessage(payload);
  }

  // 메시지 전송 (DataChannel)
  void _sendMessage(Map<String, dynamic> message) {
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      _logFlow('message send blocked: dataChannel not open');
      return;
    }

    try {
      _dataChannel!.send(RTCDataChannelMessage(jsonEncode(message)));
    } catch (e) {
      _logEvent('send error', data: {'error': e.toString()});
    }
  }
}

