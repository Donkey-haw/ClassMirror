# 설치 안내

## 요구 환경

- Apple Silicon Mac(M1 이상)
- macOS 15 이상
- iPhone 또는 iPad
- 로컬 네트워크 모드에서는 서로 통신 가능한 같은 네트워크

ClassMirror는 Intel Mac과 Windows를 지원하지 않습니다. Mac에 Homebrew나
GStreamer를 설치할 필요는 없습니다.

## DMG 설치

1. [GitHub Releases](https://github.com/Donkey-haw/ClassMirror/releases)에서
   최신 `ClassMirror-…-macos-arm64.dmg`를 다운로드합니다.
2. Release에 표시된 SHA-256과 파일의 체크섬이 같은지 확인할 수 있습니다.

   ```bash
   shasum -a 256 ~/Downloads/ClassMirror-*-macos-arm64.dmg
   ```

3. DMG를 열고 `ClassMirror.app`을 `Applications`로 드래그합니다.
4. 응용 프로그램 폴더에서 ClassMirror를 실행합니다.
5. 요청이 나타나면 로컬 네트워크 접근을 허용합니다.

## 현재 Alpha 빌드의 첫 실행

현재 Alpha DMG는 Developer ID로 서명·공증되지 않았습니다. macOS가
개발자를 확인할 수 없다는 이유로 실행을 막을 수 있습니다.

출처와 체크섬을 확인하고 실행하기로 결정했다면:

1. ClassMirror를 한 번 실행해 경고를 확인합니다.
2. 시스템 설정 → 개인정보 보호 및 보안으로 이동합니다.
3. 보안 영역에서 ClassMirror 옆의 **확인 없이 열기**를 선택합니다.
4. 사용자 암호 또는 Touch ID로 승인합니다.

Gatekeeper 전체를 비활성화하거나 출처를 확인하지 않은 앱을 승인하지
마세요. 향후 Developer ID 공증 릴리스에서는 이 수동 승인이 필요하지
않도록 할 예정입니다.

## 권한 초기화

로컬 네트워크 권한을 거절했다면 시스템 설정 → 개인정보 보호 및 보안 →
로컬 네트워크에서 ClassMirror를 허용한 뒤 앱을 다시 실행하세요.

## 제거

1. ClassMirror를 종료합니다.
2. 응용 프로그램의 `ClassMirror.app`을 휴지통으로 이동합니다.

설정까지 초기화하려면 터미널에서 다음 명령을 실행할 수 있습니다.

```bash
defaults delete com.classmirror.mac
```

이 명령은 ClassMirror의 수신 이름과 사용자 설정만 제거합니다.
