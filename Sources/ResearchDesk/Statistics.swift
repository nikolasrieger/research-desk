import SwiftUI
import AppKit

struct StatisticsProject: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var host: String
    var path: String
    init(_ project: Project) {
        id = Self.key(host: project.host, path: project.path)
        name = project.name; host = project.host; path = project.path
    }
    static func key(host: String, path: String) -> String { host + ":" + (path as NSString).standardizingPath }
}

struct StatisticsJob: Codable, Equatable, Sendable {
    var project: String
    var submitted: Double
    var started: Double?
    var end: Double?
    var seconds: Double?
    var usesGPU: Bool?
}

struct StatisticsState: Codable, Sendable {
    var projects: [String: StatisticsProject] = [:]
    var selectedSeconds: [String: [String: Double]] = [:]
    var jobs: [String: StatisticsJob] = [:]
    var tokenDays: [String: [String: Int64]]? = nil
}

struct StatisticsDay: Identifiable, Sendable {
    var id: String
    var date: Date
    var jobs = 0
    var tokens: Int64 = 0
    var selectedSeconds = 0.0
    var gpuSeconds = 0.0
    var cpuSeconds = 0.0
    var unknownSeconds = 0.0
    var computeSeconds: Double { gpuSeconds + cpuSeconds + unknownSeconds }
}

@MainActor final class StatisticsStore: ObservableObject {
    static let shared = StatisticsStore()
    @Published private(set) var revision = 0
    @Published var error = ""
    private(set) var state = StatisticsState()
    private let url: URL
    private let writer = DispatchQueue(label: "researchdesk.statistics.persistence", qos: .utility)
    private var timer: Timer?
    private var active: StatisticsProject?
    private var started: Date?
    private var dirty = false
    init(url: URL = WorkspaceStorage.fileURL.deletingLastPathComponent().appendingPathComponent("statistics.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode(StatisticsState.self, from: data) { state = loaded }
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpoint() }
        }
        timer?.tolerance = 10
    }
    func select(_ project: Project?, now: Date = Date()) {
        let next = project.map(StatisticsProject.init)
        if next?.id == active?.id { return }
        checkpoint(now: now)
        active = next; started = next == nil ? nil : now
        if let next { state.projects[next.id] = next; dirty = true }
    }
    func checkpoint(now: Date = Date()) {
        if let active, let started, now > started {
            Self.split(start: started, end: now) { day, seconds in
                state.selectedSeconds[active.id, default: [:]][day, default: 0] += seconds
            }
            self.started = now; dirty = true
        }
        guard dirty else { return }
        revision += 1; dirty = false
        let snapshot = state, url = url
        writer.async { [weak self] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.error = "Could not save statistics: " + message }
            }
        }
    }
    func finish(now: Date = Date()) {
        select(nil, now: now); checkpoint(now: now)
        writer.sync {} // Drain the small final checkpoint before application termination.
        timer?.invalidate(); timer = nil
    }
    func register(_ projects: [Project]) {
        for project in projects {
            let item = StatisticsProject(project)
            state.projects[item.id] = item
        }
        dirty = true
    }
    func ingest(_ jobs: [DeskJob], host: String, now: Date = Date()) {
        for job in jobs {
            let key = StatisticsProject.key(host: host, path: job.project)
            if state.projects[key] == nil {
                state.projects[key] = StatisticsProject(Project(name: URL(fileURLWithPath: job.project).lastPathComponent, path: job.project, host: host))
            }
            let id = host + ":" + job.id
            let verified = job.status == "running" || job.ended != nil
            let seconds = job.runtime ?? (verified ? job.started.map { max(0, (job.ended ?? job.checked ?? now.timeIntervalSince1970) - $0) } : state.jobs[id]?.seconds)
            let observedEnd = verified || job.runtime != nil ? job.ended ?? job.checked ?? now.timeIntervalSince1970 : state.jobs[id]?.end ?? job.started
            let sample = StatisticsJob(project: key, submitted: min(job.submitted, state.jobs[id]?.submitted ?? job.submitted), started: job.started,
                end: job.started == nil ? nil : observedEnd, seconds: seconds,
                usesGPU: job.usesGPU ?? state.jobs[id]?.usesGPU)
            if state.jobs[id] != sample { state.jobs[id] = sample; dirty = true }
        }
    }
    func ingestTokens(_ totals: [String: [String: Int64]], host: String) {
        var values = state.tokenDays ?? [:]
        let projects = state.projects.values.filter { $0.host == host }.sorted { $0.path.count > $1.path.count }
        for project in projects { values[project.id] = [:] }
        for (path, days) in totals {
            let normalized = (path as NSString).standardizingPath
            guard let owner = projects.first(where: {
                let root = ($0.path as NSString).standardizingPath
                return normalized == root || normalized.hasPrefix(root == "/" ? root : root + "/")
            }) else { continue }
            for (day, count) in days { values[owner.id, default: [:]][day, default: 0] += count }
        }
        state.tokenDays = values
        dirty = true
    }
    func tokens(year: Int, project: String?) -> Int64 {
        (state.tokenDays ?? [:]).filter { project == nil || $0.key == project }.values.reduce(0) { sum, days in
            sum + days.filter { $0.key.hasPrefix(String(year) + "-") }.values.reduce(0, +)
        }
    }
    var projects: [StatisticsProject] { state.projects.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    nonisolated static func split(start: Date, end: Date, calendar: Calendar = .current, apply: (String, Double) -> Void) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) else { break }
            let stop = min(next, end)
            apply(dayKey(cursor, calendar: calendar), stop.timeIntervalSince(cursor))
            cursor = stop
        }
    }
    func days(year: Int, project: String?, now: Date = Date(), calendar: Calendar = .current) -> [StatisticsDay] {
        guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let last = calendar.date(byAdding: .year, value: 1, to: first) else { return [] }
        var values: [String: StatisticsDay] = [:]
        var cursor = first
        while cursor < last {
            let key = Self.dayKey(cursor, calendar: calendar)
            values[key] = StatisticsDay(id: key, date: cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        for (key, totals) in state.selectedSeconds where project == nil || project == key {
            for (day, seconds) in totals where values[day] != nil { values[day]?.selectedSeconds += seconds }
        }
        for (key, totals) in state.tokenDays ?? [:] where project == nil || project == key {
            for (day, tokens) in totals where values[day] != nil { values[day]?.tokens += tokens }
        }
        if let active, let started, project == nil || project == active.id {
            Self.split(start: max(first, started), end: min(last, now), calendar: calendar) { key, seconds in values[key]?.selectedSeconds += seconds }
        }
        for job in state.jobs.values where project == nil || project == job.project {
            let submitted = Self.dayKey(Date(timeIntervalSince1970: job.submitted), calendar: calendar)
            values[submitted]?.jobs += 1
            guard let start = job.started, let end = job.end, let seconds = job.seconds, seconds > 0, end > start else { continue }
            let duration = end - start
            Self.split(start: max(first, Date(timeIntervalSince1970: start)), end: min(last, Date(timeIntervalSince1970: end)), calendar: calendar) { key, overlap in
                let allocation = overlap * min(1, seconds / duration)
                if job.usesGPU == true { values[key]?.gpuSeconds += allocation }
                else if job.usesGPU == false { values[key]?.cpuSeconds += allocation }
                else { values[key]?.unknownSeconds += allocation }
            }
        }
        return values.values.sorted { $0.date < $1.date }
    }
}

struct StatisticsPane: View {
    let projects: [Project]
    @ObservedObject var store: StatisticsStore
    @State private var project: String? = nil
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var metric = 0
    @State private var days: [StatisticsDay] = []
    @State private var selected: String?
    @State private var loading = false
    @State private var refreshed: Date?
    @State private var failures: [String] = []
    private var totalJobs: Int { days.reduce(0) { $0 + $1.jobs } }
    private var hours: Double { days.reduce(0) { $0 + $1.computeSeconds } / 3600 }
    private var selectedHours: Double { days.reduce(0) { $0 + $1.selectedSeconds } / 3600 }
    private var shownDay: StatisticsDay? { days.first { $0.id == selected } }
    private var totalTokens: Int64 { days.reduce(0) { $0 + $1.tokens } }
    private func value(_ day: StatisticsDay) -> Double {
        switch metric {
        case 0: return Double(day.jobs)
        case 1: return day.computeSeconds / 3600
        case 2: return day.selectedSeconds / 3600
        default: return Double(day.tokens)
        }
    }
    private func dayLabel(_ day: StatisticsDay) -> String {
        if metric == 0 { return "\(day.jobs) jobs" }
        if metric == 3 { return day.tokens.formatted() + " tokens" }
        return String(format: "%.2f hours", value(day))
    }
    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    DeskSidebarToggle()
                    Text("Statistics").font(.system(size: 28, weight: .light)).tracking(-0.7)
                    Spacer()
                    Menu {
                        Button { project = nil } label: {
                            if project == nil { Label("All projects", systemImage: "checkmark") }
                            else { Text("All projects") }
                        }
                        Divider()
                        ForEach(store.projects) { item in
                            Button { project = item.id } label: {
                                let title = item.name + (item.host.isEmpty ? "" : " · " + item.host)
                                if project == item.id { Label(title, systemImage: "checkmark") }
                                else { Text(title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(DeskStyle.muted)
                            Text(store.projects.first { $0.id == project }?.name ?? "All projects")
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DeskStyle.muted)
                        }.font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DeskStyle.accent).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeskStyle.edge, lineWidth: 0.5))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 220, alignment: .trailing).help("Filter statistics by project")
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(DeskButtonStyle(compact: true)).disabled(loading).help("Refresh job and token statistics")
                }
                HStack(spacing: 16) {
                    card("Jobs submitted", value: totalJobs.formatted(), detail: "Registered jobs", index: 0)
                    card("Compute time", value: String(format: "%.1f h", hours), detail: "Elapsed job hours", index: 1)
                    card("Time spent", value: String(format: "%.1f h", selectedHours), detail: "Time spent working on your projects, including while the app is unfocused", index: 2)
                    card("Tokens", value: totalTokens.formatted(.number.notation(.compactName)), detail: "Reported Claude/Codex input, cached input and output from saved conversations: " + totalTokens.formatted() + " tokens", index: 3)
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(["Jobs", "Compute time", "Time spent", "Tokens"][metric]).font(.system(size: 14, weight: .medium))
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                        Button { year -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                        Text(String(year)).font(.system(size: 12, design: .monospaced)).monospacedDigit()
                        Button { year += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                            .disabled(year >= Calendar.current.component(.year, from: Date()))
                    }
                    calendarGrid(width: viewport.size.width - 88)
                    HStack(spacing: 5) {
                        Text("Less").padding(.trailing, 4)
                        ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 3).fill(color(level)).frame(width: 11, height: 11) }
                        Text("More").padding(.leading, 4)
                        Spacer()

                    }.font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                }.padding(20).background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                if let day = shownDay {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(day.date.formatted(date: .complete, time: .omitted)).font(.system(size: 14, weight: .medium))
                            Text("\(day.jobs) jobs · \(String(format: "%.2f", day.selectedSeconds / 3600)) h spent · \(day.tokens.formatted()) tokens")
                                .font(.caption).foregroundStyle(DeskStyle.muted)
                        }
                        Spacer()
                        breakdown(day.gpuSeconds, day.cpuSeconds, day.unknownSeconds)
                    }.padding(.horizontal, 4)
                } else {
                    breakdown(days.reduce(0) { $0 + $1.gpuSeconds }, days.reduce(0) { $0 + $1.cpuSeconds }, days.reduce(0) { $0 + $1.unknownSeconds })
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if let refreshed { Text("Updated " + refreshed.formatted(date: .omitted, time: .shortened)) }
                        Spacer()
                        if !failures.isEmpty {
                            Label("Some hosts unavailable", systemImage: "wifi.slash")
                                .help(failures.joined(separator: ", ") + ". Cached statistics are retained.")
                        }
                    }
                    if !store.error.isEmpty { Text(store.error) }
                }.font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(DeskStyle.background)
        }
        .task { store.register(projects); store.checkpoint(); rebuild(); await refresh() }
        .onChange(of: store.revision) { _, _ in rebuild() }
        .onChange(of: project) { _, _ in selected = nil; rebuild() }
        .onChange(of: year) { _, _ in selected = nil; rebuild() }
    }
    private func card(_ title: String, value: String, detail: String, index: Int) -> some View {
        Button { metric = index } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(metric == index ? DeskStyle.accent : DeskStyle.muted)
                Text(value).font(.system(size: 34, weight: .light)).tracking(-1).monospacedDigit()
                    .foregroundStyle(DeskStyle.accent)
                Capsule().fill(metric == index ? DeskStyle.highlight : DeskStyle.edge).frame(height: 2)
                    .padding(.top, 7)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(detail).accessibilityAddTraits(metric == index ? .isSelected : [])
    }
    private func color(_ level: Int) -> Color { level == 0 ? Color.white.opacity(0.04) : DeskStyle.highlight.opacity([0, 0.23, 0.43, 0.68, 0.95][level]) }
    private func calendarGrid(width: CGFloat) -> some View {
        let calendar = Calendar.current
        let offset = days.first.map { (calendar.component(.weekday, from: $0.date) + 5) % 7 } ?? 0
        let count = (offset + days.count + 6) / 7
        let maximum = days.map(value).max() ?? 0
        let side = max(8, (width - CGFloat(count) * 4) / CGFloat(count + 1))
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    Text(" ").frame(height: 15)
                    ForEach(0..<7) { row in Text(["M", "", "W", "", "F", "", ""][row]).font(.system(size: 8)).foregroundStyle(DeskStyle.muted).frame(width: side, height: side) }
                }
                ForEach(0..<count, id: \.self) { column in
                    VStack(spacing: 4) {
                        let index = column * 7 - offset
                        let month = (0..<7).compactMap { row -> StatisticsDay? in
                            let i = index + row
                            return days.indices.contains(i) && calendar.component(.day, from: days[i].date) == 1 ? days[i] : nil
                        }.first
                        Text(month.map { $0.date.formatted(.dateTime.month(.abbreviated)) } ?? " ")
                            .font(.system(size: 8)).foregroundStyle(DeskStyle.muted).fixedSize().frame(width: side, height: 15, alignment: .leading)
                        ForEach(0..<7) { row in
                            let i = index + row
                            if days.indices.contains(i) {
                                let day = days[i], v = value(day)
                                let level = v <= 0 ? 0 : max(1, min(4, Int(ceil(v / max(maximum, 0.001) * 4))))
                                Button { selected = day.id } label: {
                                    RoundedRectangle(cornerRadius: 3).fill(color(level)).frame(width: side, height: side)
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected == day.id ? DeskStyle.accent : .clear, lineWidth: 1))
                                }.buttonStyle(.plain).help(day.id + " · " + dayLabel(day))
                                    .accessibilityLabel(day.id + ", " + dayLabel(day))
                            } else { Color.clear.frame(width: side, height: side) }
                        }
                    }
                }
            }.padding(.bottom, 4)
        }.frame(height: 7 * side + 47)
    }
    private func breakdown(_ gpu: Double, _ cpu: Double, _ unknown: Double) -> some View {
        HStack(spacing: 24) {
            ForEach(Array(zip(["GPU", "CPU", "Unclassified"], [gpu, cpu, unknown])), id: \.0) { name, value in
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                    Text(String(format: "%.2f h", value / 3600)).font(.system(size: 16, weight: .light, design: .monospaced))
                }
            }
        }
    }
    private func rebuild() { days = store.days(year: year, project: project) }
    private func refresh() async {
        guard !loading else { return }
        loading = true; failures = []
        let hosts = Array(Set(projects.map(\.host)))
        for batch in stride(from: 0, to: hosts.count, by: 4) {
            if Task.isCancelled { loading = false; return }
            let results = await withTaskGroup(of: (String, [DeskJob]?).self) { group in
                for host in hosts[batch..<min(batch + 4, hosts.count)] {
                    group.addTask { await Task.detached { (host, try? JobsBackend.statistics(host: host)) }.value }
                }
                var results: [(String, [DeskJob]?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled else { loading = false; return }
            for (host, jobs) in results {
                if let jobs { store.ingest(jobs, host: host) }
                else { failures.append(host.isEmpty ? "This Mac" : host) }
            }
        }
        for batch in stride(from: 0, to: hosts.count, by: 4) {
            let results = await withTaskGroup(of: (String, [String: [String: Int64]]?).self) { group in
                for host in hosts[batch..<min(batch + 4, hosts.count)] {
                    group.addTask { await Task.detached { (host, try? TokenStatistics.read(host: host)) }.value }
                }
                var results: [(String, [String: [String: Int64]]?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled else { loading = false; return }
            for (host, totals) in results {
                if let totals { store.ingestTokens(totals, host: host) }
                else { failures.append((host.isEmpty ? "This Mac" : host) + " (tokens)") }
            }
        }
        store.checkpoint(); refreshed = Date(); rebuild(); loading = false
    }
}
