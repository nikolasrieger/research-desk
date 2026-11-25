import SwiftUI
import PDFKit

enum AgentFileLink {
    static func path(_ url: URL, project: Project) -> String? {
        let raw: String
        if url.scheme == "research-file" {
            guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
            raw = value
        } else if url.isFileURL { raw = url.path }
        else if url.scheme == "sandbox" { raw = url.path }
        else if url.scheme == "vscode", url.host == "file" { raw = url.path }
        else if url.scheme == "ssh", url.host == project.host || url.host == project.host.split(separator: "@").last.map(String.init) { raw = url.path }
        else if url.scheme == nil { raw = url.path }
        else { return nil }
        let cleaned = raw.replacingOccurrences(of: #":\d+(?::\d+)?(?:-\d+(?::\d+)?)?$"#, with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasPrefix("~/") {
            if project.isRemote { return cleaned }
            return (cleaned as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: cleaned.hasPrefix("/") ? cleaned : project.path + "/" + cleaned).standardizedFileURL.path
    }
    /// Explicitly clicked paths may live outside the workspace (e.g. Downloads).
    /// Narrow the preview scope to that file's parent without changing the workspace.
    static func previewProject(path: String, project: Project) -> Project {
        guard !FileBrowserIO.containsPath(path, in: project.path) || path.hasPrefix("~/") else { return project }
        var scoped = project
        if path.hasPrefix("~/"), project.isRemote { scoped.path = "~" }
        else { scoped.path = URL(fileURLWithPath: path).deletingLastPathComponent().path }
        return scoped
    }

    static func relativeLink(_ url: URL, document: String, project: Project) -> URL {
        var base = project
        base.path = URL(fileURLWithPath: document).deletingLastPathComponent().path
        guard let path = path(url, project: base), var components = URLComponents(string: "research-file://open") else { return url }
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url ?? url
    }

    static func linkCodePaths(_ source: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<![\[`])`([^`\n]+)`(?![\]`])"#)
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result), let content = Range(match.range(at: 1), in: source) else { continue }
            let path = String(source[content])
            guard (!path.contains(" ") || path.hasPrefix("/") || path.hasPrefix("~/")), path.range(of: #"(?:^|/)[^/\n]+\.[A-Za-z0-9]{1,10}(?::\d+(?::\d+)?)?$"#, options: .regularExpression) != nil else { continue }
            var url = URLComponents(); url.scheme = "research-file"; url.host = "open"; url.queryItems = [URLQueryItem(name: "path", value: path)]
            if let link = url.url { result.replaceSubrange(range, with: "[`" + path + "`](" + link.absoluteString + ")") }
        }
        let links = try! NSRegularExpression(pattern: #"\]\((<[^>]+>|(?:[^()\s]|\([^()]*\))+)(?:\s+"[^"]*")?\)"#)
        for match in links.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let raw = String(result[range]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let destination = URL(string: raw), destination.scheme == nil || ["file", "sandbox", "vscode"].contains(destination.scheme ?? "") else { continue }
            let value = destination.path
            var link = URLComponents(); link.scheme = "research-file"; link.host = "open"; link.queryItems = [URLQueryItem(name: "path", value: value)]
            if let url = link.url { result.replaceSubrange(range, with: url.absoluteString) }
        }
        return result
    }
}

enum AgentFileResolver {
    // Metadata only: use the same resolver on the Mac and on the conversation's SSH host.
    static let script = #"""
    import os,sys,json
    root=os.path.abspath(os.path.expanduser(sys.argv[1]))
    path=os.path.abspath(os.path.expanduser(sys.argv[2]))
    if os.path.isfile(path):
        print(json.dumps([path])); sys.exit(0)
    if os.path.isdir(path):
        sys.exit('This link points to a folder, not a file: '+path)
    if os.path.commonpath([root,path]) != root:
        sys.exit('File not found: '+path)
    compact=[root]
    matches=set()
    suffix=set()
    relative=os.path.relpath(path,root)
    count=0
    for base in compact:
        for directory,folders,files in os.walk(base):
            folders[:]=sorted(folders)
            count+=1
            if count>40000:
                sys.exit('Search limit reached. Open the file from Files using its full path.')
            if os.path.basename(path) in files:
                candidate=os.path.join(directory,os.path.basename(path))
                matches.add(candidate)
                if candidate.endswith('/'+relative): suffix.add(candidate)
    print(json.dumps(sorted(suffix or matches)))
    """#
    static func candidates(path: String, project: Project) throws -> [String] {
        let output: String, failure: String, status: Int32
        if project.isRemote {
            (output, failure, status) = Command.ssh(project.host, "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(project.path) + " " + Command.shellQuote(path), maxOutput: 1_000_000, timeout: 30)
        } else {
            (output, failure, status) = Command.run("/usr/bin/python3", ["-c", script, project.path, path], timeout: 30, maxOutput: 1_000_000)
        }
        guard status == 0 else { throw ResearchError.message(failure.isEmpty ? "Could not locate file: " + path : failure) }
        guard let data = output.data(using: .utf8), let candidates = try? JSONDecoder().decode([String].self, from: data) else {
            throw ResearchError.message("Could not read file search results for " + path)
        }
        guard !candidates.isEmpty else { throw ResearchError.message("File not found: " + path) }
        return candidates
    }
}

struct AgentFilePreview: View {
    let project: Project
    let path: String
    let openLink: (URL) -> OpenURLAction.Result
    var sessionID = ""
    var agent = "claude"
    @State private var candidates: [String] = []
    @State private var selectedPath: String?
    @State private var error = ""
    @State private var loading = true
    @State private var revision = 0
    @State private var location = ""
    @State private var overridePath: String?
    @State private var showRemotePicker = false
    private var mappingKey: String { "fileLinkSelection." + project.host + "\n" + project.path + "\n" + sessionID + "\n" + path }
    private var defaults: UserDefaults { UserDefaults(suiteName: WorkspaceStorage.domain) ?? .standard }
    private var requestedPath: String { overridePath ?? path }
    private func choose(_ path: String) {
        overridePath = path; location = path
        defaults.set(path, forKey: mappingKey)
        revision += 1
    }
    private func openLocation() {
        var url = URLComponents(string: "research-file://open")!
        url.queryItems = [URLQueryItem(name: "path", value: location)]
        if let url = url.url, let path = AgentFileLink.path(url, project: project) { choose(path) }
    }
    private func browse() {
        if project.isRemote { showRemotePicker = true; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url { choose(url.path) }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("File path", text: $location).textFieldStyle(DeskFieldStyle()).onSubmit(openLocation)
                Button("Open", action: openLocation).buttonStyle(DeskButtonStyle(compact: true))
                Button("Browse…", action: browse).buttonStyle(DeskButtonStyle(compact: true))
            }
            Group {
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !error.isEmpty {
                VStack {
                    DeskErrorBanner(message: error, title: "Could not open file")
                    Button("Retry") { revision += 1 }.buttonStyle(DeskButtonStyle())
                    Spacer()
                }
            } else if let selectedPath {
                VStack(spacing: 8) {
                    if candidates.count > 1 {
                        HStack { Button("Matching files") { self.selectedPath = nil }.buttonStyle(DeskButtonStyle(compact: true)); Spacer() }
                    }
                    AgentFilePreviewContent(project: project, path: selectedPath, openLink: openLink).id(selectedPath)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a file").font(.system(size: 13, weight: .medium))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(candidates, id: \.self) { candidate in
                                Button { choose(candidate) } label: {
                                    Text(candidate.hasPrefix(project.path + "/") ? String(candidate.dropFirst(project.path.count + 1)) : candidate)
                                        .font(.system(size: 11, design: .monospaced)).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                }.buttonStyle(DeskSidebarRowStyle(selected: false))
                            }
                        }
                    }
                }
            }
        }
            }
        .sheet(isPresented: $showRemotePicker) {
            LinkedRemoteFilePicker(project: project) { choose($0); showRemotePicker = false }
        }
        .task(id: path + String(revision)) {
            if overridePath == nil { overridePath = defaults.string(forKey: mappingKey) }
            let requested = requestedPath
            if location.isEmpty { location = requested }
            loading = true; error = ""; selectedPath = nil; candidates = []
            let result = await Task.detached { Result { try AgentFileResolver.candidates(path: requested, project: project) } }.value
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let matches):
                candidates = matches
                let exact = project.isRemote ? requested : (requested as NSString).expandingTildeInPath
                if matches.count == 1 && matches[0] == exact { selectedPath = matches[0] }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

struct AgentFilePreviewContent: View {
    let project: Project
    let path: String
    let openLink: (URL) -> OpenURLAction.Result
    @State private var content: PreviewContent?
    @State private var html: ArtifactHTMLFile?
    @State private var pdf: PDFDocument?
    @State private var error = ""
    @State private var webError = ""
    @State private var loading = true
    @State private var revision = 0
    private var previewProject: Project { AgentFileLink.previewProject(path: path, project: project) }
    private var ext: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).lineLimit(1).help(path)
                Spacer()
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(DeskButtonStyle(compact: true))
            }.padding(.bottom, 10)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !error.isEmpty { VStack { DeskErrorBanner(message: error, title: "Could not open file"); Spacer() } }
            else if ["html", "htm"].contains(ext) {
                HostedArtifactWebView(url: html?.url ?? URL(fileURLWithPath: path), reload: revision, error: $webError,
                    readAccessRoot: html?.root ?? URL(fileURLWithPath: previewProject.path))
                if !webError.isEmpty { DeskErrorBanner(message: webError, title: "Preview could not load", onDismiss: { webError = "" }) }
            } else if let pdf {
                PDFDocumentView(document: pdf)
            } else if let image = content?.image {
                DeskZoomableImage(image: image, animated: ext == "gif").id(path)
            } else if let text = content?.text {
                if ["md", "markdown"].contains(ext) {
                    MarkdownPreview(source: text, rendersTables: true, linksFilePaths: true)
                        .environment(\.openURL, OpenURLAction { url in
                            openLink(AgentFileLink.relativeLink(url, document: path, project: project))
                        })
                } else { ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10) } }
            } else { ContentUnavailableView("Preview unavailable", systemImage: "doc") }
        }
        .task(id: path + String(revision)) {
            loading = true; error = ""; webError = ""; content = nil; html = nil; pdf = nil
            let cancellation = PreviewCancellation()
            let force = revision > 0
            let project = previewProject
            let result = await withTaskCancellationHandler {
                await Task.detached { () -> Result<(PreviewContent?, ArtifactHTMLFile?, Data?), Error> in
                Result {
                    var path = path
                    var project = project
                    if project.isRemote, path.hasPrefix("~/") {
                        let script = "import os,sys,json; print(json.dumps(os.path.expanduser(sys.argv[1])))"
                        let (output, failure, status) = Command.ssh(project.host, "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(path))
                        guard status == 0, let data = output.data(using: .utf8),
                              let expanded = try? JSONDecoder().decode(String.self, from: data) else {
                            throw ResearchError.message(failure.isEmpty ? "Could not resolve the remote home directory." : failure)
                        }
                        path = expanded
                        project.path = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    }
                    if ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                        if project.isRemote { return (nil, try ArtifactHTML.snapshot(project: project, path: path, force: force, cancellation: cancellation), nil) }
                        guard FileManager.default.isReadableFile(atPath: path) else { throw ResearchError.message("File could not be read: " + path) }
                        return (nil, nil, nil)
                    }
                    let (data, failure) = Command.fileData(project, path: path, cancellation: cancellation)
                    guard let data else { throw ResearchError.message(failure) }
                    if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" { return (nil, nil, data) }
                    return (PreviewContent(data: data, extension: URL(fileURLWithPath: path).pathExtension.lowercased()), nil, nil)
                }
                }.value
            } onCancel: { cancellation.cancel() }
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let value):
                content = value.0; html = value.1
                if let data = value.2 {
                    pdf = PDFDocument(data: data)
                    if pdf == nil { error = "This file is not a readable PDF." }
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
