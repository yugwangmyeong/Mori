import 'package:flutter/material.dart';

/// 고양이 캐릭터에 어울리는 색상 팔레트
class AppColors {
  // 메인 컬러 (부드러운 코랄/피치 톤)
  static const Color primary = Color(0xFFFF8A95); // 부드러운 코랄 핑크
  static const Color primaryLight = Color(0xFFFFB3BA); // 밝은 핑크
  static const Color primaryDark = Color(0xFFFF6B7D); // 진한 핑크
  
  // 보조 컬러 (따뜻한 오렌지/피치)
  static const Color secondary = Color(0xFFFFB88C); // 따뜻한 피치
  static const Color secondaryLight = Color(0xFFFFD4A3); // 밝은 피치
  static const Color secondaryDark = Color(0xFFFF9A6B); // 진한 피치
  
  // 악센트 컬러 (부드러운 파란색)
  static const Color accent = Color(0xFFA8D8EA); // 부드러운 스카이 블루
  static const Color accentLight = Color(0xFFC8E6F0); // 밝은 스카이 블루
  
  // 배경 컬러 (부드러운 베이지/크림)
  static const Color background = Color(0xFFFFF8F3); // 따뜻한 크림
  static const Color backgroundLight = Color(0xFFFFFCF9); // 매우 밝은 크림
  static const Color surface = Color(0xFFFFFEFE); // 거의 흰색
  
  // 텍스트 컬러
  static const Color textPrimary = Color(0xFF4A4A4A); // 부드러운 다크 그레이
  static const Color textSecondary = Color(0xFF8B8B8B); // 중간 그레이
  static const Color textLight = Color(0xFFB8B8B8); // 밝은 그레이
  
  // 그라데이션 컬러 조합
  static const List<Color> gradientSunset = [
    Color(0xFFFFB3BA), // 핑크
    Color(0xFFFFDFBA), // 피치
    Color(0xFFFFF8DC), // 크림
  ];
  
  static const List<Color> gradientSky = [
    Color(0xFFA8D8EA), // 스카이 블루
    Color(0xFFC8E6F0), // 밝은 블루
    Color(0xFFFFF8F3), // 크림
  ];
  
  static const List<Color> gradientWarm = [
    Color(0xFFFF8A95), // 코랄
    Color(0xFFFFB88C), // 피치
    Color(0xFFFFF8F3), // 크림
  ];
  
  // 메시지 버블 컬러
  static const Color messageUser = Color(0xFFFF8A95); // 사용자 메시지 (코랄)
  static const Color messageBot = Color(0xFFF0F0F0); // 봇 메시지 (연한 그레이)
}

