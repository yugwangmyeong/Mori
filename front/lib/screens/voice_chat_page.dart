import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';
import '../providers/service_providers.dart';
import '../models/ui_phase.dart';
import '../widgets/waveform_ring.dart';

class VoiceChatPage extends ConsumerStatefulWidget {
  const VoiceChatPage({super.key});

  @override
  ConsumerState<VoiceChatPage> createState() => _VoiceChatPageState();
}

class _VoiceChatPageState extends ConsumerState<VoiceChatPage>
    with SingleTickerProviderStateMixin {
  StreamSubscription? _uiPhaseSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _transcriptSubscription;
  
  UiPhase _currentPhase = UiPhase.idle;
  String _userTranscript = '';
  bool _showTranscript = false; // 개발자 모드용
  late AnimationController _lottieController;

  @override
  void initState() {
    super.initState();
    _lottieController = AnimationController(vsync: this);
    _lottieController.repeat();
    _initializeConnection();
  }

  Future<void> _initializeConnection() async {
    final webrtcService = ref.read(webrtcVoiceServiceProvider);
    
    // UI 상태 리스너
    _uiPhaseSubscription = webrtcService.uiPhase.listen((phase) {
      if (mounted) {
        setState(() {
          _currentPhase = phase;
        });
      }
    });

    // 연결 상태 리스너
    _connectionSubscription = webrtcService.connectionStatus.listen((status) {
      if (mounted) {
        setState(() {});
      }
    });

    // 사용자 음성 전사 리스너 (개발자 모드용)
    _transcriptSubscription = webrtcService.transcript.listen((transcript) {
      if (mounted && _showTranscript) {
        setState(() {
          _userTranscript = transcript;
        });
      }
    });

    // 연결 시도
    await webrtcService.connect();
  }

  @override
  void dispose() {
    _lottieController.dispose();
    _uiPhaseSubscription?.cancel();
    _connectionSubscription?.cancel();
    _transcriptSubscription?.cancel();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final webrtcService = ref.watch(webrtcVoiceServiceProvider);
    final isConnected = webrtcService.isConnected;

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Mori'),
        actions: [
          // 연결 상태 표시
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isConnected ? Colors.green : Colors.red,
                ),
              ),
            ),
          ),
          // 개발자 모드 토글
          IconButton(
            icon: Icon(_showTranscript ? Icons.code : Icons.code_off),
            onPressed: () {
              setState(() {
                _showTranscript = !_showTranscript;
                if (!_showTranscript) {
                  _userTranscript = '';
                }
              });
            },
            tooltip: '개발자 모드 (STT 표시)',
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 캐릭터 + 파형 링
            Stack(
              alignment: Alignment.center,
              children: [
                // 파형 링 (listening/speaking일 때만 표시)
                if (_currentPhase == UiPhase.listening || _currentPhase == UiPhase.speaking)
                  WaveformRing(
                    isActive: true,
                    size: 320,
                    color: _currentPhase == UiPhase.listening 
                        ? Colors.blue 
                        : Colors.green,
                  ),
                // Lottie 캐릭터
                SizedBox(
                  width: 280,
                  height: 280,
                  child: Lottie.asset(
                    'assets/images/mori.json',
                    fit: BoxFit.contain,
                    controller: _lottieController,
                    onLoaded: (composition) {
                      _lottieController.duration = composition.duration;
                      _lottieController.repeat();
                    },
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 40),
            
            // 상태 텍스트
            Text(
              _currentPhase.displayText,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: Colors.grey[700],
              ),
            ),
            
            // 개발자 모드: STT 표시
            if (_showTranscript && _userTranscript.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Text(
                  _userTranscript,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.blue[900],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            
            // 연결 상태 안내
            if (!isConnected) ...[
              const SizedBox(height: 20),
              Text(
                '연결 중...',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[500],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
