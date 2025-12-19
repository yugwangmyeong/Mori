import 'package:flutter/material.dart';

/// 텍스트 스타일 모음 (CSS 클래스처럼 사용)
class AppTextStyles {
  // 헤딩 스타일
  static const TextStyle h1 = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.5,
    height: 1.2,
  );
  
  static const TextStyle h2 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.3,
    height: 1.3,
  );
  
  static const TextStyle h3 = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.4,
  );
  
  // 본문 스타일
  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.normal,
    letterSpacing: 0.15,
    height: 1.5,
  );
  
  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.normal,
    letterSpacing: 0.25,
    height: 1.5,
  );
  
  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    letterSpacing: 0.4,
    height: 1.5,
  );
  
  // 버튼 스타일
  static const TextStyle button = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
  );
  
  static const TextStyle buttonLarge = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    letterSpacing: 1,
  );
  
  // 캡션 스타일
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    letterSpacing: 0.4,
    color: Color(0xFF6B7280),
  );
  
  // 커스텀 스타일 (색상 적용)
  static TextStyle withColor(TextStyle style, Color color) {
    return style.copyWith(color: color);
  }
  
  static TextStyle withOpacity(TextStyle style, double opacity) {
    return style.copyWith(
      color: (style.color ?? Colors.black).withOpacity(opacity),
    );
  }
}

