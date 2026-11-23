//
//  InstallBanner.swift
//  HfUI
//

import SwiftUI

// MARK: - InstallBanner

/// The managed-runtime banner shown in the menu bar and Settings → Harnesses whenever
/// `InstallRepository`'s state needs surfacing. Dumb component — it holds no logic beyond layout;
/// the owning VM maps `InstallState` to `Model` and supplies the two closures. Compact enough to sit in a 320-pt menu bar popover.
public struct InstallBanner: View {
    /// Presentation data for one banner state. Built by the owning VM from `InstallState`.
    public struct Model: Equatable {
        public let title: String
        public let detail: String
        /// "Try again". `nil` while `isBusy` (`running`), since there is nothing to tap.
        public let primaryTitle: String?
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
            isBusy: Bool = false,
            errorText: String? = nil,
            canDismiss: Bool = false,
            footnote: String? = nil
        ) {
            self.title = title
            self.detail = detail
            self.primaryTitle = primaryTitle
            self.isBusy = isBusy
            self.errorText = errorText
            self.canDismiss = canDismiss
            self.footnote = footnote
        }
    }

    public let model: Model
    public let onPrimary: () -> Void
    public let onDismiss: () -> Void

    public init(model: Model, onPrimary: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onPrimary = onPrimary
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
#Preview("running · harflow") {
    InstallBanner(
        model: .init(title: "Preparing Harflow runtime…", detail: "Preparing the exact paired runtime. This can take a few minutes.", isBusy: true),
        onPrimary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("running · validate") {
    InstallBanner(
        model: .init(title: "Checking…", detail: "Checking the new install. This can take a little while.", isBusy: true),
        onPrimary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("failed") {
    InstallBanner(
        model: .init(
            title: "Harflow runtime preparation failed",
            detail: "The managed runtime is unavailable. Try again to prepare it.",
            primaryTitle: "Try again",
            errorText: "Runtime preparation failed.",
            canDismiss: true
        ),
        onPrimary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("installed") {
    InstallBanner(
        model: .init(
            title: "harflow is installed",
            detail: "The new install passed its checks.",
            canDismiss: true,
            footnote: "Next: register it with your harnesses in Settings → Harnesses."
        ),
        onPrimary: {}, onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}
#endif
