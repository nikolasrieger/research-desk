import SwiftUI
import AppKit
import AVKit

enum FileBrowserIO {
    static func containsPath(_ path: String, in root: String) -> Bool {
        func normalized(_ value: String) -> String {
            var parts: [Substring] = []
            for part in URL(fileURLWithPath: value).path.split(separator: "/") {
                if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                else if part != "." { parts.append(part) }
            }
            return "/" + parts.joined(separator: "/")
        }
        let base = normalized(root)
        let file = normalized(path)
        return file == base || file.hasPrefix(base == "/" ? "/" : base + "/")
    }

    static let remotePathScript = """
    import os,sys
    requested_root=os.path.abspath(os.path.expanduser(sys.argv[1]))
    requested_path=os.path.abspath(os.path.expanduser(sys.argv[2]))
    if os.path.commonpath([requested_root,requested_path]) != requested_root:
        sys.exit('File path is outside this project.\\nRequested file: '+requested_path+'\\nProject: '+requested_root)
    p=os.path.realpath(requested_path)
    """

    static let remotePreviewScript = remotePathScript + "\n" + """
    import base64,stat
    try:
        with open(p,'rb') as f:
            info=os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode):
                sys.exit('Not a regular file: '+requested_path)
            if info.st_size>15000000:
                sys.exit('File is larger than 15 MB: '+requested_path)
            data=f.read(15000001)
            if len(data)>15000000:
                sys.exit('File is larger than 15 MB: '+requested_path)
            sys.stdout.write(base64.b64encode(data).decode('ascii'))
    except OSError as error:
        sys.exit('Could not read '+requested_path+': '+str(error))
    """

    /// Streams remote bytes to disk, so downloads and movies do not pass through base64 or RAM.
    static func copyFile(_ project: Project, path: String, to destination: URL, limit: Int? = nil) throws {
        if !project.isRemote {
            guard containsPath(path, in: project.path) else {
                throw CocoaError(.fileReadNoPermission)
            }
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if let limit, (values.fileSize ?? 0) > limit {
                throw NSError(domain: "ResearchDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Media preview is limited to 500 MB. Download the file to play it locally."])
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard !project.host.hasPrefix("-"), project.host.range(of: #"^[a-zA-Z0-9._@-]+$"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let script = remotePathScript + "\n" + """
        import stat,shutil
        limit=int(sys.argv[3])
        with open(p,'rb') as f:
            info=os.fstat(f.fileno())
            assert stat.S_ISREG(info.st_mode), 'Not a regular file'
            assert limit<0 or info.st_size<=limit, 'Media preview is limited to 500 MB. Download the file to play it locally.'
            shutil.copyfileobj(f,sys.stdout.buffer,1024*1024)
        """
        let command = "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(project.path) + " " + Command.shellQuote(path) + " " + String(limit ?? -1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5", project.host, command]
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(300)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw NSError(domain: "ResearchDesk", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transfer timed out. Try again."]) }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "Could not download remote file."
            throw NSError(domain: "ResearchDesk", code: 3, userInfo: [NSLocalizedDescriptionKey: String(message.suffix(4000))])
        }
    }

    static func download(_ project: Project, path: String, directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".research-desk-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try copyFile(project, path: path, to: temporary)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let original = directory.appendingPathComponent(name)
        var candidate = original
        var index = 1
        while true {
            do { try manager.moveItem(at: temporary, to: candidate); return candidate }
            catch CocoaError.fileWriteFileExists {
                let ext = original.pathExtension
                let stem = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
                candidate = directory.appendingPathComponent("\(stem) (\(index))" + (ext.isEmpty ? "" : "." + ext))
                index += 1
            }
        }
    }

    static func uncommittedPaths(_ project: Project) -> Set<String> {
        let command = "python3 -c " + Command.shellQuote(gitStatusScript) + " " + Command.shellQuote(project.path)
        let result = project.isRemote ? Command.ssh(project.host, command, maxOutput: 2_000_000) : Command.run("/bin/zsh", ["-c", command], maxOutput: 2_000_000)
        guard result.2 == 0, let paths = try? JSONDecoder().decode([String].self, from: Data(result.0.utf8)) else { return [] }
        return Set(paths)
    }
    static func isUncommitted(_ path: String, directory: Bool, changes: Set<String>) -> Bool {
        changes.contains(path) || (directory && changes.contains { $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") })
    }
    static let gitStatusScript = #"""
import os, subprocess, sys, json
project = os.path.abspath(sys.argv[1])
root = subprocess.run(['git', '-C', project, 'rev-parse', '--show-toplevel'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
if root.returncode:
    print('[]'); sys.exit(0)
root = os.fsdecode(root.stdout).rstrip('\n')
status = subprocess.run(['git', '-C', project, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
if status.returncode:
    print('[]'); sys.exit(0)
entries = status.stdout.split(b'\0')
paths = set()
i = 0
while i < len(entries):
    entry = entries[i]; i += 1
    if len(entry) < 4: continue
    names = [entry[3:]]
    if b'R' in entry[:2] or b'C' in entry[:2]:
        if i < len(entries): names.append(entries[i]); i += 1
    for name in names:
        absolute = os.path.join(root, os.fsdecode(name))
        relative = os.path.relpath(absolute, os.path.realpath(project))
        if relative == '..' or relative.startswith('../'): continue
        paths.add(os.path.normpath(os.path.join(project, relative)))
print(json.dumps(sorted(paths)))
"""#

    static func listing(_ project: Project, path: String) -> (RemoteListing?, String) {
        if project.isRemote { return Command.remoteListing(host: project.host, path: path) }
        let directory = URL(fileURLWithPath: path)
        guard containsPath(path, in: project.path) else {
            return (nil, "Folder is outside this project")
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey], options: [])
            let entries = urls.map { url -> RemoteEntry in
                let isDirectory = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return RemoteEntry(name: url.lastPathComponent, directory: isDirectory)
            }.sorted { left, right in
                if left.directory != right.directory { return left.directory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return (RemoteListing(path: directory.path, entries: Array(entries.prefix(500))), "")
        } catch { return (nil, error.localizedDescription) }
    }
}

final class MediaPreviewFile: Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct FilePreview: Sendable {
    static func isMovie(_ name: String) -> Bool {
        ["mp4", "m4v", "mov"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
    var media: MediaPreviewFile? = nil
    var isGIF: Bool { URL(fileURLWithPath: name).pathExtension.lowercased() == "gif" }

    let name: String
    let path: String
    let data: Data
    let isImage: Bool
}

@MainActor final class FileBrowserModel: ObservableObject {
    let project: Project
    @Published var directory: String
    @Published var entries: [RemoteEntry] = []
    @Published var preview: FilePreview?
    @Published var selectedPath: String?
    @Published var search = ""
    @Published var renderMarkdown = true
    @Published var loading = false
    @Published var error = ""
    @Published var downloading = false
    @Published var downloadMessage = ""
    @Published var downloadedURL: URL?
    @Published var uncommittedPaths: Set<String> = []
    private var loadingGit = false
    private var requestID = UUID()

    func download(path: String) {
        guard !downloading else { return }
        downloading = true
        downloadedURL = nil
        downloadMessage = "Downloading…"
        let project = project
        Task.detached { [weak self] in
            do {
                let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let url = try FileBrowserIO.download(project, path: path, directory: directory)
                await MainActor.run {
                    self?.downloading = false
                    self?.downloadedURL = url
                    self?.downloadMessage = "Saved \(url.lastPathComponent) to Downloads"
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self?.downloading = false; self?.downloadMessage = message }
            }
        }
    }

    init(project: Project) {
        self.project = project
        directory = project.path
        load(project.path)
    }

    func refreshGitStatus() {
        guard !loadingGit else { return }
        loadingGit = true
        let project = project
        Task { [weak self] in
            let changes = await Task.detached { FileBrowserIO.uncommittedPaths(project) }.value
            self?.uncommittedPaths = changes
            self?.loadingGit = false
        }
    }

    var canGoUp: Bool { directory != project.path }

    func up() {
        guard canGoUp else { return }
        load(URL(fileURLWithPath: directory).deletingLastPathComponent().path)
    }

    func open(_ entry: RemoteEntry) {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(entry.name).path
        if entry.directory { load(path) } else { show(path: path, name: entry.name) }
    }

    func load(_ path: String) {
        guard FileBrowserIO.containsPath(path, in: project.path) else { return }
        refreshGitStatus()
        requestID = UUID()
        let request = requestID
        loading = true
        error = ""
        preview = nil
        selectedPath = nil
        let project = self.project
        Task.detached { [weak self] in
            let (listing, failure) = FileBrowserIO.listing(project, path: path)
            await MainActor.run {
                guard let self, self.requestID == request else { return }
                self.loading = false
                self.error = failure
                if let listing {
                    self.directory = listing.path
                    self.entries = listing.entries
                }
            }
        }
    }

    func show(path: String, name: String) {
        requestID = UUID()
        let request = requestID
        loading = true
        error = ""
        selectedPath = path
        preview = nil
        let project = self.project
        Task.detached { [weak self] in
            if FilePreview.isMovie(name) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("research-desk-media-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let media = MediaPreviewFile(url: folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent))
                    try FileBrowserIO.copyFile(project, path: path, to: media.url, limit: 500_000_000)
                    await MainActor.run {
                        guard let self, self.requestID == request else { return }
                        self.loading = false
                        self.preview = FilePreview(media: media, name: name, path: path, data: Data(), isImage: false)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    let message = error.localizedDescription
                    await MainActor.run {
                        guard let self, self.requestID == request else { return }
                        self.loading = false; self.error = message
                    }
                }
                return
            }
            let (data, failure) = Command.fileData(project, path: path)
            await MainActor.run {
                guard let self, self.requestID == request else { return }
                self.loading = false
                self.error = failure
                if let data {
                    let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]
                    let image = imageTypes.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
                    self.preview = FilePreview(name: name, path: path, data: data, isImage: image)
                }
            }
        }
    }
}

private struct FilePathHoverTarget {
    let path: String
    let bounds: Anchor<CGRect>
}
private struct FilePathHoverPreference: PreferenceKey {
    static var defaultValue: [String: FilePathHoverTarget] { [:] }
    static func reduce(value: inout [String: FilePathHoverTarget], nextValue: () -> [String: FilePathHoverTarget]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    func filePathHover(_ path: String, id: String, hovered: Binding<String?>) -> some View {
        self.contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered.wrappedValue = id }
                else if hovered.wrappedValue == id { hovered.wrappedValue = nil }
            }
            .anchorPreference(key: FilePathHoverPreference.self, value: .bounds) { [id: FilePathHoverTarget(path: path, bounds: $0)] }
            .accessibilityHint(path)
    }
}

struct FilesPane: View {
    @ObservedObject var browser: FileBrowserModel
    @State private var hoveredPathID: String?

    private var visibleEntries: [RemoteEntry] {
        guard !browser.search.isEmpty else { return browser.entries }
        return browser.entries.filter { $0.name.localizedCaseInsensitiveContains(browser.search) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Button { browser.up() } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(DeskButtonStyle(compact: true)).disabled(!browser.canGoUp).help("Parent folder")
                    Text(browser.directory == browser.project.path ? browser.project.name : URL(fileURLWithPath: browser.directory).lastPathComponent)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .filePathHover(fullPath(browser.directory), id: "folder", hovered: $hoveredPathID)
                    Spacer(minLength: 0)
                    Button { browser.load(browser.directory) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(DeskButtonStyle(compact: true)).help("Refresh files")
                }
                TextField("Filter this folder", text: $browser.search)
                    .textFieldStyle(DeskFieldStyle())
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleEntries) { entry in
                            let path = URL(fileURLWithPath: browser.directory).appendingPathComponent(entry.name).path
                            Button { browser.open(entry) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.directory ? "folder" : "doc.text")
                                        .foregroundStyle(DeskStyle.muted)
                                        .frame(width: 16)
                                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    if entry.directory { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DeskStyle.muted) }
                                    if FileBrowserIO.isUncommitted(path, directory: entry.directory, changes: browser.uncommittedPaths) {
                                        Circle().fill(Color.gray).frame(width: 5, height: 5)
                                            .help("Uncommitted changes").accessibilityLabel("Uncommitted changes")
                                    }
                                }.padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(browser.selectedPath == path ? DeskStyle.raised : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                                .filePathHover(fullPath(path), id: "file:" + path, hovered: $hoveredPathID)
                                .contextMenu {
                                    if !entry.directory {
                                        Button("Download to Downloads") { browser.download(path: path) }.disabled(browser.downloading)
                                    }
                                }
                        }
                    }
                }
                if let path = browser.selectedPath {
                    Button { browser.download(path: path) } label: { Label(browser.downloading ? "Downloading…" : "Download file", systemImage: "arrow.down.to.line") }
                        .buttonStyle(DeskButtonStyle()).disabled(browser.downloading)
                }
                if !browser.downloadMessage.isEmpty {
                    Text(browser.downloadMessage).font(.caption).foregroundStyle(DeskStyle.muted).textSelection(.enabled)
                    if let url = browser.downloadedURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(DeskButtonStyle())
                    }
                }
                if browser.loading { ProgressView().controlSize(.small) }
                if !browser.error.isEmpty { DeskErrorBanner(message: browser.error, title: "Could not load files", onDismiss: { browser.error = "" }) }
            }.padding(12).frame(minWidth: 150, idealWidth: 234, maxWidth: .infinity, maxHeight: .infinity)
                .background(DeskStyle.surface)
            previewPane.frame(minWidth: 220, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeskStyle.background)
        .task { browser.refreshGitStatus() }
        .onChange(of: browser.directory) { _, _ in hoveredPathID = nil }
        .onDisappear { hoveredPathID = nil }
        .overlayPreferenceValue(FilePathHoverPreference.self) { targets in
            GeometryReader { geometry in
                if let id = hoveredPathID, let target = targets[id] {
                    let bounds = geometry[target.bounds]
                    let width = min(560, max(180, geometry.size.width - 24))
                    Text(target.path)
                        .font(.system(size: 11)).foregroundStyle(DeskStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .frame(width: width, alignment: .leading)
                        .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DeskStyle.edge))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .offset(x: min(max(8, bounds.minX), max(8, geometry.size.width - width - 12)),
                                y: max(8, min(bounds.maxY + 5, geometry.size.height - 110)))
                        .allowsHitTesting(false)
                }
            }.allowsHitTesting(false)
        }
    }

    private func fullPath(_ path: String) -> String {
        browser.project.isRemote ? browser.project.host + ":" + path : path
    }

    @ViewBuilder private var previewPane: some View {
        if let preview = browser.preview {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(preview.name).font(.system(size: 13, weight: .semibold)).filePathHover(fullPath(preview.path), id: "preview", hovered: $hoveredPathID)
                    Spacer()
                    if ["md", "markdown"].contains(URL(fileURLWithPath: preview.name).pathExtension.lowercased()) {
                        Picker("Markdown view", selection: $browser.renderMarkdown) {
                            Text("Preview").tag(true)
                            Text("Source").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    Button { browser.download(path: preview.path) } label: { Label("Download", systemImage: "arrow.down.to.line") }
                        .buttonStyle(DeskButtonStyle()).disabled(browser.downloading)
                    if preview.media == nil {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(preview.data.count), countStyle: .file))
                            .font(.caption).foregroundStyle(DeskStyle.muted)
                    }
                }.padding(15)
                Rectangle().fill(DeskStyle.edge).frame(height: 1)
                if let media = preview.media {
                    DeskMoviePlayer(media: media).id(media.url)
                } else if preview.isGIF, let image = NSImage(data: preview.data) {
                    DeskAnimatedImage(image: image).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if preview.isImage, let image = NSImage(data: preview.data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                    }
                } else if let text = String(data: preview.data, encoding: .utf8), !preview.data.contains(0) {
                    if browser.renderMarkdown,
                       ["md", "markdown"].contains(URL(fileURLWithPath: preview.name).pathExtension.lowercased()) {
                        MarkdownPreview(source: String(text.prefix(300_000)))
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            let shown = String(text.prefix(300_000))
                            Text(shown)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .textSelection(.enabled).padding(18)
                        }
                    }
                } else {
                    ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text("This file format cannot be shown here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VStack(spacing: 12) {
                DeskSpatialMark()
                DeskEyebrow(title: "Workspace files")
                Text("Select a file").font(.system(size: 25, weight: .light)).tracking(-0.6)
                Text("Text, Markdown, images, GIFs, and videos").font(.system(size: 12)).foregroundStyle(DeskStyle.muted)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// AppKit advances GIF frames; SwiftUI's static Image only draws a single frame.
struct DeskAnimatedImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }
    static func dismantleNSView(_ view: NSImageView, coordinator: ()) { view.animates = false; view.image = nil }
}

struct DeskMoviePlayer: View {
    let media: MediaPreviewFile
    @State private var player: AVPlayer
    init(media: MediaPreviewFile) {
        self.media = media
        _player = State(initialValue: AVPlayer(url: media.url))
    }
    var body: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDisappear { player.pause() }
    }
}
