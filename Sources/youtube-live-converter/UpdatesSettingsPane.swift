import SwiftUI

struct UpdatesSettingsPane: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        ScrollView {
            Form {
                Section("Automatic Updates") {
                    HStack {
                        Text("Check Automatically")
                            .frame(width: 170, alignment: .leading)
                        Toggle("Enable", isOn: automaticChecksBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text("Current Version")
                            .frame(width: 170, alignment: .leading)
                        Text(updater.currentVersion)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text("Last Check")
                            .frame(width: 170, alignment: .leading)
                        Text(lastCheckedLabel)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }

                Section("Release Updates") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Status")
                            .frame(width: 170, alignment: .leading)
                        Text(updater.statusSummary)
                            .foregroundStyle(updater.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        Spacer(minLength: 0)
                    }

                    if let release = updater.latestRelease {
                        HStack {
                            Text("Latest Version")
                                .frame(width: 170, alignment: .leading)
                            Text(release.version)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }

                        HStack {
                            Text("Published")
                                .frame(width: 170, alignment: .leading)
                            Text(releaseDateLabel(for: release))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Check Now") {
                            Task {
                                await updater.checkForUpdates(userInitiated: true)
                            }
                        }
                        .disabled(!updater.canCheckForUpdates)

                        Button("Download Update") {
                            Task {
                                await updater.downloadAndPrepareUpdate()
                            }
                        }
                        .disabled(!updater.canDownloadUpdate)

                        Button("Install and Relaunch") {
                            updater.installPreparedUpdate()
                        }
                        .disabled(!updater.canInstallPreparedUpdate)

                        Button("Open Release Page") {
                            updater.openReleasePage()
                        }
                        .disabled(updater.latestRelease == nil)

                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }
            }
            .formStyle(.grouped)
            .padding(16)
            .padding(.top, 10)
        }
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticChecksEnabled },
            set: { newValue in
                updater.automaticChecksEnabled = newValue
                if newValue {
                    updater.scheduleAutomaticCheck()
                }
            }
        )
    }

    private var lastCheckedLabel: String {
        guard let lastCheckedAt = updater.lastCheckedAt else { return "Never" }
        return lastCheckedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func releaseDateLabel(for release: AppReleaseInfo) -> String {
        guard let publishedAt = release.publishedAt else { return "Unknown" }
        return publishedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
