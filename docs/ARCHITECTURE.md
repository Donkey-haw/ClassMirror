# 아키텍처

## 구성

```text
SwiftUI / AppKit
  ├─ 상태 창, 메뉴바, 설정
  ├─ MetalVideoView
  └─ AVAudioEngine 출력
          │
ClassMirrorCore (Swift)
  ├─ 세션 상태 머신
  ├─ H.264 access-unit 파서
  ├─ VideoToolbox 디코더
  └─ AudioConverter 디코더
          │
AirPlayCoreC
  ├─ ClassMirrorReceiver C wrapper
  └─ UxPlay 기반 receiver subset
          │
Bonjour · RTSP/RAOP · pairing · crypto · timing
```

UI는 프로토콜 구현에 직접 접근하지 않고 `ReceiverEngine` 계약을 사용합니다.
C 콜백 데이터는 Swift 경계에서 즉시 복사되고 제한된 `AsyncStream`으로
전달됩니다. 느린 소비자가 네트워크 콜백을 막거나 미디어 패킷이 무제한
쌓이지 않도록 하는 구조입니다.

## 영상

```text
AirPlay H.264 → Annex-B/AVCC parsing → VTDecompressionSession
→ CVPixelBuffer → Core Image/Metal → MTKView
```

렌더러는 원본 비율을 유지하고 회전 시 새 영상 크기를 반영합니다. 시스템
전체 화면 상태에서는 회전에 따른 일반 창 크기 변경을 적용하지 않습니다.

## 오디오

```text
PCM/AAC/ALAC → AVAudioConverter → Float32 PCM
→ bounded playback queue → AVAudioEngine
```

재생 대기열이 지연 목표를 초과하면 오래된 backlog를 폐기하여 지연이 계속
증가하는 것을 막습니다.

## 네트워크 모드

- Local Network: Bonjour/mDNS와 일반 LAN. Apple TV 동시 사용 기본값.
- Experimental P2P: AWDL과 `SO_RECV_ANYIF` 기반 실험 경로. 비공개 플랫폼
  동작에 의존하며 OS 업데이트와 Apple TV 송출의 영향을 받을 수 있음.

## 디렉터리

```text
Sources/ClassMirrorApp/        macOS UI와 재생 출력
Sources/ClassMirrorCore/       UI 독립 상태·미디어 처리
ThirdParty/AirPlayCoreTarget/  C wrapper와 고정 upstream source
Tests/                         Swift 및 C 경계 자동 테스트
script/                        빌드, 패키징, 공증 자동화
docs/                          사용자·개발자 문서
```
