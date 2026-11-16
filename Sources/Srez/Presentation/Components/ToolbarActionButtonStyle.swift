import SwiftUI

struct ToolbarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(width: 20, height: 16)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary
                            .opacity(isEnabled && (isHovered || configuration.isPressed) ?
                                0.1 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
        }
    }
}
