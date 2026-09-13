# Traffic Light Attention HUD v0.2.3

Build the existing Rust Observer first, then build and run the Windows HUD:

```powershell
cargo build
dotnet build hud\AgentObserver.Hud\AgentObserver.Hud.csproj
dotnet run --project hud\AgentObserver.Hud\AgentObserver.Hud.csproj
```

The HUD locates `target\debug\agent-observer-poc.exe` automatically and starts:

```text
agent-observer-poc watch --json --interval-secs 1
```

Override the executable when needed:

```powershell
dotnet run --project hud\AgentObserver.Hud\AgentObserver.Hud.csproj -- `
  --observer-exe D:\path\agent-observer-poc.exe
```

Run the dependency-free projection/parser checks with:

```powershell
dotnet run --project hud\AgentObserver.Hud\AgentObserver.Hud.csproj -- --self-test
```

QA-only flags: `--screenshot-file`, `--diagnostic-log`, and `--close-after-ms`.

The first screen shows at most eight attention rows. Use `--max-sessions 1..20`
to change that cap. Each row is a red, yellow, or green light plus the session
name, then `workspace · family surface`. A session is first admitted only when
it maps to a light and evidence is `FRESH` or `AGING`. Once admitted, later
`STALE` evidence keeps the row and the light; it does not hide the session or
appear as homepage copy. Historical `STALE` sessions are not admitted at HUD
start. `UNKNOWN` and `IDLE` are never admitted and remove an already admitted
row. Missing native titles fall back to `Session` plus the first eight
characters of the native session ID. QA-only `--replay-file` applies scan JSONL
without starting Observer.

This HUD intentionally has no tray, details page, settings page, footer, or new
IPC. Closing the HUD also terminates the Observer child it owns.

The HUD intentionally omits `--all`: recent-only discovery avoids parsing
hundreds of historical journals on every refresh. The Observer watch cache and
the HUD admission store retain sessions first seen during the current run as
their evidence ages. Use the Console Observer directly with `--all` for
historical research; it is not the live HUD default.

Session titles are passed through in their original language. Claude uses its
native journal title. Codex uses the exact native-session entry in
`%USERPROFILE%\.codex\session_index.jsonl`. The HUD does not translate titles
or derive them from prompts/cwd. Only a missing or rejected native title falls
back to `Session <id prefix>`.

Session rows reserve explicit line height for CJK glyphs and Latin descenders.
Titles and workspace metadata are vertically centered within those lines so
characters such as `g`, `p`, `q`, and `y` are not clipped.

Unchanged scans keep the existing controls still. The HUD compares a visible
render fingerprint after every Observer scan and skips layout, `ClientSize`,
`Invalidate`, and QA screenshots when the homepage has not changed. Live
status updates do not rebuild the list before the Scan arrives.
