import 'package:flutter/material.dart';

extension TextStyleExtension on TextStyle {
  TextStyle get bold => copyWith(fontWeight: FontWeight.bold);
  TextStyle get semiBold => copyWith(fontWeight: FontWeight.w600);
  TextStyle get medium => copyWith(fontWeight: FontWeight.w500);
  TextStyle get regular => copyWith(fontWeight: FontWeight.normal);
  
  TextStyle color(Color color) => copyWith(color: color);
  TextStyle size(double size) => copyWith(fontSize: size);
  TextStyle opacity(double opacity) {
    final baseColor = (color as Color?) ?? Colors.black;
    // ignore: deprecated_member_use
    return copyWith(
      color: baseColor.withOpacity(opacity.clamp(0.0, 1.0)),
    );
  }
}

extension SizedBoxExtension on double {
  SizedBox get w => SizedBox(width: this); // 가로 간격
  SizedBox get h => SizedBox(height: this); // 세로 간격
}
