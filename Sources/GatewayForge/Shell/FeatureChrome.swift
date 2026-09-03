import SwiftUI

/// Shared geometry for feature entry screens. Features supply content; the
/// shell can move the whole screen without each one reinventing padding,
/// readable width and title hierarchy.
struct FeaturePage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.largeTitle).foregroundStyle(Monokai.fg)
                    Text(subtitle).foregroundStyle(Monokai.comment)
                }
                content
            }
            .padding(22)
            // Capped, but explicitly willing to be narrower. Without the
            // flexible frame, the page reported 760 as the width it wanted;
            // NavigationSplitView handed the detail column that much and
            // squeezed the climb rail and the inspector below their own
            // declared minimums to pay for it, laying their contents out at
            // full width and clipping both edges.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A destination, not a dashboard widget. Its fixed leading icon and trailing
/// chevron make every Studio entry read and move the same way.
struct FeatureLinkCard: View {
    let title: String
    let subtitle: String
    let icon: String
    var status: UIStatus = .ok
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(status.color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(Monokai.fg)
                    Text(subtitle).font(.caption).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(Monokai.comment)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
