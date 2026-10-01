# 릴리스 절차

## 1. 버전과 소스 고정

1. `Resources/Info.plist`의 사용자 버전과 빌드 번호를 갱신합니다.
2. `CHANGELOG.md`에 출시일과 변경 내용을 기록합니다.
3. `swift test`와 [실기기 시험](TESTING.md)을 완료합니다.
4. 모든 대응 소스, 빌드 스크립트, 라이선스가 커밋됐는지 확인합니다.

Release 태그는 사전 공개판에 `v0.1.0-alpha.1`, 안정판에 `v0.1.0` 형식을
사용합니다. GitHub가 제공하는 태그 source archive가 배포 바이너리의 정확한
대응 소스가 되도록 태그 이후 바이너리를 다시 변경하지 않습니다.

## 2. Alpha DMG

Developer ID가 없는 시험용 빌드는 다음과 같이 만듭니다.

```bash
CLASSMIRROR_RELEASE_VERSION=0.1.0-alpha.1 \
  ./script/package_release.sh
```

생성 파일:

```text
dist-release/ClassMirror-0.1.0-alpha.1-macos-arm64.dmg
dist-release/ClassMirror-0.1.0-alpha.1-macos-arm64.dmg.sha256
```

배포 바이너리에 정적으로 연결되는 의존성의 고정 원본까지 포함한 대응 소스
묶음도 생성합니다.

```bash
CLASSMIRROR_RELEASE_VERSION=0.1.0-alpha.1 \
  ./script/package_source.sh
```

```text
dist-release/ClassMirror-0.1.0-alpha.1-source.tar.gz
dist-release/ClassMirror-0.1.0-alpha.1-source.tar.gz.sha256
```

이 DMG는 ad-hoc 서명이므로 GitHub Release를 **pre-release**로 표시하고
Gatekeeper 수동 승인 필요성을 릴리스 노트 첫 부분에 명시합니다.

## 3. Developer ID 서명과 공증

최초 한 번 공증 자격을 키체인에 저장합니다.

```bash
xcrun notarytool store-credentials ClassMirrorNotary
```

그 다음 공증 릴리스를 생성합니다.

```bash
CLASSMIRROR_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
CLASSMIRROR_NOTARY_PROFILE="ClassMirrorNotary" \
CLASSMIRROR_RELEASE_VERSION=0.1.0 \
  ./script/notarize_release.sh
```

스크립트는 앱 서명 검증, DMG 생성과 서명, notary 제출, 티켓 staple,
Gatekeeper 평가까지 수행합니다. 인증서, 비밀번호, App Store Connect 키를
저장소에 커밋하지 않습니다.

## 4. 최종 검사

```bash
codesign --verify --deep --strict --verbose=2 dist-release/ClassMirror.app
xcrun stapler validate dist-release/ClassMirror-*-macos-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 \
  dist-release/ClassMirror-*-macos-arm64.dmg
(cd dist-release && shasum -a 256 -c ClassMirror-*-macos-arm64.dmg.sha256)
```

공증 릴리스는 `spctl` 결과가 `accepted`여야 합니다. 새 macOS 사용자
계정이나 ClassMirror를 설치한 적 없는 Mac에서 브라우저 다운로드부터 다시
시험합니다.

## 5. GitHub Release

- 태그와 제목이 앱 버전과 일치하는지 확인
- DMG, 전체 대응 소스 묶음과 각 `.sha256` 첨부
- 지원 환경, 설치법, 주요 변경, 알려진 문제 작성
- GPL-3.0과 정확한 태그 source archive 링크 확인
- 공증 여부를 명시
- 공개 후 첨부 파일을 교체하지 않고 새 버전으로 수정 배포
