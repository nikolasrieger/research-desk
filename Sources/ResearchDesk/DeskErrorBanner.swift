import SwiftUI

struct DeskErrorText {
    let details: String
    let summary: String
    let hasDetails: Bool
    init(_ message: String) {
        let clean = message
            .replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        details = clean
        let lines = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let technical = clean.contains("Traceback (most recent call last)") || clean.hasPrefix("{") || clean.hasPrefix("<")
        let candidate: String
        if clean.contains("Traceback (most recent call last)") {
            candidate = lines.last(where: { $0.range(of: #"^[A-Za-z.]+(?:Error|Exception):"#, options: .regularExpression) != nil }) ?? "The operation could not be completed. Open details for the full error."
        } else if technical { candidate = "The operation could not be completed. Open details for the full error." }
        else { candidate = lines.first ?? "The operation could not be completed." }
        hasDetails = technical || clean.count > 240 || lines.count > 1
        summary = hasDetails ? String(candidate.prefix(240)) + (candidate.count > 240 ? "…" : "") : clean
    }
}

/// Consistent presentation for user-facing errors; technical output stays available on demand.
struct DeskErrorBanner: View {
    let message: String
    var title = "Something went wrong"
    var onDismiss: (() -> Void)? = nil
    @State private var expanded = false
    @State private var dismissed = false
    private var text: DeskErrorText { DeskErrorText(message) }
    var body: some View {
        Group {
            if !message.isEmpty && !dismissed {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .center, spacing: 9) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DeskStyle.accent)
                        Spacer(minLength: 4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text.details, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy error details").accessibilityLabel("Copy error details")
                        Button { dismissed = true; onDismiss?() } label: { Image(systemName: "xmark") }
                            .help("Dismiss error").accessibilityLabel("Dismiss error")
                    }.buttonStyle(DeskButtonStyle(compact: true))
                    Text(text.summary).font(.system(size: 12)).foregroundStyle(DeskStyle.accent)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if text.hasDetails {
                        DisclosureGroup("Details", isExpanded: $expanded) {
                            ScrollView([.vertical, .horizontal]) {
                                Text(text.details).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DeskStyle.accent).textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }.frame(height: 150)
                                .background(DeskStyle.background, in: RoundedRectangle(cornerRadius: 5))
                                .padding(.top, 7)
                        }.font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeskStyle.raised, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.25)))
            }
        }.onChange(of: message) { _, _ in expanded = false; dismissed = false }
    }
}
