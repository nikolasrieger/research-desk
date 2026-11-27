import SwiftUI
import CryptoKit

struct OvernightWindow {
    var start: Date
    var end: Date
    var zone: String
    func changingTimeZone(to zone: TimeZone) -> Self {
        var old = Calendar(identifier: .gregorian)
        old.timeZone = TimeZone(identifier: self.zone) ?? .current
        var new = Calendar(identifier: .gregorian); new.timeZone = zone
        func convert(_ date: Date) -> Date {
            new.date(from: old.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
        }
        return Self(start: convert(start), end: convert(end), zone: zone.identifier)
    }
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
        guard window.end > window.start, window.end > Date(), TimeZone(identifier: window.zone) != nil else {
            throw ResearchError.message("Choose a valid session window with an end later than now.")
        }
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
    @State private var editingWindow = false
    @State private var zoneSearch = ""
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

    private var selectedZone: TimeZone { TimeZone(identifier: window.zone) ?? .current }
    private var validWindow: Bool { window.end > window.start && window.end > Date() }
    private var windowTime: String {
        let format = DateFormatter(); format.timeZone = selectedZone; format.dateFormat = "HH:mm"
        return format.string(from: window.start) + " – " + format.string(from: window.end)
    }
    private var windowDate: String {
        let format = DateFormatter(); format.timeZone = selectedZone; format.dateStyle = .medium
        return format.string(from: window.start)
    }
    private var windowEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session window").font(.headline)
            DatePicker("Start", selection: $window.start, displayedComponents: [.date, .hourAndMinute])
            DatePicker("End", selection: $window.end, displayedComponents: [.date, .hourAndMinute])
            Text("Timezone · " + window.zone).font(.system(size: 11, weight: .medium))
            TextField("Find a timezone", text: $zoneSearch).textFieldStyle(DeskFieldStyle())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers.filter { zoneSearch.isEmpty || $0.localizedCaseInsensitiveContains(zoneSearch) }, id: \.self) { identifier in
                        Button {
                            if let zone = TimeZone(identifier: identifier) { window = window.changingTimeZone(to: zone) }
                        } label: {
                            HStack {
                                Text(identifier)
                                Spacer()
                                if identifier == window.zone { Image(systemName: "checkmark") }
                            }.font(.system(size: 11)).padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 160)
            if !validWindow {
                Text("Choose an end after the start and later than now.").font(.caption).foregroundStyle(.orange)
            }
            HStack { Spacer(); Button("Done") { editingWindow = false }.buttonStyle(DeskButtonStyle()) }
        }.padding(18).frame(width: 360).environment(\.timeZone, selectedZone)
            .background(DeskStyle.surface)
    }

    private func overnightMetric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DeskStyle.muted)
            Text(value).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(16).frame(height: 76)
            .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DeskStyle.edge, lineWidth: 0.5) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(.indigo.opacity(0.9))
                        .frame(width: 58, height: 58)
                        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AFTER HOURS").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2).foregroundStyle(DeskStyle.muted)
                        Text("Overnight sessions").font(.system(size: 26, weight: .semibold))
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh sessions").accessibilityLabel("Refresh sessions").disabled(model.busy)
                }.buttonStyle(DeskButtonStyle()).padding(.bottom, 8)
                HStack(spacing: 12) {
                    Button { editingWindow = true } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("WINDOW", systemImage: "moon")
                                Spacer()
                                Image(systemName: "pencil")
                            }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(DeskStyle.muted)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(windowTime).font(.system(size: 14, weight: .semibold))
                                Text(selectedZone.abbreviation(for: window.start) ?? window.zone)
                                    .font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                            }.lineLimit(1)
                        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(16).frame(height: 76)
                            .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DeskStyle.edge, lineWidth: 0.5) }
                    }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity)
                        .help("Edit session time and timezone · " + window.zone)
                        .popover(isPresented: $editingWindow) { windowEditor }
                    overnightMetric("WORKER", value: project.isRemote ? project.host : "This Mac", symbol: "desktopcomputer")
                    overnightMetric("DAILY BUDGET", value: "14.29 points", symbol: "gauge.with.dots.needle.33percent")
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Plan your night").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(windowDate)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DeskStyle.muted)
                    }
                    DeskEyebrow(title: "Research goal")
                    DeskChoiceMenu(title: goal.rawValue, choices: OvernightGoal.allCases.map(\.rawValue), selection: goal.rawValue) {
                        if let value = OvernightGoal(rawValue: $0) { goal = value }
                    }
                    Text(goal.detail).font(.callout).foregroundStyle(DeskStyle.muted)
                    TextField("Additional instructions or questions to investigate", text: $instructions, axis: .vertical)
                        .lineLimit(3...8).textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DeskStyle.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DeskStyle.edge, lineWidth: 1) }
                    DeskEyebrow(title: "Model")
                    DeskChoiceMenu(title: selectedModel.capitalized, choices: ["Sonnet", "Opus", "Haiku"], selection: selectedModel.capitalized) {
                        selectedModel = $0.lowercased()
                    }
                    Button("Arm this night", systemImage: "moon.stars") {
                        // Only this explicit action installs and starts a detached, one-shot worker.
                        let captured = window
                        Task { await model.launch(goal: goal, instructions: instructions, model: selectedModel, window: captured) }
                    }.buttonStyle(DeskButtonStyle(prominent: true))
                        .disabled(model.busy || !validWindow || model.jobs.contains(where: \.active) || (goal == .custom && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }.padding(20)
                    .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DeskStyle.edge, lineWidth: 1) }
                if !model.error.isEmpty { DeskErrorBanner(message: model.error, title: "Overnight session needs attention", onDismiss: { model.error = "" }) }
                HStack {
                    Text("Session journal").font(.system(size: 17, weight: .semibold))
                    Text("\(model.jobs.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DeskStyle.muted)
                    Spacer()
                }.padding(.top, 10)
                if model.jobs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.zzz").font(.system(size: 26, weight: .light))
                        Text("Quiet night so far").font(.system(size: 13, weight: .medium))
                    }.foregroundStyle(DeskStyle.muted).frame(maxWidth: .infinity).padding(30)
                        .background(DeskStyle.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                }
                ForEach(model.jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(job.goal.components(separatedBy: ":").first ?? job.goal).font(.system(size: 13, weight: .bold, design: .monospaced))
                            Spacer()
                            Label(job.status.capitalized, systemImage: job.active ? "circle.fill" : "circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(job.status == "blocked" ? Color.orange : job.active ? DeskStyle.running : DeskStyle.muted)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(DeskStyle.raised, in: Capsule())
                            if job.active { Button("Cancel") { Task { await model.cancel(job) } } }
                            Button("View report") { Task { await model.openReport(job) } }
                        }.buttonStyle(DeskButtonStyle(compact: true)).disabled(model.busy)
                        if job.status == "blocked" { DeskErrorBanner(message: job.message, title: "Overnight session blocked") }
                        else { Text(job.message).font(.caption).textSelection(.enabled) }
                        Text(jobTime(job)).font(.caption).foregroundStyle(DeskStyle.muted)
                        if job.used != nil { Text(quotaSummary(job)).font(.caption.monospaced()).foregroundStyle(DeskStyle.muted) }

                        HStack(spacing: 14) {
                            if let batches = job.batches { Label("\(batches) batches", systemImage: "square.stack.3d.up") }
                            if let spent = job.spent { Label(String(format: "%.1f points used", spent), systemImage: "gauge.with.dots.needle.33percent") }
                        }.font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                        DisclosureGroup("Report location") {
                            Text(job.folder).font(.caption2.monospaced()).foregroundStyle(DeskStyle.muted).textSelection(.enabled)
                        }.font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                    }.padding(18).background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(DeskStyle.edge, lineWidth: 1) }
                }
                if !model.report.isEmpty {
                    HStack { DeskEyebrow(title: "Report"); Spacer(); Button("Close") { model.report = "" }.buttonStyle(DeskButtonStyle(compact: true)) }
                    MarkdownPreview(source: model.report, rendersTables: true).frame(minHeight: 450)
                }
            }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.background(DeskStyle.background)
            .task {
                await model.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    await model.refresh()
                }
            }
    }
}
