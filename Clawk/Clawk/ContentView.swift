import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MessageStore
    
    var body: some View {
        NavigationView {
            List {
                ForEach(store.messages) { message in
                    MessageCard(message: message) {
                        store.respond(to: message, with: $0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
            .navigationTitle("Clawk")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionStatus(isConnected: store.isConnected)
                }
            }
            .overlay {
                if store.messages.isEmpty {
                    EmptyState()
                }
            }
        }
    }
}

struct MessageCard: View {
    let message: ClawkMessage
    let onAction: (String) -> Void
    @State private var hasResponded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.message)
                .font(.body)
            
            if !message.responded && !hasResponded {
                FlowLayout(spacing: 8) {
                    ForEach(Array(message.actions.enumerated()), id: \.offset) { index, action in
                        ActionButton(
                            action: action,
                            isEnabled: !hasResponded,
                            onTap: { selectedAction in
                                hasResponded = true
                                onAction(selectedAction)
                            }
                        )
                    }
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Responded: \(message.response ?? "")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct ConnectionStatus: View {
    let isConnected: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Live" : "Offline")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct ActionButton: View {
    let action: String
    let isEnabled: Bool
    let onTap: (String) -> Void
    
    var body: some View {
        Button(action: { 
            if isEnabled {
                onTap(action)
            }
        }) {
            Text(action)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isEnabled ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .disabled(!isEnabled)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No messages yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Messages from OpenClaw will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// Simple flow layout for buttons
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
