import XCTest
@testable import ResearchDesk

final class StatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Vancouver")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor
    func testSelectionSpansMidnightPausesAndSurvivesRestartWithoutCountingClosedTime() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stats.json")
        let store = StatisticsStore(url: url)
        let a = Project(name: "A", path: "/a"), b = Project(name: "B", path: "/b")
        let start = date(2026, 11, 24, 23)
        store.select(a, now: start)
        // No focus or input events are needed for the selected project to accumulate time.
        store.select(a, now: date(2026, 11, 25, 1))
        store.select(b, now: date(2026, 11, 25, 2))
        store.select(nil, now: date(2026, 11, 25, 3))
        store.select(b, now: date(2026, 11, 25, 5))
        store.finish(now: date(2026, 11, 25, 6))
        let restored = StatisticsStore(url: url)
        let keyA = StatisticsProject(a).id
        let days = restored.days(year: 2026, project: keyA, now: date(2026, 11, 30), calendar: calendar)
        XCTAssertEqual(days.first { $0.id == "2026-11-24" }?.selectedSeconds, 3600)
        XCTAssertEqual(days.first { $0.id == "2026-11-25" }?.selectedSeconds, 7200)
        let all = restored.days(year: 2026, project: nil, now: date(2026, 11, 30), calendar: calendar)
        XCTAssertEqual(all.reduce(0) { $0 + $1.selectedSeconds }, 5 * 3600)
    }
    func testDailySplitUsesCalendarDaysAcrossDST() {
        let start = date(2026, 11, 1), end = date(2026, 11, 2)
        var result: [String: Double] = [:]
        StatisticsStore.split(start: start, end: end, calendar: calendar) { result[$0] = $1 }
        XCTAssertEqual(result["2026-11-01"], 25 * 3600)
    }
    @MainActor
    func testJobsDeduplicateSplitElapsedHoursAndPreserveUnknownAttribution() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = StatisticsStore(url: root.appendingPathComponent("stats.json"))
        let start = date(2026, 11, 24, 23).timeIntervalSince1970
        var job = DeskJob(id: "gpu", name: "GPU run", project: "/a", kind: "slurm", submitted: start, status: "succeeded")
        job.started = start; job.ended = start + 7200; job.runtime = 7200; job.usesGPU = true
        store.ingest([job], host: "cluster")
        store.ingest([job], host: "cluster")
        var unknown = job; unknown.id = "unknown"; unknown.project = "/b"; unknown.usesGPU = nil
        store.ingest([unknown], host: "cluster")
        let a = store.days(year: 2026, project: "cluster:/a", calendar: calendar)
        XCTAssertEqual(a.reduce(0) { $0 + $1.jobs }, 1)
        XCTAssertEqual(a.first { $0.id == "2026-11-24" }?.gpuSeconds, 3600)
        XCTAssertEqual(a.first { $0.id == "2026-11-25" }?.gpuSeconds, 3600)
        XCTAssertEqual(a.reduce(0) { $0 + $1.computeSeconds }, 7200, "Elapsed hours must not multiply by GPU count")
        let all = store.days(year: 2026, project: nil, calendar: calendar)
        XCTAssertEqual(all.reduce(0) { $0 + $1.unknownSeconds }, 7200)
        XCTAssertEqual(all.reduce(0) { $0 + $1.cpuSeconds }, 0)
        // A later ordinary Jobs refresh without GPU metadata must not lose known attribution.
        job.usesGPU = nil; job.submitted += 86400 // Later registration metadata must not move a known original submission date.
        store.ingest([job], host: "cluster")
        let preserved = store.days(year: 2026, project: "cluster:/a", calendar: calendar)
        XCTAssertEqual(preserved.reduce(0) { $0 + $1.gpuSeconds }, 7200)
        XCTAssertEqual(preserved.first { $0.id == "2026-11-24" }?.jobs, 1)
    }
    @MainActor
    func testMissingProcessDoesNotAccumulateUnobservedHours() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = StatisticsStore(url: root.appendingPathComponent("stats.json"))
        let start = date(2026, 11, 24).timeIntervalSince1970
        var job = DeskJob(id: "process", name: "Run", project: "/a", kind: "process", submitted: start, status: "running")
        job.started = start; job.checked = start + 3600; job.usesGPU = false
        store.ingest([job], host: "")
        job.status = "unknown"; job.checked = start + 86400
        store.ingest([job], host: "")
        let days = store.days(year: 2026, project: nil, calendar: calendar)
        XCTAssertEqual(days.reduce(0) { $0 + $1.cpuSeconds }, 3600)
    }
    @MainActor
    func testTenThousandJobAggregationIsBounded() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = StatisticsStore(url: root.appendingPathComponent("stats.json"))
        let first = date(2026, 1, 1).timeIntervalSince1970
        var jobs: [DeskJob] = []
        for index in 0..<10000 {
            let start = first + Double(index % 300) * 86400
            var job = DeskJob(id: String(index), name: "Fixture", project: "/a", kind: "slurm", submitted: start, status: "succeeded")
            job.started = start; job.ended = start + 1800; job.runtime = 1800; job.usesGPU = index % 2 == 0
            jobs.append(job)
        }
        store.ingest(jobs, host: "cluster")
        let before = Date()
        let days = store.days(year: 2026, project: nil, calendar: calendar)
        let elapsed = Date().timeIntervalSince(before)
        XCTAssertEqual(days.reduce(0) { $0 + $1.jobs }, 10000)
        XCTAssertEqual(days.reduce(0) { $0 + $1.computeSeconds }, 18000000)
        XCTAssertLessThan(elapsed, 2, "A yearly aggregate should not stall the UI")
        print("Statistics: 10,000 jobs aggregated in \(elapsed) seconds")
    }

    func testSlurmStatisticsUsesAllocationTypeAndElapsedSeconds() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let script = "__name__='fixture'\n" + JobsBackend.source + #"""

def list_jobs():
    return [dict(id='g',name='GPU',project='/a',kind='slurm',submitted=1,status='succeeded',schedulerID='123'),dict(id='c',name='CPU',project='/a',kind='slurm',submitted=1,status='succeeded',schedulerID='124')]
def run(args):
    assert args[0]=='sacct'
    return 0,'123|cpu=16,gres/gpu=4|7200|2026-11-24T12:00:00|2026-11-24T14:00:00|COMPLETED\n124|cpu=8,mem=1G|3600|2026-11-24T12:00:00|2026-11-24T13:00:00|COMPLETED\n',''
print(json.dumps(statistics()))
"""#
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let jobs = try JSONDecoder().decode([DeskJob].self, from: data)
        XCTAssertEqual(jobs[0].usesGPU, true)
        XCTAssertEqual(jobs[0].runtime, 7200)
        XCTAssertEqual(jobs[1].usesGPU, false)
        XCTAssertEqual(jobs[1].runtime, 3600)
    }
}
