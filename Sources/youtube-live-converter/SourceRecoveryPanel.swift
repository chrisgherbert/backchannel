import SwiftUI

struct SourceRecoveryPanel: View {
    let recovery: StreamSourceRecovery
    var openBrowser: () -> Void
    var openCookieSettings: () -> Void
    var retry: () -> Void

    private var recovering: Bool { recovery.phase == .switching || recovery.phase == .trying }

    var body: some View {
        if recovery.phase != .none {
            VStack(alignment: .leading, spacing: 10) {
                if recovering {
                    Label(recovery.failureTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(recovery.failureDetail).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(recovery.phase == .switching ? "Switching to yt-dlp…" : "Trying yt-dlp…")
                            .font(.callout.weight(.semibold))
                    }
                    Text(recovery.attemptDetail).font(.caption).foregroundStyle(.secondary)
                } else if recovery.phase == .failed {
                    Label("Both source tools failed", systemImage: "exclamationmark.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.red)
                    Text("Streamlink and yt-dlp could not open this source. Automatic retries stopped.")
                        .font(.caption)
                    recoveryDetails
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Open in Browser", action: openBrowser)
                        Button("Browser Cookie Settings", action: openCookieSettings)
                        Button("Retry", action: retry).buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                } else {
                    Label(recovery.phase == .restored ? "Streaming restored with yt-dlp" : "Recovery stopped",
                          systemImage: recovery.phase == .restored ? "checkmark.circle.fill" : "stop.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(recovery.phase == .restored ? Color.green : Color.secondary)
                    recoveryDetails
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    private var recoveryDetails: some View {
        DisclosureGroup("View recovery details") {
            VStack(alignment: .leading, spacing: 6) {
                Text(recovery.failureTitle).fontWeight(.medium)
                Text(recovery.failureDetail)
                if !recovery.fallbackError.isEmpty {
                    Text(recovery.fallbackError).textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        }
        .font(.caption)
    }
}
