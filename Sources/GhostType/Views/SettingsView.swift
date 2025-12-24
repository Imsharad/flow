import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            ModelsSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
                .tag(1)

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }
                .tag(2)
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("App Behavior")) {
                Toggle("Launch at Login", isOn: .constant(false)) // Placeholder
                Toggle("Show Dock Icon", isOn: .constant(false)) // Placeholder
            }
        }
        .padding()
    }
}

struct ModelsSettingsView: View {
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    let models = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-tiny"
    ]

    var body: some View {
        Form {
            Section(header: Text("Local Inference Model")) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(MenuPickerStyle())

                Text("Note: Changing models requires a restart or re-initialization.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct AudioSettingsView: View {
    @ObservedObject private var audioManager = AudioInputManager.shared

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                Slider(value: Binding(
                    get: { Double(audioManager.micSensitivity) },
                    set: { audioManager.micSensitivity = Float($0) }
                ), in: 0...1) {
                    Text("Sensitivity")
                }
                Text("Current Sensitivity: \(Int(audioManager.micSensitivity * 100))%")
            }
        }
        .padding()
    }
}
