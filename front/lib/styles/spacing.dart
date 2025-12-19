import 'package:flutter/material.dart';

/// 간격 상수 정의 (CSS margin/padding처럼)
class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
  static const double xxxl = 64.0;
}

/// EdgeInsets 헬퍼 (간편하게 사용)
class AppPadding {
  static const EdgeInsets allXS = EdgeInsets.all(AppSpacing.xs);
  static const EdgeInsets allSM = EdgeInsets.all(AppSpacing.sm);
  static const EdgeInsets allMD = EdgeInsets.all(AppSpacing.md);
  static const EdgeInsets allLG = EdgeInsets.all(AppSpacing.lg);
  static const EdgeInsets allXL = EdgeInsets.all(AppSpacing.xl);
  
  static const EdgeInsets horizontalMD = EdgeInsets.symmetric(horizontal: AppSpacing.md);
  static const EdgeInsets horizontalLG = EdgeInsets.symmetric(horizontal: AppSpacing.lg);
  
  static const EdgeInsets verticalMD = EdgeInsets.symmetric(vertical: AppSpacing.md);
  static const EdgeInsets verticalLG = EdgeInsets.symmetric(vertical: AppSpacing.lg);
}

class AppMargin {
  static const EdgeInsets allXS = EdgeInsets.all(AppSpacing.xs);
  static const EdgeInsets allSM = EdgeInsets.all(AppSpacing.sm);
  static const EdgeInsets allMD = EdgeInsets.all(AppSpacing.md);
  static const EdgeInsets allLG = EdgeInsets.all(AppSpacing.lg);
}

