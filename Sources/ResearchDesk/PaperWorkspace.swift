import SwiftUI

struct PaperWorkspace: View {
    @Environment(\.deskSidebarHidden) private var sidebarHidden
    @ObservedObject var model: DeskModel
    @State private var tab = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    DeskEyebrow(title: "Paper workspace")
                    Text("PaperDaily").font(.system(size: 28, weight: .light)).tracking(-0.8)
                    Text(model.paperRepository)
                        .font(.system(size: 11))
                        .foregroundStyle(DeskStyle.muted)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Choose repo…") { model.choosePaperRepository() }
                    .buttonStyle(DeskButtonStyle())
                    .disabled(model.paperAgent?.ended == false)
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)

            HStack(spacing: 2) {
                if sidebarHidden { DeskSidebarToggle().padding(.trailing, 6) }
                tabButton("Files", "folder", 0)
                tabButton("Claude console", "terminal", 1)
                tabButton("Papers", "book", 2)
                tabButton("Artifacts", "globe", 3)
                tabButton("Notes", "note.text", 4)
                tabButton("Terminal", "terminal", 5)
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
            Rectangle().fill(DeskStyle.edge).frame(height: 0.5)

            Group {
                switch tab {
                case 0: FilesPane(browser: model.fileBrowser(for: model.paperProject)).id(model.paperRepository)
                case 2: PapersPane(project: model.paperProject, model: model, library: model.papers, showAgent: { tab = 1 }, showTerminal: { tab = 5 })
                case 3: ArtifactsPane(session: model.paperAgent).id(model.paperAgent.map(ObjectIdentifier.init))
                case 4: NotesPane(project: model.paperProject, model: model, showAgent: { tab = 1 }, showTerminal: { tab = 5 })
                case 5:
                    if let session = model.terminals[model.paperProject.id] {
                        AgentConsole(session: session, stopSession: { session.stop() }, newSession: { model.terminals.removeValue(forKey: model.paperProject.id) })
                    } else {
                        Button("Open terminal") { model.openTerminal(model.paperProject) }.buttonStyle(DeskButtonStyle(prominent: true))
                    }
                default: console
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background { DeskMetalSurface() }
    }

    private func tabButton(_ title: String, _ symbol: String, _ index: Int) -> some View {
        DeskTab(title: title, selected: tab == index) { tab = index }
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.paperError.isEmpty {
                Label(model.paperError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.top, 8)
            }
            if let session = model.paperAgent {
                AgentConsole(session: session, stopSession: {
                    session.stop()
                    model.paperAgent = nil
                }, newSession: { model.paperAgent = nil }, viewArtifact: { tab = 3 })
            } else {
                VStack(spacing: 12) {
                    DeskSpatialMark()
                    DeskEyebrow(title: "PaperDaily / Claude Code")
                    Text("Explore your next discovery.")
                        .font(.system(size: 28, weight: .light)).tracking(-0.8)
                    Text("Start Claude, then paste an arXiv link or a paper path.")
                        .font(.caption).foregroundStyle(DeskStyle.muted)
                        .multilineTextAlignment(.center)
                    Button("Start Claude") { model.openPaperAgent() }
                        .buttonStyle(DeskButtonStyle(prominent: true)).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }
    }
}
