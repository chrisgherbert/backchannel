import SwiftUI

struct UpdateAvailableSheet: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sheetTitle)
                .font(.title2.weight(.semibold))

            Text(sheetSubtitle)
                .foregroundStyle(.secondary)

            if let release = updater.latestRelease {
                HStack(spacing: 8) {
                    statPill("Current \(updater.currentVersion)")
                    statPill("Latest \(release.version)")
                }
            }

            if !updater.lastError.isEmpty {
                Text(updater.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if updater.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(updater.statusSummary)
                        .foregroundStyle(.secondary)
                }
            }

            if let release = updater.latestRelease, !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                GroupBox("What’s New") {
                    ScrollView {
                        Text(release.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 140, maxHeight: 220)
                }
            }

            HStack {
                if updater.state != .installing {
                    Button(updater.isBusy ? "Close" : "Not Now") {
                        updater.shouldPresentUpdateSheet = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updater.state == .downloading)
                }

                if updater.state == .updateAvailable || updater.state == .readyToInstall {
                    Button("Skip This Version") {
                        updater.skipAvailableUpdate()
                    }
                    .disabled(updater.isBusy)
                }

                Spacer()

                if updater.state == .upToDate {
                    Button("Done") {
                        updater.shouldPresentUpdateSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else if updater.canInstallPreparedUpdate {
                    Button("Install and Relaunch") {
                        updater.installPreparedUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else if updater.state == .updateAvailable || (updater.state == .failed && updater.latestRelease != nil && updater.preparedUpdate == nil) {
                    Button("Download Update") {
                        Task {
                            await updater.downloadAndPrepareUpdate()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canDownloadUpdate)
                    .keyboardShortcut(.defaultAction)
                } else if updater.state == .installing {
                    Text("Back Channel will relaunch automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var sheetTitle: String {
        switch updater.state {
        case .checking:
            return "Checking for Updates"
        case .downloading:
            return "Downloading Update"
        case .installing:
            return "Installing Update"
        case .readyToInstall:
            return "Update Ready to Install"
        case .upToDate:
            return "Back Channel is Up to Date"
        case .failed:
            return "Update Failed"
        default:
            return "Update Available"
        }
    }

    private var sheetSubtitle: String {
        switch updater.state {
        case .installing:
            return "The update has already been downloaded and verified. Back Channel will quit and reopen automatically."
        case .downloading:
            return "Back Channel is downloading and verifying the latest release from GitHub."
        case .checking:
            return "Back Channel is checking GitHub Releases for a newer version."
        case .readyToInstall:
            return updater.statusSummary
        case .upToDate:
            return updater.statusSummary
        default:
            return updater.statusSummary
        }
    }

    private func statPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }
}
