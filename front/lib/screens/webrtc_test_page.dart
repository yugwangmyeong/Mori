import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/service_providers.dart';
import '../models/ui_phase.dart';

/// WebRTC 연결 테스트 페이지
class WebRTCTestPage extends ConsumerStatefulWidget {
  const WebRTCTestPage({super.key});

  @override
  ConsumerState<WebRTCTestPage> createState() => _WebRTCTestPageState();
}

class _WebRTCTestPageState extends ConsumerState<WebRTCTestPage> {
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _phaseSubscription;
  
  String _connectionStatus = 'disconnected';
  UiPhase _currentPhase = UiPhase.idle;
  String _logMessages = '';

  void _addLog(String message) {
    setState(() {
      _logMessages = '${DateTime.now().toString().substring(11, 19)}: $message\n$_logMessages';
    });
    print(message);
  }

  @override
  void initState() {
    super.initState();
    _addLog('페이지 초기화');
  }

  Future<void> _connect() async {
    final service = ref.read(webrtcVoiceServiceProvider);
    
    _addLog('연결 시작...');
    
    // 연결 상태 리스너
    _connectionSubscription = service.connectionStatus.listen((status) {
      setState(() {
        _connectionStatus = status;
      });
      _addLog('연결 상태: $status');
    });
    
    // UI Phase 리스너
    _phaseSubscription = service.uiPhase.listen((phase) {
      setState(() {
        _currentPhase = phase;
      });
      _addLog('UI Phase: ${phase.displayText}');
    });
    
    try {
      await service.connect();
      _addLog('연결 요청 완료');
    } catch (e) {
      _addLog('연결 오류: $e');
    }
  }

  Future<void> _disconnect() async {
    final service = ref.read(webrtcVoiceServiceProvider);
    _addLog('연결 종료 중...');
    await service.disconnect();
    _addLog('연결 종료 완료');
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _phaseSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(webrtcVoiceServiceProvider);
    final isConnected = service.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('WebRTC 연결 테스트'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 상태 카드
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '연결 상태',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isConnected ? Colors.green : Colors.red,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _connectionStatus,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isConnected ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('UI Phase: ${_currentPhase.displayText}'),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // 버튼
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: isConnected ? null : _connect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('연결'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: isConnected ? _disconnect : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('연결 종료'),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // 로그 영역
            Expanded(
              child: Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        '로그',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: SingleChildScrollView(
                        reverse: true,
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          _logMessages.isEmpty ? '로그가 없습니다.' : _logMessages,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

