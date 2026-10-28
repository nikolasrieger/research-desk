import SwiftUI
import AppKit
import AVKit

enum FileBrowserIO {
    static let remotePathScript = """
    import os,sys
    requested_root=os.path.expanduser(sys.argv[1])
    requested_path=os.path.expanduser(sys.argv[2])
    root=os.path.realpath(requested_root)
    p=os.path.realpath(requested_path)
    if os.path.commonpath([root,p]) != root:
        sys.exit('File resolves outside this project. A file or parent folder may be a symlink.\\nRequested file: '+requested_path+'\\nResolved file: '+p+'\\nProject: '+requested_root+'\\nResolved project: '+root)
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
            let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard source.path.hasPrefix(root == "/" ? root : root + "/") else {
                throw CocoaError(.fileReadNoPermission)
            }
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

    static func listing(_ project: Project, path: String) -> (RemoteListing?, String) {
        if project.isRemote { return Command.remoteListing(host: project.host, path: path) }
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard directory.path == root || directory.path.hasPrefix(root + "/") else {
            return (nil, "Folder is outside this project")
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            let entries = urls.map { url -> RemoteEntry in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
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
        guard path == project.path || path.hasPrefix(project.path + "/") else { return }
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

struct FilesPane: View {
    @ObservedObject var browser: FileBrowserModel

    private var visibleEntries: [RemoteEntry] {
        guard !browser.search.isEmpty else { return browser.entries }
        return browser.entries.filter { $0.name.localizedCaseInsensitiveContains(browser.search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Button { browser.up() } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(DeskButtonStyle(compact: true)).disabled(!browser.canGoUp).help("Parent folder")
                    Text(browser.directory == browser.project.path ? browser.project.name : URL(fileURLWithPath: browser.directory).lastPathComponent)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
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
                                }.padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(browser.selectedPath == path ? DeskStyle.raised : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
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
                if !browser.error.isEmpty { Text(browser.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.frame(width: 210).padding(12).background(DeskStyle.surface)
            Rectangle().fill(DeskStyle.edge).frame(width: 1)
            previewPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeskStyle.background)
    }

    @ViewBuilder private var previewPane: some View {
        if let preview = browser.preview {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(preview.name).font(.system(size: 13, weight: .semibold))
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
