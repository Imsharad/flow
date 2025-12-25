import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedModelId") private var selectedModelId = "distil-whisper_distil-large-v3"
    @AppStorage("useANE") private var useANE = false
    @ObservedObject var audioManager = AudioInputManager.shared

    // For now, these are the only models we support/test
    let availableModels = [
        "distil-whisper_distil-large-v3": "Distil-Whisper Large v3 (Recommended)",
        "openai_whisper-large-v3-turbo": "Whisper Large v3 Turbo (Fastest)",
        "openai_whisper-large-v3": "Whisper Large v3 (Most Accurate)"
    ]

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsView(selectedModelId: $selectedModelId, useANE: $useANE, availableModels: availableModels)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            AudioSettingsView(audioManager: audioManager)
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }
        }
        .frame(width: 450, height: 300)
        .padding()
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("Shortcuts")) {
                HStack {
                    Text("Dictation Hotkey")
                    Spacer()
                    Text("Right Option (⌥)")
                        .foregroundColor(.secondary)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2)))
                }
                Text("Hold to record, or Tap to toggle.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Behavior")) {
                Toggle("Launch at Login", isOn: .constant(false)) // TODO: Implement LoginItem
                    .disabled(true)
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    @Binding var selectedModelId: String
    @Binding var useANE: Bool
    let availableModels: [String: String]

    var body: some View {
        Form {
            Section(header: Text("Transcription Model")) {
                Picker("Model", selection: $selectedModelId) {
                    ForEach(availableModels.keys.sorted(), id: \.self) { key in
                        Text(availableModels[key] ?? key).tag(key)
                    }
                }
                .pickerStyle(.menu)

                Text("Distil-Whisper is recommended for M-Series chips.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Compute Engine")) {
                Toggle("Enable Apple Neural Engine (ANE)", isOn: $useANE)
                Text("Experimental. May cause hangs on some M1/M2 chips. Disable if dictation gets stuck.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
    }
}

struct AudioSettingsView: View {
    @ObservedObject var audioManager: AudioInputManager

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                HStack {
                    Text("Sensitivity (Gain)")
                    Spacer()
                    Text("\(String(format: "%.1f", audioManager.micSensitivity))x")
                }
                Slider(value: $audioManager.micSensitivity, in: 0.1...5.0, step: 0.1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("0.1x")
                } maximumValueLabel: {
                    Text("5.0x")
                }

                Text("Increase if your voice is too quiet. Default is 1.0x.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
