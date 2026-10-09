import DroppyKit
import SwiftUI

struct TranslateCircleStyle: ButtonStyle {
    var diameter: CGFloat
    var accent: Color? = nil
    var usesAdaptiveForegrounds = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .foregroundStyle(accent == nil ? AdaptiveColors.notchSurfacePrimaryText : Color.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(accent ?? Color.white.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct TranslatePillStyle: ButtonStyle {
    var height: CGFloat
    var usesAdaptiveForegrounds = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.horizontal, DroppySpacing.md)
            .frame(height: height)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
