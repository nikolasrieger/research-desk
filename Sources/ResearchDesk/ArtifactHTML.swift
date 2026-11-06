import Foundation

/// Keeps the page and its referenced project assets together for WebKit's file access scope.
final class ArtifactHTMLFile: Sendable {
    let root: URL
    let url: URL
    init(root: URL, url: URL) { self.root = root; self.url = url }
    deinit { try? FileManager.default.removeItem(at: root) }
}

enum ArtifactHTML {
    static func snapshot(project: Project, path: String) throws -> ArtifactHTMLFile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: project.path).standardizedFileURL.path
        guard FileBrowserIO.containsPath(page, in: base) else { throw ResearchError.message("HTML file is outside this project.") }
        let relativePage = String(page.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let snapshot = ArtifactHTMLFile(root: root, url: root.appendingPathComponent(relativePage))
        let archive = root.appendingPathComponent(".assets-" + UUID().uuidString + ".tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        let command = "python3 -c " + Command.shellQuote(assetScript) + " " + Command.shellQuote(project.path) + " " + Command.shellQuote(path) + " archive"
        try transfer(host: project.host, command: command, destination: archive)
        let (_, failure, code) = Command.run("/usr/bin/tar", ["-xf", archive.path, "-C", root.path], timeout: 60, maxOutput: 2000)
        guard code == 0 else { throw ResearchError.message(failure.isEmpty ? "Could not unpack HTML assets." : failure) }
        return snapshot
    }

    /// One SSH connection streams all assets to disk, avoiding per-file connection latency.
    private static func transfer(host: String, command: String, destination: URL) throws {
        guard !host.hasPrefix("-"), host.range(of: #"^[a-zA-Z0-9._@-]+$"#, options: .regularExpression) != nil else {
            throw ResearchError.message("Invalid SSH host.")
        }
        let errorsURL = destination.appendingPathExtension("stderr")
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer { try? output.close(); try? errors.close(); try? FileManager.default.removeItem(at: errorsURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", host, command]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(300)
        while process.isRunning && Date() < deadline {
            if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber, size.intValue > 505_000_000 {
                process.terminate(); process.waitUntilExit()
                throw ResearchError.message("HTML assets exceed the 500 MB preview limit.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate(); process.waitUntilExit()
            throw ResearchError.message("HTML transfer timed out. Try again.")
        }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorsURL, encoding: .utf8)) ?? "Could not download HTML assets."
            throw ResearchError.message(String(message.suffix(4000)))
        }
    }

    static let assetScript = #"""
import os, sys, json, re
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
root = os.path.abspath(sys.argv[1])
page = os.path.abspath(sys.argv[2])
pending = [page]
seen = set()
total = 0
class References(HTMLParser):
    def __init__(self):
        super().__init__(); self.refs = []
    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if not value: continue
            if key in ('src', 'href', 'poster', 'data-src'): self.refs.append(value)
            elif key == 'srcset':
                self.refs.extend(part.strip().split()[0] for part in value.split(',') if part.strip())
while pending:
    path = os.path.normpath(pending.pop())
    if path in seen: continue
    if os.path.commonpath([root, path]) != root: continue
    if os.path.commonpath([os.path.realpath(root), os.path.realpath(path)]) != os.path.realpath(root): continue
    if not os.path.isfile(path):
        if path == page: raise ValueError('HTML file does not exist')
        continue
    size = os.path.getsize(path)
    total += size
    if total > 500000000 or len(seen) >= 500: raise ValueError('HTML assets exceed preview limit (500 MB / 500 files)')
    seen.add(path)
    if os.path.splitext(path)[1].lower() not in ('.html', '.htm', '.css', '.svg'): continue
    with open(path, encoding='utf-8', errors='replace') as f: text = f.read()
    parser = References(); parser.feed(text)
    refs = parser.refs + re.findall(r'url\(\s*[\'"]?([^\'"\)]+)', text)
    refs += re.findall(r'@import\s+[\'"]([^\'"]+)', text)
    for ref in refs:
        parsed = urlsplit(ref.strip())
        if parsed.scheme or parsed.netloc or not parsed.path: continue
        value = unquote(parsed.path)
        target = os.path.normpath(os.path.join(os.path.dirname(path), value))
        pending.append(target)
paths = sorted(os.path.relpath(path, root) for path in seen)
if len(sys.argv) > 3 and sys.argv[3] == 'archive':
    import tarfile, stat
    transferred = 0
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
        for relative in paths:
            if os.path.isabs(relative) or '..' in relative.split(os.sep): raise ValueError('Invalid asset path')
            source = os.path.join(root, relative)
            if os.path.commonpath([os.path.realpath(root), os.path.realpath(source)]) != os.path.realpath(root): raise ValueError('Asset outside project')
            with open(source, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode): raise ValueError('Asset is not a regular file')
                transferred += info.st_size
                if transferred > 500000000: raise ValueError('HTML assets exceed the 500 MB preview limit')
                # Only regular relative entries: no symlinks, hard links or directory traversal.
                entry = tarfile.TarInfo(relative)
                entry.size = info.st_size
                entry.mode = 0o600
                archive.addfile(entry, stream)
else:
    print(json.dumps(paths))
"""#
}
