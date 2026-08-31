import SwiftUI

/// Visual confirmation of the Thread palette. This is a reference swatch, not
/// shipped UI — a place to eyeball the color system before views build on it.
struct PaletteSwatchView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                section("Surfaces") {
                    surfaceRow("Background", Palette.background, "#0F0F0F")
                    surfaceRow("Surface", Palette.surface, "#1A1A1A")
                    surfaceRow("Elevated", Palette.elevated, "#242424")
                }

                section("Text") {
                    textRow("Primary", Palette.textPrimary, "white 90%")
                    textRow("Secondary", Palette.textSecondary, "white 50%")
                }

                section("Accent") {
                    surfaceRow("Accent", Palette.accent, "#4A9EFF")
                }

                section("Node types") {
                    nodeCard("Facts", hex: "#4A9EFF", color: Palette.fact)
                    nodeCard("Decisions", hex: "#FFB84D", color: Palette.decision)
                    nodeCard("Open Questions", hex: "#FF6B6B", color: Palette.openQuestion)
                    nodeCard("Action Items", hex: "#4ADE80", color: Palette.actionItem)
                }

                section("Superseded — 30% opacity + strikethrough") {
                    nodeCard("Ship the beta on Friday", hex: "current", color: Palette.decision)
                    nodeCard("Ship the beta on Thursday", hex: "superseded", color: Palette.decision)
                        .superseded()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private func section(
        _ title: String,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .tracking(0.5)
            content()
        }
    }

    // MARK: - Rows

    /// A filled color chip beside its name and value.
    private func surfaceRow(_ name: String, _ color: Color, _ value: String) -> some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10)
                .fill(color)
                .frame(width: 68, height: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Palette.textSecondary.opacity(0.25))
                }
            label(name, value)
            Spacer(minLength: 0)
        }
    }

    /// A text sample rendered in the token's color on a surface tile.
    private func textRow(_ name: String, _ color: Color, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text("Ag")
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 68, height: 48)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            label(name, value)
            Spacer(minLength: 0)
        }
    }

    /// A card carrying a semantic left border, mirroring the Context tab.
    private func nodeCard(_ text: String, hex: String, color: Color) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(hex)
                    .font(.caption.monospaced())
                    .foregroundStyle(color)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func label(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.textPrimary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

#Preview("Thread Palette") {
    PaletteSwatchView()
}
