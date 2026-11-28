import AppKit
import SwiftUI

/// Own the mouse sequence in AppKit; SwiftUI tap/list gestures cannot consume the drag.
struct ProjectRowDrag: NSViewRepresentable {
    let id: UUID
    let title: String
    let accepts: (UUID) -> Bool
    let select: () -> Void
    let move: (UUID, Bool) -> Void
    func makeNSView(context: Context) -> DragView { DragView(frame: .zero) }
    func updateNSView(_ view: DragView, context: Context) {
        view.projectID = id; view.title = title
        view.accepts = accepts; view.select = select; view.move = move
    }
    @MainActor final class DragView: NSView, NSDraggingSource {
        static let pasteboardType = NSPasteboard.PasteboardType("com.nrieger.researchdesk.project-order")
        var projectID = UUID()
        var title = ""
        var accepts: (UUID) -> Bool = { _ in false }
        var select: () -> Void = {}
        var move: (UUID, Bool) -> Void = { _, _ in }
        private var dropAfter: Bool?
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([Self.pasteboardType])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Let the SwiftUI row retain its context menu and hover behavior.
            if let type = NSApp.currentEvent?.type,
               [.rightMouseDown, .rightMouseUp, .mouseMoved, .mouseEntered, .mouseExited].contains(type) { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let deadline = Date().addingTimeInterval(0.25)
            while true {
                guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: deadline, inMode: .eventTracking, dequeue: true) else {
                    startDrag(with: event)
                    return
                }
                if next.type == .leftMouseUp { select(); return }
                let delta = next.locationInWindow - event.locationInWindow
                if hypot(delta.x, delta.y) >= 4 { startDrag(with: next); return }
            }
        }
        private func startDrag(with event: NSEvent) {
            let item = NSPasteboardItem()
            item.setString(projectID.uuidString, forType: Self.pasteboardType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let size = NSSize(width: max(120, bounds.width), height: bounds.height)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(DeskStyle.raised).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
                (self.title as NSString).draw(in: rect.insetBy(dx: 12, dy: 10), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(DeskStyle.accent)])
                return true
            }
            dragging.setDraggingFrame(NSRect(origin: .zero, size: size), contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        private func source(_ sender: NSDraggingInfo) -> UUID? {
            guard sender.draggingSource is DragView,
                  let text = sender.draggingPasteboard.string(forType: Self.pasteboardType),
                  let id = UUID(uuidString: text), id != projectID, accepts(id) else { return nil }
            return id
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard source(sender) != nil else { dropAfter = nil; needsDisplay = true; return [] }
            dropAfter = convert(sender.draggingLocation, from: nil).y < bounds.midY
            needsDisplay = true
            if let event = NSApp.currentEvent { _ = autoscroll(with: event) }
            return .move
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { dropAfter = nil; needsDisplay = true }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { dropAfter = nil; needsDisplay = true }
            guard let id = source(sender) else { return false }
            move(id, convert(sender.draggingLocation, from: nil).y < bounds.midY)
            return true
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let after = dropAfter else { return }
            NSColor(DeskStyle.highlight).setFill()
            NSRect(x: 4, y: after ? 0 : bounds.height - 2, width: max(0, bounds.width - 8), height: 2).fill()
        }
    }
}

private extension NSPoint {
    static func - (lhs: Self, rhs: Self) -> Self { NSPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}
