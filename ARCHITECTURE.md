# Architecture

This is a map of the codebase: where things live and how the main pieces connect. It describes structure, not exact behavior. For the details, read the type named here.

The app is **SwiftUI + SwiftData**. One codebase builds a macOS app and an iOS app. Swift 5.10; macOS 15+, iOS 26+.

## Repository layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec: targets, packages, build phases. **Source of truth for the Xcode project.** |
| `Config/` | Signing xcconfig (`Signing.local.xcconfig` is per-machine and git-ignored). |
| `MemoryPalace/` | The app. Almost all of it is shared between macOS and iOS. |
| `MemoryPalace/Models/` | SwiftData models and plain value types: conversations, messages, memories, cards, presets, … |
| `MemoryPalace/Services/` | Non-UI logic: providers, prompt assembly, memory, import / export, tools, sub-app backends. |
| `MemoryPalace/ViewModels/` | The few long-lived view models (`ConversationViewModel` drives a chat). |
| `MemoryPalace/Views/` | SwiftUI views, one folder per area (`Chat/`, `Settings/`, `Page2/`, `FileLibrary/`, `Terminal/`, …). |
| `MemoryPalace/Utils/`, `Vendor/` | Helpers and small vendored code. |
| `MemoryPalaceWidget/`, `MemoryPalacePushNSE/`, `LiveActivityShared/` | iOS widget, notification service extension, and the Live Activity types they share with the app. |
| `Sandbox/ish/` | iOS offline Linux sandbox: glue around the iSH emulator (GPLv3, adapted from OpenMinis). |
| `deps/ish` | Git submodule: the iSH emulator source, built into static libraries by `scripts/build-ish.sh`. |
| `cc-bridge/` | TypeScript (Bun) **hub** and **MCP server** that connect the app to Claude Code / Codex sessions on a computer. |
| `mp-code/` | `mp-code`, a macOS command-line tool for coding sessions (CLI + stdio MCP server). Its logic lives in the app's `CodingCLI` so tests can cover it. |
| `Packages/` | In-tree Swift packages: `SwiftStreamingMarkdown` (the streaming Markdown renderer for message bodies) and a patched `SwiftTerm`. |
| `MemoryPalaceTests/`, `StickerProbeUITests/` | macOS-hosted unit tests; iOS UI tests. |
| `fixtures/` | Synthetic test data (export packages, session logs, …). |
| `scripts/` | Build helpers (`build-cc-bridge.sh`, `build-ish.sh`, `bootstrap-sandbox.sh`, `prepare-rootfs.sh`, …). |

## Targets

| Target | Platform | Notes |
|---|---|---|
| `MemoryPalace` | macOS | The app. A pre-build phase compiles the `cc-bridge` binaries and bundles them. Sparkle handles updates. |
| `mp-code` | macOS | CLI, embedded in the app. |
| `MemoryPalaceIOS` | iOS | The app. A pre-build phase builds the iSH static libraries; the Alpine rootfs zip is bundled as a resource. |
| `MemoryPalacePushNSE` | iOS | Notification service extension (rich pushes from the hub). |
| `MemoryPalaceWidget` | iOS | Widgets and Live Activities. |
| `MemoryPalaceTests` | macOS | Unit tests, hosted in the macOS app with a redirected home directory. |
| `StickerProbeUITests` | iOS | UI tests. |

Platform-specific code uses `#if os(iOS)` / `#if os(macOS)` inside shared files. There are few platform-only files.

## Core concepts

### Floors (profiles)

A **floor** (`Profile`, managed by `ProfileManager` in `MemoryPalaceApp.swift`) is an isolated space with its own character, user persona, prompt configuration, conversations, memories and file library. All floors share **one** SwiftData `ModelContainer` (`unified.store` under Application Support). Floor-scoped models carry a `profileId`, and every query filters on it. Switching floors never swaps containers.

Files that don't belong in the database live on disk per floor: the file library, memory profile files and attachments. Large preference blobs go through `BlobStore` instead of `UserDefaults`.

### Conversations as trees

A `Conversation` owns `MessageNode`s (`Models/Conversation.swift`) linked by parent IDs. Edits and regenerations create siblings, so every conversation is a tree. The UI shows one path through it, chosen by branch selection and computed off the main thread.

Messages are never all fetched at once. Long conversations load by path and page.

### Sending a message

```
ConversationViewModel                      (one per open chat)
  └─ PromptAssembler                        builds the request from preset slots:
       system / character / persona / world books / memory / history / …
  └─ ProviderRouter                         picks the backend for the selected model
       ├─ OpenAICompatibleProvider          OpenAI-compatible endpoints (most presets)
       ├─ AnthropicProvider                 Anthropic Messages API
       ├─ ChatGPT OAuth backend             ChatGPT account sign-in (unofficial)
       └─ CCBridgeProvider                  a Claude Code / Codex session via the hub
  └─ streaming response → MessageSegments (text / thinking / tool call / tool result)
  └─ tool calls → Services/Tools, results fed back, loop until the turn ends
```

The providers live in `Services/ChatService.swift`, the assembler in `Services/PromptAssembler.swift`. The prompt inspector in the UI shows exactly what `PromptAssembler` produced: the preview reuses the real path, not a separate one.

**API keys** are stored in the Keychain (`KeychainStore`). Provider cards (`APIProvider.swift`) are global; they aren't per floor. A global budget (`GlobalBudgetStore`) is checked before each request.

### Memory

The memory module lives in `Services/Memory*.swift`, `SelfMemory*.swift` and `DreamConsolidator.swift`:

1. **Extraction**: after a turn, a background job asks a secondary model to extract atomic memories, then stores them as `Memory` records.
2. **Decay and importance**: memories have importance and age. Ranking decays older, less important ones.
3. **Retrieval and injection**: before a turn, several retrievers (keyword, vector, fallback by weight) propose candidates. The assembler fits them into a token budget and records what was injected for the inspector.
4. **Consolidation ("dreaming")**: periodically, memories are condensed into a readable profile file.

The user can inspect, edit, pin, retire and restore memories in Settings. This module is the part most actively being reworked in 0.x.

### Import

`Services/ExportPackage/` and the per-source importers:

```
ExportPackageScanner      recognizes zips / folders / files by content, not by name
  └─ ImportRunner / ImportSession       preview, category selection, cross-floor conflict probe
       └─ source parsers (Claude, ChatGPT, Gemini, AI Studio, RikkaHub, Kelivo, …)
            └─ PayloadImportEngine      shared write loop: dedupe, merge, snapshot for undo
```

Every import writes an `ImportRecord`, so a whole import can be reviewed and undone later. Importers only read local files.

### Sandbox and terminal

The terminal has three kinds of targets:

| | Backend | Code |
|---|---|---|
| **The small computer in your phone** (iOS) | iSH emulator running Alpine Linux. Booted lazily the first time something needs it; the rootfs is unpacked from the bundled zip. | `Sandbox/ish/` (`SandboxRuntime`, `RootfsManager`, `ISHShellExecutor`) |
| **My computer** | A shell on a paired computer, through the hub (tmux panes). | `Services/TerminalBackend.swift`, `CCBridgeWebSocketClient` |
| **Agents** | Claude Code / Codex sessions running on the paired computer. | `Services/CodingSessions/`, `cc-bridge/` |

`TerminalBackend` abstracts over the guest PTY and the hub so that one terminal view (SwiftTerm) drives either. The model reaches the sandbox through tool calls; you reach it through the terminal.

### cc-bridge

`cc-bridge/` is a TypeScript project compiled to self-contained binaries with `bun build --compile`.

- **`hub`**: a local WebSocket server. On macOS, `CCHubProcess` spawns it as a child process, with its token kept in the Keychain. It launches and tracks Claude Code / Codex sessions in tmux, relays messages between them and the app, and sends push notifications. iOS devices pair with a hub by scanning a QR code.
- **`mcp-server`**: an MCP server that Claude Code / Codex sessions load. It gives the agent tools to talk back to the app: reply, edit a message, read the card guide, and more.

The hub has its own test suite (`bun test`).

### Sub-apps

The home screen (`Views/Page2/`) hosts a set of small apps: reading room, calendar, file library, study, vocabulary, and others. Each pairs a `Views/<App>/` folder with its backend under `Services/<App>/` or a `Services/<App>*.swift` file. Most can expose tools to the model through `Services/Tools/`.

## Conventions worth knowing

- **XcodeGen.** After pulling or editing `project.yml`, run `xcodegen generate`.
- **SwiftData pitfalls.** Prefer explicit `profileId` predicates. Avoid predicates on optional relationships (they silently match nothing). Save explicitly when writing across contexts.
- **Large files.** `SidebarView`, `ConversationViewModel` and `CardFlowView` are several thousand lines each. They're known debt, so prefer adding new code in new files over growing them. Refactors are welcome, but open an issue first.
