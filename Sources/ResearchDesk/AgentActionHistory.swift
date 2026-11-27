import SwiftUI

/// A compact, newest-first activity timeline. Full tool output stays selectable on expansion.
struct AgentActionHistory: View {
    let actions: [String]
    @Binding var expanded: Bool
    private var visible: [Int] { Array(actions.indices.reversed().prefix(expanded ? actions.count : 5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PAST ACTIONS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.4)
                Text("\(actions.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(DeskStyle.raised, in: Capsule())
                Spacer()
            }.foregroundStyle(DeskStyle.accent)
            LazyVStack(spacing: 0) {
                ForEach(visible, id: \.self) { index in
                    AgentActionRow(text: actions[index], number: index + 1, latest: index == actions.count - 1)
                }
            }
            if actions.count > 5 {
                Button {
                    expanded.toggle()
                } label: {
                    HStack {
                        Text(expanded ? "Show recent actions" : "Show all \(actions.count) actions")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.system(size: 11, weight: .medium)).padding(10)
                }.buttonStyle(.plain)
                    .background(DeskStyle.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(12)
            .background(DeskStyle.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DeskStyle.edge, lineWidth: 0.5) }
    }
}

private struct AgentActionRow: View {
    let text: String
    let number: Int
    let latest: Bool
    @State private var expanded = false
    private var title: String { text.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? text }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Image(systemName: "terminal").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(latest ? DeskStyle.highlight : DeskStyle.muted)
                    .frame(width: 20, height: 20)
                    .background((latest ? DeskStyle.highlight : DeskStyle.muted).opacity(0.12), in: Circle())
                Rectangle().fill(DeskStyle.edge).frame(width: 1).frame(minHeight: 14)
            }.frame(width: 20)
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ACTION \(number)").font(.system(size: 8, weight: .medium, design: .monospaced))
                                .tracking(1).foregroundStyle(DeskStyle.muted)
                            Text(title).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DeskStyle.accent).lineLimit(expanded ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(DeskStyle.muted).padding(.top, 4)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Action \(number): \(title)")
                if expanded {
                    Text(text).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DeskStyle.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(.bottom, 16)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
