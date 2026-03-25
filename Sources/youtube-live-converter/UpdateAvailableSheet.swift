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

            Text(updater.manualInstallMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

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
                Button(updater.isBusy ? "Close" : "Not Now") {
                    updater.shouldPresentUpdateSheet = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(updater.isBusy)

                if updater.state == .updateAvailable {
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
                } else if updater.latestRelease != nil {
                    Button("Download in Browser") {
                        updater.openLatestDownloadInBrowser()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canDownloadUpdate)
                    .keyboardShortcut(.defaultAction)
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
        case .checking:
            return "Back Channel is checking GitHub Releases for a newer version."
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
