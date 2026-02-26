import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKeys.defaultEncodeMode) private var defaultEncodeModeRaw = EncodeMode.transcode.rawValue
    @AppStorage(AppPreferenceKeys.rtmpPresetsJSON) private var rtmpPresetsJSON = "[]"

    @State private var presets: [RtmpPreset] = []
    @State private var selectedPresetID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Video Output Defaults") {
                HStack {
                    Text("Default Mode")
                        .frame(width: 120, alignment: .leading)
                    Picker("Default Mode", selection: $defaultEncodeModeRaw) {
                        ForEach(EncodeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.top, 4)
            }

            GroupBox("RTMP Presets") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        List(selection: $selectedPresetID) {
                            ForEach(presets) { preset in
                                Text(preset.name)
                                    .tag(Optional(preset.id))
                            }
                        }
                        .frame(minWidth: 220, minHeight: 220)

                        HStack(spacing: 8) {
                            Button("Add") { addPreset() }
                            Button("Remove") { removeSelectedPreset() }
                                .disabled(selectedPresetIndex == nil)
                        }
                        .controlSize(.small)
                    }

                    if let index = selectedPresetIndex {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledField("Name", text: binding(for: index, keyPath: \.name), placeholder: "My RTMP Preset")
                            labeledField("Server URL", text: binding(for: index, keyPath: \.serverURL), placeholder: "rtmp://server/app/")
                            labeledField("Stream Key", text: binding(for: index, keyPath: \.streamKey), placeholder: "streamName?key=abc123")
                            labeledField("Full URL (Optional)", text: binding(for: index, keyPath: \.fullURLOverride), placeholder: "rtmp://server/app/streamName?key=abc123")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Select a preset to edit, or add a new one.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 430)
        .onAppear {
            presets = AppPreferencesCodec.decodePresets(from: rtmpPresetsJSON)
            if let first = presets.first {
                selectedPresetID = first.id
            }
        }
        .onChange(of: presets) { newValue in
            rtmpPresetsJSON = AppPreferencesCodec.encodePresets(newValue)
            if let selectedPresetID,
               !newValue.contains(where: { $0.id == selectedPresetID }) {
                self.selectedPresetID = newValue.first?.id
            }
        }
    }

    private var selectedPresetIndex: Int? {
        guard let id = selectedPresetID else { return nil }
        return presets.firstIndex(where: { $0.id == id })
    }

    private func addPreset() {
        let index = presets.count + 1
        let preset = RtmpPreset(
            name: "Preset \(index)",
            serverURL: "",
            streamKey: "",
            fullURLOverride: ""
        )
        presets.append(preset)
        selectedPresetID = preset.id
    }

    private func removeSelectedPreset() {
        guard let index = selectedPresetIndex else { return }
        presets.remove(at: index)
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func binding(for index: Int, keyPath: WritableKeyPath<RtmpPreset, String>) -> Binding<String> {
        Binding(
            get: { presets[index][keyPath: keyPath] },
            set: { presets[index][keyPath: keyPath] = $0 }
        )
    }
}

