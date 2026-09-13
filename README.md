# Agent Observer (PoC)

> **Notice**: `agent-observer-poc` is a working proof-of-concept name, not the final product name.

Agent Observer provides a non-intrusive Windows "traffic light" attention HUD (Heads-Up Display) and lifecycle monitor for AI coding agents. It helps developers track multiple concurrently running agents across different surfaces (CLI, extensions, and desktop apps) without constantly switching windows.

---

## Windows Alpha: Extract And Open

The planned `v0.1.0-alpha.1` download is a **Windows 11 x64** ZIP, not an installer.
Until a reviewed release is published, local candidate packages are not a public release.

1. Extract the **entire** ZIP into a writable folder. Do not run it inside the ZIP.
2. Double-click `AgentObserver.Hud.exe`. Keep its adjacent Observer and runtime files together.
3. The HUD observes local sessions. Green means a result is ready, yellow means last
   observed work in progress, and red means attention is required. Old evidence is
   not proof of current activity; passive journals can be delayed or incomplete.
4. Close the HUD normally to stop the Observer it started. Agent sessions are not stopped.

The self-contained candidate bundles .NET 10: end users do not need Rust, an SDK,
or a separate .NET installation. Other Windows versions and ARM64 are not yet validated.
The Alpha is unsigned. Check the published SHA-256 and source before trusting a
download; do not disable Windows security protections. There is no auto-update.

From the extracted directory, optional diagnostics are:

```powershell
.\agent-observer-poc.exe doctor --json
.\AgentObserver.Hud.exe --self-test
```

Missing optional Agents are expected diagnostics, not a requirement to install all Agents.
Pi/Grok bridges are **optional**; the commands below explicitly install or remove them.
Opening the HUD does not install bridges or change Agent settings. Session names and
workspace paths are visible on screen; review screenshots before sharing.

## Building A Candidate From Source

Use Rust 1.98.0 (MSVC), the Visual C++ build tools, and .NET SDK 10.0.401.
From a source checkout, the existing entry point builds into a new `artifacts` directory,
tests the binaries, bundles .NET 10.0.12 and notices, and produces a ZIP and `SHA256SUMS`:

```powershell
& .\tools\build-local-hud-package.ps1 -DotnetExe 'C:\path\to\dotnet.exe' -AllowDependencyDownloads
```

This command permits dependency downloads from NuGet/crates.io, not Agent/model calls.
It does not replace a daily-use package, launch the HUD UI, upload artifacts, or publish.
Its deterministic test result is not a substitute for the final fresh-directory UI check.
See `AGENTS.md` for bounded execution and retry rules.

## What It Does

When running multiple agents across projects, knowing **which agent is working**, **which is waiting for input/approval (red/yellow attention)**, and **which has completed (green)** is critical.

Agent Observer monitors agent processes and session journals, exposing four independent dimensions defined in `src/model.rs`:
- **`attention_state`**:
  - `WORKING` (Yellow): Actively executing tools, running commands, or streaming tokens.
  - `NEEDS_ME` (Red): Explicitly requires human intervention, prompt input, or tool approval.
  - `RESULT_READY` (Green): Work turn has concluded with a result ready for review.
  - `INTERRUPTED` (Red): Work was interrupted by user or execution error.
  - `UNKNOWN`: Insufficient attention evidence.
- **`evidence_freshness`**: `FRESH`, `AGING`, `STALE`, `NONE` (`WORKING` + `STALE` 表示最后一次 attention 证据表明正在工作，但该证据已过期；不能据此确认任务当前仍在运行。HUD 黄灯不会仅因 STALE 自动改变)。
- **`host_liveness`**: `ALIVE`, `DEAD`, `UNREACHABLE`, `UNKNOWN` (tracks whether the process or window exists; does not guarantee it is actively healthy).
- **`session_liveness`**: `LIVE_ACTIVE`, `LIVE_IDLE`, `DETACHED`, `LOST`, `UNKNOWN` (tracks logical session state; `LOST` indicates an abnormal exit of a bound process).

For full technical specifications of these dimensions, see [docs/observer-design.md](docs/observer-design.md).

---

## Agent & Surface Support Matrix

| Agent / Surface | Support Type | Observation Mechanism | Current Limitations |
|---|---|---|---|
| **Claude CLI** (`claude`) | Passive Discovery or Controlled Run | **Passive**: Scans `.claude\projects` JSONL journals.<br>**Run**: Spawns via `cargo run --bin agent-observer-poc -- run claude` with exact Job Object PID binding. | Passive mode relies on local disk flush timing. |
| **Codex CLI** (`codex`) | Passive Discovery or Controlled Run | **Passive**: Scans `.codex\sessions` transcripts and session indices.<br>**Run**: Spawns via `cargo run --bin agent-observer-poc -- run codex`. | Subagent child transcripts may have delayed journal updates. |
| **Claude Desktop** | Desktop Probe & Local Code Journal | **Local Code**: Claude parser scans project/session JSONL journals and distinguishes Desktop sessions via `entrypoint="claude-desktop"`, parsing `attention_state` (e.g. `WORKING`, `RESULT_READY`, `NEEDS_ME`).<br>**App Chat**: Desktop container chat lacks public per-session JSONL journals. The observer probes the desktop process and top-level window handle (`host_liveness = ALIVE`), while `session_liveness` remains `UNKNOWN`. | Lacks per-session OS process binding; Local Code journal parsing cannot be generalized to general desktop chats. |
| **Codex Desktop** | Desktop Probe & Session Journal | **Lifecycle & Attention**: Parsed from rollout/session JSONL journals (`session_meta`, `event_msg`, `task_complete`).<br>**Title Supplement**: Local `%USERPROFILE%\.codex\session_index.jsonl` is read by exact native session ID to populate `session_display_name`. | `session_index.jsonl` provides title metadata only, not primary lifecycle/attention evidence. No per-session exact OS process binding without a controlled launcher. |
| **Pi Coding Agent** (`pi`) | Passive Discovery, Bridge, or RPC Run | **Passive**: Reads `.pi\agent\sessions` JSONL files.<br>**Bridge**: Hook installed to `.pi\agent\extensions\agent-observer-bridge.ts`.<br>**Run**: Managed RPC runner via `cargo run --bin agent-observer-poc -- run pi`. | Passive discovery observes standard session files. Bridge requires installation via the PowerShell script. |
| **Grok CLI** (`grok`) | Passive Discovery or Hook Bridge | **Passive**: Reads session `summary.json` and `updates.jsonl` from Grok session roots.<br>**Bridge**: Hook registered in `.grok\hooks\agent-observer.json` capturing collector hook evidence. | Passive scanning derives status from summary/updates files without requiring bridge; bridge hook provides push evidence. Passive scanning is not identical in timeliness to native bridge events. |

---

## Getting Started & Available Commands

### 1. Diagnostic Preflight

Check whether your local environment, agent directories, and bridge files are detected:

```powershell
# Text summary
cargo run --bin agent-observer-poc -- doctor

# Machine-readable JSON output
cargo run --bin agent-observer-poc -- doctor --json
```

### 2. Observing Agents (CLI Watcher)

```powershell
# One-shot scan of active sessions
cargo run --bin agent-observer-poc -- observe

# Continuous watch loop (polls every 2 seconds by default)
cargo run --bin agent-observer-poc -- watch

# Continuous watch output formatted as JSONL
cargo run --bin agent-observer-poc -- watch --json

# Filter observations to a specific working directory
cargo run --bin agent-observer-poc -- watch --cwd "D:\work\my-project"
```

### 3. Launching Agents Under Supervised Run

Controlled execution assigns the child process directly into a Windows Job Object before execution, tracking exact PID and process start time to detect abnormal exits:

```powershell
# Launch Claude CLI under observer supervision (--cwd belongs before the child delimiter --)
cargo run --bin agent-observer-poc -- run claude --cwd "D:\work\my-project" -- --model sonnet

# Launch Codex CLI under observer supervision
cargo run --bin agent-observer-poc -- run codex --cwd "D:\work\my-project"

# Launch Pi Agent under managed RPC supervision (requires -- followed by exactly one prompt, and --pi-session-dir or AGENT_OBSERVER_PI_RPC_SESSION_ROOT)
cargo run --bin agent-observer-poc -- run pi --cwd "D:\work\my-project" --pi-session-dir "D:\work\observer-pi-sessions" -- "Review diff"
```

### 4. Running the Traffic Light Attention HUD

The Windows floating HUD (`AgentObserver.Hud`) connects to the observer's `watch --json` stream.

**Prerequisites**: Build the Rust observer binary first, then build and run the HUD project:

```powershell
# 1. Build the observer binary
cargo build --bin agent-observer-poc

# 2. Build and start the HUD (automatically launches target\debug\agent-observer-poc.exe)
dotnet build hud\AgentObserver.Hud\AgentObserver.Hud.csproj
dotnet run --project hud\AgentObserver.Hud\AgentObserver.Hud.csproj
```

To run HUD unit and projection self-tests without launching UI or child processes:

```powershell
dotnet run --project hud\AgentObserver.Hud\AgentObserver.Hud.csproj -- --self-test
```

### 5. Bridge Installation and Management

For Pi and Grok, bridges record events directly to the observer collector. The bridge installer script (`tools/install-native-agent-bridges.ps1`) supports atomic installation, safe preview, and non-destructive uninstallation:

```powershell
# Preview what would be installed (dry run, writes nothing)
powershell.exe -ExecutionPolicy Bypass -File tools/install-native-agent-bridges.ps1 -WhatIf

# Install bridges for all supported agents (Pi and Grok)
powershell.exe -ExecutionPolicy Bypass -File tools/install-native-agent-bridges.ps1 -Install

# Install only for Pi
powershell.exe -ExecutionPolicy Bypass -File tools/install-native-agent-bridges.ps1 -Scope Pi -Install

# Install only for Grok
powershell.exe -ExecutionPolicy Bypass -File tools/install-native-agent-bridges.ps1 -Scope Grok -Install

# Preview uninstallation without touching disk (dry run)
powershell.exe -ExecutionPolicy Bypass -File tools/install-native-agent-bridges.ps1 -Uninstall -WhatIf

# Perform actual uninstallation
powershell.exe -ExecutionPolicy Bypass -File tools/install-native-agent-bridges.ps1 -Uninstall
```

**Bridge Safety Guarantees**:
- **Strict Ownership**: Only removes bridge files or JSON entries matching known SHA-256 hashes and observer commands.
- **Config Preservation**: If Grok's hook configuration file contains other user hooks, custom events, or unknown settings, only the observer's specific hook entry is removed; user data, empty arrays, and custom events are verified lossless before write.
- **Fail-Safe**: If lossless verification fails, writing is aborted and the target file remains byte-for-byte unchanged.

---

## Runtime Requirements & Known Limitations

### Runtime Requirements
- **OS**: Windows 11 x64 is the Alpha validation target. Uses Windows Job Objects, Process Threads APIs, and Win32 Window Probes.
- **Rust Toolchain**: Rust 1.98.0 MSVC for the candidate build (Edition 2024); this is a pinned build baseline, not a tested minimum version.
- **PowerShell**: Windows PowerShell 5.1+ (used by bridge collectors and verification scripts).
- **.NET**: Source builds target `net10.0-windows`, using SDK 10.0.401. The self-contained candidate includes runtime 10.0.12.

### Current Status & Known Limitations
- **Packaging & CI**: Candidate packaging and a manual Windows CI workflow are supplied. Public release and hosted CI execution require separate approval; no MSI installer is provided.
- **Process Hard Cutoff**: Hard process cutoff enforcement by an external supervisor is implemented in native test harnesses, but PowerShell-internal worker execution deadlines remain **unproven** at the OS kernel boundary.

---

## Privacy & Network Boundaries

Agent Observer enforces clear boundaries regarding privacy, network access, and data retention:

1. **No External Network Calls by Observer**:
   The observer (`observe`, `watch`, `doctor`) and native bridge scripts perform **zero network requests** and invoke **zero external LLM APIs**.
2. **Controlled Run Network Activity**:
   When launching an agent via `cargo run --bin agent-observer-poc -- run <family>`, any network activity is strictly that of the underlying agent talking to its configured model provider. The observer adds no telemetry or network relay.
3. **Journal Inspection vs Body Storage**:
   Passive observation reads existing local journals and session transcripts (`.codex\sessions`, `.claude\projects`, etc.) to extract turn state, timestamps, and message roles. The observer derives operational status (e.g. attention needed vs working), but **does not publish or transmit transcript bodies or user prompts** to any external server. Derived operational state records reside solely on your local filesystem.
