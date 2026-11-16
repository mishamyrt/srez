import SwiftUI

struct JobActionButtonStyle: ButtonStyle {
    let hint: String
    @Binding var hoveredHint: String?

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, hint: hint, hoveredHint: $hoveredHint)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let hint: String
        @Binding var hoveredHint: String?
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered || configuration
                    .isPressed ? .secondary : .tertiary)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        hoveredHint = hint
                    } else if hoveredHint == hint {
                        hoveredHint = nil
                    }
                }
                .onChange(of: hint) { oldHint, newHint in
                    if isHovered, hoveredHint == oldHint {
                        hoveredHint = newHint
                    }
                }
                .onDisappear {
                    if hoveredHint == hint {
                        hoveredHint = nil
                    }
                }
        }
    }
}
