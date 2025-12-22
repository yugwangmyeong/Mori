# 마이크 제어 기능 구현 정리

## 개요
마이크 버튼을 눌렀을 때 마이크를 완전히 끄고, 백엔드에서 무음 프레임 로그가 출력되지 않도록 구현했습니다.

## 문제점
- `track.enabled = false`로 설정해도 WebRTC가 무음 프레임을 계속 전송
- 백엔드에서 모든 프레임을 처리하여 로그가 계속 출력됨
- 마이크를 꺼도 오디오 인코딩 로그가 반복적으로 출력되는 문제

## 해결 방법

### 1. 프론트엔드 (Flutter)

#### 파일: `front/lib/services/webrtc_voice_service.dart`

**추가된 변수:**
```dart
List<MediaStreamTrack>? _audioTracks; // 오디오 트랙 저장
bool _isMicEnabled = true; // 마이크 활성화 상태
final StreamController<bool> _micEnabledController = 
    StreamController<bool>.broadcast(); // 마이크 상태 스트림
```

**추가된 메서드:**

1. **`toggleMicrophone()`** - 마이크 토글
   - 마이크 끄기: `replaceTrack(null)`로 트랙을 완전히 제거
   - 마이크 켜기: 새 트랙을 가져와 `replaceTrack()`으로 교체
   - 트랙을 완전히 제거하여 오디오 전송 중지

2. **`enableMicrophone()`** - 마이크 켜기
3. **`disableMicrophone()`** - 마이크 끄기

**Getter 추가:**
- `isMicEnabled` - 현재 마이크 상태 확인
- `micEnabled` - 마이크 상태 변경 스트림

**연결 시 트랙 저장:**
```dart
// 로컬 스트림을 PeerConnection에 추가
_audioTracks = _localStream!.getAudioTracks();
_audioTracks!.forEach((track) {
  _peerConnection!.addTrack(track, _localStream!);
});
```

#### 파일: `front/lib/screens/main_page.dart`

**변경 사항:**
- 마이크 상태 추적 변수 추가: `bool _isMicEnabled = true`
- 마이크 상태 리스너 추가
- 버튼 UI 업데이트:
  - 마이크 ON: 빨간색 + `Icons.mic`
  - 마이크 OFF: 회색 + `Icons.mic_off`
- 버튼 클릭 시 `toggleMicrophone()` 호출

### 2. 백엔드 (Python)

#### 파일: `backend_python/webrtc_handler.py`

**변경 사항:**
- 무음 프레임 감지 로직 추가
- 무음 프레임은 로그 출력하지 않음

**구현 코드:**
```python
async def recv(self):
    """오디오 프레임 수신 (20ms 단위)"""
    frame = await self.track.recv()
    
    # 오디오 인코딩 처리
    processed_audio = await self.audio_processor.process_frame(frame)
    
    # 무음 프레임 체크 (모든 샘플이 0에 가까우면 무음으로 간주)
    if processed_audio is not None:
        # 무음 감지: 절대값의 평균이 매우 작으면 무음
        audio_abs = np.abs(processed_audio.astype(np.float32))
        audio_mean = np.mean(audio_abs)
        is_silent = audio_mean < 10.0  # 임계값 (PCM16 기준, 매우 작은 값)
        
        # 무음이 아닐 때만 로그 출력 (로그 스팸 방지)
        if not is_silent:
            logger.info(f"✅ 오디오 인코딩 완료: {len(processed_audio)} samples (16kHz, mono, PCM16)")
    
    return frame
```

**무음 감지 로직:**
- 오디오 샘플의 절대값 평균 계산
- 평균이 10 미만이면 무음으로 판단
- 무음 프레임은 로그 출력하지 않음

## 동작 흐름

### 마이크 끄기
1. 사용자가 마이크 버튼 클릭
2. `toggleMicrophone()` 호출
3. `_isMicEnabled = false`로 설정
4. `replaceTrack(null)`로 트랙 제거 → 오디오 전송 완전 중지
5. 로컬 트랙 `stop()` 호출
6. 스트림 정리 및 dispose
7. UI 업데이트 (회색 + mic_off 아이콘)
8. 백엔드에서 프레임 수신 중단 → 로그 출력 중단

### 마이크 켜기
1. 사용자가 마이크 버튼 클릭
2. `toggleMicrophone()` 호출
3. `_isMicEnabled = true`로 설정
4. `getUserMedia()`로 새 트랙 가져오기
5. `replaceTrack(newTrack)`로 트랙 교체
6. UI 업데이트 (빨간색 + mic 아이콘)
7. 백엔드에서 프레임 수신 재개

## 주요 개선 사항

1. **완전한 오디오 전송 중지**
   - `track.enabled = false` 대신 `replaceTrack(null)` 사용
   - 트랙을 완전히 제거하여 무음 프레임도 전송하지 않음

2. **로그 스팸 방지**
   - 백엔드에서 무음 프레임 감지
   - 무음 프레임은 로그 출력하지 않음

3. **사용자 경험 개선**
   - 마이크 상태를 시각적으로 표시
   - 버튼 색상과 아이콘으로 상태 구분

## 테스트 방법

1. 앱 실행 후 WebRTC 연결 확인
2. 마이크 버튼 클릭 → 마이크 OFF
   - 버튼이 회색으로 변경
   - 백엔드 로그에서 오디오 인코딩 로그 중단 확인
3. 마이크 버튼 다시 클릭 → 마이크 ON
   - 버튼이 빨간색으로 변경
   - 백엔드 로그에서 오디오 인코딩 로그 재개 확인

## 참고 사항

- `replaceTrack(null)`을 사용하면 트랙이 완전히 제거되어 오디오 전송이 중지됩니다
- 마이크를 다시 켤 때는 새로운 트랙을 가져와야 합니다
- 무음 감지 임계값(10.0)은 필요에 따라 조정 가능합니다

