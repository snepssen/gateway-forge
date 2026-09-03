import Foundation
import SwiftUI

/// The listener controls whether the interface points out its next useful
/// action. The preference survives relaunches; targets remain feature-owned
/// facts rather than a second navigation model.
@MainActor
final class GuidanceMode: ObservableObject {
    static let storageKey = "gatewayforge.guidance.enabled"

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.storageKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.storageKey)
    }

    func toggle() { isEnabled.toggle() }
}

enum GuidanceTarget: Equatable {
    case homeContinue
    case homeFirstJourney
    case createSession
    case beginSession
}

enum GuidanceRules {
    static func home(hasPlayableSession: Bool) -> GuidanceTarget {
        hasPlayableSession ? .homeContinue : .homeFirstJourney
    }

    static func sessionPlan(hasUnresolvedUses: Bool) -> GuidanceTarget? {
        hasUnresolvedUses ? nil : .createSession
    }

    static func track(isLoaded: Bool) -> GuidanceTarget? {
        isLoaded ? .beginSession : nil
    }
}

/// A fixed-size toolbar toggle. Its label never changes width and it contains
/// no animated status layer, avoiding the drifting indicator failure this
/// pattern replaces.
struct GuidanceButton: View {
    @EnvironmentObject var guidance: GuidanceMode

    var body: some View {
        Button { guidance.toggle() } label: {
            Image(systemName: guidance.isEnabled ? "lightbulb.fill" : "lightbulb")
                .frame(width: 26, height: 24)
                .foregroundStyle(guidance.isEnabled ? Monokai.yellow : Monokai.comment)
                .background(guidance.isEnabled ? Monokai.yellow.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel("Guidance")
        .accessibilityValue(guidance.isEnabled ? "On" : "Off")
        .help(guidance.isEnabled
              ? "Guidance is on — highlighted outlines point to the next useful action"
              : "Highlight the next useful action")
    }
}

private struct GuidanceHighlightModifier: ViewModifier {
    @EnvironmentObject var guidance: GuidanceMode
    @EnvironmentObject var player: SessionPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isTarget: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if guidance.isEnabled && isTarget {
                if player.isPlaying || reduceMotion {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Monokai.yellow.opacity(0.42), lineWidth: 1.5)
                        .padding(-2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    GuidancePulse(cornerRadius: cornerRadius)
                }
            }
        }
    }
}

private struct GuidancePulse: View {
    let cornerRadius: CGFloat
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(Monokai.yellow.opacity(bright ? 0.78 : 0.06), lineWidth: 1.5)
            .shadow(color: Monokai.yellow.opacity(bright ? 0.28 : 0),
                    radius: bright ? 4 : 0)
            .padding(-2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}

extension View {
    /// Draws outside the target's existing bounds, so enabling guidance cannot
    /// move siblings, resize a toolbar item or change hit testing.
    func guidanceHighlight(_ isTarget: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(GuidanceHighlightModifier(isTarget: isTarget,
                                           cornerRadius: cornerRadius))
    }
}
