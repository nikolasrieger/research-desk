import SwiftUI
import PDFKit
import WebKit

enum BoundedDownload {
    static func data(from url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("ResearchDesk/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ResearchError.message("The server could not provide this document. Try again or open it in your browser.")
        }
        guard response.expectedContentLength <= limit else { throw ResearchError.message("This document exceeds the preview size limit.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ResearchError.message("This document exceeds the preview size limit.") }
            data.append(byte)
        }
        return data
    }
}

struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(white: 0.105, alpha: 1)
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

struct RemotePDFPane: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var error = ""
    @State private var attempt = 0
    var body: some View {
        Group {
            if let document { PDFDocumentView(document: document) }
            else if !error.isEmpty {
                VStack(spacing: 12) {
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    HStack {
                        Button("Retry") { attempt += 1 }
                        Button("Open PDF in browser") { NSWorkspace.shared.open(url) }
                    }
                }.padding(24)
            } else { ProgressView("Loading paper…") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: attempt) {
                error = ""
                do {
                    let data = try await BoundedDownload.data(from: url, limit: 50_000_000)
                    try Task.checkCancellation()
                    guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw ResearchError.message("The server did not return a readable PDF.") }
                    document = pdf
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
    }
}

enum ConsolePaste {
    // Plain shells must not receive a newline or terminal control sequence.
    // Agent consoles with bracketed paste can retain paragraphs safely.
    static func text(_ text: String, multiline: Bool) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            if multiline && scalar.value == 10 { return "\n" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(String(scalar))
        })
    }
}

struct ConsolePasteMenu: View {
    let text: String
    let project: Project
    @ObservedObject var model: DeskModel
    let showAgent: () -> Void
    let showTerminal: () -> Void
    private var agent: AgentSession? { project.id == model.paperProject.id ? model.paperAgent : model.sessions[project.id] }
    var body: some View {
        Menu {
            Button("Paste into agent console") {
                if let agent { paste(agent); showAgent() }
            }.disabled(agent == nil || agent?.ended == true || agent?.started != true)
            Button("Paste into terminal") {
                if let terminal = model.terminals[project.id] { paste(terminal); showTerminal() }
            }.disabled(model.terminals[project.id] == nil || model.terminals[project.id]?.ended == true || model.terminals[project.id]?.started != true)
        } label: { DeskMenuLabel(title: "Paste into", symbol: "text.insert") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Insert into a running console without submitting. Shell pastes use one line.")
    }
    private func paste(_ session: AgentSession) {
        guard session.started, !session.ended else { return }
        let multiline = session.agent != "terminal" && session.terminal.getTerminal().bracketedPasteMode
        session.terminal.pasteText(ConsolePaste.text(text, multiline: multiline))
    }
}

/// Hosted artifacts have an ordinary web session, without a native message bridge.
struct HostedArtifactWebView: NSViewRepresentable {
    let url: URL
    let reload: Int
    @Binding var error: String
    func makeCoordinator() -> Coordinator { Coordinator(error: $error) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url || context.coordinator.reload != reload {
            context.coordinator.loadedURL = url; context.coordinator.reload = reload
            view.load(URLRequest(url: url))
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading() }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedURL: URL?
        var reload = -1
        var error: Binding<String>
        init(error: Binding<String>) { self.error = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { error.wrappedValue = "" }
        private func failed(_ failure: Error) {
            guard (failure as NSError).code != NSURLErrorCancelled else { return }
            error.wrappedValue = failure.localizedDescription
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, ["https", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
            // Authentication redirects remain in the web view; no credentials are read by the app.
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
