import XCTest
@testable import ResearchDesk

final class JobsTests: XCTestCase {
    func testDisplayOrderKeepsRunningJobsFirstAcrossStatusChanges() {
        func job(_ id: String, _ status: String, _ submitted: Double) -> DeskJob {
            DeskJob(id: id, name: id, project: "/tmp", kind: "process", submitted: submitted, status: status)
        }
        var jobs = [job("completed", "succeeded", 300), job("older-running", "running", 100),
                    job("queued", "queued", 400), job("newer-running", "running", 200), job("failed", "failed", 250)]
        XCTAssertEqual(jobs.sorted(by: DeskJob.displayOrder).map(\.id),
                       ["newer-running", "older-running", "queued", "completed", "failed"])
        jobs[1].status = "succeeded"
        jobs[2].status = "running"
        XCTAssertEqual(jobs.sorted(by: DeskJob.displayOrder).map(\.id),
                       ["queued", "newer-running", "completed", "failed", "older-running"])
        XCTAssertEqual([job("b", "running", 1), job("a", "running", 1)].sorted(by: DeskJob.displayOrder).map(\.id), ["a", "b"])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func invoke(_ root: URL, _ action: String, _ payload: [String: Any] = [:], path: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", JobsBackend.source, action, String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]
        var env = ProcessInfo.processInfo.environment
        env["RD_JOBS_ROOT"] = root.appendingPathComponent("registry").path
        if let path { env["PATH"] = path + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
        process.environment = env
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ResearchError.message(String(decoding: error, as: UTF8.self)) }
        return data
    }
    private func list(_ root: URL, path: String? = nil) throws -> [DeskJob] {
        try JSONDecoder().decode([DeskJob].self, from: invoke(root, "list", path: path))
    }
    func testDetachedScheduledJobCompletesAndLogsAreIncremental() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scheduled = Date().timeIntervalSince1970 + 0.7
        let data = try invoke(root, "launch", ["name": "Fixture", "kind": "shell", "project": root.path, "command": "printf first; sleep 0.2; printf second; exit 7", "scheduled": scheduled])
        let job = try JSONDecoder().decode(DeskJob.self, from: data)
        XCTAssertEqual(job.status, "queued")
        XCTAssertEqual(try list(root).first?.status, "queued")
        var result: DeskJob?
        for _ in 0..<100 {
            result = try list(root).first
            if result?.terminal == true { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(result?.status, "failed")
        XCTAssertEqual(result?.exitCode, 7)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result?.started), scheduled)
        XCTAssertNotNil(result?.ended)
        let chunk = try JSONDecoder().decode(JobLogChunk.self, from: invoke(root, "log", ["id": job.id]))
        XCTAssertEqual(chunk.text, "firstsecond")
        let next = try JSONDecoder().decode(JobLogChunk.self, from: invoke(root, "log", ["id": job.id, "offset": chunk.offset, "inode": chunk.inode]))
        XCTAssertEqual(next.text, "")
        XCTAssertFalse(next.reset)
        try Data(repeating: 65, count: 100000).write(to: URL(fileURLWithPath: try XCTUnwrap(job.log)))
        let truncated = try JSONDecoder().decode(JobLogChunk.self, from: invoke(root, "log", ["id": job.id, "offset": next.offset, "inode": next.inode]))
        XCTAssertTrue(truncated.reset)
        XCTAssertEqual(truncated.text.utf8.count, 65536)
    }
    func testProcessIdentityAndExitFilePreventFalseSuccessOrPIDReuse() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try invoke(root, "register", ["name": "Adopt", "kind": "process", "project": root.path, "pid": ProcessInfo.processInfo.processIdentifier])
        let job = try JSONDecoder().decode(DeskJob.self, from: data)
        XCTAssertEqual(try list(root).first?.status, "running")
        XCTAssertNotNil(job.started)
        let file = root.appendingPathComponent("registry/" + job.id + ".json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["processStart"] = "Different start time"
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        XCTAssertEqual(try list(root).first?.status, "unknown")
        let exit = root.appendingPathComponent("exit.json")
        try JSONSerialization.data(withJSONObject: ["exitCode": 0, "ended": Date().timeIntervalSince1970]).write(to: exit)
        record["exitFile"] = exit.path
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        XCTAssertEqual(try list(root).first?.status, "succeeded")
        try FileManager.default.removeItem(at: exit)
        XCTAssertEqual(try list(root).first?.status, "succeeded", "Terminal outcome must persist without repeated process checks")
    }
    func testSlurmBatchQueriesAccountingAndMissingJobIsUnknown() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [
            ("squeue", "#!/bin/sh\nprintf '101|PENDING|0:00|N/A|Resources\\n102|RUNNING|01:02|2026-11-25T10:00:00|None\\n'\n"),
            ("sacct", "#!/bin/sh\nprintf '103|COMPLETED|00:23|2026-11-25T10:00:00|2026-11-25T10:00:23|0:0\\n104|OUT_OF_MEMORY|00:05|2026-11-25T10:00:00|2026-11-25T10:00:05|1:0\\n'\n")
        ] {
            let file = bin.appendingPathComponent(name)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for id in 101...105 {
            _ = try invoke(root, "register", ["name": "Cluster \(id)", "kind": "slurm", "project": root.path, "schedulerID": String(id)])
        }
        let jobs = try list(root, path: bin.path)
        let states = Dictionary(uniqueKeysWithValues: jobs.map { ($0.schedulerID!, $0.status) })
        XCTAssertEqual(states, ["101": "queued", "102": "running", "103": "succeeded", "104": "failed", "105": "unknown"])
        XCTAssertEqual(jobs.first { $0.schedulerID == "102" }?.runtime, 62)
        XCTAssertThrowsError(try invoke(root, "register", ["name": "Invalid", "kind": "slurm", "project": root.path, "schedulerID": "--help"]))
    }
    func testProjectScopeFiltersBeforeMonitoringAndNormalizesTrailingSlash() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first").path
        let second = root.appendingPathComponent("second").path
        for (path, id) in [(first, "201"), (second, "202")] {
            _ = try invoke(root, "register", ["name": "Scoped job", "kind": "slurm", "project": path, "schedulerID": id])
        }
        let data = try invoke(root, "list", ["project": first + "/"])
        let jobs = try JSONDecoder().decode([DeskJob].self, from: data)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.schedulerID, "201")
        XCTAssertTrue(JobsBackend.matches(try XCTUnwrap(jobs.first), project: first + "/"))
        XCTAssertFalse(JobsBackend.matches(try XCTUnwrap(jobs.first), project: second))
    }

    @MainActor
    func testHiddenViewDoesNotRefreshAndCachedStateSurvivesRestart() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let snapshot = JobHostSnapshot(host: "fixture.invalid", jobs: [], checked: Date(), error: "Cached")
        try JSONEncoder().encode([snapshot.host: snapshot]).write(to: cache)
        let model = JobsModel(cacheURL: cache)
        let token = model.activate()
        model.deactivate()
        await model.refresh(hosts: ["fixture.invalid"], token: token)
        XCTAssertFalse(model.refreshing)
        XCTAssertEqual(model.snapshots["fixture.invalid"]?.error, "Cached")
        XCTAssertEqual(JobsModel.duration(3661), "01:01:01")
    }
}
