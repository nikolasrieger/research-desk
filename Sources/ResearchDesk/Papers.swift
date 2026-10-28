import SwiftUI

struct ResearchPaper: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var authors: [String]
    var abstract: String
    var year: String
    var category: String
    var tags: [String] = []
    var url: URL { URL(string: "https://arxiv.org/abs/\(id)")! }
    var pdfURL: URL { URL(string: "https://arxiv.org/pdf/\(id)")! }
    var bibtex: String {
        let key = "arxiv" + id.filter { $0.isLetter || $0.isNumber }
        return """
        @misc{\(key),
          title = {{\(Self.bibEscape(title))}},
          author = {\(authors.map(Self.bibEscape).joined(separator: " and "))},
          year = {\(year)},
          eprint = {\(id)},
          archivePrefix = {arXiv},
          primaryClass = {\(Self.bibEscape(category))},
          url = {\(url.absoluteString)}
        }
        """
    }
    static func bibEscape(_ value: String) -> String {
        value.map { c in
            switch c {
            case "\\": return "\\textbackslash{}"
            case "{", "}", "&", "%", "$", "#", "_": return "\\" + String(c)
            case "~": return "\\textasciitilde{}"
            case "^": return "\\textasciicircum{}"
            default: return String(c)
            }
        }.joined()
    }
}

enum ResearchError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum ArxivID {
    static func parse(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("arxiv:") { value = String(value.dropFirst(6)) }
        if value.contains("://") {
            guard let url = URL(string: value), ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? ""),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            value = url.path
            guard let prefix = ["/abs/", "/pdf/", "/html/"].first(where: { value.hasPrefix($0) }) else { return nil }
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        let pattern = #"^(?:[0-9]{4}\.[0-9]{4,5}|[A-Za-z][A-Za-z.\-]*/[0-9]{7})(?:v[1-9][0-9]*)?$"#
        return value.range(of: pattern, options: .regularExpression) == nil ? nil : value
    }
}

actor ArxivService {
    static let shared = ArxivService()
    private var nextRequest = Date.distantPast
    func paper(id: String) async throws -> ResearchPaper {
        let slot = max(Date(), nextRequest)
        nextRequest = slot.addingTimeInterval(3)
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        var url = URLComponents(string: "https://export.arxiv.org/api/query")!
        url.queryItems = [URLQueryItem(name: "id_list", value: id)]
        let data = try await BoundedDownload.data(from: url.url!, limit: 2_000_000)
        return try ArxivFeed.parse(data, requestedID: id)
    }
}

final class ArxivFeed: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var values: [String: String] = [:]
    private var authors: [String] = []
    private var author = ""
    private var category = ""
    private var inEntry = false
    private var finished = false
    static func parse(_ data: Data, requestedID: String) throws -> ResearchPaper {
        let delegate = ArxivFeed()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let entryID = delegate.values["id"], ArxivID.parse(entryID) != nil,
              let title = delegate.values["title"], !title.isEmpty, !delegate.authors.isEmpty else {
            throw ResearchError.message("arXiv did not return a paper for this ID. Check the link and try again.")
        }
        func clean(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return ResearchPaper(id: requestedID, title: clean(title), authors: delegate.authors.map(clean),
                             abstract: clean(delegate.values["summary"] ?? ""),
                             year: String((delegate.values["published"] ?? "").prefix(4)), category: delegate.category)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        if name == "entry", !finished { inEntry = true }
        guard inEntry else { return }
        if name == "author" { author = "" }
        if name == "primary_category" { category = attributes["term"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry, let element = path.last else { return }
        if element == "name", path.contains("author") { author += string }
        if path.count >= 2, path[path.count - 2] == "entry", ["id", "title", "summary", "published"].contains(element) {
            values[element, default: ""] += string
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if inEntry && name == "author" { authors.append(author) }
        if inEntry && name == "entry" { inEntry = false; finished = true }
        if !path.isEmpty { path.removeLast() }
    }
}

@MainActor final class PaperLibrary: ObservableObject {
    @Published private(set) var collections: [UUID: [ResearchPaper]] = [:]
    @Published private(set) var busy = false
    @Published var error = ""
    private let file: URL
    private var canSave = true
    init(file: URL = WorkspaceStorage.fileURL.deletingLastPathComponent().appendingPathComponent("papers.json")) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do { collections = try JSONDecoder().decode([UUID: [ResearchPaper]].self, from: Data(contentsOf: file)) }
            catch { self.error = "Could not read the paper library: \(error.localizedDescription)"; canSave = false }
        }
    }
    func add(_ input: String, project: UUID) async -> String? {
        guard !busy else { return nil }
        guard let id = ArxivID.parse(input) else { error = "Enter an arXiv abstract/PDF link or paper ID."; return nil }
        if collections[project, default: []].contains(where: { $0.id == id }) { error = ""; return id }
        busy = true; error = ""
        defer { busy = false }
        do {
            let paper = try await ArxivService.shared.paper(id: id)
            var updated = collections
            updated[project, default: []].insert(paper, at: 0)
            return save(updated) ? id : nil
        } catch { self.error = error.localizedDescription; return nil }
    }
    func updateTags(_ text: String, paper: String, project: UUID) {
        var updated = collections
        guard let index = updated[project]?.firstIndex(where: { $0.id == paper }) else { return }
        updated[project]![index].tags = Self.tags(text)
        _ = save(updated)
    }
    static func tags(_ text: String) -> [String] {
        Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
    func remove(_ paper: String, project: UUID) {
        var updated = collections
        updated[project]?.removeAll { $0.id == paper }
        _ = save(updated)
    }
    @discardableResult func save(_ updated: [UUID: [ResearchPaper]]) -> Bool {
        guard canSave else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            collections = updated; error = ""; return true
        } catch { self.error = "Could not save papers: \(error.localizedDescription)"; return false }
    }
}

struct PapersPane: View {
    let project: Project
    @ObservedObject var model: DeskModel
    @ObservedObject var library: PaperLibrary
    let showAgent: () -> Void
    let showTerminal: () -> Void
    @State private var input = ""
    @State private var selected: String?
    @State private var filter = ""
    @State private var tagFilter = "All tags"
    private var papers: [ResearchPaper] { library.collections[project.id] ?? [] }
    private var visible: [ResearchPaper] {
        papers.filter { (tagFilter == "All tags" || $0.tags.contains(tagFilter)) &&
            (filter.isEmpty || ($0.title + " " + $0.authors.joined(separator: " ") + " " + $0.id).localizedCaseInsensitiveContains(filter)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("arXiv link or ID", text: $input).textFieldStyle(DeskFieldStyle())
                    .onSubmit { add() }
                Button("Add paper") { add() }.disabled(library.busy || input.isEmpty)
                if library.busy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 16).padding(.vertical, 12).background(DeskStyle.surface)
            if !library.error.isEmpty { Text(library.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8) }
            HSplitView {
                VStack(spacing: 10) {
                    TextField("Search papers", text: $filter).textFieldStyle(DeskFieldStyle())
                    HStack {
                        DeskChoiceMenu(title: tagFilter, symbol: "line.3.horizontal.decrease",
                                       choices: ["All tags"] + Array(Set(papers.flatMap(\.tags))).sorted(),
                                       selection: tagFilter) { tagFilter = $0 }.fixedSize()
                        Spacer()
                        Text("\(visible.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DeskStyle.muted)
                    }
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(visible) { paper in
                                Button { selected = paper.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(paper.title).font(.system(size: 12, weight: .medium)).lineLimit(3)
                                        Text(paper.id + (paper.tags.isEmpty ? "" : " · " + paper.tags.joined(separator: ", ")))
                                            .font(.system(size: 10)).foregroundStyle(DeskStyle.muted).lineLimit(2)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background { if selected == paper.id { DeskMetalPlate() } }
                                }.buttonStyle(.plain)
                            }
                            if visible.isEmpty { Text(papers.isEmpty ? "Add a paper to this workspace." : "No matching papers.").font(.caption).foregroundStyle(DeskStyle.muted).padding(12) }
                        }
                    }
                }.padding(16).frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                if let paper = papers.first(where: { $0.id == selected }) {
                    PaperDetail(paper: paper, project: project, model: model, library: library,
                                showAgent: showAgent, showTerminal: showTerminal).id(paper.id)
                } else {
                    Text("Select a paper").foregroundStyle(DeskStyle.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.background(DeskStyle.background)
    }
    private func add() {
        let value = input
        Task { if let id = await library.add(value, project: project.id) { selected = id; input = ""; filter = ""; tagFilter = "All tags" } }
    }
}

private struct PaperDetail: View {
    let paper: ResearchPaper
    let project: Project
    @ObservedObject var model: DeskModel
    @ObservedObject var library: PaperLibrary
    let showAgent: () -> Void
    let showTerminal: () -> Void
    @State private var tags = ""
    @State private var showPDF = false
    @State private var copied = false
    @State private var remove = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { readingActions; sharingActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 6) { readingActions }; HStack(spacing: 6) { sharingActions } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(DeskStyle.surface)
            HStack(spacing: 8) {
                TextField("Tags, separated by commas", text: $tags).textFieldStyle(DeskFieldStyle())
                    .onSubmit { saveTags() }
                Button("Save tags") { saveTags() }
                DeskChoiceMenu(title: "Add tag", choices: ["baseline", "related work", "method", "dataset", "to read"]) { tag in
                    tags = PaperLibrary.tags(tags + "," + tag).joined(separator: ", ")
                    saveTags()
                }.fixedSize()
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if showPDF {
                RemotePDFPane(url: paper.pdfURL).id(paper.pdfURL)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(paper.title).font(.system(size: 22, weight: .semibold))
                        Text(paper.authors.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(DeskStyle.muted)
                        Text("arXiv:\(paper.id) · \(paper.year) · \(paper.category)").font(.caption).foregroundStyle(DeskStyle.muted)
                        Text(paper.abstract).font(.system(size: 14)).lineSpacing(5)
                        Divider()
                        Text(paper.bibtex).font(.system(size: 11, design: .monospaced))
                    }.textSelection(.enabled).padding(24).frame(maxWidth: 850, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { tags = paper.tags.joined(separator: ", ") }
            .confirmationDialog("Remove this paper from the collection?", isPresented: $remove) {
                Button("Remove paper", role: .destructive) { library.remove(paper.id, project: project.id) }
            }
    }
    @ViewBuilder private var readingActions: some View {
        Button(showPDF ? "Details" : "Read PDF") { showPDF.toggle() }
        Button("arXiv ↗") { NSWorkspace.shared.open(paper.url) }
    }
    @ViewBuilder private var sharingActions: some View {
        Button(copied ? "Copied" : "Copy BibTeX") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paper.bibtex, forType: .string); copied = true }
        ConsolePasteMenu(text: paper.url.absoluteString, project: project, model: model, showAgent: showAgent, showTerminal: showTerminal)
        Menu { Button("Remove paper", role: .destructive) { remove = true } } label: { Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 30, height: 30).contentShape(Rectangle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Paper options")
    }
    private func saveTags() { library.updateTags(tags, paper: paper.id, project: project.id) }
}
