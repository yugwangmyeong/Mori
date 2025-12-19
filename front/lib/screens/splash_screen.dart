import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'login_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _isChecking = true;
  bool _connectionFailed = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkBackendAndNavigate();
  }

  Future<void> _checkBackendAndNavigate() async {
    setState(() {
      _isChecking = true;
      _connectionFailed = false;
      _errorMessage = null;
    });

    // 백엔드 연결 확인
    final isConnected = await AuthService.checkBackendConnection();
    
    if (!mounted) return;
    
    if (isConnected) {
      // 연결 성공 시 로그인 페이지로 이동
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const LoginPage(),
        ),
      );
    } else {
      // 연결 실패 시 재시도 옵션 표시
      setState(() {
        _isChecking = false;
        _connectionFailed = true;
        _errorMessage = '백엔드 서버에 연결할 수 없습니다.\n\n해결 방법:\n1. Windows 방화벽에서 포트 3000 허용\n2. 같은 Wi-Fi 네트워크 연결 확인\n3. 백엔드 서버 실행 확인';
      });
    }
  }

  void _skipToLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => const LoginPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.secondary,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 로고 또는 아이콘
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Icon(
                      _connectionFailed ? Icons.error_outline : Icons.pets,
                      size: 60,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // 앱 이름
                  Text(
                    'Mori',
                    style: Theme.of(context).textTheme.displayLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                          shadows: [
                            Shadow(
                              color: Colors.black.withOpacity(0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                  ),
                  const SizedBox(height: 48),
                  if (_isChecking) ...[
                    // 로딩 인디케이터
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      strokeWidth: 3,
                    ),
                    const SizedBox(height: 24),
                    // 백엔드 연결 확인 중 메시지
                    Text(
                      '백엔드 연결 확인 중...',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Colors.white.withOpacity(0.9),
                            fontWeight: FontWeight.w400,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ] else if (_connectionFailed) ...[
                    // 연결 실패 메시지
                    Icon(
                      Icons.wifi_off,
                      size: 48,
                      color: Colors.white.withOpacity(0.9),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _errorMessage ?? '백엔드 서버에 연결할 수 없습니다.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withOpacity(0.9),
                            fontWeight: FontWeight.w400,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    // 재시도 버튼
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => _checkBackendAndNavigate(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Theme.of(context).colorScheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          '다시 시도',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 건너뛰기 버튼
                    TextButton(
                      onPressed: _skipToLogin,
                      child: Text(
                        '건너뛰기',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

