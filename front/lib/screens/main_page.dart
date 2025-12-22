import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';
import '../providers/auth_provider.dart';
import '../models/ui_phase.dart';
import '../theme/app_colors.dart';
import '../widgets/waveform_ring.dart';
import '../providers/service_providers.dart';
import '../services/webrtc_voice_service.dart';
import 'login_page.dart';
import 'webrtc_test_page.dart';

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lottieController;
  
  UiPhase _currentPhase = UiPhase.idle;
  String _userTranscript = '';
  bool _showTranscript = false;
  bool _isMicEnabled = true;

  @override
  void initState() {
    super.initState();
    _lottieController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    // MainPage initState - WebRTC 연결
    print('MainPage initState - WebRTC 연결 시작');
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final webrtcService = ref.read(webrtcVoiceServiceProvider);
      
      // UI 상태 리스너 설정
      webrtcService.uiPhase.listen((phase) {
        if (mounted) {
          setState(() {
            _currentPhase = phase;
          });
        }
      });
      
      // 연결 상태 리스너
      webrtcService.connectionStatus.listen((status) {
        if (mounted) {
          setState(() {});
          print('WebRTC 연결 상태: $status');
        }
      });
      
      // 전사 리스너 (개발자 모드용)
      webrtcService.transcript.listen((transcript) {
        if (mounted && _showTranscript) {
          setState(() {
            _userTranscript = transcript;
          });
        }
      });
      
      // 초기 마이크 상태 설정
      _isMicEnabled = webrtcService.isMicEnabled;
      
      // 마이크 상태 리스너
      webrtcService.micEnabled.listen((enabled) {
        if (mounted) {
          setState(() {
            _isMicEnabled = enabled;
          });
        }
      });
      
      // WebRTC 연결 시작
      try {
        await webrtcService.connect();
        print('✅ WebRTC 연결 성공');
      } catch (e) {
        print('❌ WebRTC 연결 실패: $e');
      }
    });
  }

  @override
  void dispose() {
    _lottieController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webrtcService = ref.watch(webrtcVoiceServiceProvider);

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [AppColors.primary, AppColors.secondary],
                ),
              ),
              child: const Icon(Icons.pets, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            const Text(
              'Mori',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        actions: [
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
          IconButton(
            icon: const Icon(Icons.history_outlined),
            onPressed: () {
              // 대화 기록 보기
            },
            tooltip: '대화 기록',
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              // 설정 페이지로 이동
            },
            tooltip: '설정',
          ),
          // WebRTC 테스트 버튼 (개발용)
          IconButton(
            icon: const Icon(Icons.wifi),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const WebRTCTestPage(),
                ),
              );
            },
            tooltip: 'WebRTC 테스트',
          ),
              // 종료 버튼
          IconButton(
            icon: const Icon(Icons.exit_to_app, size: 20),
            onPressed: () async {
              // 로그아웃 확인 다이얼로그
              final shouldLogout = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('로그아웃'),
                  content: const Text('로그아웃 하시겠습니까?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('취소'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('로그아웃'),
                    ),
                  ],
                ),
              );

              if (shouldLogout == true && mounted) {
                // WebRTC 연결 종료
                final webrtcService = ref.read(webrtcVoiceServiceProvider);
                try {
                  await webrtcService.disconnect();
                  print('✅ WebRTC 연결 종료 완료');
                } catch (e) {
                  print('⚠️ WebRTC 연결 종료 중 오류: $e');
                }

                // 로그아웃 처리
                final authNotifier = ref.read(authProvider.notifier);
                await authNotifier.logout();

                // login_page로 이동
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (context) => const LoginPage()),
                    (route) => false,
                  );
                }
              }
            },
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
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
                        _lottieController.repeat(reverse: true);
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
              if (!webrtcService.isConnected) ...[
                const SizedBox(height: 20),
                Text(
                  '연결 중...',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[500],
                  ),
                ),
              ],
              
              const SizedBox(height: 40),
              
              // 마이크 버튼 (일시정지/재개)
              _buildMicButton(context, webrtcService),
            ],
          ),
        ),
      ),
    );
  }


  Widget _buildMicButton(
    BuildContext context,
    WebRTCVoiceService webrtcService,
  ) {
    // 마이크 상태에 따라 색상 결정
    final micColor = webrtcService.isConnected && _isMicEnabled 
        ? Colors.red 
        : Colors.grey.shade400;
    final micIcon = _isMicEnabled ? Icons.mic : Icons.mic_off;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Center(
          child: Semantics(
            button: true,
            label: _isMicEnabled ? '마이크 끄기' : '마이크 켜기',
            child: GestureDetector(
              onTap: () async {
                print('마이크 버튼 클릭 - 현재 상태: ${_isMicEnabled ? "ON" : "OFF"}');
                if (webrtcService.isConnected) {
                  await webrtcService.toggleMicrophone();
                } else {
                  print('⚠️ WebRTC가 연결되지 않았습니다.');
                }
              },
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: micColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(
                  micIcon,
                  color: Colors.white,
                  size: 42,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
