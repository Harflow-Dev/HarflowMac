import SwiftUI

// MARK: - HarnessQualificationCard

/// Shared staged qualification card for launch forms and explicit Settings inspection.
/// Reference: HarflowDesign 5d48a18, features/qualification.html, all documented states.
public struct HarnessQualificationCard: View {
    private let model: HarnessQualificationModel
    private let action: () -> Void

    /// Creates a card whose action is handled by the owning feature.
    public init(model: HarnessQualificationModel, action: @escaping () -> Void) {
        self.model = model
        self.action = action
    }

    /// Renders the immutable qualification state and its explicit action.
    public var body: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing14) {
                HStack(alignment: .top, spacing: HfRadius.Metrics.spacing16) {
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                        Text("Harness qualification").font(.hf(.body, weight: .semibold))
                        Text(model.identity).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                    }
                    Spacer(minLength: HfRadius.Metrics.zero)
                    Text(model.state.title)
.font(.hf(.caption, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                Text(model.message).font(.hf(.secondary))
                ForEach(model.features) { feature in
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: HfRadius.Metrics.spacing16) {
                            Text(feature.id).font(.hf(.secondary))
                            Spacer(minLength: HfRadius.Metrics.zero)
                            Text(feature.result).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                        }
                        if !feature.reason.isEmpty {
                            Text(feature.reason)
.font(.hf(.secondary))
.foregroundStyle(Color.warningFG)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if !model.reason.isEmpty {
                    Text(model.reason)
.font(.hf(.secondary))
.foregroundStyle(Color.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let title = model.actionTitle {
                    Button(title, action: action)
                        .disabled(!model.canCheck)
                        .font(.hf(.secondary))
                }
                if model.state == .checking || model.state == .cancelled {
                    Text("Cancelling stops waiting for this check. The engine may still finish it.")
                        .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                }
            }
            .foregroundStyle(Color.primaryText)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Harness qualification, \(model.state.title)")
    }

    private var statusColor: Color {
        switch model.state {
        case .ready: .doneGreen
        case .failed, .failedAtRuntime: .dangerFG
        case .checking: .runningFG
        default: .neutralText
        }
    }
}

#if DEBUG
#Preview("Qualification states · Light") {
    ScrollView {
        VStack {
            ForEach(HarnessQualificationModel.State.allCases, id: \.self) { state in
                HarnessQualificationCard(model: .init(identity: "Fixture harness · fixture version", state: state,
                                                       message: "Required features reported by the engine", features: []), action: {})
            }
        }.padding(HfRadius.Metrics.spacing16)
    }
.frame(width: HfRadius.Metrics.setupWelcomeContainerWidth)
.preferredColorScheme(.light)
}

#Preview("Qualification · Dark") {
    HarnessQualificationCard(model: .init(identity: "Fixture harness · fixture version", state: .failedAtRuntime,
                                           message: "A required feature failed at runtime.",
                                           features: [.init(id: "fixture_feature", result: "failed-at-runtime", reason: "Fixture failure detail")]), action: {})
        .padding(HfRadius.Metrics.spacing16)
        .frame(width: HfRadius.Metrics.setupWelcomeContainerWidth)
.preferredColorScheme(.dark)
}
#endif
