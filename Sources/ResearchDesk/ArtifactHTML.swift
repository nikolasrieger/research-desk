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
        let command = "python3 -c " + Command.shellQuote(assetScript) + " " + Command.shellQuote(project.path) + " " + Command.shellQuote(path)
        let (output, failure, code) = Command.ssh(project.host, command, maxOutput: 2_000_000)
        guard code == 0 else { throw ResearchError.message(failure.isEmpty ? "Could not resolve HTML assets." : failure) }
        let paths = try JSONDecoder().decode([String].self, from: Data(output.utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: project.path).standardizedFileURL.path
        guard FileBrowserIO.containsPath(page, in: base) else { throw ResearchError.message("HTML file is outside this project.") }
        let relativePage = String(page.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let snapshot = ArtifactHTMLFile(root: root, url: root.appendingPathComponent(relativePage))
        for relative in paths {
            let target = root.appendingPathComponent(relative).standardizedFileURL
            guard FileBrowserIO.containsPath(target.path, in: root.path), !relative.hasPrefix("/") else {
                throw ResearchError.message("Invalid HTML asset path.")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileBrowserIO.copyFile(project, path: URL(fileURLWithPath: base).appendingPathComponent(relative).path, to: target, limit: 500_000_000)
        }
        return snapshot
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
print(json.dumps(sorted(os.path.relpath(path, root) for path in seen)))
"""#
}
