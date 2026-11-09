import SwiftUI

enum FatlineStyle {
    static let paper = adaptive(light: 0xFDFBF7, dark: 0x121B16)
    static let ink = adaptive(light: 0x0A2F1D, dark: 0xF0F1E9)
    static let secondary = adaptive(light: 0x54635A, dark: 0xAAB8AF)
    static let action = adaptive(light: 0x0A2F1D, dark: 0xC0D8C7)
    static let actionInk = adaptive(light: 0xFDFBF7, dark: 0x0A2F1D)
    // Increase Contrast darkens the two colors that only barely differ from the paper.
    static let quiet = adaptive(light: 0xECEFE8, dark: 0x25342B, contrastLight: 0xD3DAD0, contrastDark: 0x3B4D41)
    static let line = adaptive(light: 0xDFE4DC, dark: 0x3A493F, contrastLight: 0x7E8B82, contrastDark: 0x8A9A90)
    static let outline = adaptive(light: 0xC5CEC6, dark: 0x506256, contrastLight: 0x7E8B82, contrastDark: 0x8A9A90)
    static let danger = Color(nsColor: .systemRed)

    enum Weight: String {
        case regular = "Regular"
        case semibold = "SemiBold"
    }

    // Type scale: 28, 22, 14, and 12 only. The title bar draws titles in the system font.
    static let bodySize: CGFloat = 14
    static let display = font(28, .semibold, relativeTo: .largeTitle)
    static let screenTitle = font(22, .semibold, relativeTo: .title2)
    static let body = font(bodySize)
    static let bodyStrong = font(bodySize, .semibold)
    static let meta = font(12, relativeTo: .footnote)
    static let metaStrong = font(12, .semibold, relativeTo: .footnote)
    static let bodyLineSpacing: CGFloat = 3 // Puts 14-point Inter on 20-point lines.
    static let plusGlyph = Font.system(size: 20, weight: .semibold)

    static let avatarSize: CGFloat = 28
    static let avatarGap: CGFloat = 10
    static let avatarTopInset: CGFloat = 1
    static let rowPadding: CGFloat = 11
    static let headerHeight: CGFloat = 52
    /// The feed stops growing at this width and stays centered.
    static let columnMaxWidth: CGFloat = 620
    static let compactButtonHeight: CGFloat = 30
    static let regularButtonHeight: CGFloat = 40
    static let outlineButtonHeight: CGFloat = 32
    static let screenGutter: CGFloat = 32
    static let screenTop: CGFloat = 24
    static let screenBottom: CGFloat = 28

    // Grid: content runs from the gutter to the mirrored right gutter. Text in lists starts at textColumn.
    static let gutter: CGFloat = 16
    static let textColumn = gutter + avatarSize + avatarGap

    // A symbol next to text takes that text's font. These are the exceptions: the glyphs that stand
    // alone as a control, and body-size marks in a fixed frame.
    static let markGlyph = Font.system(size: bodySize, weight: .semibold)

    private static func font(_ size: CGFloat, _ weight: Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom("Inter-\(weight.rawValue)", size: size, relativeTo: textStyle)
    }

    private static func adaptive(light: UInt32, dark: UInt32, contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .accessibilityHighContrastAqua: rgb(contrastLight ?? light)
            case .accessibilityHighContrastDarkAqua: rgb(contrastDark ?? dark)
            case .darkAqua: rgb(dark)
            default: rgb(light)
            }
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// A one-pixel rule at any display scale.
struct FatlineDivider: View {
    @Environment(\.displayScale) private var displayScale
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(FatlineStyle.line)
            .frame(height: 1 / displayScale)
            .padding(.horizontal, inset)
    }
}

extension View {
    /// For a step whose title is in the content, so the bar only holds the back button.
    func fatlineStepBar() -> some View {
        navigationTitle("")
            .toolbarBackground(FatlineStyle.paper, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }

    /// Keeps a step's main button in the same place from screen to screen.
    func fatlineBottomAction<Action: View>(
        gutter: CGFloat = FatlineStyle.screenGutter, @ViewBuilder _ action: () -> Action
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            action()
                .padding(.horizontal, gutter)
                .padding(.top, 12)
                .padding(.bottom, FatlineStyle.screenBottom)
                .frame(maxWidth: FatlineStyle.columnMaxWidth)
                .frame(maxWidth: .infinity)
                .background(FatlineStyle.paper)
        }
    }
}

extension Text {
    func fatlineScreenTitle() -> some View {
        font(FatlineStyle.screenTitle)
            .tracking(-0.4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The short title and single instruction at the top of every step after the splash.
struct FatlineStepHeader: View {
    let title: String
    let instruction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fatlineScreenTitle()
            Text(instruction)
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A secondary action beside a field. It has an outline because the field and a turned-off primary
/// button are already filled with `quiet`.
struct FatlineOutlineButton: ButtonStyle {
    @ScaledMetric(relativeTo: .footnote) private var height = FatlineStyle.outlineButtonHeight

    var fills = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FatlineStyle.metaStrong)
            .foregroundStyle(FatlineStyle.ink)
            .lineLimit(1)
            .padding(.horizontal, fills ? 8 : 14)
            .frame(maxWidth: fills ? .infinity : nil, minHeight: height)
            .overlay { Capsule().strokeBorder(FatlineStyle.outline, lineWidth: 1) }
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct FatlinePrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .subheadline) private var compactHeight = FatlineStyle.compactButtonHeight
    @ScaledMetric(relativeTo: .subheadline) private var regularHeight = FatlineStyle.regularButtonHeight

    let compact: Bool
    let minWidth: CGFloat
    let isWorking: Bool

    init(compact: Bool = false, minWidth: CGFloat = 80, isWorking: Bool = false) {
        self.compact = compact
        self.minWidth = minWidth
        self.isWorking = isWorking
    }

    func makeBody(configuration: Configuration) -> some View {
        let filled = enabled || isWorking
        return configuration.label
            .font(FatlineStyle.bodyStrong)
            .foregroundStyle(filled ? FatlineStyle.actionInk : FatlineStyle.secondary)
            .padding(.horizontal, compact ? 16 : 23)
            .frame(minWidth: minWidth, minHeight: compact ? compactHeight : regularHeight)
            .background(filled ? FatlineStyle.action : FatlineStyle.quiet, in: .capsule)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(.rect)
    }
}
