import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/realtime_service.dart';
import '../services/audio_service.dart';

// Realtime 서비스 Provider
final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  final service = RealtimeService();
  ref.onDispose(() => service.dispose());
  return service;
});

// Audio 서비스 Provider
final audioServiceProvider = Provider<AudioService>((ref) {
  final service = AudioService();
  ref.onDispose(() => service.dispose());
  return service;
});






