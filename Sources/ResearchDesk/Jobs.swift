import SwiftUI
import AppKit

struct JobHostSnapshot: Codable, Sendable {
    var host: String
    var jobs: [DeskJob] = []
    var checked: Date?
    var error = ""
}

@MainActor final class JobsModel: ObservableObject {
    @Published var snapshots: [String: JobHostSnapshot] = [:]
    @Published private(set) var hiddenJobs: Set<String> = []
    @Published var refreshing = false
    @Published var error = ""
    private var generation = UUID()
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private let cacheURL: URL
    init(cacheURL: URL = WorkspaceStorage.fileURL.deletingLastPathComponent().appendingPathComponent("jobs-cache.json")) {
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([String: JobHostSnapshot].self, from: data) { snapshots = saved }
        if let data = try? Data(contentsOf: hiddenURL), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { hiddenJobs = saved }
    }
    private var hiddenURL: URL { cacheURL.deletingPathExtension().appendingPathExtension("hidden.json") }
    func isHidden(_ job: DeskJob, host: String, now: Date = Date()) -> Bool {
        hiddenJobs.contains(host + ":" + job.id) || job.submitted < now.timeIntervalSince1970 - 3 * 24 * 60 * 60
    }
    func hide(_ job: DeskJob, host: String) {
        var updated = hiddenJobs
        updated.insert(host + ":" + job.id)
        saveHidden(updated)
    }
    func restoreHidden() { saveHidden([]) }
    private func saveHidden(_ updated: Set<String>) {
        do {
            try FileManager.default.createDirectory(at: hiddenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: hiddenURL, options: .atomic)
            hiddenJobs = updated
        } catch { self.error = "Could not save hidden jobs: " + error.localizedDescription }
    }
    func activate() -> UUID { generation = UUID(); return generation }
    func deactivate() { generation = UUID(); refreshing = false }
    func refresh(hosts: [String], token: UUID, project: String? = nil, force: Bool = false) async {
        guard token == generation, !refreshing, !Task.isCancelled else { return }
        refreshing = true
        let now = Date()
        let due = Array(Set(hosts)).sorted().filter { force || (retryAfter[$0] ?? .distantPast) <= now }
        // Bound concurrent SSH connections for desks with many hosts.
        for start in stride(from: 0, to: due.count, by: 4) {
            guard token == generation, !Task.isCancelled else { return }
            let batch = Array(due[start..<min(start + 4, due.count)])
            let results = await withTaskGroup(of: JobHostSnapshot.self) { group in
                for host in batch {
                    group.addTask {
                        await Task.detached {
                            do { return JobHostSnapshot(host: host, jobs: try JobsBackend.list(host: host, project: project), checked: Date()) }
                            catch { return JobHostSnapshot(host: host, error: error.localizedDescription) }
                        }.value
                    }
                }
                var results: [JobHostSnapshot] = []
                for await result in group { results.append(result) }
                return results
            }
            guard token == generation, !Task.isCancelled else { return }
            for result in results {
                if result.error.isEmpty {
                    StatisticsStore.shared.ingest(result.jobs, host: result.host)
                    snapshots[result.host] = result; failures[result.host] = 0; retryAfter[result.host] = nil
                } else {
                    var previous = snapshots[result.host] ?? JobHostSnapshot(host: result.host)
                    previous.error = result.error; snapshots[result.host] = previous
                    let count = min(5, (failures[result.host] ?? 0) + 1)
                    failures[result.host] = count
                    retryAfter[result.host] = Date().addingTimeInterval(min(300, 10 * pow(2, Double(count))))
                }
            }
        }
        refreshing = false
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshots).write(to: cacheURL, options: .atomic)
        } catch { self.error = "Could not cache jobs: " + error.localizedDescription }
    }
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let value = max(0, Int(seconds))
        return value >= 86400 ? "\(value / 86400)d \(value % 86400 / 3600)h" : String(format: "%02d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60)
    }
}

struct JobsPane: View {
    let project: Project
    @StateObject private var model: JobsModel
    init(project: Project) {
        self.project = project
        let cache = WorkspaceStorage.fileURL.deletingLastPathComponent()
            .appendingPathComponent("jobs-" + OvernightBackend.key(project) + ".json")
        _model = StateObject(wrappedValue: JobsModel(cacheURL: cache))
    }
    @State private var token = UUID()
    @State private var adding = false
    @State private var selected: String?
    @State private var log = ""
    @State private var logError = ""
    @State private var logOffset = -1
    @State private var logInode = ""
    @State private var loadingLog = false
    @State private var search = ""
    @State private var showSearch = false
    private var hosts: [String] { [project.host] }
    private var selection: (host: String, job: DeskJob)? {
        for host in hosts {
            if let job = model.snapshots[host]?.jobs.first(where: { host + ":" + $0.id == selected && JobsBackend.matches($0, project: project.path) }) { return (host, job) }
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(model.snapshots[project.host]?.error.isEmpty == false ? DeskStyle.highlight : model.snapshots[project.host]?.checked == nil ? DeskStyle.muted : DeskStyle.running.opacity(0.7))
                    .frame(width: 5, height: 5)
                Text(project.isRemote ? project.host : "This Mac")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(DeskStyle.muted)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(hosts: hosts, token: token, project: project.path, force: true) }
                    }.disabled(model.refreshing)
                    Button(showSearch ? "Hide filter" : "Filter jobs", systemImage: "line.3.horizontal.decrease") {
                        showSearch.toggle(); if !showSearch { search = "" }
                    }
                    if !model.hiddenJobs.isEmpty {
                        Button("Restore hidden jobs (\(model.hiddenJobs.count))", systemImage: "eye") { model.restoreHidden() }
                    }
                    Divider()
                    Button("Copy agent instructions", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(JobsInstructions.text + "\nCurrent workspace root: " + project.path + "\nUse this exact root in the project field, even when the command runs in a subdirectory.", forType: .string)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Job options").accessibilityLabel("Job options")
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(DeskStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).foregroundStyle(DeskStyle.accent)
                    .help("Add job").accessibilityLabel("Add job")
            }.padding(.horizontal, 4)
                .help("Refreshes every 10 seconds while this tab is open. No background polling or LLM calls.")
            if showSearch {
                TextField("Filter jobs", text: $search).textFieldStyle(DeskFieldStyle())
            }
            if !model.error.isEmpty { DeskErrorBanner(message: model.error, title: "Jobs", onDismiss: { model.error = "" }) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(hosts, id: \.self) { host in hostSection(host) }
                }.padding(.trailing, 8)
            }
        }.padding(4).background(DeskStyle.background)
        .sheet(isPresented: $adding) {
            AddJobPane(projects: [project]) { host in
                Task { await model.refresh(hosts: [host], token: token, project: project.path, force: true) }
            }
        }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selection {
                detail(selection.job, host: selection.host)
                    .frame(minWidth: 600, minHeight: 480)
                    .padding(16)
            }
        }
        .task(id: project) {
            token = model.activate()
            while !Task.isCancelled {
                await model.refresh(hosts: hosts, token: token, project: project.path)
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .onDisappear { model.deactivate() }
        .task(id: selected) {
            log = ""; logError = ""; logOffset = -1; logInode = ""
            guard let selection, selection.job.log != nil else { return }
            let key = selected
            while !Task.isCancelled {
                loadingLog = true
                let host = selection.host, id = selection.job.id, offset = logOffset, inode = logInode
                let result = await Task.detached { Result { try JobsBackend.log(host: host, id: id, offset: offset, inode: inode) } }.value
                guard !Task.isCancelled, key == selected else { return }
                loadingLog = false
                switch result {
                case .success(let chunk):
                    log = String((chunk.reset ? chunk.text : log + chunk.text).suffix(65536))
                    logOffset = chunk.offset; logInode = chunk.inode; logError = ""
                case .failure(let error): logError = error.localizedDescription
                }
                if model.snapshots[host]?.jobs.first(where: { $0.id == id })?.terminal == true { break }
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }
    private func hostSection(_ host: String) -> some View {
        let snapshot = model.snapshots[host]
        let jobs = (snapshot?.jobs ?? []).filter { JobsBackend.matches($0, project: project.path) && !model.isHidden($0, host: host) }.filter { search.isEmpty || ($0.name + " " + $0.status).localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 4) {
            if let error = snapshot?.error, !error.isEmpty {
                DisclosureGroup {
                    Text(error).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DeskStyle.muted).textSelection(.enabled).padding(.top, 6)
                } label: {
                    Label("Offline · cached results", systemImage: "wifi.slash")
                        .font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                }.padding(10).background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            if jobs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: search.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 25, weight: .ultraLight)).foregroundStyle(DeskStyle.muted.opacity(0.5))
                    Text(search.isEmpty ? "A little breathing room." : "No matches")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(DeskStyle.accent.opacity(0.8))
                    Text(search.isEmpty ? "Your project’s jobs will appear here." : "Try another name or status.")
                        .font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 64)
            }
            ForEach(jobs) { job in
                MinimalJobRow(job: job, cached: snapshot?.error.isEmpty == false, checked: snapshot?.checked) {
                    selected = host + ":" + job.id
                }
                .contextMenu {
                    Button("Hide from view", systemImage: "eye.slash") {
                        model.hide(job, host: host)
                        if selected == host + ":" + job.id { selected = nil }
                    }
                }
            }
            if let date = snapshot?.checked, !jobs.isEmpty {
                Text("Updated " + date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(DeskStyle.muted.opacity(0.65))
                    .padding(.horizontal, 10).padding(.top, 12)
            }
        }
    }
    private func detail(_ job: DeskJob, host: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job.name).font(.headline)
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(DeskButtonStyle(compact: true))
            }
            Text(job.message ?? job.status).font(.caption).foregroundStyle(DeskStyle.muted).textSelection(.enabled)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 7) {
                    if let command = job.command { Text(command).font(.caption.monospaced()).textSelection(.enabled) }
                    if let scheduled = job.scheduled { Text("Scheduled · " + Date(timeIntervalSince1970: scheduled).formatted()) }
                    if let started = job.started { Text("Started · " + Date(timeIntervalSince1970: started).formatted()) }
                    if let ended = job.ended { Text("Ended · " + Date(timeIntervalSince1970: ended).formatted()) }
                    if let code = job.exitCode { Text("Exit · \(code)") }
                    if let conversation = job.conversation { Text("Conversation · " + conversation).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(DeskStyle.muted).padding(.vertical, 8)
            }.font(.caption).foregroundStyle(DeskStyle.muted)
            Divider()
            HStack {
                Text("Log · latest 64 KB").font(.caption)
                Spacer()
                if loadingLog { ProgressView().controlSize(.small) }
            }
            if let path = job.log { Text(path).font(.caption).foregroundStyle(DeskStyle.muted).textSelection(.enabled) }
            if !logError.isEmpty { Text(logError).font(.caption).foregroundStyle(DeskStyle.highlight) }
            ScrollView([.vertical, .horizontal]) {
                Text(job.log == nil ? "No log path registered" : log.isEmpty ? "No output yet" : log)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }.padding(14).background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MinimalJobRow: View {
    let job: DeskJob
    let cached: Bool
    let checked: Date?
    let open: () -> Void
    @State private var hovered = false
    private var tint: Color {
        if cached { return DeskStyle.muted }
        switch job.status {
        case "running": return DeskStyle.running
        case "succeeded": return DeskStyle.running.opacity(0.6)
        case "failed": return DeskStyle.highlight
        default: return DeskStyle.muted
        }
    }
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskStyle.accent).lineLimit(1)
                    Text((cached ? "Cached · " : "") + job.status.capitalized + (job.schedulerID.map { " · " + $0 } ?? ""))
                        .font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(JobsModel.duration(job.elapsed(now: cached ? checked ?? context.date : context.date)))
                        .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(DeskStyle.muted).padding(.top, 2)
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium))
                    .foregroundStyle(DeskStyle.muted).opacity(hovered ? 1 : 0).padding(.top, 4)
            }.padding(.horizontal, 10).padding(.vertical, 12)
                .background(hovered ? DeskStyle.raised : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(job.name + ", " + job.status + (cached ? ", cached" : ""))
    }
}

struct AddJobPane: View {
    let projects: [Project]
    let added: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var kind = "shell"
    @State private var name = ""
    @State private var value = ""
    @State private var log = ""
    @State private var schedule = false
    @State private var date = Date().addingTimeInterval(60)
    @State private var busy = false
    @State private var error = ""
    private var project: Project? { projects.first { $0.id == projectID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add job").font(.title2)
            if projects.count > 1 {
                Picker("Workspace", selection: $projectID) {
                    Text("Choose workspace").tag(nil as UUID?)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
            } else if let project = projects.first {
                Text(project.name + " · " + (project.isRemote ? project.host : "This Mac"))
                    .font(.caption).foregroundStyle(DeskStyle.muted)
            }
            Picker("Track", selection: $kind) {
                Text("Launch shell command").tag("shell")
                Text("Existing process").tag("process")
                Text("Slurm job").tag("slurm")
            }
            TextField("Job name / purpose", text: $name)
            if kind == "shell" {
                Text("Runs on the workspace host, independently of the app. Use Slurm for compute work on a cluster.").font(.caption).foregroundStyle(DeskStyle.muted)
                TextEditor(text: $value).font(.system(size: 12, design: .monospaced)).frame(height: 100)
                Toggle("Schedule a start time", isOn: $schedule)
                if schedule { DatePicker("Start", selection: $date, in: Date()...) }
            } else {
                TextField(kind == "process" ? "PID on workspace host" : "Slurm job ID (or individual array task ID)", text: $value)
            }
            TextField(kind == "shell" ? "Log path (optional; generated by default)" : "Log path (optional)", text: $log)
            if kind == "process" { Text("An adopted process can be verified while running. Its outcome is unknown after exit unless an exit-status file is registered through the agent protocol.").font(.caption).foregroundStyle(DeskStyle.muted) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(DeskStyle.highlight) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button(busy ? "Adding…" : kind == "shell" ? "Launch job" : "Register job") { add() }
                    .disabled(busy || project == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(DeskButtonStyle())
        }.padding(22).frame(width: 620).background(DeskStyle.background)
            .onAppear { projectID = projects.first?.id }
            .onChange(of: kind) { _, _ in value = ""; error = "" }
    }
    private func add() {
        guard let project, !busy else { return }
        busy = true; error = ""
        let name = name, kind = kind, value = value.trimmingCharacters(in: .whitespacesAndNewlines), log = log, scheduled = schedule ? date : nil
        Task {
            let result = await Task.detached { Result { try JobsBackend.add(project: project, name: name, kind: kind, value: value, log: log, scheduled: scheduled) } }.value
            busy = false
            switch result {
            case .success: added(project.host); dismiss()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

enum JobsInstructions {
    static let text = #"""
For every long-running or scheduled job, register a JSON record on the machine that owns the process or scheduler, under ~/.local/state/researchdesk/jobs/<id>.json. Research Desk reads these records without LLM calls. Do not claim a job completed without an exit code or scheduler result.

When known, add usesGPU=true for a GPU job or usesGPU=false for a CPU-only job. Leave it absent if uncertain; statistics will keep it unclassified. This field records resource type, not utilization. Set project to the workspace root rather than a command's subdirectory.

Schema v1: {"version":1,"id":"<uuid>","name":"<purpose>","project":"<absolute workspace root>","kind":"process","submitted":<Unix seconds>,"status":"unknown","pid":<integer>,"processStart":"<exact trimmed output of ps -p PID -o lstart=>","started":<Unix seconds if known>,"log":"<absolute log path>","conversation":"<agent + session ID>"}.
Use kind="slurm" and schedulerID="<job ID or individual array task ID>" instead of pid/processStart for Slurm. Register on the login host where squeue/sacct can see that job. Use one record per individual array task, not an array-range expression. For a scheduled job, use status="queued" and scheduled=<Unix start time>, then update pid and processStart when it actually launches. Registering a record does not schedule or launch the command: use the existing scheduler, or Research Desk's Launch job UI.

For ordinary shell jobs, a shell wrapper may write an exit file after the command finishes: {"exitCode":0,"ended":<Unix seconds>}. Add exitFile="<absolute exit JSON path>" to the job record. Research Desk will read it to resolve the outcome. Capture the actual command's exit code, not the wrapper's final echo/write command. Without an exit file, an absent PID is shown as unknown, never as successful. Job records must use absolute paths, stable IDs matching their filename, atomic writes (temporary file + rename), and must not exceed 64 KB. Do not place credentials in job metadata or logs.
"""#
}
