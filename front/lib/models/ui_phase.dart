// UI 상태 머신
enum UiPhase {
  idle,      // 대기 중
  listening, // 듣는 중 (speech_started)
  thinking,  // 생각 중 (committed/done)
  speaking,  // 말하는 중 (output_audio_buffer.started)
}

extension UiPhaseExtension on UiPhase {
  String get displayText {
    switch (this) {
      case UiPhase.idle:
        return '대기 중';
      case UiPhase.listening:
        return '듣는 중…';
      case UiPhase.thinking:
        return '생각 중…';
      case UiPhase.speaking:
        return '말하는 중…';
    }
  }
}


