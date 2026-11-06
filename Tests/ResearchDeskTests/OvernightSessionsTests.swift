import XCTest
@testable import ResearchDesk

final class OvernightSessionsTests: XCTestCase {
    func testWindowUsesMacTimeZoneAcrossDSTAndNeverRepeats() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Vancouver"))
        let formatter = ISO8601DateFormatter()
        let evening = try XCTUnwrap(formatter.date(from: "2026-10-31T23:00:00-07:00"))
        let window = OvernightWindow.next(now: evening, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        XCTAssertEqual(calendar.component(.hour, from: window.start), 1)
        XCTAssertEqual(calendar.component(.hour, from: window.end), 7)
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 7 * 3600) // fall-back night
        let during = OvernightWindow.next(now: window.start.addingTimeInterval(1800), timeZone: zone)
        XCTAssertEqual(during.end, window.end)
        let after = OvernightWindow.next(now: window.end, timeZone: zone)
        XCTAssertGreaterThan(after.start, window.end)
        XCTAssertEqual(after.end.timeIntervalSince(after.start), 6 * 3600)
    }
    func testDetachedOneNightWorkerSurvivesLauncherExitWithFakeClaude() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoded = Data(OvernightWorker.source.utf8).base64EncodedString()
        let setup = #"""
import base64
root=pathlib.Path(sys.argv[1])
ROOT=root/'state'
fake=root/'claude'
fake.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps({"loggedIn":True,"authMethod":"oauth","apiProvider":"firstParty"} if "auth" in sys.argv else {"type":"result","result":"# Report\\nNO_MORE_WORK"}))\n')
fake.chmod(0o700)
os.environ['PATH']=str(root)+os.pathsep+os.environ['PATH']
SOURCE=base64.b64decode(sys.argv[2]).decode()
SOURCE=SOURCE.replace("ROOT = pathlib.Path.home() / '.local/state/researchdesk/overnight'", 'ROOT = pathlib.Path('+repr(str(ROOT))+')')
SOURCE=SOURCE.replace("if __name__ == '__main__':", "def usage(): return dict(weekly=10,session=0,reset="+str(time.time()+4*86400)+")\nif __name__ == '__main__':")
def usage(): return dict(weekly=10,session=0,reset=time.time()+4*86400)
now=time.time()
launch(dict(id=str(uuid.uuid4()),key='test',project=str(root),goal='audit',instructions='test only',model='sonnet',start=now+1,end=now+20,zone='America/Vancouver',submitted=now))
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "__name__='overnight_test'\n" + OvernightWorker.source + "\n" + setup, folder.path, encoded]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        let job = try JSONDecoder().decode(OvernightJob.self, from: output)
        let status = URL(fileURLWithPath: job.folder).appendingPathComponent("status.json")
        var latest = job
        for _ in 0..<100 {
            latest = try JSONDecoder().decode(OvernightJob.self, from: Data(contentsOf: status))
            if latest.status == "complete" || latest.status == "blocked" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(latest.status, "complete", latest.message)
        let report = URL(fileURLWithPath: job.folder).appendingPathComponent("report-0001.md")
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("NO_MORE_WORK"))
    }

    func testWorkerBudgetCancellationAndFailClosedBehavior() throws {
        let test = #"""
import tempfile, unittest.mock as mock
from pathlib import Path
# Worker globals have already been defined; no launch command or real network is invoked.
now=2000000000.0
validate_auth=lambda executable: None
assert abs(ceiling(now, now+4*86400, 35)-3*DAILY)<0.001
assert ceiling(now, now+1*86400, 10)<=10+DAILY
assert ceiling(now, now+4*86400, 50)<50 # already ahead of the daily pace
with tempfile.TemporaryDirectory() as tmp:
    ROOT=Path(tmp)
    def job(name):
        folder=ROOT/name; folder.mkdir()
        (folder/'job.json').write_text(json.dumps(dict(start=now-10,end=now+100,project=tmp,goal='audit',instructions='',model='sonnet',claude='unused')))
        (folder/'status.json').write_text(json.dumps(dict(status='queued')))
        return folder
    folder=job('quota')
    usage=lambda:dict(weekly=42,session=10,reset=now+4*86400)
    with mock.patch.object(time,'time',return_value=now), mock.patch.object(subprocess,'Popen',side_effect=AssertionError('Must not run beyond quota')):
        run(folder)
    assert json.loads((folder/'status.json').read_text())['status']=='budget reached'
    folder=job('cancel'); (folder/'cancel').touch()
    usage=lambda:dict(weekly=10,session=10,reset=now+4*86400)
    with mock.patch.object(time,'time',return_value=now), mock.patch.object(subprocess,'Popen',side_effect=AssertionError('Cancelled jobs must not run')): run(folder)
    assert json.loads((folder/'status.json').read_text())['status']=='cancelled'
    folder=job('network')
    def unavailable(): raise RuntimeError('Usage unavailable')
    usage=unavailable
    with mock.patch.object(time,'time',return_value=now), mock.patch.object(subprocess,'Popen',side_effect=AssertionError('Missing usage must block work')): run(folder)
    assert json.loads((folder/'status.json').read_text())['status']=='blocked'
    folder=job('ended')
    with mock.patch.object(time,'time',return_value=now+200), mock.patch.object(subprocess,'Popen',side_effect=AssertionError('Expired jobs must not run')): run(folder)
    assert json.loads((folder/'status.json').read_text())['status']=='expired'
    # Re-arming the same night cannot create a second daily allocation.
    ROOT=Path(tmp)/'shared'; ROOT.mkdir()
    folder=job('shared-budget')
    key=hashlib.sha256((':'+str(int(now-10))).encode()).hexdigest()[:20]
    (ROOT/('budget-'+key+'.json')).write_text(json.dumps(dict(reset=now+4*86400,ceiling=DAILY)))
    usage=lambda:dict(weekly=14,session=0,reset=now+4*86400)
    with mock.patch.object(time,'time',return_value=now), mock.patch.object(subprocess,'Popen',side_effect=AssertionError('Re-arming must preserve budget')): run(folder)
    assert json.loads((folder/'status.json').read_text())['status']=='budget reached'
    ROOT=Path(tmp)
    # Exercise a running child reaching the quota boundary; termination is mocked.
    folder=job('active')
    clock=[now]
    def sleep(seconds): clock[0]+=seconds
    reads=[dict(weekly=10,session=0,reset=now+4*86400),dict(weekly=43,session=0,reset=now+4*86400)]
    usage=lambda:reads.pop(0)
    POLL=1
    class FakeProcess:
        pid=987654
        returncode=None
        def poll(self): return self.returncode
        def wait(self,timeout=None): self.returncode=-15; return self.returncode
    with mock.patch.object(time,'time',side_effect=lambda:clock[0]), mock.patch.object(time,'sleep',side_effect=sleep), mock.patch.object(subprocess,'Popen',return_value=FakeProcess()), mock.patch.object(os,'killpg') as kill:
        run(folder)
        assert kill.called
    assert json.loads((folder/'status.json').read_text())['status']=='budget reached'
print('worker tests passed')
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "__name__='overnight_test'\n" + OvernightWorker.source + "\n" + test]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
}
