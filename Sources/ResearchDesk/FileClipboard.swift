import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

struct ClipboardFile: Sendable {
    let url: URL
    let imageData: Data?
    let imageType: String?
    let tiff: Data?
}

enum FileClipboard {
    /// Clipboard file URLs must outlive the preview and the app's temporary downloads.
    static func prepare(project: Project, path: String, root: URL? = nil) throws -> ClipboardFile {
        var project = project
        var path = path
        if project.isRemote, path.hasPrefix("~/") {
            let script = "import os,sys,json; print(json.dumps(os.path.expanduser(sys.argv[1])))"
            let command = "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(path)
            let (output, error, status) = Command.ssh(project.host, command)
            guard status == 0, let data = output.data(using: .utf8), let expanded = try? JSONDecoder().decode(String.self, from: data) else {
                throw ResearchError.message(error.isEmpty ? "Could not resolve the remote file." : error)
            }
            path = expanded
            project.path = URL(fileURLWithPath: path).deletingLastPathComponent().path
        } else if !project.isRemote { path = (path as NSString).expandingTildeInPath }
        let directory = (root ?? WorkspaceStorage.fileURL.deletingLastPathComponent().appendingPathComponent("Clipboard"))
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        do {
            try FileBrowserIO.copyFile(project, path: path, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var original: Data?, type: String?, tiff: Data?
            if let fileType = UTType(filenameExtension: url.pathExtension), fileType.conforms(to: .image),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 15_000_000,
               let data = try? Data(contentsOf: url),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
               width.doubleValue * height.doubleValue <= 40_000_000 {
                original = data; type = fileType.identifier
                tiff = NSImage(data: data)?.tiffRepresentation
            }
            return ClipboardFile(url: url, imageData: original, imageType: type, tiff: tiff)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @MainActor static func write(_ file: ClipboardFile, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        item.setString(file.url.absoluteString, forType: .fileURL)
        if let data = file.imageData, let type = file.imageType {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        if let tiff = file.tiff { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ResearchError.message("Could not write the file to the clipboard.") }
    }
}

struct FileCopyButton: View {
    let project: Project
    let path: String
    @State private var copying = false
    @State private var copied = false
    @State private var error = ""
    @State private var showError = false
    var body: some View {
        Button {
            guard !copying else { return }
            copying = true; copied = false; error = ""
            let project = project, path = path
            Task {
                let result = await Task.detached { Result { try FileClipboard.prepare(project: project, path: path) } }.value
                copying = false
                do {
                    try FileClipboard.write(result.get())
                    copied = true
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                } catch { self.error = error.localizedDescription; showError = true }
            }
        } label: {
            if copying { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
            else { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
        }
        .buttonStyle(DeskButtonStyle(compact: true)).disabled(copying)
        .help(copying ? "Preparing file…" : copied ? "Copied" : "Copy file or image to clipboard")
        .accessibilityLabel(copied ? "Copied file" : "Copy file or image")
        .popover(isPresented: $showError) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Could not copy file").font(.headline)
                Text(error).font(.caption).textSelection(.enabled)
            }.padding(16).frame(maxWidth: 340)
        }
    }
}
