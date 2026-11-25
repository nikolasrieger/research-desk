import SwiftUI
import AppKit

/// Imported images live alongside workspace storage, independent of temporary previews.
enum NoteAttachments {
    static func importImage(project: Project, path: String, root: URL? = nil) throws -> URL {
        let directory = (root ?? WorkspaceStorage.fileURL.deletingLastPathComponent().appendingPathComponent("NoteAttachments"))
            .appendingPathComponent(project.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(URL(fileURLWithPath: path).pathExtension.lowercased())
        do {
            try FileBrowserIO.copyFile(project, path: path, to: url, limit: 15_000_000)
            let data = try Data(contentsOf: url)
            guard PreviewContent(data: data, extension: url.pathExtension).image != nil else {
                throw ResearchError.message("Choose a supported image file (PNG, JPEG, GIF, TIFF, HEIC, BMP or WebP).")
            }
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    static func markdown(url: URL, name: String) -> String {
        let label = name.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return "![" + label + "](" + url.absoluteString + ")"
    }
}

enum NoteImageLink {
    static func parse(_ line: String) -> (alt: String, url: URL)? {
        guard line.hasPrefix("!["), let split = line.range(of: "]("), line.hasSuffix(")") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound])
        let target = String(line[split.upperBound..<line.index(before: line.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let url = URL(string: target), url.isFileURL else { return nil }
        return (alt, url)
    }
}

struct NoteImagePreview: View {
    let url: URL?
    let alt: String
    @State private var content: PreviewContent?
    @State private var loading = true
    @State private var showingDetail = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = content?.image {
                Button { showingDetail = true } label: {
                    Group {
                        if url?.pathExtension.lowercased() == "gif" { DeskAnimatedImage(image: image).frame(maxHeight: 500) }
                        else { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 600) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to enlarge and zoom")
                .accessibilityLabel(alt.isEmpty ? "Enlarge note image" : "Enlarge " + alt)
                .accessibilityHint("Opens an image viewer with zoom controls")
            } else if loading { ProgressView().controlSize(.small) }
            else { Label(alt.isEmpty ? "Image unavailable" : "Image unavailable: " + alt, systemImage: "photo").foregroundStyle(DeskStyle.muted) }
        }
        .accessibilityLabel(alt.isEmpty ? "Note image" : alt)
        .sheet(isPresented: $showingDetail) {
            if let url { NoteImageDetail(url: url, title: alt) }
        }
        .task(id: url) {
            showingDetail = false
            loading = true; content = nil
            let loaded = await Task.detached { () -> PreviewContent? in
                guard let url, url.isFileURL,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 15_000_000,
                      let data = try? Data(contentsOf: url) else { return nil }
                return PreviewContent(data: data, extension: url.pathExtension.lowercased())
            }.value
            guard !Task.isCancelled else { return }
            content = loaded; loading = false
        }
    }
}

/// Load the original only while the detail viewer is open; inline notes keep lightweight previews.
struct NoteImageDetail: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var content: PreviewContent?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.isEmpty ? url.lastPathComponent : title)
                    .font(.headline).lineLimit(1).help(url.path)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            if let image = content?.image {
                DeskZoomableImage(image: image, animated: url.pathExtension.lowercased() == "gif")
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Label("Image unavailable", systemImage: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 540, idealHeight: 720)
        .background(DeskStyle.background)
        .task(id: url) {
            loading = true; content = nil
            let loaded = await Task.detached { () -> PreviewContent? in
                guard url.isFileURL,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 15_000_000,
                      let data = try? Data(contentsOf: url) else { return nil }
                return PreviewContent(data: data, extension: url.pathExtension.lowercased(), fullResolution: true)
            }.value
            guard !Task.isCancelled else { return }
            content = loaded; loading = false
        }
    }
}

struct NotesPane: View {
    let project: Project
    @ObservedObject var model: DeskModel
    let showAgent: () -> Void
    let showTerminal: () -> Void
    @State private var preview = false
    @State private var chooseImage = false
    @State private var linkedPath: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Project notes").font(.system(size: 14, weight: .medium))
                Spacer()
                Button("Edit") { preview = false }.buttonStyle(DeskButtonStyle(prominent: !preview, compact: true))
                Button("Preview") { preview = true }.buttonStyle(DeskButtonStyle(prominent: preview, compact: true))
                Button("Add image", systemImage: "photo.badge.plus") { chooseImage = true }.buttonStyle(DeskButtonStyle(compact: true))
                ConsolePasteMenu(text: model.notes[project.id] ?? "", project: project, model: model, showAgent: showAgent, showTerminal: showTerminal)
            }
            if preview {
                MarkdownPreview(source: model.notes[project.id] ?? "", rendersTables: true, linksFilePaths: true)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let path = AgentFileLink.path(url, project: project) else { return .systemAction }
                        linkedPath = path; return .handled
                    })
            } else {
                TextEditor(text: Binding(get: { model.notes[project.id] ?? "" }, set: { model.setNote($0, for: project) }))
                    .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).accessibilityLabel("Project notes Markdown")
            }
        }.padding(20)
            .sheet(isPresented: Binding(get: { linkedPath != nil }, set: { if !$0 { linkedPath = nil } })) {
                if let linkedPath {
                    VStack {
                        HStack { Spacer(); Button("Close") { self.linkedPath = nil } }
                        AgentFilePreview(project: project, path: linkedPath, openLink: { url in
                            guard let path = AgentFileLink.path(url, project: project) else { return .systemAction }
                            self.linkedPath = path; return .handled
                        }).id(linkedPath)
                    }.padding(16).frame(minWidth: 700, minHeight: 540)
                }
            }
            .sheet(isPresented: $chooseImage) {
                NoteImagePicker(project: project) { url, name in
                    let current = model.notes[project.id] ?? ""
                    model.setNote(current + (current.isEmpty ? "" : "\n\n") + NoteAttachments.markdown(url: url, name: name) + "\n", for: project)
                }
            }
    }
}

struct NoteImagePicker: View {
    let project: Project
    let insert: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var entries: [RemoteEntry] = []
    @State private var selected: String?
    @State private var busy = false
    @State private var error = ""
    private let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project.isRemote ? "Add image from " + project.host : "Add project image")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
            HStack {
                Button("Up", systemImage: "arrow.up") { load(URL(fileURLWithPath: directory).deletingLastPathComponent().path) }
                    .disabled(directory == project.path || busy)
                Text(directory).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.buttonStyle(DeskButtonStyle(compact: true))
            List(entries, selection: $selected) { entry in
                HStack {
                    Image(systemName: entry.directory ? "folder" : "photo")
                    Text(entry.name)
                    Spacer()
                    if entry.directory {
                        Button("Open") { load(URL(fileURLWithPath: directory).appendingPathComponent(entry.name).path) }
                            .buttonStyle(DeskButtonStyle(compact: true)).disabled(busy)
                    }
                }.tag(entry.name)
            }.frame(minHeight: 260).disabled(busy)
            if !error.isEmpty { DeskErrorBanner(message: error, title: "Could not add image", onDismiss: { error = "" }) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button(busy ? "Loading…" : "Download and insert") { download() }
                    .buttonStyle(DeskButtonStyle(prominent: true))
                    .disabled(busy || selected == nil || entries.first(where: { $0.name == selected })?.directory != false)
            }.buttonStyle(DeskButtonStyle())
        }.padding(20).frame(width: 660, height: 480).background(DeskStyle.background)
            .task { load(project.path) }
    }
    private func load(_ path: String) {
        guard !busy, FileBrowserIO.containsPath(path, in: project.path) else { return }
        busy = true; error = ""; selected = nil
        Task {
            let result = await Task.detached { FileBrowserIO.listing(project, path: path) }.value
            if let listing = result.0 {
                directory = listing.path
                entries = listing.entries.filter { $0.directory || extensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
            } else { error = result.1 }
            busy = false
        }
    }
    private func download() {
        guard let selected, !busy else { return }
        let path = URL(fileURLWithPath: directory).appendingPathComponent(selected).path
        busy = true; error = ""
        Task {
            let result = await Task.detached { Result { try NoteAttachments.importImage(project: project, path: path) } }.value
            busy = false
            switch result {
            case .success(let url): insert(url, selected); dismiss()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
