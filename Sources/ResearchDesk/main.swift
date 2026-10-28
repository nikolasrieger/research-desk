import SwiftUI
import AppKit
import Darwin
import SwiftTerm

enum DeskStyle {
    static let background = Color(red: 0.025, green: 0.025, blue: 0.035)
    static let sidebar = Color(red: 0.045, green: 0.045, blue: 0.06)
    static let surface = Color(red: 0.065, green: 0.065, blue: 0.085)
    static let raised = Color(red: 0.24, green: 0.245, blue: 0.37).opacity(0.35)
    static let edge = Color(red: 0.73, green: 0.73, blue: 0.81).opacity(0.16)
    static let muted = Color(red: 0.62, green: 0.62, blue: 0.67)
    static let accent = Color(red: 0.89, green: 0.89, blue: 0.91)
    static let violet = Color(red: 0.44, green: 0.44, blue: 0.82)
    static let running = Color(red: 0.61, green: 0.66, blue: 0.48)
    static let terminalBackground = NSColor(red: 0.025, green: 0.025, blue: 0.035, alpha: 1)
}

struct DeskVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A dark glass backdrop with a quiet violet reflection.
struct DeskMetalSurface: View {
    var body: some View {
        DeskVibrancy()
            .overlay(DeskStyle.background.opacity(0.88))
            .overlay {
                LinearGradient(colors: [DeskStyle.violet.opacity(0.075), .clear, .white.opacity(0.015)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DeskMetalPlate: View {
    var radius: CGFloat = 12
    var pressed = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.20, blue: 0.27).opacity(pressed ? 0.9 : 0.65),
                                          Color(red: 0.09, green: 0.09, blue: 0.12).opacity(0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.23), DeskStyle.edge.opacity(0.4), .white.opacity(0.09)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Static planes suggest the reference's spatial gallery without distracting motion.
struct DeskSpatialMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<7) { index in
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [DeskStyle.violet.opacity(0.16), DeskStyle.surface.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(DeskStyle.accent.opacity(0.12), lineWidth: 0.75)
                    }
                    .frame(width: 72, height: 94)
                    .rotation3DEffect(.degrees(-28), axis: (x: 0, y: 1, z: 0))
                    .rotationEffect(.degrees(Double(index - 3) * 8))
                    .offset(x: CGFloat(index - 3) * 23, y: CGFloat(abs(index - 3)) * 7)
            }
            DeskMark(size: 36)
        }
        .frame(width: 240, height: 140)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DeskEyebrow: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(2).foregroundStyle(DeskStyle.muted)
    }
}

/// Flat controls with a shared hit area and subtle hover feedback.
struct DeskButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration, prominent: prominent, compact: compact)
    }

    private struct Control: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: prominent ? .medium : .regular))
                .foregroundStyle(Color.primary.opacity(prominent ? 1 : 0.82))
                .padding(.horizontal, compact ? 6 : 9)
                .frame(minHeight: 30)
                .background {
                    if prominent || hovered || configuration.isPressed {
                        DeskMetalPlate(pressed: configuration.isPressed)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.38)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

/// A quiet, shared tab strip for project and paper workspaces.
struct DeskTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : DeskStyle.muted)
                .padding(.horizontal, 14).frame(height: 34)
                .background { if selected { DeskMetalPlate(radius: 17) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Shared field and menu geometry keeps the workspace chrome consistent.
struct DeskFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DeskStyle.edge, lineWidth: 0.5) }
    }
}

struct DeskMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DeskStyle.muted)
        }
        .font(.system(size: 12)).foregroundStyle(DeskStyle.accent)
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DeskStyle.edge, lineWidth: 0.5) }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct DeskChoiceMenu: View {
    let title: String
    var symbol: String? = nil
    let choices: [String]
    var selection: String? = nil
    let choose: (String) -> Void
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: { DeskMenuLabel(title: title, symbol: symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(presented ? "Expanded" : "Collapsed")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(choices, id: \.self) { choice in
                            Button {
                                choose(choice)
                                presented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Text(choice)
                                    Spacer(minLength: 16)
                                    if selection == choice { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(DeskButtonStyle(prominent: selection == choice))
                        }
                    }.padding(6)
                }.frame(width: 210, height: min(CGFloat(choices.count) * 32 + 12, 280))
                    .background(DeskStyle.surface)
                    .preferredColorScheme(.dark)
            }
    }
}

private struct DeskSidebarHiddenKey: EnvironmentKey {
    static let defaultValue = false
}
private struct DeskSidebarActionKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}
extension EnvironmentValues {
    var deskSidebarHidden: Bool {
        get { self[DeskSidebarHiddenKey.self] }
        set { self[DeskSidebarHiddenKey.self] = newValue }
    }
    var deskToggleSidebar: @MainActor () -> Void {
        get { self[DeskSidebarActionKey.self] }
        set { self[DeskSidebarActionKey.self] = newValue }
    }
}
struct DeskSidebarToggle: View {
    @Environment(\.deskToggleSidebar) private var toggle
    var body: some View {
        Button(action: toggle) { Image(systemName: "sidebar.left") }
            .buttonStyle(DeskButtonStyle(compact: true))
            .help("Toggle sidebar (Control-Command-S)")
            .accessibilityLabel("Toggle sidebar")
    }
}

struct DeskMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23)
                .stroke(DeskStyle.accent, lineWidth: min(2.2, size * 0.055))
            VStack(alignment: .leading, spacing: size * 0.12) {
                Capsule().frame(width: size * 0.38, height: min(3, size * 0.065))
                Capsule().frame(width: size * 0.25, height: min(3, size * 0.065))
            }
            .foregroundStyle(DeskStyle.accent)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Research Desk")
    }
}

enum AgentLocator {
    static func executable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".claude/local").path,
               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in search {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if name == "codex" {
            for extensions in [home.appendingPathComponent(".vscode/extensions"), home.appendingPathComponent(".vscode-insiders/extensions")] {
                let entries = (try? FileManager.default.contentsOfDirectory(at: extensions, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                let candidates = entries.filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") }
                    .sorted { left, right in
                        let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        return leftDate > rightDate
                    }
                for candidate in candidates {
                    let path = candidate.appendingPathComponent("bin/macos-aarch64/codex").path
                    if FileManager.default.isExecutableFile(atPath: path) { return path }
                }
            }
        }
        return nil
    }
}

@MainActor final class AgentSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let project: Project
    let agent: String
    let resumeID: String?
    let claudeSessionID: String
    var artifactURL: URL?
    let resumeWorkspace: String?
    let executable: String?
    let terminal = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    @Published var started = false
    @Published var exitCode: Int32?
    @Published var ended = false

    init(project: Project, agent: String, executable: String?, resumeID: String? = nil, resumeWorkspace: String? = nil) {
        self.project = project
        self.agent = agent
        self.claudeSessionID = resumeID ?? UUID().uuidString.lowercased()
        self.resumeID = resumeID
        self.resumeWorkspace = resumeWorkspace
        self.executable = executable
        super.init()
        terminal.processDelegate = self
        if agent == "claude" {
            terminal.getTerminal().changeHistorySize(20_000)
            terminal.alternateScreenScrollsByPage = true
        }
        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = DeskStyle.terminalBackground
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func start() {
        guard !started else { return }
        started = true
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [executable.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
                     ProcessInfo.processInfo.environment["PATH"],
                     home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .compactMap { $0 }.joined(separator: ":")
        environment.append("PATH=" + paths)
        environment.append("SHELL=/bin/zsh")
        let agentArguments = resumeID.map { agent == "codex" ? ["resume", $0] : ["--resume", $0] } ?? (agent == "claude" ? ["--session-id", claudeSessionID] : [])
        let workingDirectory = resumeWorkspace.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? project.path
        if agent == "terminal" {
            if project.isRemote {
                let remoteCommand = "cd " + Command.shellQuote(project.path) + " && exec \"${SHELL:-/bin/bash}\" -l"
                terminal.startProcess(executable: "/usr/bin/ssh", args: ["-t", "--", project.host, remoteCommand], environment: environment)
            } else {
                terminal.startProcess(executable: "/bin/zsh", args: ["-l"], environment: environment, currentDirectory: project.path)
            }
        } else if project.isRemote {
            let agentCommand = ([agent] + agentArguments).map(Command.shellQuote).joined(separator: " ")
            let remoteCommand = "cd " + Command.shellQuote(workingDirectory) + " && exec \"${SHELL:-/bin/bash}\" -lic " + Command.shellQuote(agentCommand)
            terminal.startProcess(executable: "/usr/bin/ssh", args: ["-t", "--", project.host, remoteCommand], environment: environment)
        } else if let executable {
            let bundledCodex = agent == "codex" && executable.contains("/.vscode") && executable.contains("/extensions/openai.chatgpt-")
            terminal.startProcess(executable: executable, args: (bundledCodex ? ["--no-daemon"] : []) + agentArguments, environment: environment, currentDirectory: workingDirectory)
        }
    }

    func stop() {
        guard started, !ended else { return }
        let pid = terminal.process?.shellPid ?? 0
        if pid > 0 { Darwin.kill(pid, SIGTERM) }
        terminal.terminate()
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.exitCode = exitCode.map { $0 > 255 ? ($0 >> 8) & 0xff : $0 }
            self.ended = true
        }
    }
}

struct EmbeddedTerminal: NSViewRepresentable {
    @ObservedObject var session: AgentSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminal.presentationSuspended = false
        DispatchQueue.main.async { session.start() }
        return session.terminal
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        nsView.presentationSuspended = true
    }
}

enum SSHHosts {
    static func configured() -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        var seenFiles = Set<String>()
        var hosts = Set<String>()
        func read(_ file: URL) {
            let path = file.standardizedFileURL.path
            guard seenFiles.insert(path).inserted,
                  let contents = try? String(contentsOf: file, encoding: .utf8) else { return }
            for rawLine in contents.components(separatedBy: .newlines) {
                let line = String(rawLine.prefix(while: { $0 != "#" })).trimmingCharacters(in: .whitespaces)
                let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let key = words.first?.lowercased() else { continue }
                if key == "host" {
                    for host in words.dropFirst() where !host.contains("*") && !host.contains("?") && !host.hasPrefix("!") {
                        hosts.insert(host)
                    }
                } else if key == "include" {
                    for pattern in words.dropFirst() {
                        let expanded = (pattern as NSString).expandingTildeInPath
                        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(pattern)
                        let directory = url.deletingLastPathComponent()
                        let filePattern = url.lastPathComponent
                        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                            for candidate in files where fnmatch(filePattern, candidate.lastPathComponent, 0) == 0 { read(candidate) }
                        }
                    }
                }
            }
        }
        read(root.appendingPathComponent("config"))
        return hosts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct Project: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var host: String = ""
    var isRemote: Bool { !host.isEmpty }
}

struct Snapshot: Sendable {
    var branch = "—"
    var changes = 0
    var summary = "Not checked"
    var files: [String] = []
    var error = ""
}

struct RemoteEntry: Decodable, Identifiable, Sendable {
    let name: String
    let directory: Bool
    var id: String { name }
}

struct RemoteListing: Decodable, Sendable {
    let path: String
    let entries: [RemoteEntry]
}

enum Command {
    private static let sshControlDirectory: String? = {
        let path = "/private/tmp/research-desk-\(getuid())"
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return nil }
            return path
        } catch { return nil }
    }()

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 12, maxOutput: Int = 200_000) -> (String, String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let directory = FileManager.default.temporaryDirectory
        let outputURL = directory.appendingPathComponent("research-desk-out-\(UUID().uuidString)")
        let errorURL = directory.appendingPathComponent("research-desk-err-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL),
              let error = try? FileHandle(forWritingTo: errorURL) else {
            return ("", "Could not create command output files", -1)
        }
        defer {
            try? output.close(); try? error.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return ("", error.localizedDescription, -1) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); return ("", "Timed out", -1) }
        let outputRead = try? FileHandle(forReadingFrom: outputURL)
        let errorRead = try? FileHandle(forReadingFrom: errorURL)
        let stdout = String(data: (try? outputRead?.read(upToCount: maxOutput)) ?? Data(), encoding: .utf8) ?? ""
        let stderr = String(data: (try? errorRead?.read(upToCount: 20_000)) ?? Data(), encoding: .utf8) ?? ""
        try? outputRead?.close(); try? errorRead?.close()
        return (stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func ssh(_ host: String, _ command: String, maxOutput: Int = 200_000) -> (String, String, Int32) {
        guard !host.hasPrefix("-"), host.range(of: #"^[a-zA-Z0-9._@-]+$"#, options: .regularExpression) != nil else {
            return ("", "Invalid SSH host", -1)
        }
        var arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5"]
        if let sshControlDirectory {
            arguments += ["-o", "ControlMaster=auto", "-o", "ControlPersist=2m", "-o", "ControlPath=\(sshControlDirectory)/%C"]
        }
        arguments += [host, command]
        return run("/usr/bin/ssh", arguments, maxOutput: maxOutput)
    }

    static func closeSSHConnections(hosts: [String]) {
        guard let sshControlDirectory else { return }
        for host in Set(hosts) where !host.isEmpty {
            _ = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-S", "\(sshControlDirectory)/%C", "-O", "exit", host], timeout: 2)
        }
    }

    static func remoteListing(host: String, path: String) -> (RemoteListing?, String) {
        let python = "import os,json,sys; p=os.path.abspath(os.path.expanduser(sys.argv[1])); e=sorted(({'name':x.name,'directory':x.is_dir(follow_symlinks=True)} for x in os.scandir(p)), key=lambda x:(not x['directory'],x['name'].lower())); print(json.dumps({'path':p,'entries':e[:500]}))"
        let command = "python3 -c " + shellQuote(python) + " " + shellQuote(path)
        let (output, error, status) = ssh(host, command)
        guard status == 0 else { return (nil, error.isEmpty ? "Could not list remote directory" : error) }
        guard let listing = try? JSONDecoder().decode(RemoteListing.self, from: Data(output.utf8)) else {
            return (nil, "Could not read directory listing from remote Python 3")
        }
        return (listing, "")
    }

    static func fileData(_ project: Project, path: String) -> (Data?, String) {
        let limit = 15_000_000
        if project.isRemote {
            let python = "import os,sys,base64; root=os.path.realpath(sys.argv[1]); p=os.path.realpath(sys.argv[2]); assert os.path.commonpath([root,p])==root, 'Outside project'; assert os.path.getsize(p)<=15000000, 'File is larger than 15 MB'; sys.stdout.write(base64.b64encode(open(p,'rb').read()).decode('ascii'))"
            let command = "python3 -c " + shellQuote(python) + " " + shellQuote(project.path) + " " + shellQuote(path)
            let (output, error, status) = ssh(project.host, command, maxOutput: 21_000_000)
            guard status == 0 else { return (nil, error.isEmpty ? "Could not read remote file" : error) }
            guard let data = Data(base64Encoded: output) else { return (nil, "Could not decode remote file") }
            return (data, "")
        }
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard file.path == root || file.path.hasPrefix(root + "/") else { return (nil, "File is outside this project") }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= limit else { return (nil, "File is larger than 15 MB") }
            return (try Data(contentsOf: file), "")
        } catch { return (nil, error.localizedDescription) }
    }

    static func git(_ project: Project, _ args: [String]) -> (String, String, Int32) {
        if project.isRemote {
            let command = (["git", "-C", project.path] + args).map(shellQuote).joined(separator: " ")
            return ssh(project.host, command)
        }
        return run("/usr/bin/git", ["-C", project.path] + args)
    }

    static func snapshot(_ project: Project) -> Snapshot {
        var result = Snapshot()
        let (branch, branchError, branchCode) = git(project, ["branch", "--show-current"])
        if branchCode != 0 { result.error = branchError; return result }
        result.branch = branch.isEmpty ? "detached HEAD" : branch
        let (status, statusError, statusCode) = git(project, ["status", "--short"])
        if statusCode != 0 { result.error = statusError; return result }
        result.files = status.split(separator: "\n").map(String.init)
        result.changes = result.files.count
        let (log, _, _) = git(project, ["log", "-1", "--format=%h · %s"])
        result.summary = log.isEmpty ? "No commits yet" : log
        return result
    }
}

@MainActor final class DeskModel: ObservableObject {
    let papers = PaperLibrary()
    @Published var projects: [Project] = []
    @Published var snapshots: [UUID: Snapshot] = [:]
    @Published var selected: UUID?
    @Published var paperSelected = false
    @Published var storageError = ""
    @Published var busy = false
    @Published var showRemote = false
    @Published var remoteHost = ""
    @Published var remotePath = ""
    @Published var sshHosts: [String] = []
    @Published var showRemoteBrowser = false
    @Published var remoteBrowsePath = ""
    @Published var remoteEntries: [RemoteEntry] = []
    @Published var remoteBrowserBusy = false
    @Published var remoteBrowserError = ""
    @Published var agentError = ""
    @Published var paperError = ""
    @Published var paperRepository = ""
    @Published var paperAgent: AgentSession?
    @Published var sessions: [UUID: AgentSession] = [:]
    @Published var terminals: [UUID: AgentSession] = [:]
    @Published var history: [UUID: [SavedAgentSession]] = [:]
    @Published var historyLoading: Set<UUID> = []
    @Published var projectTabs: [UUID: Int] = [:]
    private var fileBrowsers: [UUID: FileBrowserModel] = [:]
    private var historyChecked: [UUID: Date] = [:]
    private var historyAttempted: [UUID: Date] = [:]

    func fileBrowser(for project: Project) -> FileBrowserModel {
        if let browser = fileBrowsers[project.id],
           browser.project.path == project.path, browser.project.host == project.host { return browser }
        let browser = FileBrowserModel(project: project)
        fileBrowsers[project.id] = browser
        return browser
    }
    @Published var favoriteSessionKeys: Set<String> = []
    @Published var notes: [UUID: String] = [:]
    @Published var showRename = false
    @Published var renameText = ""
    private var renameID: UUID?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: WorkspaceStorage.domain) ?? .standard,
         loadWorkspace: Bool = true) {
        self.defaults = defaults
        guard loadWorkspace else { return }
        let legacy = UserDefaults(suiteName: "ResearchDesk")
        for key in ["sessionHistory", "favoriteSessionKeys", "projectNotes", "paperRepository"] {
            if defaults.object(forKey: key) == nil, let value = legacy?.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        do {
            projects = try WorkspaceStorage.loadOrMigrate(primary: defaults, legacy: legacy)
        } catch {
            storageError = "Workspaces could not be loaded: \(error.localizedDescription)"
        }
        if let data = defaults.data(forKey: "sessionHistory"), let stored = try? JSONDecoder().decode([UUID: [SavedAgentSession]].self, from: data) { history = stored }
        if let data = defaults.data(forKey: "sessionHistoryChecked"),
           let stored = try? JSONDecoder().decode([UUID: Date].self, from: data) { historyChecked = stored }
        favoriteSessionKeys = Set(defaults.stringArray(forKey: "favoriteSessionKeys") ?? [])
        if let data = defaults.data(forKey: "projectNotes"), let stored = try? JSONDecoder().decode([UUID: String].self, from: data) { notes = stored }
        paperRepository = defaults.string(forKey: "paperRepository") ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Projects/paper-app").path
        let previousSelection = defaults.string(forKey: "selectedWorkspaceID").flatMap(UUID.init(uuidString:))
        selected = projects.contains(where: { $0.id == previousSelection }) ? previousSelection : projects.first?.id
        paperSelected = defaults.bool(forKey: "paperSelected")
        refresh()
    }

    var current: Project? { projects.first { $0.id == selected } }

    func persist() {
        do {
            try WorkspaceStorage.save(projects)
            if let data = try? JSONEncoder().encode(projects) { defaults.set(data, forKey: "projects") }
            saveSelection()
            storageError = ""
        } catch {
            storageError = "Workspaces could not be saved: \(error.localizedDescription)"
        }
    }

    private func saveSelection() {
        defaults.set(selected?.uuidString, forKey: "selectedWorkspaceID")
        defaults.set(paperSelected, forKey: "paperSelected")
    }

    func selectPaperWorkspace() {
        paperSelected = true
        saveSelection()
    }

    func prepareRename(_ project: Project) {
        renameID = project.id
        renameText = project.name
        showRename = true
    }

    func renameProject() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let renameID, !name.isEmpty, let index = projects.firstIndex(where: { $0.id == renameID }) else { return }
        projects[index].name = name
        persist()
        self.renameID = nil
    }

    private func favoriteKey(_ session: SavedAgentSession) -> String { "\(session.agent):\(session.id)" }
    func isFavorite(_ session: SavedAgentSession) -> Bool { favoriteSessionKeys.contains(favoriteKey(session)) }
    func toggleFavorite(_ session: SavedAgentSession) {
        let key = favoriteKey(session)
        if !favoriteSessionKeys.insert(key).inserted { favoriteSessionKeys.remove(key) }
        defaults.set(Array(favoriteSessionKeys).sorted(), forKey: "favoriteSessionKeys")
    }

    func setNote(_ text: String, for project: Project) {
        notes[project.id] = text
        if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: "projectNotes") }
    }

    func addLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add projects"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                guard !projects.contains(where: { $0.path == path && !$0.isRemote }) else { continue }
                let project = Project(name: url.lastPathComponent, path: path)
                projects.append(project)
                selected = project.id
                paperSelected = false
            }
            persist(); refresh()
        }
    }

    func addRemote() {
        let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, path.hasPrefix("/"), !projects.contains(where: { $0.host == host && $0.path == path }) else { return }
        let project = Project(name: URL(fileURLWithPath: path).lastPathComponent, path: path, host: host)
        projects.append(project); selected = project.id; paperSelected = false
        remoteHost = ""; remotePath = ""; showRemote = false
        persist(); refresh()
    }

    func prepareRemote() {
        sshHosts = SSHHosts.configured()
        remoteHost = sshHosts.first ?? ""
        showRemote = true
    }

    func browseRemote(_ path: String? = nil) {
        let host = remoteHost
        guard !host.isEmpty else { return }
        remoteBrowserBusy = true
        remoteBrowserError = ""
        let target = path ?? (remotePath.isEmpty ? "~" : remotePath)
        Task.detached { [weak self] in
            let (listing, error) = Command.remoteListing(host: host, path: target)
            await MainActor.run {
                guard let self, self.remoteHost == host else { return }
                self.remoteBrowserBusy = false
                self.remoteBrowserError = error
                if let listing {
                    self.remoteBrowsePath = listing.path
                    self.remoteEntries = listing.entries
                }
            }
        }
    }

    func chooseRemoteFolder() {
        remotePath = remoteBrowsePath
        showRemoteBrowser = false
    }

    func remove(_ project: Project) {
        sessions[project.id]?.stop()
        sessions.removeValue(forKey: project.id)
        terminals[project.id]?.stop()
        terminals.removeValue(forKey: project.id)
        notes.removeValue(forKey: project.id)
        if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: "projectNotes") }
        fileBrowsers.removeValue(forKey: project.id)
        projectTabs.removeValue(forKey: project.id)
        historyChecked.removeValue(forKey: project.id)
        historyAttempted.removeValue(forKey: project.id)
        history.removeValue(forKey: project.id)
        saveHistory()
        projects.removeAll { $0.id == project.id }
        if project.isRemote && !projects.contains(where: { $0.host == project.host }) {
            Command.closeSSHConnections(hosts: [project.host])
        }
        snapshots.removeValue(forKey: project.id)
        if selected == project.id { selected = projects.first?.id }
        persist()
    }

    func stopAgent(_ project: Project) {
        sessions[project.id]?.stop()
        sessions.removeValue(forKey: project.id)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            refreshHistory(project, force: true)
        }
    }

    func shutdown() {
        for session in sessions.values { session.stop() }
        for terminal in terminals.values { terminal.stop() }
        paperAgent?.stop()
        Command.closeSSHConnections(hosts: projects.filter(\.isRemote).map(\.host))
    }

    func openTerminal(_ project: Project) {
        if let existing = terminals[project.id], !existing.ended { return }
        terminals[project.id] = AgentSession(project: project, agent: "terminal", executable: nil)
    }

    func stopTerminal(_ project: Project) {
        terminals[project.id]?.stop()
        terminals.removeValue(forKey: project.id)
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let entries = projects
        Task.detached { [weak self] in
            var fresh: [UUID: Snapshot] = [:]
            for project in entries { fresh[project.id] = Command.snapshot(project) }
            let completed = fresh
            await MainActor.run { self?.snapshots = completed; self?.busy = false }
        }
    }

    func select(_ project: Project) {
        selected = project.id
        paperSelected = false
        saveSelection()
    }

    var paperProject: Project {
        Project(id: UUID(uuidString: "d63c5850-9630-4fbd-b8e7-695b340fd2fb")!, name: "PaperDaily", path: paperRepository)
    }

    func choosePaperRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose paper-app repo"
        panel.directoryURL = URL(fileURLWithPath: paperRepository)
        if panel.runModal() == .OK, let path = panel.url?.path {
            paperRepository = path
            defaults.set(path, forKey: "paperRepository")
            paperError = ""
        }
    }

    func openPaperAgent() {
        paperError = ""
        guard paperAgent?.ended != false else { return }
        guard let executable = AgentLocator.executable("claude") else {
            paperError = "Claude Code CLI was not found on this Mac. Install it to use the interactive console."
            return
        }
        paperAgent = AgentSession(project: paperProject, agent: "claude", executable: executable)
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "sessionHistory") }
        if let data = try? JSONEncoder().encode(historyChecked) { defaults.set(data, forKey: "sessionHistoryChecked") }
    }

    func refreshHistory(_ project: Project, force: Bool = false) {
        let now = Date()
        if !force {
            if history[project.id] != nil, let checked = historyChecked[project.id],
               now.timeIntervalSince(checked) < 300 { return }
            if let attempted = historyAttempted[project.id], now.timeIntervalSince(attempted) < 30 { return }
        }
        guard historyLoading.insert(project.id).inserted else { return }
        historyAttempted[project.id] = now
        Task.detached { [weak self] in
            let found = SessionHistory.discover(project)
            await MainActor.run {
                guard let self else { return }
                guard self.projects.contains(where: { $0.id == project.id }) else {
                    self.historyLoading.remove(project.id)
                    return
                }
                if let found {
                    self.history[project.id] = found
                    self.historyChecked[project.id] = Date()
                }
                self.historyLoading.remove(project.id)
                self.saveHistory()
            }
        }
    }

    func openAgent(_ name: String, resumeID: String? = nil, resumeWorkspace: String? = nil) {
        guard let project = current else { return }
        agentError = ""
        if let resumeID, UUID(uuidString: resumeID) == nil {
            agentError = "Invalid session ID."
            return
        }
        if let existing = sessions[project.id], !existing.ended {
            agentError = "An agent session is already running for this project. Stop it before starting another."
            return
        }
        if !project.isRemote {
            guard let executable = AgentLocator.executable(name) else {
                agentError = "\(name.capitalized) CLI was not found on this Mac. Install it or add it to a standard executable location, then try again."
                return
            }
            sessions[project.id] = AgentSession(project: project, agent: name, executable: executable, resumeID: resumeID, resumeWorkspace: resumeWorkspace)
        } else {
            sessions[project.id] = AgentSession(project: project, agent: name, executable: nil, resumeID: resumeID, resumeWorkspace: resumeWorkspace)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            refreshHistory(project, force: true)
        }
    }
}

@main struct ResearchDeskApp: App {
    @StateObject private var model = DeskModel()
    @AppStorage("sidebarHidden", store: UserDefaults(suiteName: WorkspaceStorage.domain)) private var sidebarHidden = false
    var body: some Scene {
        WindowGroup("Research Desk") {
            NavigationSplitView(columnVisibility: Binding(
                get: { sidebarHidden ? .detailOnly : .all },
                set: { sidebarHidden = $0 == .detailOnly }
            )) {
                VStack(spacing: 0) {
                    HStack {
                        HStack(spacing: 10) {
                            DeskMark(size: 23)
                            Text("research desk").font(.system(size: 15, weight: .medium)).tracking(-0.5)
                        }.foregroundStyle(DeskStyle.accent)
                        Spacer()
                        DeskSidebarToggle()
                    }.foregroundStyle(DeskStyle.muted)
                        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
                    Button { model.selectPaperWorkspace() } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 14)).foregroundStyle(DeskStyle.accent).frame(width: 19)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PaperDaily").font(.system(size: 12, weight: .medium))
                                
                            }
                            Spacer()
                            if model.paperAgent?.ended == false {
                                Circle().fill(DeskStyle.running).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { if model.paperSelected { DeskMetalPlate() } }
                    }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 24)
                    HStack {
                        DeskEyebrow(title: "Workspaces")
                        Spacer()
                        Text("\(model.projects.count)").font(.caption2).foregroundStyle(DeskStyle.muted)
                    }.padding(.horizontal, 18).padding(.bottom, 10)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.projects) { project in
                                Button { model.select(project) } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: project.isRemote ? "server.rack" : "folder")
                                            .font(.system(size: 14))
                                            .foregroundStyle(model.selected == project.id && !model.paperSelected ? DeskStyle.accent : DeskStyle.muted)
                                            .frame(width: 19)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(project.name).font(.system(size: 12, weight: model.selected == project.id && !model.paperSelected ? .medium : .regular)).lineLimit(1)
                                            if project.isRemote {
                                                Text(project.host).font(.system(size: 10)).foregroundStyle(DeskStyle.muted).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 2)
                                        if let session = model.sessions[project.id], !session.ended {
                                            Circle().fill(DeskStyle.running).frame(width: 5, height: 5)
                                        } else if let snapshot = model.snapshots[project.id], snapshot.changes > 0 {
                                            Text("\(snapshot.changes)").font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(DeskStyle.muted).help("Uncommitted changes")
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 11)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        if model.selected == project.id && !model.paperSelected { DeskMetalPlate() }
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename…") { model.prepareRename(project) }
                                    Button("Remove from desk", role: .destructive) { model.remove(project) }
                                }
                            }
                        }.padding(.horizontal, 12)
                    }
                    if !model.storageError.isEmpty {
                        Label(model.storageError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    HStack(spacing: 8) {
                        Button { model.addLocal() } label: { Label("Local folder", systemImage: "plus") }
                        Button { model.prepareRemote() } label: { Label("SSH", systemImage: "network") }
                    }.buttonStyle(DeskButtonStyle()).controlSize(.small).padding(.horizontal, 16).padding(.vertical, 16)
                }
                .background { DeskMetalSurface() }
                .navigationSplitViewColumnWidth(min: 220, ideal: 238)
                .navigationTitle("")
            } detail: {
                if model.paperSelected {
                    PaperWorkspace(model: model)
                } else if let project = model.current {
                    ProjectDetail(project: project, snapshot: model.snapshots[project.id] ?? Snapshot(), model: model)
                        .id(project.id)
                } else {
                    VStack(spacing: 16) {
                        DeskSpatialMark()
                        DeskEyebrow(title: "Your research, connected")
                        Text("A space for your next idea.")
                            .font(.system(size: 32, weight: .light)).tracking(-1.2)
                        Text("Open a local folder or connect to a machine over SSH.")
                            .font(.subheadline).foregroundStyle(DeskStyle.muted)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                        HStack {
                            DeskSidebarToggle()
                            Button("Add local project") { model.addLocal() }.buttonStyle(DeskButtonStyle(prominent: true))
                            Button("Add SSH project") { model.prepareRemote() }.buttonStyle(DeskButtonStyle())
                        }.padding(.top, 6)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DeskStyle.background)
                }
            }
            .toolbar(removing: .sidebarToggle)
            .toolbar(.hidden, for: .windowToolbar)
            .environment(\.deskToggleSidebar, { sidebarHidden.toggle() })
            .environment(\.deskSidebarHidden, sidebarHidden)
            .buttonStyle(DeskButtonStyle())
            .frame(minWidth: 1000, minHeight: 680)
            .preferredColorScheme(.dark)
            .tint(DeskStyle.accent)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.shutdown()
            }
            .alert("Rename project", isPresented: $model.showRename) {
                TextField("Project name", text: $model.renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { model.renameProject() }
            } message: {
                Text("Choose the name shown in Research Desk.")
            }
            .sheet(isPresented: $model.showRemote) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Add SSH project").font(.title2.bold())
                    Text("Uses your existing SSH configuration and known hosts. Status checks run Git read-only commands.").foregroundStyle(.secondary)
                    if model.sshHosts.isEmpty {
                        Text("No named hosts found in ~/.ssh/config.").foregroundStyle(.secondary)
                    } else {
                        Picker("SSH connection", selection: $model.remoteHost) {
                            ForEach(model.sshHosts, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        TextField("Absolute project path", text: $model.remotePath)
                        Button("Browse…") {
                            model.showRemoteBrowser = true
                            model.browseRemote()
                        }.disabled(model.remoteHost.isEmpty)
                    }
                    HStack { Spacer(); Button("Cancel") { model.showRemote = false }; Button("Add") { model.addRemote() }.buttonStyle(DeskButtonStyle(prominent: true)).disabled(model.remoteHost.isEmpty || !model.remotePath.hasPrefix("/")) }
                }.padding(24).frame(width: 520)
                .sheet(isPresented: $model.showRemoteBrowser) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Browse \(model.remoteHost)").font(.title2.bold())
                        HStack {
                            Button { model.browseRemote(URL(fileURLWithPath: model.remoteBrowsePath).deletingLastPathComponent().path) } label: {
                                Label("Up", systemImage: "arrow.up")
                            }.disabled(model.remoteBrowserBusy || model.remoteBrowsePath == "/" || model.remoteBrowsePath.isEmpty)
                            Text(model.remoteBrowsePath.isEmpty ? "Connecting…" : model.remoteBrowsePath)
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            if model.remoteBrowserBusy { ProgressView().controlSize(.small) }
                        }
                        if !model.remoteBrowserError.isEmpty {
                            Text(model.remoteBrowserError).foregroundStyle(.red).textSelection(.enabled)
                        }
                        List(model.remoteEntries) { entry in
                            HStack {
                                Image(systemName: entry.directory ? "folder" : "doc")
                                if entry.directory {
                                    Button(entry.name) {
                                        model.browseRemote(URL(fileURLWithPath: model.remoteBrowsePath).appendingPathComponent(entry.name).path)
                                    }.buttonStyle(.plain)
                                } else {
                                    Text(entry.name).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { model.showRemoteBrowser = false }
                            Button("Choose this folder") { model.chooseRemoteFolder() }
                                .buttonStyle(DeskButtonStyle(prominent: true))
                                .disabled(model.remoteBrowsePath.isEmpty || model.remoteBrowserBusy)
                        }
                    }.padding(24).frame(width: 620, height: 520)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(sidebarHidden ? "Show workspace sidebar" : "Hide workspace sidebar") { sidebarHidden.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
    }
}

struct ProjectDetail: View {
    @Environment(\.deskSidebarHidden) private var sidebarHidden
    let project: Project
    let snapshot: Snapshot
    @ObservedObject var model: DeskModel
    private var tab: Int { model.projectTabs[project.id] ?? 0 }
    @State private var favoritesOnly = false
    @State private var agentFilter = "all"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    DeskEyebrow(title: project.isRemote ? "Remote workspace" : "Local workspace")
                    HStack(spacing: 8) {
                        Text(project.name).font(.system(size: 28, weight: .light)).tracking(-0.8)
                        Button { model.prepareRename(project) } label: {
                            Image(systemName: "pencil").font(.system(size: 11))
                        }.buttonStyle(DeskButtonStyle(compact: true)).help("Rename project")
                    }
                    Text(project.isRemote ? "\(project.host):\(project.path)" : project.path)
                        .font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DeskButtonStyle()).help("Refresh project status").disabled(model.busy)
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
            HStack(spacing: 2) {
                if sidebarHidden { DeskSidebarToggle().padding(.trailing, 6) }
                tabButton("Files", "folder", 0)
                tabButton("Agent console", "terminal", 1)
                tabButton("Terminal", "greaterthan.square", 2)
                tabButton("Notes", "note.text", 3)
                tabButton("Papers", "book", 4)
                tabButton("Artifacts", "globe", 5)
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
            Rectangle().fill(DeskStyle.edge).frame(height: 0.5)
            Group {
                switch tab {
                case 0: FilesPane(browser: model.fileBrowser(for: project))
                case 1: agent
                case 2: machineTerminal
                case 4: PapersPane(project: project, model: model, library: model.papers, showAgent: { model.projectTabs[project.id] = 1 }, showTerminal: { model.projectTabs[project.id] = 2 })
                case 5: ArtifactsPane(session: model.sessions[project.id]).id(model.sessions[project.id].map(ObjectIdentifier.init))
                default: notesPane
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            statusBar
        }
        .background { DeskMetalSurface() }
    }

    @State private var showGitError = false
    private var statusBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if snapshot.error.isEmpty {
                    Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                    Text("\(snapshot.changes) changed")
                    Spacer(minLength: 12)
                    Text(snapshot.summary).lineLimit(1).truncationMode(.middle)
                } else {
                    Button { showGitError.toggle() } label: {
                        Label("Git status unavailable", systemImage: "exclamationmark.circle")
                    }.buttonStyle(.plain)
                        .help("Show Git error details")
                        .popover(isPresented: $showGitError) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Git status").font(.headline)
                                Text(snapshot.error).font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.padding(20).frame(width: 440)
                        }
                    Spacer()
                }
            }.font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                .padding(.horizontal, 24).frame(height: 32)
                .background { DeskMetalSurface() }
        }
    }

    private func tabButton(_ title: String, _ symbol: String, _ index: Int) -> some View {
        DeskTab(title: title, selected: tab == index) { model.projectTabs[project.id] = index }
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session = model.sessions[project.id] {
                AgentConsole(session: session,
                             stopSession: { model.stopAgent(project) },
                             newSession: {
                    model.sessions.removeValue(forKey: project.id)
                    model.refreshHistory(project)
                }, viewArtifact: { model.projectTabs[project.id] = 5 })
            } else {
                ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            DeskEyebrow(title: "Agent workspace")
                            Text("Pick up where you left off.").font(.system(size: 25, weight: .light)).tracking(-0.7)
                            
                        }
                        Spacer()
                        Button { model.refreshHistory(project, force: true) } label: { Label("Refresh sessions", systemImage: "arrow.clockwise") }
                            .buttonStyle(DeskButtonStyle()).controlSize(.small)
                            .disabled(model.historyLoading.contains(project.id))
                    }
                    if model.historyLoading.contains(project.id) { ProgressView().controlSize(.small) }
                    VStack(spacing: 12) {
                        launcher("codex", symbol: "chevron.left.forwardslash.chevron.right")
                        launcher("claude", symbol: "terminal")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Saved sessions")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DeskStyle.muted)
                            Spacer()
                            Menu {
                                Picker("Agent", selection: $agentFilter) {
                                    Text("All agents").tag("all")
                                    Text("Codex").tag("codex")
                                    Text("Claude").tag("claude")
                                }
                            } label: {
                                Text(agentFilter == "all" ? "All agents" : agentFilter.capitalized)
                                    .font(.system(size: 12, weight: .medium))
                            }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10)
                                .accessibilityLabel("Filter by agent")
                            Button { favoritesOnly.toggle() } label: {
                                Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
                            }.buttonStyle(DeskButtonStyle(prominent: favoritesOnly))
                                .accessibilityValue(favoritesOnly ? "On" : "Off")
                        }
                        let recent = (model.history[project.id] ?? [])
                            .filter { agentFilter == "all" || $0.agent == agentFilter }
                            .filter { !favoritesOnly || model.isFavorite($0) }
                            .sorted { $0.modified > $1.modified }
                        if recent.isEmpty {
                            Text(favoritesOnly ? "No favorite sessions match this filter." : "Sessions saved by Codex or Claude will appear here.")
                                .font(.system(size: 12)).foregroundStyle(DeskStyle.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(17)
                                
                        } else {
                            VStack(spacing: 0) {
                                ForEach(recent) { saved in
                                    HStack(spacing: 0) {
                                        Button { model.openAgent(saved.agent, resumeID: saved.id, resumeWorkspace: saved.workspace) } label: {
                                            HStack(spacing: 11) {
                                            Image(systemName: saved.agent == "codex" ? "chevron.left.forwardslash.chevron.right" : "terminal")
                                                .foregroundStyle(DeskStyle.accent).frame(width: 18)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(saved.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                                Text("\(saved.agent.capitalized) · \(saved.belongs(to: project) ? project.name : saved.locationLabel)")
                                                    .font(.system(size: 11)).foregroundStyle(DeskStyle.muted).lineLimit(1)
                                            }
                                            Spacer()
                                            Text(saved.modified.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                                            Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 16).padding(.vertical, 12)
                                        }.buttonStyle(.plain)
                                        Button { model.toggleFavorite(saved) } label: {
                                            Image(systemName: model.isFavorite(saved) ? "star.fill" : "star")
                                                .foregroundStyle(model.isFavorite(saved) ? DeskStyle.accent : DeskStyle.muted)
                                                .frame(width: 42, height: 38)
                                        }.buttonStyle(.plain).help(model.isFavorite(saved) ? "Remove favorite" : "Mark favorite")
                                    }
                                    if saved.id != recent.last?.id {
                                        Rectangle().fill(DeskStyle.edge).frame(height: 1).padding(.leading, 45)
                                    }
                                }
                            }
                        }
                    }.padding(.top, 12)
                    if !model.agentError.isEmpty { Text(model.agentError).font(.caption).foregroundStyle(.orange) }
                }.padding(20).frame(maxWidth: 960, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
            .task(id: project.id) { model.refreshHistory(project) }
    }

    private var machineTerminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(model.terminals[project.id]?.ended == true ? Color.gray : DeskStyle.accent)
                    .frame(width: 8, height: 8)
                Text(project.isRemote ? "Terminal on \(project.host)" : "Local terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text(project.path).font(.caption.monospaced()).foregroundStyle(DeskStyle.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.terminals[project.id] != nil {
                    Button("Stop") { model.stopTerminal(project) }.buttonStyle(DeskButtonStyle())
                }
                Button("New terminal") { model.stopTerminal(project); model.openTerminal(project) }
                    .buttonStyle(DeskButtonStyle(prominent: true))
            }.padding(.horizontal, 16).padding(.vertical, 6).background { DeskMetalSurface() }
            Rectangle().fill(DeskStyle.edge).frame(height: 1)
            if let session = model.terminals[project.id] {
                EmbeddedTerminal(session: session).id(ObjectIdentifier(session))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 16).padding(.top, 8)
            } else {
                ContentUnavailableView("Terminal closed", systemImage: "terminal", description: Text("Open a terminal in this project directory."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DeskStyle.background)
        .task(id: project.id) { model.openTerminal(project) }
    }

    private var notesPane: some View {
        NotesPane(project: project, model: model, showAgent: { model.projectTabs[project.id] = 1 }, showTerminal: { model.projectTabs[project.id] = 2 })
    }

    private func launcher(_ name: String, symbol: String) -> some View {
        let previous = (model.history[project.id] ?? []).filter { $0.agent == name }
        let sameProject = previous.filter { $0.belongs(to: project) }
        let otherWorkspaces = previous.filter { !$0.belongs(to: project) }
        return HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(DeskStyle.muted)
                    .frame(width: 18)
                Text(name.capitalized).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(previous.count) saved").font(.caption).foregroundStyle(DeskStyle.muted)
            }
            HStack(spacing: 8) {
                Button("New session") { model.openAgent(name) }.buttonStyle(DeskButtonStyle())
                Menu {
                    if previous.isEmpty {
                        Text("No saved sessions found")
                    } else {
                        if !sameProject.isEmpty {
                            Section("This project") {
                                ForEach(sameProject) { saved in
                                    Button(saved.title) { model.openAgent(name, resumeID: saved.id, resumeWorkspace: saved.workspace) }
                                        .help(saved.id)
                                }
                            }
                        }
                        if !otherWorkspaces.isEmpty {
                            Section("Other workspaces on this machine") {
                                ForEach(otherWorkspaces) { saved in
                                    Button("\(saved.title) · \(saved.locationLabel)") { model.openAgent(name, resumeID: saved.id, resumeWorkspace: saved.workspace) }
                                        .help("\(saved.workspace ?? "") · \(saved.id)")
                                }
                            }
                        }
                    }
                } label: { Text("Resume").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(previous.isEmpty)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background { DeskMetalPlate(radius: 16) }
    }
}

struct AgentConsole: View {
    @ObservedObject var session: AgentSession
    @StateObject private var dictation = ConsoleDictation()
    let stopSession: () -> Void
    let newSession: () -> Void
    var viewArtifact: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(session.ended ? Color.gray : DeskStyle.running).frame(width: 5, height: 5)
                Text(session.agent.capitalized).font(.system(size: 13, weight: .semibold))
                if let resumeID = session.resumeID {
                    Text("· \(resumeID.prefix(8))").font(.caption.monospaced()).foregroundStyle(DeskStyle.muted)
                }
                Text(session.ended ? "Ended · exit \(session.exitCode.map(String.init) ?? "unknown")" : "Running")
                    .font(.caption).foregroundStyle(DeskStyle.muted)
                Spacer()
                if !session.ended {
                    Button {
                        dictation.toggle { text in
                            guard !session.ended else { return }
                            session.terminal.pasteText(text)
                            session.terminal.window?.makeFirstResponder(session.terminal)
                        }
                    } label: {
                        Label(dictation.recording ? "Stop dictation" : "Dictate",
                              systemImage: dictation.recording ? "stop.circle.fill" : "mic")
                    }
                    .buttonStyle(DeskButtonStyle(prominent: dictation.recording))
                    .disabled(dictation.busy)
                    .help("Transcribe on this Mac and insert without submitting")
                }
                if session.agent == "claude" {
                    if let viewArtifact { Button("Artifact", action: viewArtifact).buttonStyle(DeskButtonStyle()) }
                    Button { session.terminal.pageUp() } label: {
                        Image(systemName: "chevron.up")
                    }.buttonStyle(DeskButtonStyle(compact: true)).help("Scroll conversation up")
                    Button { session.terminal.pageDown() } label: {
                        Image(systemName: "chevron.down")
                    }.buttonStyle(DeskButtonStyle(compact: true)).help("Scroll conversation down")
                }
                if session.ended {
                    Button("New session", action: newSession).buttonStyle(DeskButtonStyle(prominent: true))
                } else {
                    Button("Stop session", action: stopSession).buttonStyle(DeskButtonStyle())
                }
            }.padding(.horizontal, 16).padding(.vertical, 6).background { DeskMetalSurface() }
            if !dictation.status.isEmpty {
                HStack {
                    Text(dictation.status).font(.caption).foregroundStyle(DeskStyle.muted)
                    Spacer()
                    Button("Cancel") { dictation.cancel() }.buttonStyle(.plain)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            Rectangle().fill(DeskStyle.edge).frame(height: 1)
            EmbeddedTerminal(session: session).id(ObjectIdentifier(session))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 16).padding(.top, 8)
        }
        .background(DeskStyle.background)
        .onDisappear { dictation.cancel() }
        .onChange(of: ObjectIdentifier(session)) { _, _ in dictation.cancel() }
        .onChange(of: session.ended) { _, ended in if ended { dictation.cancel() } }
    }
}

struct NotesPane: View {
    let project: Project
    @ObservedObject var model: DeskModel
    let showAgent: () -> Void
    let showTerminal: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project notes").font(.system(size: 14, weight: .medium))
                    Text("Saved automatically on this Mac.").font(.caption).foregroundStyle(DeskStyle.muted)
                }
                Spacer()
                ConsolePasteMenu(text: model.notes[project.id] ?? "", project: project, model: model, showAgent: showAgent, showTerminal: showTerminal)
            }
            TextEditor(text: Binding(get: { model.notes[project.id] ?? "" }, set: { model.setNote($0, for: project) }))
                .font(.system(size: 14)).scrollContentBackground(.hidden).accessibilityLabel("Project notes")
        }.padding(20)
    }
}
