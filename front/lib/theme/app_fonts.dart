import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';

/// 고양이 캐릭터에 어울리는 폰트 모음
class AppFonts {
  // 추천 폰트 옵션들 (고양이 캐릭터에 어울리는 둥글고 친근한 폰트)
  
  // 1. Nunito - 둥글고 현대적, 가독성 우수
  static TextStyle nunito({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
  }) {
    return GoogleFonts.nunito(
      fontSize: fontSize,
      fontWeight: fontWeight ?? FontWeight.normal,
      color: color,
    );
  }
  
  // 2. Quicksand - 발랄하고 귀여운 느낌 (기본 추천)
  static TextStyle quicksand({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
  }) {
    return GoogleFonts.quicksand(
      fontSize: fontSize,
      fontWeight: fontWeight ?? FontWeight.normal,
      color: color,
    );
  }
  
  // 3. Comfortaa - 부드럽고 편안한 느낌
  static TextStyle comfortaa({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
  }) {
    return GoogleFonts.comfortaa(
      fontSize: fontSize,
      fontWeight: fontWeight ?? FontWeight.normal,
      color: color,
    );
  }
  
  // 4. Poppins - 깔끔하면서도 둥근 느낌
  static TextStyle poppins({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
  }) {
    return GoogleFonts.poppins(
      fontSize: fontSize,
      fontWeight: fontWeight ?? FontWeight.normal,
      color: color,
    );
  }
  
  // 5. Fredoka - 귀엽고 장난스러운 느낌 (제목용)
  static TextStyle fredoka({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
  }) {
    return GoogleFonts.fredoka(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
    );
  }
  
  // 제목용 스타일
  static TextStyle heading({
    double fontSize = 24,
    FontWeight fontWeight = FontWeight.bold,
    Color? color,
  }) {
    return GoogleFonts.quicksand(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
    );
  }
  
  // 본문용 스타일
  static TextStyle body({
    double fontSize = 16,
    FontWeight fontWeight = FontWeight.normal,
    Color? color,
  }) {
    return GoogleFonts.nunito(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
    );
  }
  
  // 버튼용 스타일
  static TextStyle button({
    double fontSize = 16,
    FontWeight fontWeight = FontWeight.w600,
    Color? color,
  }) {
    return GoogleFonts.comfortaa(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
    );
  }
}

