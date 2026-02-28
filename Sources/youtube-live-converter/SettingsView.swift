import SwiftUI
import AppKit

private enum SettingsPane: Hashable {
    case general
    case outputDefaults
    case rtmpPresets
    case sourcePresets
}

private enum DefaultOutputModeSelection: Hashable {
    case compatible
    case streamCopy
}

struct SettingsView: View {
    @AppStorage(AppPreferenceKeys.defaultEncodeMode) private var defaultEncodeModeRaw = EncodeMode.transcode.rawValue
    @AppStorage(AppPreferenceKeys.defaultBufferSeconds) private var defaultBufferSeconds = 30
    @AppStorage(AppPreferenceKeys.defaultUseDiskBackedBuffer) private var defaultUseDiskBackedBuffer = true
    @AppStorage(AppPreferenceKeys.defaultAVSyncOffsetMs) private var defaultAVSyncOffsetMs = 0
    @AppStorage(AppPreferenceKeys.defaultAudioBoostEnabled) private var defaultAudioBoostEnabled = false
    @AppStorage(AppPreferenceKeys.defaultAudioBoostDb) private var defaultAudioBoostDb = 0
    @AppStorage(AppPreferenceKeys.defaultAudioContinuityEnabled) private var defaultAudioContinuityEnabled = true
    @AppStorage(AppPreferenceKeys.logMonitoringEnabled) private var defaultExtendedLogging = true
    @AppStorage(AppPreferenceKeys.appearanceMode) private var appearanceModeRaw = AppearanceMode.automatic.rawValue
    @AppStorage(AppPreferenceKeys.rtmpPresetsJSON) private var rtmpPresetsJSON = "[]"
    @AppStorage(AppPreferenceKeys.sourcePresetsJSON) private var sourcePresetsJSON = "[]"

    @State private var selectedPane: SettingsPane = .general
    @State private var rtmpPresets: [RtmpPreset] = []
    @State private var selectedRtmpPresetID: String?
    @State private var sourcePresets: [SourcePreset] = []
    @State private var selectedSourcePresetID: String?

    private let bufferOptions = [0, 5, 15, 30, 60, 120]
    private let audioBoostOptions = [0, 5, 10, 20]

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)

            outputDefaultsPane
                .tabItem { Label("Output Defaults", systemImage: "slider.horizontal.3") }
                .tag(SettingsPane.outputDefaults)

            rtmpPresetsPane
                .tabItem { Label("RTMP Presets", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsPane.rtmpPresets)

            sourcePresetsPane
                .tabItem { Label("Input Presets", systemImage: "link.badge.plus") }
                .tag(SettingsPane.sourcePresets)
        }
        .background(SettingsWindowConfigurator(minSize: NSSize(width: 760, height: 540)))
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            rtmpPresets = AppPreferencesCodec.decodePresets(from: rtmpPresetsJSON)
            if let first = rtmpPresets.first {
                selectedRtmpPresetID = first.id
            }
            sourcePresets = AppPreferencesCodec.decodeSourcePresets(from: sourcePresetsJSON)
            if let first = sourcePresets.first {
                selectedSourcePresetID = first.id
            }
            sanitizeDefaults()
        }
        .onChange(of: rtmpPresets) { newValue in
            rtmpPresetsJSON = AppPreferencesCodec.encodePresets(newValue)
            if let selectedRtmpPresetID,
               !newValue.contains(where: { $0.id == selectedRtmpPresetID }) {
                self.selectedRtmpPresetID = newValue.first?.id
            }
        }
        .onChange(of: sourcePresets) { newValue in
            sourcePresetsJSON = AppPreferencesCodec.encodeSourcePresets(newValue)
            if let selectedSourcePresetID,
               !newValue.contains(where: { $0.id == selectedSourcePresetID }) {
                self.selectedSourcePresetID = newValue.first?.id
            }
        }
    }

    private var generalPane: some View {
        ScrollView {
            Form {
                Section("Appearance") {
                    HStack {
                        Text("Appearance")
                            .frame(width: 150, alignment: .leading)
                        Picker("", selection: $appearanceModeRaw) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(16)
            .padding(.top, 10)
        }
    }

    private var outputDefaultsPane: some View {
        ScrollView {
            Form {
                Section("Video Output") {
                    HStack {
                        Text("Default Mode")
                            .frame(width: 170, alignment: .leading)
                        Picker("", selection: defaultModeSelectionBinding) {
                            Text("Compatible (DVR-to-Live)").tag(DefaultOutputModeSelection.compatible)
                            Text("Stream Copy").tag(DefaultOutputModeSelection.streamCopy)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text("Buffer Delay")
                            .frame(width: 170, alignment: .leading)
                        Picker("", selection: $defaultBufferSeconds) {
                            ForEach(bufferOptions, id: \.self) { seconds in
                                Text(seconds == 0 ? "No buffer" : "\(seconds)s").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(defaultModeSelection != .compatible)
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text("DVR Disk Staging")
                            .frame(width: 170, alignment: .leading)
                        Toggle("Enable", isOn: $defaultUseDiskBackedBuffer)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(defaultModeSelection != .compatible || defaultBufferSeconds <= 0)
                        Spacer(minLength: 0)
                    }

                    Text("Compatible mode stages normalized media to a local DVR playlist before publish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Audio/Video") {
                    HStack {
                        Text("A/V Sync Offset")
                            .frame(width: 170, alignment: .leading)
                        Stepper(value: $defaultAVSyncOffsetMs, in: -2000...2000, step: 50) {
                            Text("\(defaultAVSyncOffsetMs) ms")
                                .monospacedDigit()
                        }
                        .controlSize(.small)
                        .disabled(defaultModeSelection != .compatible)
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text("Audio Boost")
                            .frame(width: 170, alignment: .leading)
                        Toggle("Enable", isOn: $defaultAudioBoostEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(defaultModeSelection != .compatible)
                        if defaultAudioBoostEnabled {
                            Picker("", selection: $defaultAudioBoostDb) {
                                ForEach(audioBoostOptions, id: \.self) { db in
                                    Text("\(db) dB").tag(db)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .disabled(defaultModeSelection != .compatible)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text("Audio Continuity")
                            .frame(width: 170, alignment: .leading)
                        Toggle("Enable", isOn: $defaultAudioContinuityEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(defaultModeSelection != .compatible)
                        Spacer(minLength: 0)
                    }
                }

                Section("Monitoring") {
                    HStack {
                        Text("Extended Logging")
                            .frame(width: 170, alignment: .leading)
                        Toggle("Enable", isOn: $defaultExtendedLogging)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Restore Output Defaults") {
                            restoreOutputDefaults()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(16)
            .padding(.top, 10)
        }
    }

    private var rtmpPresetsPane: some View {
        ScrollView {
            GroupBox("RTMP Presets") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        List(selection: $selectedRtmpPresetID) {
                            ForEach(rtmpPresets) { preset in
                                Text(preset.name)
                                    .tag(Optional(preset.id))
                            }
                        }
                        .frame(minWidth: 220, minHeight: 280)

                        HStack(spacing: 8) {
                            Button("Add") { addRtmpPreset() }
                            Button("Remove") { removeSelectedRtmpPreset() }
                                .disabled(selectedRtmpPresetIndex == nil)
                        }
                        .controlSize(.small)
                    }

                    if let index = selectedRtmpPresetIndex {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledField("Name", text: rtmpBinding(for: index, keyPath: \.name), placeholder: "My RTMP Preset")
                            labeledField("Server URL", text: rtmpBinding(for: index, keyPath: \.serverURL), placeholder: "rtmp://server/app/")
                            labeledField("Stream Key", text: rtmpBinding(for: index, keyPath: \.streamKey), placeholder: "streamName?key=abc123")
                            labeledField("Full URL (Optional)", text: rtmpBinding(for: index, keyPath: \.fullURLOverride), placeholder: "rtmp://server/app/streamName?key=abc123")
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
            .padding(16)
            .padding(.top, 10)
        }
    }

    private var sourcePresetsPane: some View {
        ScrollView {
            GroupBox("Input Source Presets") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        List(selection: $selectedSourcePresetID) {
                            ForEach(sourcePresets) { preset in
                                Text(preset.name)
                                    .tag(Optional(preset.id))
                            }
                        }
                        .frame(minWidth: 220, minHeight: 280)

                        HStack(spacing: 8) {
                            Button("Add") { addSourcePreset() }
                            Button("Remove") { removeSelectedSourcePreset() }
                                .disabled(selectedSourcePresetIndex == nil)
                        }
                        .controlSize(.small)
                    }

                    if let index = selectedSourcePresetIndex {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledField("Name", text: sourceBinding(for: index, keyPath: \.name), placeholder: "My Source Preset")
                            labeledField("URL", text: sourceBinding(for: index, keyPath: \.url), placeholder: "https://www.youtube.com/watch?v=...")
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
            .padding(16)
            .padding(.top, 10)
        }
    }

    private var selectedRtmpPresetIndex: Int? {
        guard let id = selectedRtmpPresetID else { return nil }
        return rtmpPresets.firstIndex(where: { $0.id == id })
    }

    private var selectedSourcePresetIndex: Int? {
        guard let id = selectedSourcePresetID else { return nil }
        return sourcePresets.firstIndex(where: { $0.id == id })
    }

    private var defaultModeSelection: DefaultOutputModeSelection {
        if defaultEncodeModeRaw == "Stream Copy (Paced)" {
            return .streamCopy
        }
        let mode = EncodeMode(rawValue: defaultEncodeModeRaw) ?? .transcode
        return mode == .transcode ? .compatible : .streamCopy
    }

    private var defaultModeSelectionBinding: Binding<DefaultOutputModeSelection> {
        Binding(
            get: { defaultModeSelection },
            set: { selection in
                switch selection {
                case .compatible:
                    defaultEncodeModeRaw = EncodeMode.transcode.rawValue
                case .streamCopy:
                    defaultEncodeModeRaw = EncodeMode.copy.rawValue
                }
            }
        )
    }

    private func sanitizeDefaults() {
        if defaultEncodeModeRaw == "Stream Copy (Paced)" {
            defaultEncodeModeRaw = EncodeMode.copy.rawValue
        }
        if !bufferOptions.contains(defaultBufferSeconds) {
            defaultBufferSeconds = 30
        }
        if !audioBoostOptions.contains(defaultAudioBoostDb) {
            defaultAudioBoostDb = 0
        }
        defaultAVSyncOffsetMs = min(2000, max(-2000, defaultAVSyncOffsetMs))
    }

    private func restoreOutputDefaults() {
        defaultEncodeModeRaw = EncodeMode.transcode.rawValue
        defaultBufferSeconds = 30
        defaultUseDiskBackedBuffer = true
        defaultAVSyncOffsetMs = 0
        defaultAudioBoostEnabled = false
        defaultAudioBoostDb = 0
        defaultAudioContinuityEnabled = true
        defaultExtendedLogging = true
    }

    private func addRtmpPreset() {
        let index = rtmpPresets.count + 1
        let preset = RtmpPreset(
            name: "Preset \(index)",
            serverURL: "",
            streamKey: "",
            fullURLOverride: ""
        )
        rtmpPresets.append(preset)
        selectedRtmpPresetID = preset.id
    }

    private func removeSelectedRtmpPreset() {
        guard let index = selectedRtmpPresetIndex else { return }
        rtmpPresets.remove(at: index)
    }

    private func addSourcePreset() {
        let index = sourcePresets.count + 1
        let preset = SourcePreset(
            name: "Source \(index)",
            url: ""
        )
        sourcePresets.append(preset)
        selectedSourcePresetID = preset.id
    }

    private func removeSelectedSourcePreset() {
        guard let index = selectedSourcePresetIndex else { return }
        sourcePresets.remove(at: index)
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

    private func rtmpBinding(for index: Int, keyPath: WritableKeyPath<RtmpPreset, String>) -> Binding<String> {
        Binding(
            get: { rtmpPresets[index][keyPath: keyPath] },
            set: { rtmpPresets[index][keyPath: keyPath] = $0 }
        )
    }

    private func sourceBinding(for index: Int, keyPath: WritableKeyPath<SourcePreset, String>) -> Binding<String> {
        Binding(
            get: { sourcePresets[index][keyPath: keyPath] },
            set: { sourcePresets[index][keyPath: keyPath] = $0 }
        )
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    var minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }

        window.styleMask.insert(.resizable)
        window.minSize = minSize

        if window.frame.width < minSize.width || window.frame.height < minSize.height {
            var frame = window.frame
            frame.size.width = max(frame.size.width, minSize.width)
            frame.size.height = max(frame.size.height, minSize.height)
            window.setFrame(frame, display: true)
        }
    }
}
