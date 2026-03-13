import SwiftUI

// MARK: - Design Tokens (Neo-Brutalism — OpenCAN flavor)

enum Brutal {
    // Colors — OpenCAN palette (lime-primary, mint-accent)
    static let lime      = Color(hex: 0xA6FF00)  // Primary / brand
    static let mint      = Color(hex: 0x00E5A0)  // CTA / accent buttons
    static let cyan      = Color(hex: 0x00CFFF)  // Agent avatars / info
    static let lavender  = Color(hex: 0xC4B5FD)  // User avatars
    static let orange    = Color(hex: 0xFF9F43)  // Warning / jump server
    static let pink      = Color(hex: 0xFF6B9D)  // Error / destructive
    static let cream     = Color(hex: 0xFAFAE0)  // Page background
    static let mintLight = Color(hex: 0xBFF8E7)  // User bubble (25% mint on white, opaque)

    // Opaque tint colors for cards (pre-mixed on white to avoid shadow bleed)
    static let limeTint    = Color(hex: 0xF0FFD9)  // ~15% lime on white
    static let cyanTint    = Color(hex: 0xD9F5FF)  // ~15% cyan on white
    static let orangeTint  = Color(hex: 0xFFF0D9)  // ~15% orange on white

    // Shadows — offset only, no blur
    static let shadowSm: CGFloat   = 2   // Small inputs, chips
    static let shadow: CGFloat     = 4   // Standard cards, buttons
    static let shadowLg: CGFloat   = 6   // Hero cards
    static let shadowActive: CGFloat = 1 // Pressed state

    // Borders
    static let border: CGFloat     = 2   // Standard
    static let borderThick: CGFloat = 3  // Emphasis cards

    // Fonts — display (.rounded) and mono (.monospaced)
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - UIKit Colors (for UIKit-based message rows)

enum BrutalUIKit {
    static let lime      = UIColor(red: 0xA6/255.0, green: 0xFF/255.0, blue: 0x00/255.0, alpha: 1)
    static let mint      = UIColor(red: 0x00/255.0, green: 0xE5/255.0, blue: 0xA0/255.0, alpha: 1)
    static let cyan      = UIColor(red: 0x00/255.0, green: 0xCF/255.0, blue: 0xFF/255.0, alpha: 1)
    static let cream     = UIColor(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xE0/255.0, alpha: 1)
    static let orange    = UIColor(red: 0xFF/255.0, green: 0x9F/255.0, blue: 0x43/255.0, alpha: 1)
    static let pink      = UIColor(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x9D/255.0, alpha: 1)
    static let mintLight = UIColor(red: 0xBF/255.0, green: 0xF8/255.0, blue: 0xE7/255.0, alpha: 1)
    // Opaque tints (20% color on white) for tool call status backgrounds
    static let mintTint  = UIColor(red: 0xCC/255.0, green: 0xFA/255.0, blue: 0xEC/255.0, alpha: 1)
    static let pinkTint  = UIColor(red: 0xFF/255.0, green: 0xE1/255.0, blue: 0xEB/255.0, alpha: 1)
    static let cyanTint  = UIColor(red: 0xCC/255.0, green: 0xF5/255.0, blue: 0xFF/255.0, alpha: 1)
    static let borderColor = UIColor.black
    static let borderWidth: CGFloat = 2
    static let shadow: CGFloat = 4
    static let shadowSm: CGFloat = 2
}

// MARK: - Color hex init

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Shadow Plate (offset shadow via background layer)

struct BrutalShadowPlate: ViewModifier {
    let fill: Color
    let offset: CGFloat
    let borderWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Rectangle().fill(Color.black).offset(x: offset, y: offset)
                    Rectangle().fill(fill)
                }
            )
            .overlay(Rectangle().stroke(Color.black, lineWidth: borderWidth))
    }
}

extension View {
    func brutalCard(fill: Color = .white, shadow: CGFloat = Brutal.shadow, border: CGFloat = Brutal.border) -> some View {
        modifier(BrutalShadowPlate(fill: fill, offset: shadow, borderWidth: border))
    }
}

// MARK: - Button Style

struct BrutalButtonStyle: ButtonStyle {
    let fill: Color
    let compact: Bool

    init(fill: Color = Brutal.mint, compact: Bool = false) {
        self.fill = fill
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let restShadow: CGFloat = compact ? Brutal.shadowSm : Brutal.shadow
        let currentShadow: CGFloat = pressed ? Brutal.shadowActive : restShadow

        configuration.label
            .font(Brutal.display(compact ? 14 : 16, weight: .bold))
            .foregroundStyle(.black)
            .padding(.vertical, compact ? 6 : 10)
            .padding(.horizontal, compact ? 10 : 16)
            .background(
                ZStack {
                    Rectangle().fill(Color.black).offset(x: currentShadow, y: currentShadow)
                    Rectangle().fill(fill)
                }
            )
            .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))
            .offset(
                x: pressed ? (restShadow - Brutal.shadowActive) : 0,
                y: pressed ? (restShadow - Brutal.shadowActive) : 0
            )
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

// MARK: - Text Field Style

struct BrutalTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .font(Brutal.display(16))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    Rectangle().fill(Color.black).offset(x: Brutal.shadowSm, y: Brutal.shadowSm)
                    Rectangle().fill(.white)
                }
            )
            .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))
    }
}

// MARK: - Chip (badges, status tags)

struct BrutalChip: View {
    let text: String
    let fill: Color
    let fontSize: CGFloat

    init(_ text: String, fill: Color, fontSize: CGFloat = 11) {
        self.text = text
        self.fill = fill
        self.fontSize = fontSize
    }

    var body: some View {
        Text(text)
            .font(Brutal.mono(fontSize, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill)
            .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))
    }
}
