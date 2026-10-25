//
//  InstallBanner.swift
//  HfUI
//

import SwiftUI

// MARK: - InstallBanner

/// The install/update banner shown in the sidebar, the menu bar and Settings → Harnesses whenever
/// `InstallRepository`'s state (or a load failure) needs surfacing. Dumb component — it holds no
/// logic beyond layout; the owning VM maps `InstallState`/`InstallNeed` to `Model` and supplies the
/// three closures. Compact enough to sit in a sidebar list section or a 320-pt menu bar popover.
public struct InstallBanner: View {
    /// Presentation data for one banner state. Built by the VM — see `macos/build/monitor-install-button-plan.md` section 5 for the state-to-`Model` mapping.
    public struct Model: Equatable {
        public let title: String
        public let detail: String
        /// "Install" / "Update" / "Install uv" / "Try again" / "Check again". `nil` while `isBusy`
        /// (`running`), since there is nothing to tap.
        public let primaryTitle: String?
        /// "Install anyway" — set only in the `unresolved` state.
        public let secondaryTitle: String?
        public let isBusy: Bool
        public let errorText: String?
        /// Whether the dismiss (xmark) button shows. Set for `failed` and `installed` only;
        /// dismissal is shared across all views.
        public let canDismiss: Bool
        /// Shown on success: "Next: register it with your harnesses in Settings → Harnesses."
        public let footnote: String?

        public init(
            title: String,
            detail: String,
            primaryTitle: String? = nil,
            secondaryTitle: String? = nil,
            isBusy: Bool = false,
            errorText: String? = nil,
            canDismiss: Bool = false,
            footnote: String? = nil
        ) {
            self.title = title
            self.detail = detail
            self.primaryTitle = primaryTitle
            self.secondaryTitle = secondaryTitle
            self.isBusy = isBusy
            self.errorText = errorText
            self.canDismiss = canDismiss
            self.footnote = footnote
        }
    }

    public let model: Model
    public let onPrimary: () -> Void
    public let onSecondary: () -> Void
    public let onDismiss: () -> Void

    public init(model: Model, onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.hf(.body, weight: .semibold))
                    Text(model.detail)
                        .font(.hf(.secondary))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if model.canDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.hf(.caption, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small) }
                if let primaryTitle = model.primaryTitle {
                    Button(primaryTitle, action: onPrimary).disabled(model.isBusy)
                }
                if let secondaryTitle = model.secondaryTitle {
                    Button(secondaryTitle, action: onSecondary).disabled(model.isBusy)
                }
            }
            if let footnote = model.footnote {
                Text(footnote).font(.hf(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.neutralFill))
    }
}

#if DEBUG
#Preview("missing") {
    InstallBanner(
        model: .init(title: "harflow isn't installed", detail: "Harness sessions need harflow on this Mac.", primaryTitle: "Install harflow"),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("incomplete") {
    InstallBanner(
        model: .init(
            title: "harflow is incomplete or out of date",
            detail: "harflow-ctl or harflow-setup is missing.",
            primaryTitle: "Update harflow"
        ),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("needsGit") {
    InstallBanner(
        model: .init(
            title: "harflow isn't installed",
            detail: "Install Apple's Command Line Tools first (`xcode-select --install`)",
            primaryTitle: "Try again"
        ),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("needsUv") {
    InstallBanner(
        model: .init(title: "harflow isn't installed", detail: "uv is needed to install harflow.", primaryTitle: "Install uv"),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("running · git") {
    InstallBanner(
        model: .init(title: "Installing harflow…", detail: "Checking for git…", isBusy: true),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("running · uv") {
    InstallBanner(
        model: .init(title: "Installing harflow…", detail: "Installing uv…", isBusy: true),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("running · harflow") {
    InstallBanner(
        model: .init(title: "Installing harflow…", detail: "Installing harflow from GitHub…", isBusy: true),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("running · validate") {
    InstallBanner(
        model: .init(title: "Installing harflow…", detail: "Checking…", isBusy: true),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("failed") {
    InstallBanner(
        model: .init(
            title: "harflow isn't installed",
            detail: "harflow install failed.",
            primaryTitle: "Try again",
            errorText: "Installing harflow from GitHub failed with a non-zero exit.",
            canDismiss: true
        ),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("unresolved") {
    InstallBanner(
        model: .init(
            title: "harflow isn't installed",
            detail: "An earlier install may still be running.",
            primaryTitle: "Check again",
            secondaryTitle: "Install anyway",
            errorText: "The install didn't finish in time."
        ),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("installed") {
    InstallBanner(
        model: .init(
            title: "harflow is installed",
            detail: "harflow-ctl and harflow-setup were found and validated.",
            canDismiss: true,
            footnote: "Next: register it with your harnesses in Settings → Harnesses."
        ),
        onPrimary: {}, onSecondary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}
#endif
