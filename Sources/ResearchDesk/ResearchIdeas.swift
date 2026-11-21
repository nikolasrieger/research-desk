import SwiftUI
import AppKit

struct ResearchIdea: Identifiable, Codable {
    var id = UUID()
    var title = ""
    var note = ""
    var host = ""
    var parent = ""
    var folder = ""
    var completed: Bool?
    var projectID: UUID?
}

enum ResearchProjectSetup {
    static func validate(folder: String, parent: String) throws {
        guard !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"), !folder.contains("\\"),
              !folder.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw ResearchError.message("Enter a folder name without slashes.")
        }
        guard parent.hasPrefix("/") || parent == "~" || parent.hasPrefix("~/") else {
            throw ResearchError.message("Choose an absolute parent folder or a path starting with ~/.")
        }
    }

    static func create(folder: String, parent: String, host: String) throws -> String {
        try validate(folder: folder, parent: parent)
        if host.isEmpty {
            let base = (parent as NSString).expandingTildeInPath
            let target = URL(fileURLWithPath: base).appendingPathComponent(folder)
            // mkdir is exclusive: existing folders and their contents are never reused.
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return target.path
        }
        let script = """
        import os,sys,json
        try:
            parent=os.path.abspath(os.path.expanduser(sys.argv[1]))
            target=os.path.join(parent,sys.argv[2])
            os.mkdir(target)
            print(json.dumps(target))
        except OSError as error:
            sys.exit(str(error))
        """
        let command = "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(parent) + " " + Command.shellQuote(folder)
        let (output, failure, status) = Command.ssh(host, command, timeout: 20)
        guard status == 0 else { throw ResearchError.message(failure.isEmpty ? "Could not create the project folder." : failure) }
        guard let data = output.data(using: .utf8), let path = try? JSONDecoder().decode(String.self, from: data) else {
            throw ResearchError.message("The server did not return the new folder path. Check Files before retrying.")
        }
        return path
    }
}

struct ResearchIdeasPane: View {
    @ObservedObject var model: DeskModel
    @AppStorage("researchIdeas", store: UserDefaults(suiteName: WorkspaceStorage.domain)) private var saved = Data()
    @State private var ideas: [ResearchIdea] = []
    @State private var selection: UUID?
    @State private var busy = false
    @State private var error = ""
    @State private var created = ""
    @State private var draft = ""
    @State private var showSetup = false
    private var index: Int? { ideas.firstIndex { $0.id == selection } }
    private var hosts: [String] { Array(Set(SSHHosts.configured() + model.projects.filter(\.isRemote).map(\.host))).sorted() }

    private func field(_ key: WritableKeyPath<ResearchIdea, String>) -> Binding<String> {
        Binding(get: { index.map { ideas[$0][keyPath: key] } ?? "" }, set: { value in
            guard let index else { return }
            ideas[index][keyPath: key] = value
            persist(); created = ""; error = ""
        })
    }
    private func persist() { if let data = try? JSONEncoder().encode(ideas) { saved = data } }
    private func addIdea() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let idea = ResearchIdea(title: title, parent: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Projects").path)
        ideas.append(idea); selection = idea.id; draft = ""; persist()
    }
    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { ideas.first { $0.id == id }?.title ?? "" }, set: { value in
            guard let i = ideas.firstIndex(where: { $0.id == id }) else { return }
            ideas[i].title = value; persist()
        })
    }
    private func prepareProject(_ idea: ResearchIdea) {
        selection = idea.id; error = ""; created = ""
        if let index, ideas[index].folder.isEmpty {
            ideas[index].folder = idea.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
            persist()
        }
        showSetup = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Research ideas").font(.system(size: 25, weight: .medium))
            HStack(spacing: 12) {
                Image(systemName: "plus").foregroundStyle(DeskStyle.muted)
                TextField("Add a research idea…", text: $draft).textFieldStyle(.plain).onSubmit(addIdea)
                Button("Add", action: addIdea).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(12).background(DeskStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(ideas) { idea in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                Button {
                                    guard let i = ideas.firstIndex(where: { $0.id == idea.id }) else { return }
                                    ideas[i].completed = !(idea.completed ?? false); persist()
                                } label: {
                                    Image(systemName: idea.completed == true ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18)).foregroundStyle(idea.completed == true ? DeskStyle.running : DeskStyle.muted)
                                }.buttonStyle(.plain).accessibilityLabel(idea.completed == true ? "Mark incomplete" : "Mark complete")
                                TextField("Idea", text: titleBinding(idea.id)).textFieldStyle(.plain)
                                    .font(.system(size: 14)).strikethrough(idea.completed == true)
                                    .foregroundStyle(idea.completed == true ? DeskStyle.muted : DeskStyle.accent)
                                Button { selection = selection == idea.id ? nil : idea.id } label: {
                                    Image(systemName: "note.text")
                                }.help("Edit notes")
                                if let projectID = idea.projectID, let project = model.projects.first(where: { $0.id == projectID }) {
                                    Button("Open project") { model.select(project) }
                                } else {
                                    Button("Create project…") { prepareProject(idea) }
                                }
                                Menu {
                                    Button("Delete idea", role: .destructive) {
                                        ideas.removeAll { $0.id == idea.id }; if selection == idea.id { selection = nil }; persist()
                                    }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }.padding(12)
                            if selection == idea.id {
                                TextEditor(text: field(\.note))
                                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                                    .frame(minHeight: 100, idealHeight: 150).padding(12)
                                    .accessibilityLabel("Notes for " + idea.title)
                            }
                        }.background(DeskStyle.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

            }
        }.padding(28).background(DeskStyle.background).foregroundStyle(DeskStyle.accent)
            .buttonStyle(DeskButtonStyle(compact: true))
            .onAppear { ideas = (try? JSONDecoder().decode([ResearchIdea].self, from: saved)) ?? [] }
            .sheet(isPresented: $showSetup) {
                if let index {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(ideas[index].title).font(.system(size: 20, weight: .medium))
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Connection", selection: field(\.host)) {
                            Text("This Mac").tag("")
                            ForEach(hosts, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: ideas[index].host) { _, host in
                            let parent = model.projects.first { $0.host == host }.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
                            ideas[index].parent = parent ?? (host.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : "~")
                            persist()
                        }
                        HStack {
                            TextField("Parent folder", text: field(\.parent)).textFieldStyle(DeskFieldStyle())
                            if ideas[index].host.isEmpty {
                                Button("Choose…") {
                                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                                    if panel.runModal() == .OK, let path = panel.url?.path { field(\.parent).wrappedValue = path }
                                }
                            }
                        }
                        TextField("New folder name", text: field(\.folder)).textFieldStyle(DeskFieldStyle())
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Button("Create project") { create(ideas[index]) }
                                .buttonStyle(DeskButtonStyle(prominent: true)).disabled(busy || ideas[index].folder.isEmpty)
                        }
                    }.padding(16).background(DeskStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))

                        if !error.isEmpty { DeskErrorBanner(message: error, title: "Could not create project") }
                        HStack { Spacer(); Button("Cancel") { showSetup = false }.disabled(busy) }
                    }.padding(24).frame(width: 580).background(DeskStyle.surface)
                        .buttonStyle(DeskButtonStyle()).disabled(busy).interactiveDismissDisabled(busy)
                }
            }
    }
    private func create(_ idea: ResearchIdea) {
        busy = true; error = ""; created = ""
        Task {
            let result = await Task.detached { Result { try ResearchProjectSetup.create(folder: idea.folder, parent: idea.parent, host: idea.host) } }.value
            busy = false
            switch result {
            case .success(let path):
                let project = Project(name: idea.title.isEmpty ? idea.folder : idea.title, path: path, host: idea.host)
                model.projects.append(project)
                model.setNote(idea.note, for: project)
                model.select(project); model.projectTabs[project.id] = 3; model.persist()
                if let i = ideas.firstIndex(where: { $0.id == idea.id }) { ideas[i].projectID = project.id; persist() }
                showSetup = false
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
