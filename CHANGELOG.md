# 변경 내역

이 프로젝트는 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/) 형식을
따르며, 버전은 [Semantic Versioning](https://semver.org/lang/ko/)을 기준으로
관리합니다.

## [Unreleased]

### 예정

- 실제 교실 환경의 장시간 안정성 자료 확대
- Developer ID 서명 및 Apple 공증 빌드
- 앱 아이콘과 설치 DMG 시각 개선

## [0.1.0-alpha.1] - 2026-10-01

### 추가

- 단일 iPad/iPhone AirPlay 화면 수신
- 연결마다 표시되는 PIN 인증
- H.264 VideoToolbox 디코딩과 Metal 렌더링
- PCM, AAC-LC, AAC-ELD, ALAC 오디오 디코딩 경로
- 메뉴바 제어, 시스템 전체 화면, 항상 위, 음소거
- Fit, 50%, 75%, 100% 창 배율과 회전 대응
- 로컬 네트워크와 실험적 AWDL 연결 모드
- 네트워크 변경 후 수신 서비스 재등록
- Apple TV 송출과 로컬 네트워크 수신 병행 모드

### 알려진 제한

- Apple Silicon 및 macOS 15 이상만 지원
- 한 번에 송신 기기 한 대만 지원
- 학교 Wi-Fi의 AP Isolation이나 mDNS 차단은 앱이 우회할 수 없음
- 실험적 AWDL 모드는 Mac의 Apple TV AirPlay 송출과 충돌할 수 있음
- Alpha DMG는 Developer ID로 서명·공증되지 않음

[Unreleased]: https://github.com/Donkey-haw/ClassMirror/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/Donkey-haw/ClassMirror/releases/tag/v0.1.0-alpha.1
