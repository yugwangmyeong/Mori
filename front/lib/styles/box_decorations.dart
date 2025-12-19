import 'package:flutter/material.dart';

/// BoxDecoration 스타일 모음 (CSS처럼)
class AppBoxDecorations {
  // 카드 스타일
  static BoxDecoration card({
    Color? color,
    double borderRadius = 12.0,
    List<BoxShadow>? shadows,
  }) {
    return BoxDecoration(
      color: color ?? Colors.white,
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: shadows ?? [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
  
  // 버튼 스타일
  static BoxDecoration button({
    required Color color,
    double borderRadius = 28.0,
  }) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: [
        BoxShadow(
          color: color.withOpacity(0.3),
          blurRadius: 12,
          spreadRadius: 2,
        ),
      ],
    );
  }
  
  // 입력 필드 스타일
  static BoxDecoration input({
    Color? color,
    double borderRadius = 24.0,
    Border? border,
  }) {
    return BoxDecoration(
      color: color ?? Colors.grey[100],
      borderRadius: BorderRadius.circular(borderRadius),
      border: border,
    );
  }
  
  // 그라데이션 배경
  static BoxDecoration gradient({
    required List<Color> colors,
    AlignmentGeometry begin = Alignment.topLeft,
    AlignmentGeometry end = Alignment.bottomRight,
  }) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: begin,
        end: end,
        colors: colors,
      ),
    );
  }
}

