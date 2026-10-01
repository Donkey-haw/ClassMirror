import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        TabView {
            Form {
                TextField("수신 이름", text: $preferences.receiverName)
                    .textFieldStyle(.roundedBorder)
                Text("연결 중 변경한 이름은 다음 수신기 시작부터 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("일반", systemImage: "gearshape") }

            Form {
                Picker("연결 방식", selection: $preferences.peerToPeerEnabled) {
                    Text("Apple TV 동시 사용 (권장)").tag(false)
                    Text("학교망 직접 연결 (실험적)").tag(true)
                }
                .pickerStyle(.radioGroup)

                Text(preferences.peerToPeerEnabled
                    ? "AWDL 직접 연결을 사용합니다. Mac의 Apple TV AirPlay 송출과 충돌할 수 있습니다."
                    : "iPad와 Mac이 같은 로컬 네트워크로 연결됩니다. Mac의 Apple TV 화면 미러링과 함께 사용하는 모드입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("연결 방식을 바꾼 뒤에는 수신기를 다시 시작하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("연결", systemImage: "network") }

            Form {
                Toggle("PIN 필요", isOn: $preferences.requiresPIN)
                    .disabled(preferences.peerToPeerEnabled)
                Text(preferences.peerToPeerEnabled
                    ? "직접 연결에서는 Apple식 PIN 인증이 항상 사용됩니다."
                    : "교실에서는 PIN 사용을 권장합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("보안", systemImage: "lock") }

            Form {
                Toggle("기기 오디오 재생", isOn: $preferences.audioEnabled)
            }
            .formStyle(.grouped)
            .tabItem { Label("오디오", systemImage: "speaker.wave.2") }

            Form {
                LabeledContent("버전", value: "0.1.0 Alpha")
                Text("ClassMirror는 GNU GPL version 3에 따라 배포되는 오픈소스 소프트웨어입니다.")
                    .font(.callout)
                Text("이 프로그램은 상품성 또는 특정 목적 적합성에 대한 보증 없이 제공됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    "소스 코드 및 라이선스 보기",
                    destination: URL(string: "https://github.com/Donkey-haw/ClassMirror")!
                )
            }
            .formStyle(.grouped)
            .tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 310)
        .scenePadding()
    }
}
