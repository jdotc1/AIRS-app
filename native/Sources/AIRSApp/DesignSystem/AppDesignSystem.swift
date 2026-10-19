import SwiftUI
import LumenTokens
import LumenUI

/// Compatibility names for AIRS call sites; every value comes from Lumen's standard metrics.
/// AIRS installs standard metrics at both scene roots and does not offer density/theme editing.
enum AppDesign {
    enum Space {
        static let small = Lumen.Space.s2
        static let medium = Lumen.Space.s4
        static let regular = Lumen.Space.s5
        static let section = Lumen.Space.s6
        static let page = Lumen.Space.s7
        static let large = Lumen.Space.s8
    }
    enum Layout {
        static let paneHeader = Lumen.Layout.paneHeaderHeight
        static let radius = Lumen.Radius.md
        static let pageTitle = Lumen.Font.title2
    }
    enum Symbol {
        static let audit = "waveform.path"
        static let entitlements = "square.split.2x1"
        static let batch = "square.stack"
        static let history = "clock.arrow.circlepath"
        static let library = "books.vertical"
        static let recovery = "arrow.clockwise"
    }
}

/// Lumen has detail/section headers, but no page header accepting arbitrary trailing controls.
struct AppPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.spacing.s5) {
                    Text(title).font(metrics.typography.title2).fixedSize()
                    Spacer(minLength: metrics.spacing.s4)
                    actions.controlSize(.small).fixedSize()
                }
                VStack(alignment: .leading, spacing: metrics.spacing.s4) {
                    Text(title).font(metrics.typography.title2)
                    actions.controlSize(.small)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary])
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.foregroundStyle(palette[.fgPrimary]).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppDialogTitle: View {
    let title: String
    @Environment(\.lumenMetrics) private var metrics
    var body: some View {
        Text(title).font(metrics.typography.title2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppDialogSurface: ViewModifier {
    @Environment(\.lumenPalette) private var palette
    func body(content: Content) -> some View {
        content.background(palette[.bgCanvas]).tint(palette[.accent])
    }
}

extension View {
    func appDialogSurface() -> some View { modifier(AppDialogSurface()) }
}
