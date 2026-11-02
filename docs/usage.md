# Research Desk usage

An early native macOS workspace for local and SSH research repositories.

## Run

```sh
swift run --disable-sandbox
```

Or open `dist/ResearchDesk.app` in Finder. The app requires macOS 14 or newer.

Add local Git directories with **Local**, or choose a named connection from `~/.ssh/config` with **SSH**. `Include` files are read as well. After selecting a host, **Browse…** lists remote folders and files and lets you choose a project folder. The browser uses Python 3 on the remote machine. Remote status uses your existing SSH configuration, requires a known host, and never prompts for credentials in the app. It executes read-only Git commands.

**PaperDaily** is pinned above the project list. It includes **Files**, **Claude console**, **Papers**, **Artifacts**, **Notes**, and **Terminal** tabs. The console runs Claude Code locally in the paper-app repository, so you can give it arXiv links or paper paths and steer the work directly. Use **Choose repo…** if the repository has moved. Install the `claude` CLI locally to use this console.

**Agent console** runs Codex or Claude in an embedded terminal. Sessions remain live when you switch project views, and each project can have one active session. The CLI must be installed on the machine where it runs. Local Codex discovery includes the VS Code extension binary; that bundled version starts with `--no-daemon`. Install the `claude` CLI separately before starting a local Claude session. Agent permission prompts appear inside the terminal and remain under your control.

The **Resume** menu lists recent Codex and Claude sessions from the machine and user account behind the selected project. Sessions for the current project appear first; other workspaces on that machine appear below. This includes sessions reached through another SSH alias when both aliases log into the same account. Research Desk reads the CLIs' saved session metadata and caches IDs, dates, workspace paths, and agent-generated names per project, not conversation contents. Names come from Codex thread state or Claude `ai-title` records; unnamed sessions show their date and ID. **Refresh sessions** picks up conversations started elsewhere. The saved-session list has a star for favorites, an agent filter, and a Favorites toggle. Selecting a session launches `codex resume <id>` or `claude --resume <id>` in the embedded console. **Stop session** ends the terminal and returns to the session picker. If the agent exits or its SSH connection drops, **Reload session** reconnects in the same working directory and resumes the saved conversation. Claude uses its session ID; Codex uses the selected session ID, or the latest workspace session when started without one. Reload is available inside the open console even while it still shows Running; it closes the stale connection before resuming.

The **Files** tab browses a project's folders and previews UTF-8 code/text and common image formats. Animated GIFs play in the viewer; MP4, M4V, and MOV videos have native playback controls (subject to macOS codec support). Movies are fetched into a temporary local file, limited to 500 MB per preview, and removed when their preview is released. GIFs retain the 15 MB image preview limit.

Use **Download** in the preview header, **Download file** below the file list, or right-click a file and choose **Download to Downloads**. Both local and SSH files are saved in your Downloads folder, with numbered filenames when a name already exists. Downloads are independent of preview size limits; **Show in Finder** reveals the saved file. Remote transfers use existing SSH configuration without interactive authentication and time out after five minutes.

Markdown files have **Preview** and **Source** modes. Preview renders headings, paragraphs, lists, quotes, links, inline emphasis, and fenced code. Text and image preview reads are limited to 15 MB per file. **Terminal** opens an interactive shell in the selected local or SSH project directory. **Notes** saves editable text per project on this Mac. Rename a project with the pencil beside its name or the sidebar context menu; this changes its display name, not its directory. The workspace list is stored in `~/Library/Application Support/ResearchDesk/workspaces.json`; existing lists from the packaged app and `swift run` are merged on first launch. Notes, favorites, and the selected workspace use a fixed macOS preferences domain. The app shows a compact Git status summary. Live terminal processes end when the app quits; saved CLI conversations can be resumed from the menu. Shared SSH connections expire after two idle minutes and are closed when Research Desk quits.

The embedded terminal uses [SwiftTerm](Vendor/SwiftTerm/README.md), vendored under its [MIT license](Vendor/SwiftTerm/LICENSE).

**Dictate** in an agent console records your microphone; **Stop dictation** transcribes and pastes the text at the agent's current input cursor without submitting it. Press Enter yourself when ready. This uses Apple's free on-device SpeechTranscriber on macOS 26 or newer with supported hardware and system language. The first use may download a system-managed language model; audio transcription stays on this Mac. Use the packaged app so macOS can display its microphone permission prompt. Cancel, switching consoles, or ending a session discards pending dictation. Temporary audio is deleted after completion or cancellation. No clipboard contents are changed.

Terminal output is processed in small batches with a roughly 2 ms scheduling budget, preserving byte order and PTY backpressure. Detached console views continue processing output but defer presentation until shown again.

Session history is shown from the local cache immediately and checked again when it is more than five minutes old. **Refresh sessions** always requests a fresh scan. Failed scans retain the cache and automatic retries are limited to once per 30 seconds. File-browser directories, previews, filters, Markdown mode, and each project's selected tab stay in memory while switching workspaces. Each project owns an independent agent process; switching tabs or workspaces does not stop it. Explicitly stopping a session, removing its workspace, or quitting the app ends it.

For an optimized packaged build:

```sh
swift build -c release --disable-sandbox
cp .build/release/ResearchDesk dist/ResearchDesk.app/Contents/MacOS/ResearchDesk
codesign --force --sign - dist/ResearchDesk.app
```

Claude consoles support mouse-wheel and trackpad scrolling, with up/down page controls in the console header. Normal terminal output retains up to 20,000 lines. Interactive applications that enable mouse reporting receive wheel events; full-screen applications without mouse reporting receive page keys. Shift-scroll accesses terminal scrollback instead of sending wheel events when mouse reporting is active.

Select console text and press **⌘C** to copy it. When an agent captures mouse input, hold **Shift** while dragging to select terminal text. **Control-C** still interrupts the running program; **⌘C** with no selection leaves the console untouched.

The sidebar button beside Research Desk, or at the start of the tab row when collapsed (Control-Command-S) hides or shows the workspace list and remembers your preference. The native toolbar stays hidden in fullscreen.


**Papers** collects arXiv papers separately for each workspace. Add an abstract/PDF URL or paper ID to fetch the title, authors, abstract, and citation metadata. Search the collection, assign comma-separated tags or presets such as **baseline** and **related work**, copy BibTeX, open arXiv, or read the PDF inside the app. Collections persist in `~/Library/Application Support/ResearchDesk/papers.json`. Metadata requests are spaced at least three seconds apart; PDF previews are limited to 50 MB.

**Paste into…** in Notes and paper details inserts notes or an arXiv link into the workspace's running agent console or terminal. Start the destination first. It does not press Enter; shell pastes flatten newlines, while agents supporting bracketed paste retain paragraphs.

**Artifacts** displays hosted Claude HTML artifacts in an embedded browser. **Latest in chat** checks up to the last 8 MB of the current Claude session's transcript, locally or via SSH, for an artifact link. New Claude sessions receive an explicit UUID so lookup stays tied to that chat. This is best-effort link discovery, not a cloud artifact listing: if no link is recorded, use `/artifacts` in Claude Code and paste its URL. Private artifacts may require Claude sign-in inside the viewer. An external-browser fallback is available. Viewing does not publish an artifact or change its access permissions.

### Message-based agent console

Run `tools/build_debug_brief.sh`, then open `dist/ResearchDeskDebug.app`. This separate app has its own bundle identifier, preferences, and `ResearchDeskDebug` workspace storage, initially seeded from the normal workspace list. It does not replace `dist/ResearchDesk.app`.

The project **Agent console** uses the message-based view in both release and debug builds. The other views retain their existing UI. This console currently supports Claude Code, locally or over SSH, using the existing CLI installation and login on that machine. Send instructions, browse final Markdown responses, inspect live tool activity, and approve or decline requested tool actions. **Resume** loads recent saved final responses (up to the last 8 MB / 40 responses); new responses stay in memory for this debug run and also in Claude's own saved session. Intermediate messages are excluded from the response viewer.

**Changes** shows current staged and working-tree edits against HEAD, including pre-existing edits, and untracked files. It is not a per-turn attribution view. Click diff lines or shift-click a range, then **Attach selected lines** to add context to the next instruction. Previews are limited to 80 files and truncate large diffs. Refresh changes manually or after a request completes.

Brief starts Claude Code with `--permission-mode auto`. Any approvals Claude still requests appear in Progress; the debug app adds no permission bypass. Errors can be dismissed with the × button. Progress shows the current action, with deduplicated past actions collapsed by default. Selecting a changed file scrolls to its boxed code preview. Project files and Claude sessions are real and shared with your normal CLI—only the app's UI/preferences are isolated. Avoid opening the same Claude session concurrently in two clients. Use **Stop** to terminate an active request; after a connection failure the unsent instruction/context is restored for retry.

The debug Agent console opens to a **Conversations** overview of saved Claude chats and chats opened during this run. Use **Conversations** inside a chat to go back without stopping it. Each chat retains its own draft and request state. **Continue interrupted conversation** resumes the same session and asks Claude to finish its unfinished request; a normal **Continue conversation** action is also available after loading a saved chat. Interrupted transcript entries are not displayed as final responses.

The debug conversation overview scans all Claude transcripts for the selected machine/account, honoring `CLAUDE_CONFIG_DIR`, without the legacy history menu’s 40-session cap. Search by title, folder, or session ID; **This workspace only** is off by default. Other-folder conversations resume in their recorded original directory, shown in the chat header. To see another machine’s history, select one of its SSH workspaces. Codex conversations are not included in the Claude-only debug message view.

**Dictate** is also available under the debug message composer. Stop dictation to append locally transcribed speech to the current draft; it never sends the instruction. Existing draft text is preserved. Cancel or leave the conversation to discard the recording. The debug app requests its own microphone permission.

The debug message console reopens the last selected conversation per workspace. Its compact input grows with text; Dictate is beside Send on the right. Drag the response/progress divider to resize the panes. The chat header contains Back, its title, and Continue (disabled after a completed turn). Reload beside the final-response controls closes a stale connection and reloads the same saved conversation without sending an instruction. Stop remains in Progress. Markdown pipe tables render as grids; terminal box-drawing tables and code blocks keep their monospace layout with horizontal scrolling.

Final-response detection groups Claude assistant fragments by message ID and content-block index. Saved transcript replies require an explicit `end_turn`/`stop_sequence` marker or a successful `result` event. Commentary attached to tool-use messages, thinking, metadata, queued placeholders, subagent responses, and blank text are excluded. Live replies use successful `result` text, falling back to the grouped final assistant text when the result text is empty; if neither contains text, the console reports that explicitly instead of adding an empty response.

The debug message console keeps one Claude Code stream and SSH connection open per conversation across follow-ups. A final result leaves the connection idle and ready for the next instruction. Back and workspace switches do not close it. Stop, Reload, quitting the app, or a disconnected transport close it; the next instruction reconnects with the same saved session ID.

In the debug workspace sidebar, a green dot indicates an active request. A blue dot indicates a new final response waiting to be reviewed. Running work takes priority when a workspace has multiple chats. The blue indicator clears only after the latest response is visible in the active app; viewing an older response or only opening the conversation overview does not clear it.

The debug composer has a **Model** menu (shown as Default, Sonnet, Opus, Haiku, or the selected model name). Default leaves model selection to Claude Code. Before connecting, aliases are offered; the available model list is refreshed from Claude’s initialization response when provided. **Custom model…** accepts a full model ID for your configured provider. Choose between requests: an active connection uses the `set_model` control request and waits for confirmation; it does not reconnect. A rejected change leaves the prior selection in place and shows an error. Availability is determined by the CLI/account/provider.

In **Files**, drag the divider to resize the folder list. Hover a file, folder, or preview title to see its full path (including the SSH host for remote files). A gray dot marks uncommitted staged, working-tree, or untracked changes; folders are marked when they contain changed files. Git markers refresh when loading a folder, reopening the Files tab, or using Refresh.
