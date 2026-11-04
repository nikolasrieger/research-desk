import SwiftUI

enum AgentFileLink {
    static func path(_ url: URL, project: Project) -> String? {
        let raw: String
        if url.scheme == "research-file" {
            guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
            raw = value
        } else if url.isFileURL { raw = url.path }
        else if url.scheme == "sandbox" { raw = url.path }
        else if url.scheme == "vscode", url.host == "file" { raw = url.path }
        else if url.scheme == "ssh", url.host == project.host { raw = url.path }
        else if url.scheme == nil { raw = url.path.removingPercentEncoding ?? url.path }
        else { return nil }
        let cleaned = raw.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }
        return URL(fileURLWithPath: cleaned.hasPrefix("/") ? cleaned : project.path + "/" + cleaned).standardizedFileURL.path
    }
    static func linkCodePaths(_ source: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<![\[`])`([^`\n]+)`(?![\]`])"#)
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result), let content = Range(match.range(at: 1), in: source) else { continue }
            let path = String(source[content])
            guard !path.contains(" "), path.range(of: #"(?:^|/)[\w.-]+\.[A-Za-z0-9]{1,10}(?::\d+(?::\d+)?)?$"#, options: .regularExpression) != nil else { continue }
            var url = URLComponents(); url.scheme = "research-file"; url.host = "open"; url.queryItems = [URLQueryItem(name: "path", value: path)]
            if let link = url.url { result.replaceSubrange(range, with: "[`" + path + "`](" + link.absoluteString + ")") }
        }
        let links = try! NSRegularExpression(pattern: #"\]\(([^\)]+)\)"#)
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

struct AgentFilePreview: View {
    let project: Project
    let path: String
    let openLink: (URL) -> OpenURLAction.Result
    @State private var data: Data?
    @State private var html: ArtifactHTMLFile?
    @State private var error = ""
    @State private var webError = ""
    @State private var loading = true
    @State private var revision = 0
    private var ext: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).lineLimit(1).help(path)
                Spacer()
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(DeskButtonStyle(compact: true))
            }.padding(.bottom, 10)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !error.isEmpty { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if ["html", "htm"].contains(ext) {
                HostedArtifactWebView(url: html?.url ?? URL(fileURLWithPath: path), reload: revision, error: $webError,
                    readAccessRoot: html?.root ?? URL(fileURLWithPath: project.path))
                if !webError.isEmpty { Text(webError).font(.caption).foregroundStyle(.orange) }
            } else if let data, let image = NSImage(data: data) {
                if ext == "gif" { DeskAnimatedImage(image: image) }
                else { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1200).padding(8) } }
            } else if let data, let text = String(data: data, encoding: .utf8), !data.contains(0) {
                if ["md", "markdown"].contains(ext) {
                    MarkdownPreview(source: text, rendersTables: true, linksFilePaths: true)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == nil, let resolved = URL(string: url.relativeString, relativeTo: URL(fileURLWithPath: path)) {
                                return openLink(resolved.absoluteURL)
                            }
                            if url.scheme == "research-file", let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value, !value.hasPrefix("/") {
                                return openLink(URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(value))
                            }
                            return openLink(url)
                        })
                } else { ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10) } }
            } else { ContentUnavailableView("Preview unavailable", systemImage: "doc") }
        }
        .task(id: path + String(revision)) {
            loading = true; error = ""; webError = ""; data = nil; html = nil
            let result = await Task.detached { () -> Result<(Data?, ArtifactHTMLFile?), Error> in
                Result {
                    if ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                        if project.isRemote { return (nil, try ArtifactHTML.snapshot(project: project, path: path)) }
                        guard FileManager.default.isReadableFile(atPath: path) else { throw ResearchError.message("File could not be read: " + path) }
                        return (nil, nil)
                    }
                    let (data, failure) = Command.fileData(project, path: path)
                    guard let data else { throw ResearchError.message(failure) }
                    return (data, nil)
                }
            }.value
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let value): data = value.0; html = value.1
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
