import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var pipeline: StreamPipeline
    @State private var config = ContentView.makeInitialConfig()
    @State private var copyModePacingEnabled = false
    @State private var autoLoadInfoTask: Task<Void, Never>?
    @State private var lastAutoLoadedSourceURL = ""
    @State private var selectedRtmpPresetID = ""
    @State private var selectedSourcePresetID = ""
    @State private var selectedPanel: PanelTab = .status
    @AppStorage("show_inspector") private var showInspector = true
    @AppStorage(AppPreferenceKeys.logMonitoringEnabled) private var logMonitoringEnabled = true
    @AppStorage(AppPreferenceKeys.rtmpPresetsJSON) private var rtmpPresetsJSON = "[]"
    @AppStorage(AppPreferenceKeys.sourcePresetsJSON) private var sourcePresetsJSON = "[]"
    private let bufferOptions = [0, 5, 15, 30, 60, 120]
    private let audioBoostOptions = [0, 5, 10, 20]
    private let autoLoadDebounceNs: UInt64 = 900_000_000

    var body: some View {
        VStack(spacing: 0) {
            if showInspector {
                HSplitView {
                    mainPane
                        .frame(minWidth: 700)
                    inspectorPane
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
                }
            } else {
                mainPane
            }

            Divider()
            footerBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .onAppear {
            pipeline.setLogMonitoringEnabled(logMonitoringEnabled)
            copyModePacingEnabled = config.encodeMode == .copyPaced
            syncSelectedRtmpPreset()
            syncSelectedSourcePreset()
        }
        .onDisappear {
            autoLoadInfoTask?.cancel()
            autoLoadInfoTask = nil
        }
        .onChange(of: logMonitoringEnabled) { newValue in
            pipeline.setLogMonitoringEnabled(newValue)
        }
        .onChange(of: config.sourceURL) { _ in
            scheduleAutoLoadInfo()
            syncSelectedSourcePreset()
        }
        .onChange(of: config.encodeMode) { newValue in
            if newValue != .transcode {
                copyModePacingEnabled = (newValue == .copyPaced)
            }
        }
        .onChange(of: config.outputType) { _ in
            syncSelectedRtmpPreset()
        }
        .onChange(of: config.rtmpServerURL) { _ in
            syncSelectedRtmpPreset()
        }
        .onChange(of: config.rtmpStreamKey) { _ in
            syncSelectedRtmpPreset()
        }
        .onChange(of: config.rtmpFullURLOverride) { _ in
            syncSelectedRtmpPreset()
        }
        .onChange(of: selectedRtmpPresetID) { newValue in
            applyRtmpPresetSelection(newValue)
        }
        .onChange(of: selectedSourcePresetID) { newValue in
            applySourcePresetSelection(newValue)
        }
        .onChange(of: rtmpPresetsJSON) { _ in
            syncSelectedRtmpPreset()
        }
        .onChange(of: sourcePresetsJSON) { _ in
            syncSelectedSourcePreset()
        }
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                badge(footerPrimaryStateText, footerPrimaryStateTone)
                if shouldShowRetryChip {
                    badge("Retry \(pipeline.parsedStatus.reconnectDelay)", .warning)
                }
                if let bufferChipText {
                    badge(bufferChipText, bufferChipTone)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if shouldShowBufferProgress {
                    VStack(alignment: .center, spacing: 3) {
                        ProgressView(value: pipeline.parsedStatus.bufferProgress)
                            .controlSize(.small)
                            .tint(bufferStatusColor)
                            .frame(width: 220)
                        Text("Buffer \(Int(pipeline.parsedStatus.bufferProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(bufferStatusColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 8) {
                if canStart {
                    Button("Start") { startStream() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.regular)
                } else {
                    Button("Start") { startStream() }
                        .disabled(true)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
                if pipeline.isRunning {
                    Button("Stop") { pipeline.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.regular)
                } else {
                    Button("Stop") { pipeline.stop() }
                        .disabled(true)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "Input Source", subtitle: "URL and source metadata preview") {
                inputSectionFields
            }
            sectionCard(
                title: "Transport & Endpoint",
                subtitle: "Choose transport and destination target",
                headerAccessory: {
                    Picker("Transport", selection: $config.outputType) {
                        Text("RTMP").tag(OutputType.rtmp)
                        Text("HLS").tag(OutputType.hls)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                    .disabled(pipeline.isRunning)
                }
            ) {
                tabbedContentContainer(
                    contextText: transportContextText,
                    animatedSwapID: AnyHashable(config.outputType)
                ) {
                    transportSectionFields
                }
                .disabled(pipeline.isRunning)
            }
            sectionCard(
                title: "Video Output Mode",
                subtitle: "Choose passthrough vs compatibility processing",
                headerAccessory: {
                    Picker("Mode", selection: outputModeBinding) {
                        Text("Compatible").tag(OutputModeSelection.highCompatibility)
                        Text("Stream Copy").tag(OutputModeSelection.streamCopy)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .labelsHidden()
                    .disabled(pipeline.isRunning)
                }
            ) {
                tabbedContentContainer(
                    contextText: videoModeContextText,
                    animatedSwapID: AnyHashable(selectedOutputMode)
                ) {
                    videoModeSectionFields
                }
                .disabled(pipeline.isRunning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mainPane: some View {
        ScrollView {
            leftColumn
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inspectorPane: some View {
        inspectorPanel
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private var inspectorPanel: some View {
        sectionCard(title: "Monitoring", subtitle: "Operational status and advanced logs") {
            tabbedContentContainer(contextText: monitoringContextText, animatedSwapID: nil) {
                monitoringSectionContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var inputSectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !sourcePresets.isEmpty {
                labeled("Preset") {
                    Picker("Input Source Preset", selection: $selectedSourcePresetID) {
                        Text("Custom").tag("")
                        ForEach(sourcePresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 280, alignment: .leading)
                }
            }

            HStack {
                TextField("https://www.youtube.com/watch?v=...", text: $config.sourceURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadInfo() }
                Button("Load Info") { loadInfo() }
                    .disabled(sourceURLTrimmed.isEmpty)
                if isLoadingSourceInfo {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let message = sourceValidationMessage {
                validationLabel(message)
            }
            if let message = liveSourceValidationMessage {
                validationLabel(message)
            }

            if let preview = pipeline.preview {
                HStack(alignment: .top, spacing: 10) {
                    previewThumbnailView(for: preview)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 10) {
                            previewStatPill(preview.resolutionLabel)
                            previewStatPill(preview.frameRateLabel)
                            previewStatPill(preview.bitrateLabel)
                            previewStatPill(preview.codecLabel)
                        }
                        if !preview.descriptionExcerpt.isEmpty {
                            Text(preview.descriptionExcerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        if !pipeline.previewStatus.isEmpty {
                            Text(pipeline.previewStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } else if !pipeline.previewStatus.isEmpty {
                Text(pipeline.previewStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func previewThumbnailView(for preview: StreamPreview) -> some View {
        ZStack(alignment: .topLeading) {
            if let thumbnailURL = preview.thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    thumbnailPlaceholder
                }
            } else {
                thumbnailPlaceholder
            }

            if preview.publishState == .live {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.red)
                    .clipShape(Capsule())
                    .padding(7)
            }
        }
        .frame(width: 152, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.14))
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var transportSectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if config.outputType == .rtmp {
                if !rtmpPresets.isEmpty {
                    labeled("Preset") {
                        Picker("RTMP Preset", selection: $selectedRtmpPresetID) {
                            Text("Custom").tag("")
                            ForEach(rtmpPresets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 260, alignment: .leading)
                    }
                }
                labeled("Server URL") {
                    TextField("rtmp://server/app/", text: $config.rtmpServerURL)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("Stream Key") {
                    TextField("streamName?key=abc123", text: $config.rtmpStreamKey)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("Full URL (Optional)") {
                    TextField("rtmp://server/app/streamName?key=abc123", text: $config.rtmpFullURLOverride)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                labeled("HLS Playlist") {
                    TextField("/tmp/live/out.m3u8", text: $config.hlsPlaylistPath)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let message = outputValidationMessage {
                validationLabel(message)
            }
        }
    }

    private var videoModeSectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedOutputMode == .streamCopy {
                labeledInline("Pace Output") {
                    HStack(spacing: 10) {
                        Toggle("Enable", isOn: pacedStreamCopyBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                        Text("Enable paced output")
                            .font(.caption)
                        Spacer()
                    }
                }
            }

            if config.encodeMode == .transcode || pacedStreamCopyBinding.wrappedValue {
                labeledInline("Buffer Delay") {
                    Picker("", selection: $config.bufferSeconds) {
                        ForEach(bufferOptions, id: \.self) { seconds in
                            Text(seconds == 0 ? "No buffer" : "\(seconds)s").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .leading)
                    .controlSize(.small)
                }
            }

            if config.encodeMode == .transcode {
                labeledInline("Buffer Storage") {
                    HStack(spacing: 8) {
                        Toggle("Disk-backed", isOn: $config.useDiskBackedBuffer)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                            .disabled(config.bufferSeconds <= 0)
                        Text("Disk-backed buffer")
                            .font(.caption2)
                        Spacer()
                    }
                }
                Text("When enabled, buffered media is staged to temporary disk storage before publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)


                labeledInline("A/V Sync Offset") {
                    Stepper(value: $config.avSyncOffsetMs, in: -2000...2000, step: 50) {
                        Text("\(config.avSyncOffsetMs) ms")
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }

                labeledInline("Audio Boost") {
                    HStack(spacing: 8) {
                        Toggle("Enable", isOn: $config.audioBoostEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                        Text("Enable")
                            .font(.caption2)
                        if config.audioBoostEnabled {
                            Picker("Boost", selection: $config.audioBoostDb) {
                                ForEach(audioBoostOptions, id: \.self) { db in
                                    Text("\(db) dB").tag(db)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 110, alignment: .leading)
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                }

                if config.audioBoostEnabled {
                    Text("Applies selected boost and a hard limiter capped at -1 dBFS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if pacedStreamCopyBinding.wrappedValue {
                    Text("Paced Stream Copy keeps copy codecs, while output timing is smoothed for better stability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Stream Copy passes source audio/video through without re-encoding.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if config.encodeMode == .copy {
                Text("Startup buffer is disabled in Stream Copy mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var monitoringSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Picker("Panel", selection: $selectedPanel) {
                    Text("Status").tag(PanelTab.status)
                    Text("Advanced").tag(PanelTab.advanced)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }

            if selectedPanel == .status {
                statusPanel
            } else {
                advancedPanel
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("Source", pipeline.parsedStatus.sourceState)
            statusRow("Output", pipeline.parsedStatus.outputState)
            statusRow("Reconnect", pipeline.parsedStatus.reconnectDelay.isEmpty ? "None" : pipeline.parsedStatus.reconnectDelay)
            statusRow("Output Time", pipeline.parsedStatus.ffmpegTime.isEmpty ? "-" : pipeline.parsedStatus.ffmpegTime)
            statusRow("Output Bitrate", pipeline.parsedStatus.ffmpegBitrate.isEmpty ? "-" : pipeline.parsedStatus.ffmpegBitrate)
            statusRow("Output Speed", pipeline.parsedStatus.ffmpegSpeed.isEmpty ? "-" : pipeline.parsedStatus.ffmpegSpeed)
            bufferStatusRow
            statusRow("A/V Offset", pipeline.parsedStatus.avSyncState)
            statusRow("App Event", pipeline.parsedStatus.lastAppEvent, truncateTail: true)
            statusRow("FFmpeg Event", pipeline.parsedStatus.lastFFmpegEvent, truncateTail: true)
            statusRow("yt-dlp Event", pipeline.parsedStatus.lastYtDlpEvent, truncateTail: true)
            statusRow("Last Error", pipeline.parsedStatus.lastError.isEmpty ? "None" : pipeline.parsedStatus.lastError, truncateTail: true)
        }
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Extended Logging", isOn: $logMonitoringEnabled)
                    .toggleStyle(.switch)
                    .font(.caption2)
                    .controlSize(.mini)
                    .disabled(pipeline.isRunning)
                if pipeline.isRunning {
                    Text("Applies on next start")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Button("Copy All") { copyAllLogs() }
                Button("Export...") { exportLogs() }
                Button("Clear Logs") { pipeline.clearLogs() }
                Spacer()
            }
            .controlSize(.small)

            TextEditor(text: .constant(fullLogText))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sectionCard<HeaderAccessory: View, Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                headerAccessory()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sectionCard(title: title, subtitle: subtitle, headerAccessory: { EmptyView() }, content: content)
    }

    private func tabbedContentContainer<Content: View>(
        contextText: String,
        animatedSwapID: AnyHashable? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(contextText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if let animatedSwapID {
                    VStack(alignment: .leading, spacing: 10) {
                        content()
                    }
                    .id(animatedSwapID)
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        content()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .animation(animatedSwapID == nil ? nil : .easeOut(duration: 0.22), value: animatedSwapID)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labeledInline<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
                .padding(.top, 3)
            content()
            Spacer(minLength: 0)
        }
    }

    private func statusRow(_ key: String, _ value: String, truncateTail: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(key):")
                .bold()
                .frame(width: 112, alignment: .leading)
            Text(value)
                .lineLimit(truncateTail ? 1 : nil)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var bufferStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Startup Buffer:")
                .bold()
                .frame(width: 112, alignment: .leading)
            Circle()
                .fill(bufferStatusColor)
                .frame(width: 8, height: 8)
            Text(pipeline.parsedStatus.bufferState)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func badge(_ text: String, _ tone: StatusTone) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.background)
            .foregroundStyle(tone.foreground)
            .clipShape(Capsule())
    }

    private func validationLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
    }

    private func previewStatPill(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(.primary)
        .font(.caption2.monospaced())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    private var sourceURLTrimmed: String {
        config.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rtmpPresets: [RtmpPreset] {
        AppPreferencesCodec.decodePresets(from: rtmpPresetsJSON)
    }

    private var sourcePresets: [SourcePreset] {
        AppPreferencesCodec.decodeSourcePresets(from: sourcePresetsJSON)
    }

    private var transportContextText: String {
        switch config.outputType {
        case .rtmp:
            return "Editing RTMP endpoint settings."
        case .hls:
            return "Editing HLS playlist destination settings."
        }
    }

    private var videoModeContextText: String {
        switch config.encodeMode {
        case .transcode:
            return "Editing high compatibility output settings."
        case .copyPaced:
            return "Editing stream copy settings (paced output enabled)."
        case .copy:
            return "Editing stream copy settings."
        }
    }

    private var monitoringContextText: String {
        switch selectedPanel {
        case .status:
            return "Viewing live operational status."
        case .advanced:
            return "Viewing advanced process diagnostics and logs."
        }
    }

    private var sourceValidationMessage: String? {
        if sourceURLTrimmed.isEmpty { return "Source URL is required." }
        guard let url = URL(string: sourceURLTrimmed), let scheme = url.scheme?.lowercased() else {
            return "Enter a valid URL."
        }
        if scheme != "http" && scheme != "https" {
            return "URL must start with http:// or https://."
        }
        return nil
    }

    private var resolvedTarget: String {
        config.resolvedOutputTarget()
    }

    private var outputValidationMessage: String? {
        if config.outputType == .hls {
            return resolvedTarget.isEmpty ? "HLS output path is required." : nil
        }
        return resolvedTarget.isEmpty ? "RTMP destination requires server + key (or full URL)." : nil
    }

    private var liveSourceValidationMessage: String? {
        guard sourceValidationMessage == nil else { return nil }
        guard !sourceURLTrimmed.isEmpty else { return nil }
        guard !isLoadingSourceInfo else { return nil }

        guard pipeline.previewSourceURL == sourceURLTrimmed else {
            return "Load source info to validate livestream status."
        }

        guard let preview = pipeline.preview else {
            return "Could not verify source metadata. Use Load Info and try again."
        }

        if preview.publishState == .published {
            return "Source is not live (pre-recorded or ended)."
        }

        return nil
    }

    private var canStart: Bool {
        sourceValidationMessage == nil &&
            liveSourceValidationMessage == nil &&
            outputValidationMessage == nil &&
            !pipeline.isRunning &&
            !isLoadingSourceInfo
    }

    private var fullLogText: String {
        pipeline.logLines.joined(separator: "\n")
    }

    private var shouldShowBufferProgress: Bool {
        guard pipeline.isRunning else { return false }
        let state = pipeline.parsedStatus.bufferState
        if state.hasPrefix("Off") || state == "Stopped" {
            return false
        }
        return config.encodeMode == .copyPaced || config.encodeMode == .transcode
    }

    private var bufferStatusColor: Color {
        let state = pipeline.parsedStatus.bufferState.lowercased()
        if state.hasPrefix("off") || state == "stopped" {
            return .secondary
        }
        if state.contains("exhausted") {
            return .red
        }

        let targetSeconds = Double(config.bufferSeconds)
        guard targetSeconds > 0 else {
            return .secondary
        }

        let bufferedSeconds = max(0.0, min(targetSeconds, targetSeconds * pipeline.parsedStatus.bufferProgress))
        let redThreshold = min(2.0, targetSeconds * 0.25)
        let yellowThreshold = min(8.0, targetSeconds * 0.60)

        if bufferedSeconds < redThreshold {
            return .red
        }
        if bufferedSeconds < yellowThreshold {
            return .orange
        }
        return .green
    }

    private var isLoadingSourceInfo: Bool {
        pipeline.previewStatus == "Loading source info..."
    }

    private var footerPrimaryStateText: String {
        let source = pipeline.parsedStatus.sourceState.lowercased()
        let output = pipeline.parsedStatus.outputState.lowercased()
        let status = pipeline.status.lowercased()
        let lastError = pipeline.parsedStatus.lastError.lowercased()

        if output.contains("error") || source.contains("error") || status.contains("error") || status.contains("failed") ||
            (lastError != "none" && !lastError.isEmpty) {
            return "Error"
        }
        if status.contains("reconnect") {
            return "Recovering"
        }
        if !pipeline.isRunning {
            return "Idle"
        }
        if output.contains("buffering") || output.contains("starting") || source.contains("starting") {
            return "Buffering"
        }
        if output.contains("publishing") || output.contains("running") {
            return "Live"
        }
        return "Starting"
    }

    private var footerPrimaryStateTone: StatusTone {
        switch footerPrimaryStateText {
        case "Live":
            return .good
        case "Recovering", "Buffering", "Starting":
            return .warning
        case "Error":
            return .critical
        default:
            return .neutral
        }
    }

    private var shouldShowRetryChip: Bool {
        let retry = pipeline.parsedStatus.reconnectDelay.trimmingCharacters(in: .whitespacesAndNewlines)
        return !retry.isEmpty && retry.lowercased() != "none"
    }

    private var bufferChipText: String? {
        guard pipeline.isRunning else { return nil }
        guard (config.encodeMode == .copyPaced || config.encodeMode == .transcode) && config.bufferSeconds > 0 else {
            return nil
        }
        let state = pipeline.parsedStatus.bufferState.lowercased()
        if state.contains("exhausted") {
            return "Buffer Empty"
        }
        let seconds = Int((Double(config.bufferSeconds) * pipeline.parsedStatus.bufferProgress).rounded())
        return "Buffer \(max(0, seconds))s"
    }

    private var bufferChipTone: StatusTone {
        let state = pipeline.parsedStatus.bufferState.lowercased()
        if state.contains("exhausted") {
            return .critical
        }
        let targetSeconds = Double(config.bufferSeconds)
        guard targetSeconds > 0 else { return .neutral }
        let bufferedSeconds = max(0.0, min(targetSeconds, targetSeconds * pipeline.parsedStatus.bufferProgress))
        let redThreshold = min(2.0, targetSeconds * 0.25)
        let yellowThreshold = min(8.0, targetSeconds * 0.60)
        if bufferedSeconds < redThreshold {
            return .critical
        }
        if bufferedSeconds < yellowThreshold {
            return .warning
        }
        return .good
    }

    private func loadInfo() {
        lastAutoLoadedSourceURL = sourceURLTrimmed
        pipeline.loadPreview(for: config.sourceURL)
    }

    private func scheduleAutoLoadInfo() {
        autoLoadInfoTask?.cancel()
        autoLoadInfoTask = nil

        let trimmed = sourceURLTrimmed
        guard !trimmed.isEmpty else {
            lastAutoLoadedSourceURL = ""
            return
        }
        guard sourceValidationMessage == nil else { return }

        if pipeline.previewSourceURL == trimmed {
            lastAutoLoadedSourceURL = trimmed
            return
        }

        guard trimmed != lastAutoLoadedSourceURL else { return }

        autoLoadInfoTask = Task { [trimmed] in
            try? await Task.sleep(nanoseconds: autoLoadDebounceNs)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard sourceURLTrimmed == trimmed else { return }
                guard sourceValidationMessage == nil else { return }
                guard !isLoadingSourceInfo else { return }
                guard pipeline.previewSourceURL != trimmed else {
                    lastAutoLoadedSourceURL = trimmed
                    return
                }
                guard lastAutoLoadedSourceURL != trimmed else { return }
                loadInfo()
            }
        }
    }

    private func startStream() {
        var runtimeConfig = config
        runtimeConfig.outputTarget = runtimeConfig.resolvedOutputTarget()
        pipeline.start(config: runtimeConfig)
    }

    private var outputModeBinding: Binding<OutputModeSelection> {
        Binding(
            get: { selectedOutputMode },
            set: { selection in
                switch selection {
                case .streamCopy:
                    config.encodeMode = copyModePacingEnabled ? .copyPaced : .copy
                case .highCompatibility:
                    config.encodeMode = .transcode
                }
            }
        )
    }

    private var pacedStreamCopyBinding: Binding<Bool> {
        Binding(
            get: {
                config.encodeMode == .copyPaced ||
                    (config.encodeMode == .copy && copyModePacingEnabled)
            },
            set: { enabled in
                copyModePacingEnabled = enabled
                if selectedOutputMode == .streamCopy {
                    config.encodeMode = enabled ? .copyPaced : .copy
                }
            }
        )
    }

    private var selectedOutputMode: OutputModeSelection {
        config.encodeMode == .transcode ? .highCompatibility : .streamCopy
    }

    private func applyRtmpPresetSelection(_ id: String) {
        guard !id.isEmpty else { return }
        guard let preset = rtmpPresets.first(where: { $0.id == id }) else { return }
        config.rtmpServerURL = preset.serverURL
        config.rtmpStreamKey = preset.streamKey
        config.rtmpFullURLOverride = preset.fullURLOverride
    }

    private func syncSelectedRtmpPreset() {
        guard config.outputType == .rtmp else {
            selectedRtmpPresetID = ""
            return
        }
        if let matching = rtmpPresets.first(where: {
            $0.serverURL == config.rtmpServerURL &&
            $0.streamKey == config.rtmpStreamKey &&
            $0.fullURLOverride == config.rtmpFullURLOverride
        }) {
            selectedRtmpPresetID = matching.id
        } else {
            selectedRtmpPresetID = ""
        }
    }

    private func applySourcePresetSelection(_ id: String) {
        guard !id.isEmpty else { return }
        guard let preset = sourcePresets.first(where: { $0.id == id }) else { return }
        guard config.sourceURL != preset.url else { return }
        config.sourceURL = preset.url
    }

    private func syncSelectedSourcePreset() {
        let url = sourceURLTrimmed
        if url.isEmpty {
            selectedSourcePresetID = ""
            return
        }

        if let match = sourcePresets.first(where: {
            $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == url
        }) {
            selectedSourcePresetID = match.id
        } else {
            selectedSourcePresetID = ""
        }
    }

    private static func makeInitialConfig() -> StreamConfig {
        var config = StreamConfig()
        let defaults = UserDefaults.standard

        let raw = defaults.string(forKey: AppPreferenceKeys.defaultEncodeMode) ?? ""
        if let mode = EncodeMode(rawValue: raw) {
            config.encodeMode = mode
        }

        if defaults.object(forKey: AppPreferenceKeys.defaultBufferSeconds) != nil {
            let seconds = defaults.integer(forKey: AppPreferenceKeys.defaultBufferSeconds)
            let allowed = [0, 5, 15, 30, 60, 120]
            config.bufferSeconds = allowed.contains(seconds) ? seconds : 30
        }

        if defaults.object(forKey: AppPreferenceKeys.defaultUseDiskBackedBuffer) != nil {
            config.useDiskBackedBuffer = defaults.bool(forKey: AppPreferenceKeys.defaultUseDiskBackedBuffer)
        }

        if defaults.object(forKey: AppPreferenceKeys.defaultAVSyncOffsetMs) != nil {
            let offset = defaults.integer(forKey: AppPreferenceKeys.defaultAVSyncOffsetMs)
            config.avSyncOffsetMs = min(2000, max(-2000, offset))
        }

        if defaults.object(forKey: AppPreferenceKeys.defaultAudioBoostEnabled) != nil {
            config.audioBoostEnabled = defaults.bool(forKey: AppPreferenceKeys.defaultAudioBoostEnabled)
        }

        if defaults.object(forKey: AppPreferenceKeys.defaultAudioBoostDb) != nil {
            let db = defaults.integer(forKey: AppPreferenceKeys.defaultAudioBoostDb)
            let allowedDb = [0, 5, 10, 20]
            config.audioBoostDb = allowedDb.contains(db) ? db : 0
        }

        return config
    }

    private func copyAllLogs() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fullLogText, forType: .string)
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "youtube-live-converter.log.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fullLogText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }

    private func toneForStatus(_ value: String) -> StatusTone {
        let lower = value.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("stopped (") {
            return .critical
        }
        if lower.contains("running") || lower.contains("publishing") || lower.contains("primed") {
            return .good
        }
        if lower.contains("buffering") || lower.contains("reconnect") || lower.contains("starting") {
            return .warning
        }
        return .neutral
    }

    private func stateColor(_ state: PublishState) -> Color {
        switch state {
        case .live:
            return .red
        case .upcoming:
            return .orange
        case .published, .unknown:
            return .secondary
        }
    }
}

private enum PanelTab {
    case status
    case advanced
}

private enum OutputModeSelection: Hashable {
    case streamCopy
    case highCompatibility
}

private enum StatusTone {
    case good
    case warning
    case critical
    case neutral

    var background: Color {
        switch self {
        case .good:
            return .green.opacity(0.2)
        case .warning:
            return .orange.opacity(0.2)
        case .critical:
            return .red.opacity(0.2)
        case .neutral:
            return .secondary.opacity(0.18)
        }
    }

    var foreground: Color {
        switch self {
        case .good:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        case .neutral:
            return .primary
        }
    }
}
