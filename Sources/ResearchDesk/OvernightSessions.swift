import SwiftUI
import CryptoKit

struct OvernightWindow {
    let start: Date
    let end: Date
    let zone: String
    static func next(now: Date = Date(), timeZone: TimeZone = .current) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var day = calendar.startOfDay(for: now)
        var start = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: day)!
        var end = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day)!
        if now >= end {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            start = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: day)!
            end = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day)!
        }
        return Self(start: start, end: end, zone: timeZone.identifier)
    }
}

enum OvernightGoal: String, CaseIterable, Identifiable {
    case audit = "Evaluation audit"
    case experiments = "Experiment analysis"
    case research = "Research scout"
    case maintenance = "Maintenance proposals"
    case librarian = "Project librarian"
    case custom = "Custom goal"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .audit: return "Review evaluation code, splits, leakage risks and metric calculations. Report evidence and reproducibility gaps."
        case .experiments: return "Review existing experiment outputs and logs. Compare results, identify failed runs, and propose next experiments."
        case .research: return "Find relevant papers and primary sources for this project. Produce a cited digest and concrete experiment ideas."
        case .maintenance: return "Inspect code for bugs and missing tests. Propose small patches and validation steps for review."
        case .librarian: return "Review project documentation and saved notes. Consolidate decisions, unresolved questions, and next steps."
        case .custom: return "Work toward the goal described in your instructions and report useful findings."
        }
    }
}

struct OvernightJob: Decodable, Identifiable, Sendable {
    let id: String
    let goal: String
    let status: String
    let message: String
    let start: Double
    let end: Double
    let zone: String
    let folder: String
    let updated: Double?
    let used: Double?
    let spent: Double?
    let ceiling: Double?
    let stopAt: Double?
    let batches: Int?
    var active: Bool { ["queued", "running", "waiting"].contains(status) && end > Date().timeIntervalSince1970 }
}

enum OvernightBackend {
    static func key(_ project: Project) -> String {
        SHA256.hash(data: Data((project.host + ":" + project.path).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func invoke(_ project: Project, code: String, arguments: [String] = []) throws -> String {
        let command = "python3 -c " + Command.shellQuote(code) + " " + arguments.map(Command.shellQuote).joined(separator: " ")
        let result = project.isRemote ? Command.ssh(project.host, command, maxOutput: 200_000, timeout: 40) : Command.run("/bin/zsh", ["-lc", command], timeout: 40, maxOutput: 200_000)
        guard result.2 == 0 else { throw ResearchError.message(result.1.isEmpty ? "The overnight worker could not be reached." : result.1) }
        return result.0
    }
    static func launch(_ project: Project, goal: OvernightGoal, instructions: String, model: String, window: OvernightWindow) throws -> OvernightJob {
        let config: [String: Any] = ["id": UUID().uuidString.lowercased(), "key": key(project), "project": project.path,
                                   "goal": goal.rawValue + ": " + goal.detail, "instructions": instructions,
                                   "model": model, "start": window.start.timeIntervalSince1970, "end": window.end.timeIntervalSince1970,
                                   "zone": window.zone, "submitted": Date().timeIntervalSince1970]
        let data = try JSONSerialization.data(withJSONObject: config)
        let source = OvernightWorker.source.data(using: .utf8)!.base64EncodedString()
        let bootstrap = "import base64; SOURCE=base64.b64decode('" + source + "').decode(); exec(compile(SOURCE, '<overnight-worker>', 'exec'))"
        let output = try invoke(project, code: bootstrap, arguments: ["launch", String(decoding: data, as: UTF8.self)])
        return try JSONDecoder().decode(OvernightJob.self, from: Data(output.utf8))
    }
    static let statusScript = #"""
import pathlib,sys,json,time
root=pathlib.Path.home()/'.local/state/researchdesk/overnight'/sys.argv[1]
result=[]
for path in sorted(root.glob('*/status.json'),key=lambda p:p.stat().st_mtime,reverse=True)[:20]:
    try:
        item=json.loads(path.read_text())
        if len(sys.argv)>2 and item['id']==sys.argv[2]:
            (path.parent/'cancel').touch()
            if item.get('status') in ('queued','running','waiting'):
                item['message']='Cancellation requested. The worker will stop within a few seconds.'
                item['status']='cancelled'
                temp=path.with_suffix('.cancelled')
                temp.write_text(json.dumps(item)); temp.replace(path)
        result.append(item)
    except (ValueError,OSError,KeyError): pass
print(json.dumps(result))
"""#
    static func jobs(_ project: Project, cancel: String? = nil) throws -> [OvernightJob] {
        var args = [key(project)]
        if let cancel { guard UUID(uuidString: cancel) != nil else { throw ResearchError.message("Invalid overnight job.") }; args.append(cancel) }
        return try JSONDecoder().decode([OvernightJob].self, from: Data(invoke(project, code: statusScript, arguments: args).utf8))
    }
    static func report(_ project: Project, job: OvernightJob) throws -> String {
        let script = #"""
import pathlib,sys
root=pathlib.Path.home()/'.local/state/researchdesk/overnight'/sys.argv[1]/sys.argv[2]
files=sorted(root.glob('report-*.md'))[-10:]
print('\n\n---\n\n'.join('## '+p.stem+'\n\n'+p.read_text()[:30000] for p in files)[:60000] or 'No report has been saved yet.')
"""#
        guard UUID(uuidString: job.id) != nil else { throw ResearchError.message("Invalid overnight job.") }
        return try invoke(project, code: script, arguments: [key(project), job.id])
    }
}

@MainActor final class OvernightSessionsModel: ObservableObject {
    let project: Project
    @Published var jobs: [OvernightJob] = []
    @Published var busy = false
    @Published var error = ""
    @Published var report = ""
    init(project: Project) { self.project = project }
    func refresh() async {
        guard !busy else { return }
        busy = true
        let project = project
        let result = await Task.detached { Result { try OvernightBackend.jobs(project) } }.value
        switch result { case .success(let jobs): self.jobs = jobs; case .failure(let error): self.error = error.localizedDescription }
        busy = false
    }
    func launch(goal: OvernightGoal, instructions: String, model: String, window: OvernightWindow) async {
        guard !busy else { return }
        busy = true; error = ""
        let project = project
        let result = await Task.detached { Result { try OvernightBackend.launch(project, goal: goal, instructions: instructions, model: model, window: window) } }.value
        switch result { case .success(let job): jobs.insert(job, at: 0); case .failure(let error): self.error = error.localizedDescription }
        busy = false
    }
    func cancel(_ job: OvernightJob) async {
        guard !busy else { return }
        busy = true; let project = project
        let result = await Task.detached { Result { try OvernightBackend.jobs(project, cancel: job.id) } }.value
        switch result { case .success(let jobs): self.jobs = jobs; case .failure(let error): self.error = error.localizedDescription }
        busy = false
    }
    func openReport(_ job: OvernightJob) async {
        guard !busy else { return }
        busy = true; let project = project
        let result = await Task.detached { Result { try OvernightBackend.report(project, job: job) } }.value
        switch result { case .success(let text): report = text; case .failure(let error): self.error = error.localizedDescription }
        busy = false
    }
}

struct OvernightSessionsPane: View {
    let project: Project
    @StateObject private var model: OvernightSessionsModel
    @State private var goal: OvernightGoal = .audit
    @State private var instructions = ""
    @State private var selectedModel = "sonnet"
    @State private var window = OvernightWindow.next()
    init(project: Project) { self.project = project; _model = StateObject(wrappedValue: OvernightSessionsModel(project: project)) }
    private func jobTime(_ job: OvernightJob) -> String {
        let format = DateFormatter()
        format.timeZone = TimeZone(identifier: job.zone)
        format.dateStyle = .medium
        format.timeStyle = .short
        return format.string(from: Date(timeIntervalSince1970: job.start)) + " – " + format.string(from: Date(timeIntervalSince1970: job.end)) + " · " + job.zone
    }
    private func quotaSummary(_ job: OvernightJob) -> String {
        var text = "Weekly used: " + String(format: "%.1f", job.used ?? 0) + "%"
        if let stop = job.stopAt { text += " · Stop at " + String(format: "%.1f", stop) + "%" }
        if let spent = job.spent { text += " · Since start " + String(format: "%.1f", spent) + " points" }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Overnight sessions").font(.system(size: 23, weight: .light))
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
                }.buttonStyle(DeskButtonStyle())
                Text("Arm one night at a time. Nothing runs until you click the button below.").foregroundStyle(DeskStyle.muted)
                Picker("Goal", selection: $goal) { ForEach(OvernightGoal.allCases) { Text($0.rawValue).tag($0) } }
                Text(goal.detail).font(.callout).foregroundStyle(DeskStyle.muted)
                TextField("Additional instructions or questions to investigate", text: $instructions, axis: .vertical)
                    .lineLimit(3...8).textFieldStyle(DeskFieldStyle())
                Picker("Model", selection: $selectedModel) {
                    Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("Haiku").tag("haiku")
                }.frame(maxWidth: 280)
                VStack(alignment: .leading, spacing: 7) {
                    Label("1–7 a.m. · " + window.zone, systemImage: "moon")
                    Text(window.start.formatted(date: .abbreviated, time: .shortened) + " – " + window.end.formatted(date: .abbreviated, time: .shortened))
                    Text("Runs on " + (project.isRemote ? project.host : "this Mac") + ". The window is saved as absolute times; the machine's timezone does not change it.")
                    Text("Requires Python 3 and Claude Code signed in with a subscription on that machine.")
                    Text("Budget: 14.29 percentage points of weekly usage per day, paced from the weekly reset and including usage already spent. Stops 1 point early; small batches and minute-by-minute checks limit overshoot. Exact enforcement is not supported by Claude's delayed usage meter.")
                    Text("Produces Markdown reports using read/search tools. Project files are not edited. Session limits pause work; missing quota data blocks it. One worker per machine account can run at a time.")
                    if !project.isRemote { Text("This Mac must stay on and awake during the window.").foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(DeskStyle.muted).padding(14).background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                Button("Arm this night", systemImage: "moon.stars") {
                    // Only this explicit action installs and starts a detached, one-shot worker.
                    let captured = OvernightWindow.next()
                    window = captured
                    Task { await model.launch(goal: goal, instructions: instructions, model: selectedModel, window: captured) }
                }.buttonStyle(DeskButtonStyle(prominent: true))
                    .disabled(model.busy || model.jobs.contains(where: \.active) || (goal == .custom && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if !model.error.isEmpty { DeskErrorBanner(message: model.error, title: "Overnight session needs attention", onDismiss: { model.error = "" }) }
                Divider()
                ForEach(model.jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(job.goal.components(separatedBy: ":").first ?? job.goal).fontWeight(.medium)
                            Spacer()
                            Text(job.status.capitalized).foregroundStyle(job.status == "blocked" ? Color.orange : DeskStyle.muted)
                            if job.active { Button("Cancel") { Task { await model.cancel(job) } } }
                            Button("View report") { Task { await model.openReport(job) } }
                        }.buttonStyle(DeskButtonStyle(compact: true)).disabled(model.busy)
                        if job.status == "blocked" { DeskErrorBanner(message: job.message, title: "Overnight session blocked") }
                        else { Text(job.message).font(.caption).textSelection(.enabled) }
                        Text(jobTime(job)).font(.caption).foregroundStyle(DeskStyle.muted)
                        if job.used != nil { Text(quotaSummary(job)).font(.caption.monospaced()).foregroundStyle(DeskStyle.muted) }

                        Text(job.folder).font(.caption2.monospaced()).foregroundStyle(DeskStyle.muted).textSelection(.enabled)
                    }.padding(14).background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                if !model.report.isEmpty {
                    HStack { Text("Report").font(.headline); Spacer(); Button("Close") { model.report = "" } }
                    MarkdownPreview(source: model.report, rendersTables: true).frame(minHeight: 450)
                }
            }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.background(DeskStyle.background)
            .task {
                window = OvernightWindow.next()
                await model.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    await model.refresh()
                }
            }
    }
}
