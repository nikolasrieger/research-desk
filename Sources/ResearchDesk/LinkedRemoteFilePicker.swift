import SwiftUI

struct LinkedRemoteFilePicker: View {
    let project: Project
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var path = ""
    @State private var entries: [RemoteEntry] = []
    @State private var busy = false
    @State private var error = ""
    @State private var request = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project.host).font(.system(size: 16, weight: .medium))
            HStack {
                Button { load(URL(fileURLWithPath: directory).deletingLastPathComponent().path) } label: { Image(systemName: "arrow.up") }
                    .disabled(directory == "/" || busy)
                TextField("Folder or file path", text: $path).textFieldStyle(DeskFieldStyle()).onSubmit { load(path) }
                Button("Go") { load(path) }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if !error.isEmpty { DeskErrorBanner(message: error, title: "Could not open location") }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(entries) { entry in
                        Button {
                            let target = URL(fileURLWithPath: directory).appendingPathComponent(entry.name).path
                            if entry.directory { load(target) } else { choose(target) }
                        } label: {
                            HStack {
                                Image(systemName: entry.directory ? "folder" : "doc")
                                Text(entry.name).lineLimit(1)
                                Spacer()
                                if entry.directory { Image(systemName: "chevron.right") }
                            }.padding(10)
                        }.buttonStyle(DeskSidebarRowStyle(selected: false))
                    }
                }
            }.frame(minHeight: 300)
            HStack { Button("Open file at path") { choose(path) }.disabled(path.isEmpty || busy); Spacer(); Button("Cancel") { dismiss() } }
        }.padding(20).frame(width: 620, height: 480).background(DeskStyle.surface)
            .foregroundStyle(DeskStyle.accent).buttonStyle(DeskButtonStyle()).preferredColorScheme(.dark)
            .task { load(project.path) }
    }
    private func load(_ location: String) {
        let token = UUID(); request = token; busy = true; error = ""
        Task {
            let (listing, failure) = await Task.detached { Command.remoteListing(host: project.host, path: location) }.value
            guard request == token else { return }
            busy = false
            if let listing { directory = listing.path; path = listing.path; entries = listing.entries }
            else { error = failure }
        }
    }
}
