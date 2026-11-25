import SwiftUI

enum LiquidBackdropStyle {
    case shower
    case laundry
    case neutral
}

struct LiquidBackdrop: View {
    let style: LiquidBackdropStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.55, 0.45], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: palette
        )
        .ignoresSafeArea()
    }

    private var palette: [Color] {
        let isDark = colorScheme == .dark
        switch style {
        case .shower:
            if isDark {
                return [
                    Color(red: 0.03, green: 0.11, blue: 0.18),
                    Color(red: 0.05, green: 0.19, blue: 0.28),
                    Color(red: 0.04, green: 0.10, blue: 0.20),
                    Color(red: 0.04, green: 0.16, blue: 0.24),
                    Color(red: 0.07, green: 0.28, blue: 0.38),
                    Color(red: 0.05, green: 0.14, blue: 0.25),
                    Color(red: 0.02, green: 0.06, blue: 0.11),
                    Color(red: 0.04, green: 0.10, blue: 0.17),
                    Color(red: 0.02, green: 0.06, blue: 0.12)
                ]
            } else {
                return [
                    Color(red: 0.84, green: 0.94, blue: 0.99),
                    Color(red: 0.76, green: 0.92, blue: 0.98),
                    Color(red: 0.89, green: 0.95, blue: 1.00),
                    Color(red: 0.88, green: 0.96, blue: 0.99),
                    Color(red: 0.72, green: 0.89, blue: 0.98),
                    Color(red: 0.85, green: 0.93, blue: 0.99),
                    Color(red: 0.95, green: 0.97, blue: 0.99),
                    Color(red: 0.92, green: 0.96, blue: 0.99),
                    Color(red: 0.96, green: 0.98, blue: 1.00)
                ]
            }
        case .laundry:
            if isDark {
                return [
                    Color(red: 0.08, green: 0.08, blue: 0.20),
                    Color(red: 0.13, green: 0.12, blue: 0.30),
                    Color(red: 0.07, green: 0.10, blue: 0.22),
                    Color(red: 0.10, green: 0.10, blue: 0.24),
                    Color(red: 0.18, green: 0.16, blue: 0.38),
                    Color(red: 0.09, green: 0.14, blue: 0.28),
                    Color(red: 0.04, green: 0.05, blue: 0.12),
                    Color(red: 0.07, green: 0.07, blue: 0.16),
                    Color(red: 0.04, green: 0.06, blue: 0.13)
                ]
            } else {
                return [
                    Color(red: 0.88, green: 0.90, blue: 1.00),
                    Color(red: 0.83, green: 0.87, blue: 0.99),
                    Color(red: 0.92, green: 0.91, blue: 1.00),
                    Color(red: 0.91, green: 0.93, blue: 1.00),
                    Color(red: 0.80, green: 0.85, blue: 0.99),
                    Color(red: 0.88, green: 0.92, blue: 1.00),
                    Color(red: 0.96, green: 0.96, blue: 0.99),
                    Color(red: 0.94, green: 0.95, blue: 0.99),
                    Color(red: 0.97, green: 0.97, blue: 1.00)
                ]
            }
        case .neutral:
            if isDark {
                return Array(repeating: Color(red: 0.07, green: 0.08, blue: 0.11), count: 9)
            } else {
                return Array(repeating: Color(red: 0.95, green: 0.96, blue: 0.98), count: 9)
            }
        }
    }
}
