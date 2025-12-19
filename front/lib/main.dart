import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // .env 파일 로드
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print('⚠️ .env 파일을 찾을 수 없습니다. 기본값을 사용합니다.');
  }

  // 카카오 SDK 초기화
  KakaoSdk.init(
    nativeAppKey: dotenv.get(
      'KAKAO_NATIVE_APP_KEY',
      fallback: '1d48288f172ae47bb1b44065a8408122',
    ),
  );

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mori',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme, // 분리된 테마 사용
      home: const SplashScreen(),
    );
  }
}
