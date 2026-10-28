import Foundation

enum WorkspaceStorage {
    static let domain = "com.nrieger.researchdesk"

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ResearchDesk/workspaces.json")
    }

    static func loadOrMigrate(primary: UserDefaults, legacy: UserDefaults?) throws -> [Project] {
        let file = fileURL
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode([Project].self, from: Data(contentsOf: file))
        }
        let primaryProjects = decodeProjects(primary.data(forKey: "projects"))
        let legacyProjects = decodeProjects(legacy?.data(forKey: "projects"))
        let projects = merge(primaryProjects, legacyProjects)
        try save(projects)
        return projects
    }

    static func save(_ projects: [Project]) throws {
        let file = fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(projects)
        try data.write(to: file, options: .atomic)
    }

    static func merge(_ primary: [Project], _ legacy: [Project]) -> [Project] {
        var result: [Project] = []
        var seen = Set<String>()
        for project in primary + legacy {
            let key = project.host + "\u{0}" + project.path
            if seen.insert(key).inserted { result.append(project) }
        }
        return result
    }

    private static func decodeProjects(_ data: Data?) -> [Project] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Project].self, from: data)) ?? []
    }
}
