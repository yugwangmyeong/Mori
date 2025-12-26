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
      
      // Python 백엔드 메시지 처리
      case 'vad.speech_started':
        _logMic('VAD speech_started (Python backend)');
        _updateUiPhase(UiPhase.listening);
        break;
      case 'vad.speech_stopped':
        _logMic('VAD speech_stopped (Python backend)');
        _updateUiPhase(UiPhase.thinking);
        break;
      case 'stt.partial':
        final delta = message['delta'] ?? message['text'] ?? '';
        if (delta.isNotEmpty) {
          _logMic('STT partial: $delta');
        }
        break;
      case 'stt.final':
        final text = message['text'] ?? '';
        if (text.isNotEmpty) {
          _logMic('STT final: $text');
          _userTranscriptController.add(text);
        }
        break;
      case 'llm.response':
        final text = message['text'] ?? '';
        if (text.isNotEmpty) {
          _logEvent('LLM response: $text');
          _aiResponseTextController.add(text);
        }
        break;
      case 'tts.start':
        print('🔊 [TTS] Received tts.start');
        _handleTtsStart(message);
        break;
      case 'tts.chunk':
        print('🔊 [TTS] Received tts.chunk');
        _handleTtsChunk(message);
        break;
      case 'tts.end':
        print('🔊 [TTS] Received tts.end');
        _handleTtsEnd(message);
        break;
      
      default:
        _logNoisy('message: $type');
    }
  }
  
  // TTS 처리 관련 메서드 (버퍼는 RealtimeService 클래스에 추가 필요)
  
  void _handleTtsStart(Map<String, dynamic> message) {
    final turnId = message['turn_id'] as int?;
    final totalBytes = message['total_bytes'] as int?;
    
    print('🔊 [TTS START] turn_id=$turnId, total_bytes=$totalBytes');
    
    if (turnId != null) {
      _ttsBuffers[turnId] = [];
      _logEvent('TTS start: turn_id=$turnId, bytes=$totalBytes');
      print('   → Buffer initialized for turn $turnId');
    } else {
      print('   ⚠️ turn_id is null!');
    }
  }
  
  void _handleTtsChunk(Map<String, dynamic> message) {
    final turnId = message['turn_id'] as int?;
    final audioB64 = message['audio_b64'] as String?;
    
    print('🔊 [TTS CHUNK] turn_id=$turnId, has_audio=${audioB64 != null}, b64_length=${audioB64?.length}');
    
    if (turnId != null && audioB64 != null) {
      try {
        final bytes = base64Decode(audioB64);
        _ttsBuffers[turnId]?.add(bytes);
        final bufferSize = _ttsBuffers[turnId]?.length ?? 0;
        print('   → Chunk added: ${bytes.length} bytes, buffer_chunks=$bufferSize');
        _logNoisy('TTS chunk received: turn_id=$turnId, bytes=${bytes.length}');
      } catch (e) {
        print('   ❌ Base64 decode error: $e');
        _logEvent('TTS chunk decode error', data: {'error': e.toString()});
      }
    } else {
      print('   ⚠️ Missing data: turn_id=$turnId, audio_b64=${audioB64 != null}');
    }
  }
  
  void _handleTtsEnd(Map<String, dynamic> message) async {
    final turnId = message['turn_id'] as int?;
    
    print('🔊 [TTS END] turn_id=$turnId, has_buffer=${_ttsBuffers.containsKey(turnId)}');
    
    if (turnId != null && _ttsBuffers.containsKey(turnId)) {
      try {
        // 모든 청크를 하나로 합치기
        final allChunks = _ttsBuffers[turnId]!;
        final chunkCount = allChunks.length;
        final totalLength = allChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
        
        print('   → Merging $chunkCount chunks, total_bytes=$totalLength');
        
        final mp3Bytes = Uint8List(totalLength);
        
        int offset = 0;
        for (final chunk in allChunks) {
          mp3Bytes.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        
        print('   → MP3 merged successfully: ${mp3Bytes.length} bytes');
        _logEvent('TTS complete: turn_id=$turnId, total_bytes=${mp3Bytes.length}');
        
        // MP3 파일로 저장 및 재생
        print('   → Calling _playTtsAudio...');
        await _playTtsAudio(mp3Bytes, turnId);
        
        // 버퍼 정리
        _ttsBuffers.remove(turnId);
        print('   ✅ TTS buffer cleaned');
      } catch (e) {
        print('   ❌ TTS end error: $e');
        _logEvent('TTS end error', data: {'error': e.toString()});
      }
    } else {
      print('   ⚠️ No buffer found for turn $turnId');
    }
  }
  
  Future<void> _playTtsAudio(Uint8List mp3Bytes, int turnId) async {
    try {
      print('🔊 [_playTtsAudio] Starting, bytes=${mp3Bytes.length}');
      
      // 임시 디렉토리에 MP3 파일 저장
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/tts_$turnId.mp3';
      final file = File(filePath);
      
      print('   → Saving to: $filePath');
      await file.writeAsBytes(mp3Bytes);
      print('   → File saved successfully');
      
      _logEvent('TTS saved to: $filePath');
      
      // audioplayers로 재생
      print('   → Calling playTtsFile...');
      await playTtsFile(filePath);
      
      print('🔊 TTS 재생 요청 완료: $filePath');
    } catch (e) {
      print('❌ [_playTtsAudio] Error: $e');
      _logEvent('TTS play error', data: {'error': e.toString()});
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

