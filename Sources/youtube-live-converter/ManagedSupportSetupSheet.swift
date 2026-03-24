import SwiftUI

struct ManagedSupportSetupSheet: View {
    @EnvironmentObject private var externalTools: ExternalToolsManager
    let onDismiss: () -> Void
    let onDeferred: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Extended Support")
                .font(.title2.weight(.semibold))

            Text("Back Channel is installed and ready to use. For faster source loading, broader compatibility, and managed updates, we can install a small set of support components in Application Support.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Managed Python runtime with fast-start yt-dlp", systemImage: "shippingbox")
                Label("Managed JavaScript runtime for source extraction", systemImage: "cpu")
                Label("Automatic repair and rollback controls in Settings", systemImage: "wrench.and.screwdriver")
            }
            .font(.subheadline)

            if externalTools.isPerformingAction {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(externalTools.activityMessage.isEmpty ? "Setting up..." : externalTools.activityMessage)
                        .foregroundStyle(.secondary)
                }
            }

            Text(externalTools.managedSupportStatusMessage)
                .font(.caption)
                .foregroundStyle(externalTools.canInstallManagedSupport ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))

            if !externalTools.lastError.isEmpty {
                Text(externalTools.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Not Now") {
                    onDeferred()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(externalTools.isPerformingAction)

                Spacer()

                Button("Set Up") {
                    Task {
                        await externalTools.setUpManagedSupport()
                        if !externalTools.requiresInitialSetup {
                            onDismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(externalTools.isPerformingAction || !externalTools.canInstallManagedSupport)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
