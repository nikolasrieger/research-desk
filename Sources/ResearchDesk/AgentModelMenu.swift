import AppKit
import SwiftUI

/// Build one native menu per click. SwiftUI updates must not replace a submenu
/// while AppKit is tracking the pointer between the parent and provider menu.
struct AgentModelMenu: NSViewRepresentable {
    let title: String
    let options: [BriefModelOption]
    let selectedModel: String
    let provider: String
    let enabled: Bool
    let canSwitch: Bool
    let loadingModels: Bool
    let modelError: String
    let chooseModel: (String) -> Void
    let refreshModels: () -> Void
    let switchProvider: (String) -> Void
    let customModel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        button.imagePosition = .imageTrailing
        button.contentTintColor = NSColor(DeskStyle.accent)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = NSColor(DeskStyle.edge).cgColor
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = title
        button.isEnabled = enabled
        button.setAccessibilityLabel("Model and provider: " + title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: max(70, nsView.intrinsicContentSize.width + 20), height: 30)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: AgentModelMenu
        private var trackingMenu: NSMenu?
        private enum Action { case model(String), refresh, provider(String), custom }
        init(_ parent: AgentModelMenu) { self.parent = parent }

        @objc func openMenu(_ sender: NSButton) {
            guard parent.enabled, trackingMenu == nil else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            @discardableResult
            func add(_ title: String, action: Action, to target: NSMenu, enabled: Bool = true) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: #selector(selectItem(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = action; item.isEnabled = enabled
                target.addItem(item)
                return item
            }
            for option in parent.options {
                let item = add(option.name, action: .model(option.id), to: menu)
                item.state = option.id == parent.selectedModel ? .on : .off
            }
            menu.addItem(.separator())
            if parent.provider == "codex" {
                if !parent.modelError.isEmpty {
                    let error = NSMenuItem(title: "Could not load models: " + parent.modelError, action: nil, keyEquivalent: "")
                    error.isEnabled = false; menu.addItem(error)
                }
                add(parent.loadingModels ? "Loading models…" : "Refresh models", action: .refresh, to: menu, enabled: !parent.loadingModels)
            }
            let providers = NSMenu(title: "Switch Provider")
            providers.autoenablesItems = false
            for provider in ["claude", "codex", "gemini"] where provider != parent.provider {
                add(GeminiACP.agentLabel(provider), action: .provider(provider), to: providers, enabled: parent.canSwitch)
            }
            let switchItem = NSMenuItem(title: "Switch Provider", action: nil, keyEquivalent: "")
            switchItem.submenu = providers; switchItem.isEnabled = parent.canSwitch
            menu.addItem(switchItem)
            add("Custom model…", action: .custom, to: menu)
            trackingMenu = menu
            defer { trackingMenu = nil }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        }
        @objc private func selectItem(_ item: NSMenuItem) {
            guard parent.enabled, let action = item.representedObject as? Action else { return }
            switch action {
            case .model(let model): parent.chooseModel(model)
            case .refresh: parent.refreshModels()
            case .provider(let provider): if parent.canSwitch { parent.switchProvider(provider) }
            case .custom: parent.customModel()
            }
        }
    }
}
