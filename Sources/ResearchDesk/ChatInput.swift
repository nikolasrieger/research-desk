import SwiftUI
import AppKit

final class ChatInputTextView: NSTextView {
    var submit: () -> Void = {}
    var canSubmit = false
    var focusChanged: (Bool) -> Void = { _ in }

    static func submits(_ event: NSEvent, composing: Bool) -> Bool {
        guard !composing, event.keyCode == 36 || event.keyCode == 76 else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        return modifiers.isEmpty || modifiers == .command
    }
    override func keyDown(with event: NSEvent) {
        if Self.submits(event, composing: hasMarkedText()) {
            if canSubmit { submit() }
            return
        }
        if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift {
            insertNewline(nil)
            return
        }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged(false) }
        return accepted
    }
}

struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let canSubmit: Bool
    let label: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let input = ChatInputTextView()
        input.isRichText = false
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.drawsBackground = false
        input.font = .systemFont(ofSize: 12)
        input.textColor = .textColor
        input.textContainerInset = NSSize(width: 4, height: 4)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        input.delegate = context.coordinator
        input.focusChanged = { [weak coordinator = context.coordinator] focused in
            // Avoid changing SwiftUI state during an AppKit view update.
            DispatchQueue.main.async { coordinator?.parent.focused = focused }
        }
        scroll.documentView = input
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? ChatInputTextView else { return }
        input.canSubmit = canSubmit
        input.submit = submit
        input.setAccessibilityLabel(label)
        if input.string != text {
            input.string = text
            input.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if focused, let window = input.window, window.firstResponder !== input { window.makeFirstResponder(input) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        init(_ parent: ChatInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
