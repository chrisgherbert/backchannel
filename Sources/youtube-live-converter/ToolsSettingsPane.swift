import SwiftUI

struct ToolsSettingsPane: View {
    @EnvironmentObject private var externalTools: ExternalToolsManager

    var body: some View {
        ScrollView {
            Form {
                Section("Bundled Tools") {
                    Text("These ship inside the app. Managed support takes precedence when an installed managed version is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(externalTools.bundledStatuses) { status in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(status.kind.displayName)
                                    .frame(width: 170, alignment: .leading)
                                bundledStatusBadge(for: status)
                                if let version = status.version {
                                    Text(version)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }

                            if let path = status.path {
                                Text(path.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Managed Support") {
                    Text("Back Channel can install and maintain a fast-start Python runtime for yt-dlp and other support components in Application Support without asking the user to manage runtimes manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Availability")
                            .frame(width: 170, alignment: .leading)
                        Text(externalTools.managedSupportStatusMessage)
                            .foregroundStyle(externalTools.canInstallManagedSupport ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        Spacer(minLength: 0)
                    }

                    if externalTools.isPerformingAction {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(externalTools.activityMessage)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(externalTools.managedStatuses) { status in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(status.kind.displayName)
                                    .frame(width: 170, alignment: .leading)
                                managedStatusBadge(for: status)
                                if let installedVersion = status.installedVersion {
                                    Text(installedVersion)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                if let runtimeVersion = status.runtimeVersion,
                                   status.installedVersion != nil {
                                    Text(runtimeVersion)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }

                            if let executableURL = status.executableURL {
                                Text(executableURL.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if let availableVersion = status.availableVersion,
                               availableVersion != status.installedVersion {
                                Text("Latest available: \(availableVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let lastError = status.lastError, !lastError.isEmpty {
                                Text(lastError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }

                            HStack(spacing: 8) {
                                Button(buttonTitle(for: status)) {
                                    Task {
                                        await handlePrimaryAction(for: status)
                                    }
                                }
                                .disabled(externalTools.isPerformingAction || !externalTools.canInstallManagedSupport)

                                Button("Repair") {
                                    Task {
                                        await externalTools.repair(status.kind)
                                    }
                                }
                                .disabled(externalTools.isPerformingAction || !externalTools.canInstallManagedSupport)

                                if status.canRollback {
                                    Button("Rollback") {
                                        Task {
                                            await externalTools.rollback(status.kind)
                                        }
                                    }
                                    .disabled(externalTools.isPerformingAction)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }

                    HStack {
                        Button("Refresh Status") {
                            externalTools.refreshStatus(forceManifestRefresh: true)
                        }
                        .disabled(externalTools.isPerformingAction)

                        Button("Set Up / Update All") {
                            Task {
                                await externalTools.setUpManagedSupport()
                            }
                        }
                        .disabled(externalTools.isPerformingAction || !externalTools.canInstallManagedSupport)
                    }
                    .controlSize(.small)
                }

                Section("Status") {
                    HStack {
                        Text("Last Error")
                            .frame(width: 170, alignment: .leading)
                        Text(externalTools.lastError.isEmpty ? "None" : externalTools.lastError)
                            .foregroundStyle(externalTools.lastError.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(16)
            .padding(.top, 10)
        }
        .onAppear {
            externalTools.refreshStatus()
        }
    }

    private func buttonTitle(for status: ManagedComponentStatus) -> String {
        switch status.health {
        case .ready:
            return status.availableVersion == status.installedVersion ? "Reinstall" : "Update"
        case .bundledFallback, .missing, .error:
            return "Install"
        case .installing:
            return "Installing..."
        }
    }

    private func handlePrimaryAction(for status: ManagedComponentStatus) async {
        switch status.health {
        case .ready:
            await externalTools.update(status.kind)
        case .bundledFallback, .missing, .error:
            await externalTools.update(status.kind)
        case .installing:
            break
        }
    }

    private func managedStatusBadge(for status: ManagedComponentStatus) -> some View {
        switch status.health {
        case .ready:
            return statusBadge(text: "Installed", color: .green)
        case .bundledFallback:
            return statusBadge(text: status.installedVersion == nil ? "Bundled Fallback" : "Installed (Fallback)", color: .orange)
        case .missing:
            return statusBadge(text: "Missing", color: .orange)
        case .installing:
            return statusBadge(text: "Installing", color: .blue)
        case .error:
            return statusBadge(text: "Needs Repair", color: .red)
        }
    }

    private func bundledStatusBadge(for status: BundledToolStatus) -> some View {
        if managedOverride(for: status.kind) != nil {
            return statusBadge(text: "Managed Override", color: .blue)
        }

        switch status.health {
        case .verified:
            return statusBadge(text: "Ready", color: .green)
        case .present:
            return statusBadge(text: "Present", color: .orange)
        case .missing:
            return statusBadge(text: "Missing", color: .orange)
        }
    }

    private func managedOverride(for kind: ExternalToolKind) -> ManagedComponentStatus? {
        externalTools.managedStatuses.first(where: { status in
            status.kind.toolKind == kind && status.health == .ready
        })
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
