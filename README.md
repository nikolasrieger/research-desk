# Research Desk

A native macOS workspace for research repositories, papers, and coding agents.

Research often means jumping between servers, terminals, papers, and notes. Research Desk brings them into one place so you can stay with the problem.

- Browse local and SSH projects; preview files, GIFs, videos, and PDFs.
- Run Codex, Claude Code, and shell sessions per project.
- Collect arXiv papers, keep notes, view artifacts, and download files locally.

Requires **macOS 14+** and the Swift toolchain. Install agent CLIs separately; SSH uses your existing configuration.

```sh
swift run --disable-sandbox
```

Add a local folder or SSH workspace to begin. The optional PaperDaily workspace can point to your [paper-app](../paper-app) checkout via **Choose repo…**.

[Usage and packaging](docs/usage.md) · [Vendored SwiftTerm license](Vendor/SwiftTerm/LICENSE)
