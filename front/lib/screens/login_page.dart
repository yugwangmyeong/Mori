import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';
import 'main_page.dart';
import '../theme/app_colors.dart';
import '../providers/auth_provider.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    ));

    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _handleKakaoLogin() async {
    final authState = ref.read(authProvider.notifier);
    final success = await authState.loginWithKakao();
    
    if (success && mounted) {
      print('🚀 Navigating to MainPage...');
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const MainPage(),
        ),
      );
      print('✅ Navigation completed');
    } else if (mounted) {
      final errorMessage = ref.read(authProvider).error ?? '카카오 로그인에 실패했습니다.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          // 고양이 캐릭터에 어울리는 부드러운 그라데이션
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.gradientWarm,
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 60),
                // Lottie 애니메이션 (화면 크기에 따라 반응형)
                LayoutBuilder(
                  builder: (context, constraints) {
                    // 화면 너비의 40% 정도, 최소 250, 최대 400
                    final size = (MediaQuery.of(context).size.width * 0.4)
                        .clamp(250.0, 400.0);
                    
                    return RepaintBoundary(
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: Lottie.asset(
                          'assets/images/Cat sneaking.json',
                          fit: BoxFit.contain,
                          repeat: true,
                          animate: true,
                          frameRate: FrameRate(30),
                          // 깜빡임 방지를 위한 설정
                          key: const ValueKey('lottie_animation'),
                          errorBuilder: (context, error, stackTrace) {
                            // Lottie 파일 로드 실패 시 대체 UI
                            return Container(
                              width: size,
                              height: size,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withOpacity(0.2),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.image_not_supported_outlined,
                                    size: size * 0.3,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '로딩 중...',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                // 앱 이름
                Text(
                  'Mori',
                  style: Theme.of(context).textTheme.displayMedium?.copyWith(
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
                const SizedBox(height: 12),
                Text(
                  'Mori와 대화를 연습해보세요',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white.withOpacity(0.9),
                        fontWeight: FontWeight.w300,
                      ),
                ),
                const Spacer(),
                // 카카오 로그인 버튼
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: ref.watch(authProvider).isLoading
                              ? null
                              : _handleKakaoLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFEE500), // 카카오 노란색
                            foregroundColor: Colors.black,
                            elevation: 8,
                            shadowColor: Colors.black.withOpacity(0.3),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                          child: ref.watch(authProvider).isLoading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    // 카카오 아이콘 (간단한 텍스트로 대체)
                                    Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: Colors.black,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Center(
                                        child: Text(
                                          'K',
                                          style: TextStyle(
                                            color: Color(0xFFFEE500),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Text(
                                      '카카오로 시작하기',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 에러 메시지 표시
                      if (ref.watch(authProvider).error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            ref.watch(authProvider).error!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      // 메인 페이지로 바로 가기 버튼
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (context) => const MainPage(),
                            ),
                          );
                        },
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
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

