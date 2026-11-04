import SwiftUI
import Security

struct ClaudeUsageWindow: Codable, Sendable {
    let utilization: Double
    let resetsAt: Date?
    var used: Double { min(100, max(0, utilization)) }
    var remaining: Double { 100 - used }
}
struct ClaudeUsageReading: Codable, Sendable {
    let session: ClaudeUsageWindow?
    let weekly: ClaudeUsageWindow?
    let date: Date

    static func parse(_ data: Data, date: Date = Date()) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResearchError.message("Claude returned an invalid usage response.")
        }
        let formatter = ISO8601DateFormatter()
        func window(_ key: String, kind: String) -> ClaudeUsageWindow? {
            let legacy = object[key] as? [String: Any]
            let limits = object["limits"] as? [[String: Any]] ?? []
            let value = limits.first { $0["kind"] as? String == kind }
            guard let percent = (value?["percent"] as? NSNumber ?? legacy?["utilization"] as? NSNumber)?.doubleValue, percent.isFinite else { return nil }
            var reset: Date?
            if let text = value?["resets_at"] as? String ?? legacy?["resets_at"] as? String {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text)
                if reset == nil { formatter.formatOptions = [.withInternetDateTime]; reset = formatter.date(from: text) }
            }
            return ClaudeUsageWindow(utilization: percent, resetsAt: reset)
        }
        let reading = Self(session: window("five_hour", kind: "session"), weekly: window("seven_day", kind: "weekly_all"), date: date)
        guard reading.session != nil || reading.weekly != nil else { throw ResearchError.message("No subscription usage limits were reported for this account.") }
        return reading
    }
    static func localCache() -> Self? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") } ?? home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = object["cachedUsageUtilization"] as? [String: Any],
              let usage = cache["utilization"],
              let timestamp = cache["fetchedAtMs"] as? Double,
              let payload = try? JSONSerialization.data(withJSONObject: usage) else { return nil }
        return try? parse(payload, date: Date(timeIntervalSince1970: timestamp / 1000))
    }
}

enum ClaudeUsageAPI {
    /// Credentials stay in memory and are sent only to Anthropic's usage endpoint.
    private static func token() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Code-credentials",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var candidates: [Data] = []
        if status == errSecSuccess, let data = item as? Data { candidates.append(data) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        if let data = try? Data(contentsOf: config.appendingPathComponent(".credentials.json")) { candidates.append(data) }
        for data in candidates {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { continue }
            if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 { continue }
            return token
        }
        throw ResearchError.message("Sign in or refresh your login in Claude Code on this Mac, then try again. A Claude subscription login is required.")
    }
    static func fetch() async throws -> ClaudeUsageReading {
        let token = try await Task.detached { try Self.token() }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResearchError.message("Could not read Claude usage.") }
        switch http.statusCode {
        case 200: return try ClaudeUsageReading.parse(data)
        case 401, 403: throw ResearchError.message("Claude could not authorize usage access. Open Claude Code on this Mac and sign in again.")
        case 429: throw ResearchError.message("Claude is limiting usage checks. Wait a few minutes before refreshing again. This does not mean your chat allowance is depleted.")
        default: throw ResearchError.message("Could not refresh Claude usage (HTTP \(http.statusCode)).")
        }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

@MainActor final class ClaudeUsageModel: ObservableObject {
    static let shared = ClaudeUsageModel()
    @Published var reading: ClaudeUsageReading?
    @Published var loading = false
    @Published var error = ""
    private var nextRefresh = Date.distantPast
    func refresh(force: Bool = false) {
        if let cached = ClaudeUsageReading.localCache(), cached.date > (reading?.date ?? .distantPast) { reading = cached }
        guard !loading, Date() >= nextRefresh else { return }
        if !force, let reading, Date().timeIntervalSince(reading.date) < 300 { return }
        loading = true; error = ""
        nextRefresh = Date().addingTimeInterval(60)
        Task {
            do { reading = try await ClaudeUsageAPI.fetch() }
            catch { self.error = error.localizedDescription; nextRefresh = Date().addingTimeInterval(300) }
            loading = false
        }
    }
}

struct ClaudeUsagePane: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = ClaudeUsageModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Claude usage").font(.title2)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refresh(force: true) }.disabled(model.loading)
                Button("Done") { dismiss() }
            }.buttonStyle(DeskButtonStyle())
            usageBar("Current session", window: model.reading?.session)
            usageBar("Weekly · all models", window: model.reading?.weekly)
            if let reading = model.reading {
                Text("Updated \(reading.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(DeskStyle.muted)
            }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Uses the Claude Code account on this Mac. Remote sessions may use a different account.")
                .font(.caption).foregroundStyle(DeskStyle.muted)
        }.padding(24).frame(width: 490).background(DeskStyle.background)
            .task { model.refresh() }
    }
    private func usageBar(_ title: String, window: ClaudeUsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(window.map { "\(Int($0.remaining.rounded()))% remaining" } ?? "Unavailable")
                    .font(.system(size: 12)).foregroundStyle(DeskStyle.muted)
            }
            ProgressView(value: window?.used ?? 0, total: 100)
                .tint((window?.used ?? 0) >= 90 ? .orange : DeskStyle.accent)
                .opacity(window == nil ? 0.3 : 1)
                .accessibilityLabel(title)
                .accessibilityValue(window.map { "\(Int($0.used.rounded())) percent used" } ?? "Unavailable")
            HStack {
                Text(window.map { "\(Int($0.used.rounded()))% used" } ?? "No usage reading yet")
                Spacer()
                if let reset = window?.resetsAt { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))") }
            }.font(.caption).foregroundStyle(DeskStyle.muted)
        }
    }
}
