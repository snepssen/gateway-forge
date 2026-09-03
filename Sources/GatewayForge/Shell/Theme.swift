import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Monokai, chosen by the user 2026-08-19. Colour carries state everywhere:
/// gray = unavailable · orange = missing / to be generated · red = error ·
/// green = all okay · purple = active (selection, now playing, timeline).
enum Monokai {
    static let bg      = Color(hex: 0x272822)
    static let panel   = Color(hex: 0x31322B)
    static let inset   = Color(hex: 0x3E3D32)
    static let fg      = Color(hex: 0xF8F8F2)
    static let comment = Color(hex: 0x75715E)
    static let yellow  = Color(hex: 0xE6DB74)
    static let orange  = Color(hex: 0xFD971F)
    static let red     = Color(hex: 0xF92672)
    static let green   = Color(hex: 0xA6E22E)
    static let purple  = Color(hex: 0xAE81FF)
    static let cyan    = Color(hex: 0x66D9EF)
}

/// The five UI states, straight from the user's spec. Every dot and chip in the
/// app maps to one of these -- never invent an ad-hoc colour.
enum UIStatus: Equatable {
    case unavailable   // gray: not built yet, nothing there
    case pending       // orange: missing, waiting to be generated / authored
    case error         // red: broken, needs attention
    case ok            // green: present and healthy
    case active        // purple: selected, playing, in focus

    var color: Color {
        switch self {
        case .unavailable: Monokai.comment
        case .pending:     Monokai.orange
        case .error:       Monokai.red
        case .ok:          Monokai.green
        case .active:      Monokai.purple
        }
    }
}

struct StatusDot: View {
    var status: UIStatus

    var body: some View {
        Circle()
            .frame(width: 7, height: 7)
            .foregroundStyle(status.color)
            // Status is information, not activity chrome. Keeping this view
            // stateless also prevents SwiftUI preserving an animated layer
            // after a toolbar item is replaced or resized.
            .frame(width: 8, height: 8, alignment: .center)
            .fixedSize()
    }
}

/// A small monospaced tag. Colour follows the state spec.
struct Chip: View {
    var text: String
    var color: Color = Monokai.comment
    var body: some View {
        Text(text).font(.caption2).monospaced()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
    }
}

/// A clickable chip: same look, purple on the way in (active = purple).
struct LinkChip: View {
    var text: String
    var color: Color = Monokai.cyan
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Chip(text: text, color: hover ? Monokai.purple : color)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func panel() -> some View { modifier(PanelModifier()) }
}
