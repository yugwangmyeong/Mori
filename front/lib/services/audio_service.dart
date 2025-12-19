import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  bool _isRecording = false;
  StreamSubscription<Uint8List>? _audioStreamSubscription;
  final StreamController<Uint8List> _audioController = StreamController<Uint8List>.broadcast();
  bool _isPlaying = false;

  // 오디오 스트림
  Stream<Uint8List> get audioStream => _audioController.stream;

  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;

  // 마이크 권한 요청
  Future<bool> requestPermission() async {
    try {
      final status = await Permission.microphone.request();
      
      if (status.isGranted) {
        print('✅ 마이크 권한 허용됨');
        return true;
      } else {
        print('❌ 마이크 권한 거부됨');
        return false;
      }
    } catch (e) {
      print('❌ 권한 요청 오류: $e');
      return false;
    }
  }

  // 권한 확인
  Future<bool> hasPermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }

  // 녹음 시작
  Future<bool> startRecording() async {
    try {
      // 권한 확인
      if (!await hasPermission()) {
        final granted = await requestPermission();
        if (!granted) {
          return false;
        }
      }

      // 이미 녹음 중이면 중지
      if (_isRecording) {
        await stopRecording();
      }

      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('🎤 [마이크] 녹음 시작 요청...');
      print('   시간: ${DateTime.now().toIso8601String()}');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      // 오디오 설정: PCM 16-bit, 24kHz, 모노 (OpenAI Realtime API 요구사항)
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 24000,
        numChannels: 1,
      );

      // 스트림 시작
      final stream = await _recorder.startStream(config);
      
      _audioStreamSubscription = stream.listen(
        (data) {
          // 오디오 데이터를 스트림으로 전달
          _audioController.add(data);
        },
        onError: (error) {
          print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
          print('❌ [마이크] 오디오 스트림 오류');
          print('   에러: $error');
          print('   시간: ${DateTime.now().toIso8601String()}');
          print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
          _isRecording = false;
        },
      );

      _isRecording = true;
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('✅ [마이크] 녹음 시작됨 (ON)');
      print('   상태: 녹음 중');
      print('   포맷: PCM 16-bit, 24kHz, 모노');
      print('   시간: ${DateTime.now().toIso8601String()}');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      return true;
    } catch (e) {
      print('❌ 녹음 시작 오류: $e');
      _isRecording = false;
      return false;
    }
  }

  // 녹음 중지
  Future<void> stopRecording() async {
    try {
      if (!_isRecording) {
        return;
      }

      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('🛑 [마이크] 녹음 중지 요청...');
      print('   시간: ${DateTime.now().toIso8601String()}');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      
      await _audioStreamSubscription?.cancel();
      await _recorder.stop();
      
      _isRecording = false;
      _audioStreamSubscription = null;
      
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('✅ [마이크] 녹음 중지됨 (OFF)');
      print('   상태: 대기 중');
      print('   시간: ${DateTime.now().toIso8601String()}');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    } catch (e) {
      print('❌ 녹음 중지 오류: $e');
      _isRecording = false;
    }
  }

  // PCM16 오디오 재생 (청크 단위)
  Future<void> playAudioChunk(List<int> audioData) async {
    if (audioData.isEmpty) return;

    try {
      // WAV 헤더 추가
      final wavData = _createWavFile(audioData);
      
      // 임시 파일로 저장
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(path.join(tempDir.path, 'temp_audio_${DateTime.now().millisecondsSinceEpoch}.wav'));
      await tempFile.writeAsBytes(wavData);
      
      // 재생
      _isPlaying = true;
      await _player.play(DeviceFileSource(tempFile.path), mode: PlayerMode.lowLatency);
      
      // 재생 완료 후 파일 삭제 및 상태 업데이트
      _player.onPlayerComplete.listen((_) {
        _isPlaying = false;
        tempFile.delete().catchError((_) => tempFile);
      });
      
      print('🔊 오디오 청크 재생 시작: ${audioData.length} bytes');
    } catch (e) {
      print('❌ 오디오 재생 오류: $e');
      _isPlaying = false;
    }
  }

  // WAV 파일 생성 (PCM16, 24kHz, 모노)
  Uint8List _createWavFile(List<int> pcmData) {
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize; // 헤더(44바이트) - 8바이트 = 36 + 데이터
    
    final wav = Uint8List(44 + dataSize);
    int offset = 0;
    
    // RIFF 헤더
    wav.setRange(offset, offset += 4, 'RIFF'.codeUnits);
    wav[offset++] = fileSize & 0xFF;
    wav[offset++] = (fileSize >> 8) & 0xFF;
    wav[offset++] = (fileSize >> 16) & 0xFF;
    wav[offset++] = (fileSize >> 24) & 0xFF;
    wav.setRange(offset, offset += 4, 'WAVE'.codeUnits);
    
    // fmt 청크
    wav.setRange(offset, offset += 4, 'fmt '.codeUnits);
    wav[offset++] = 16; // fmt 청크 크기
    wav[offset++] = 0;
    wav[offset++] = 0;
    wav[offset++] = 0;
    wav[offset++] = 1; // 오디오 포맷 (1 = PCM)
    wav[offset++] = 0;
    wav[offset++] = 1; // 채널 수 (모노)
    wav[offset++] = 0;
    wav[offset++] = 0xE0; // 샘플레이트 (24000 = 0x5DC0, 리틀엔디안)
    wav[offset++] = 0x5D;
    wav[offset++] = 0x00;
    wav[offset++] = 0x00;
    wav[offset++] = 0x40; // 바이트레이트 (24000 * 1 * 2 = 48000 = 0xBB80, 리틀엔디안)
    wav[offset++] = 0xBB;
    wav[offset++] = 0x00;
    wav[offset++] = 0x00;
    wav[offset++] = 2; // 블록 정렬 (채널 * 샘플당 바이트)
    wav[offset++] = 0;
    wav[offset++] = 16; // 비트당 샘플
    wav[offset++] = 0;
    
    // data 청크
    wav.setRange(offset, offset += 4, 'data'.codeUnits);
    wav[offset++] = dataSize & 0xFF;
    wav[offset++] = (dataSize >> 8) & 0xFF;
    wav[offset++] = (dataSize >> 16) & 0xFF;
    wav[offset++] = (dataSize >> 24) & 0xFF;
    
    // PCM 데이터
    wav.setRange(offset, offset + dataSize, pcmData);
    
    return wav;
  }

  // 오디오 재생 중지
  Future<void> stopPlaying() async {
    try {
      await _player.stop();
      _isPlaying = false;
    } catch (e) {
      print('❌ 오디오 재생 중지 오류: $e');
    }
  }

  // 리소스 정리
  Future<void> dispose() async {
    await stopRecording();
    await stopPlaying();
    await _recorder.dispose();
    await _player.dispose();
    await _audioController.close();
  }
}

