# 빌드 및 개발

## 요구사항

- Apple Silicon Mac
- macOS 15 이상
- Xcode와 Swift 6.2 호환 도구 체인
- Git

개발 빌드에는 Homebrew의 `pkg-config`, OpenSSL 및 libplist가 필요합니다.

```bash
brew install pkg-config openssl@3 libplist
```

## 저장소 받기

```bash
git clone https://github.com/Donkey-haw/ClassMirror.git
cd ClassMirror
```

UxPlay 기반 Core 소스는 저장소에 포함되어 있으므로 별도 submodule 초기화는
필요하지 않습니다.

## 테스트

```bash
swift test
```

테스트는 상태 전이, 수신기 수명, H.264 파싱과 VideoToolbox, 오디오 변환을
검증합니다. 실제 iPad, Bonjour, 학교 네트워크, Apple TV 동시 사용은 자동
테스트로 대체되지 않습니다.

## 개발 앱 실행

```bash
./script/build_and_run.sh
```

추가 모드:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
```

개발 앱은 `dist/ClassMirror.app`에 생성되고 ad-hoc 서명을 사용합니다.

## 자체 포함 Release 앱

```bash
./script/build_release.sh
```

스크립트는 고정 버전과 SHA-256으로 OpenSSL 3.6.4와 libplist 2.7.0을 받아
macOS 15 arm64 정적 라이브러리로 빌드합니다. 결과 앱은
`dist-release/ClassMirror.app`이며 Homebrew 경로에 런타임 의존하지
않습니다.

## 배포용 DMG

공증되지 않은 Alpha DMG:

```bash
CLASSMIRROR_RELEASE_VERSION=0.1.0-alpha.1 \
  ./script/package_release.sh
```

Developer ID와 공증 프로필이 있는 경우:

```bash
CLASSMIRROR_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
CLASSMIRROR_NOTARY_PROFILE="ClassMirrorNotary" \
CLASSMIRROR_RELEASE_VERSION=0.1.0 \
  ./script/notarize_release.sh
```

비밀값과 인증서는 Git에 커밋하지 마세요. 자세한 절차는
[릴리스 문서](RELEASING.md)에 있습니다.

## Phase 0 비교 수신기

```bash
./script/bootstrap_phase0.sh
./script/run_phase0_receiver.sh
```

이 경로는 고정 UxPlay upstream을 비교하기 위한 개발 도구이며 ClassMirror
앱 배포물에 포함되지 않습니다.
