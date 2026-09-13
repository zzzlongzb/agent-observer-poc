# Observer Design: Multi-Agent Attention & Lifecycle Model

This document specifies the technical design, lifecycle semantics, and observation boundaries of the agent observer subsystem in `agent-observer-poc`.

---

## 1. The Four-Dimensional State Model

The observer evaluates each agent session along four orthogonal, independent dimensions defined in `src/model.rs`. These dimensions are not conflated into a single flat status, ensuring that distinct aspects of health, process state, and user interaction are preserved:

```
+-------------------------------------------------------------------------------------------------+
|                                         Four Dimensions                                         |
|                                                                                                 |
|  1. attention_state:     WORKING | NEEDS_ME | RESULT_READY | INTERRUPTED | UNKNOWN               |
|  2. evidence_freshness:  FRESH | AGING | STALE | NONE                                           |
|  3. host_liveness:        ALIVE | DEAD | UNREACHABLE | UNKNOWN                                   |
|  4. session_liveness:     LIVE_ACTIVE | LIVE_IDLE | DETACHED | LOST | UNKNOWN                   |
+-------------------------------------------------------------------------------------------------+
```

### 1.1 attention_state
Maps to the operational focus required from the developer:
- **`WORKING`**: The agent is actively processing turns, calling tools, running commands, or generating tokens (mapped to Yellow light in HUD).
- **`NEEDS_ME`**: The agent explicitly requires human intervention, prompt input, or tool approval (mapped to Red light in HUD).
- **`RESULT_READY`**: The agent turn has concluded with a result ready for review (mapped to Green light in HUD).
- **`INTERRUPTED`**: The agent execution was interrupted or terminated abnormally (mapped to Red light in HUD).
- **`UNKNOWN`**: Insufficient evidence to establish attention state. Does not map to a traffic light color.

### 1.2 evidence_freshness
Tracks the temporal recency of observations against configurable wall-clock thresholds (`--stale-after-secs`):
- `FRESH`: Recent observation received within the active fresh window.
- `AGING`: Observation timestamp is aging but still within the active observation window.
- `STALE`: No new events observed past the configured freshness threshold.
- `NONE`: No observation timestamp available.

#### Key Invariant: `STALE` Does Not Override Attention
**`evidence_freshness = STALE` never suppresses or masks an active attention state.**
对于 `WORKING` + `STALE`：最后一次 attention 证据表明正在工作，但该证据已过期；不能据此确认任务当前仍在运行。在 HUD 中，黄灯不会仅因 STALE 自动改变。同样地，如果 Agent 在等待用户确认授权（`NEEDS_ME`）时停下且证据已久，freshness 变为 `STALE`，但 attention 依然保持 `NEEDS_ME`（红灯）。

### 1.3 host_liveness
Tracks whether the hosting container/application process or window is currently detected on the OS:
- `ALIVE`: Host process/window is verified alive. (Does not guarantee the agent inside is responsive).
- `DEAD`: Host process has verified exited.
- `UNREACHABLE`: Process inspection query failed or was blocked.
- `UNKNOWN`: Process existence cannot be directly established.

### 1.4 session_liveness
Tracks whether the logical session within the host is active:
- `LIVE_ACTIVE`: Logical session is active and currently processing.
- `LIVE_IDLE`: Logical session is open but quiescent.
- `DETACHED`: 已观察到当前 runtime/session 结束或脱离的证据；不表示任务仍在后台运行，也不单独证明任务成功完成。
- `LOST`: Bound session terminated abnormally without clean exit (HUD maps this to Red light regardless of attention state).
- `UNKNOWN`: Insufficient evidence to establish session liveness.

---

## 2. Identity Model: No CWD-Based Merging

Session identity is strictly separated from working directory path:
- **HUD identity = `agent_family` + `native_session_id`**。
- `runtime_binding_id` 用于精确运行绑定（exact CLI runtime binding），不替代 HUD identity。
- **`cwd` 不参与 identity，也不用于合并 session。**
- 在同一项目目录下运行多个 Agent 或连续执行多次任务，会在 Observer/HUD 中产生各自独立的卡片条目。CWD 仅作为可选项过滤条件或展示属性。

---

## 3. Desktop Observation Limits & Exact CLI Binding

### 3.1 Desktop Adapter Limits: Claude Desktop and Codex Desktop
Desktop environments present distinct architectural boundaries:
- **Claude Desktop (Local Code vs App Chat)**:
  - **Local Code**: Claude parser scans project and session JSONL journals, identifying Desktop sessions via metadata `entrypoint = "claude-desktop"`. It parses lifecycle and attention states (`WORKING`, `RESULT_READY`, `NEEDS_ME`). Lack of a per-session OS process binding does not prevent journal-based attention parsing.
  - **App Chat**: Standard desktop chats operate entirely within the Electron container without exposing public per-session JSONL files. The observer detects the desktop process host and active window handle, setting `host_liveness = ALIVE`. However, `session_liveness` remains `UNKNOWN`. Local Code journal parsing capabilities cannot be generalized to general desktop chats.
- **Codex Desktop**:
  - Primary lifecycle and attention states are parsed from session rollout JSONL journals (`session_meta`, `event_msg`, `task_complete`).
  - Local `%USERPROFILE%\.codex\session_index.jsonl` is read by exact native session ID to populate `session_display_name` (e.g. thread title). It serves as title metadata enrichment, not as the primary lifecycle state source. Exact per-session OS process binding is absent without an observer controlled run launcher.

### 3.2 Exact CLI Runtime Binding and the `LOST` Condition
When an agent is launched through `agent-observer-poc run <claude|codex|pi>`, the observer creates an exact runtime binding record capturing:
- `runtime_binding_id`: A unique run identifier;
- `pid`: Process identifier;
- `process_creation_time_unix_ms`: Exact process creation timestamp (preventing PID-reuse aliasing);
- `active_invocation`: Set while a turn is actively executing under observation.

A session transitions to `LOST` under strict criteria in `src/runtime.rs`:
1. The snapshot holds an exact `runtime_binding_id` matching an active bound invocation;
2. The observer directly observed an abnormal process exit, or loaded a persisted abnormal exit record (`AbnormalRuntimeExit`) with matching `runtime_binding_id`, `pid`, and `process_creation_time_unix_ms`;
3. The process terminated without a clean, normal exit handshake while work was still active.

**Crucial Bound**: If the Observer was offline when a process terminated and no persisted abnormal exit evidence was recorded by the supervisor, the Observer **cannot guess** `LOST`. It reports what it can prove from disk journals without fabricating crash guarantees. No claim of "catching 100% of crashes" is made.

---

## 4. Passive Discovery vs Bridge vs Controlled Run

Observer supports three distinct tiers of integration across different agent ecosystems:

| Integration Tier | Mechanism | Target Agents | Characteristics & Trade-offs |
|---|---|---|---|
| **Passive Discovery** | Reads existing session disk journals | Codex CLI (`.codex\sessions`), Claude CLI (`.claude\projects`), Pi CLI (`.pi\agent\sessions`), Grok CLI (`summary.json`, `updates.jsonl`) | Zero configuration required. No background processes or injected scripts. Observer parses native session journals. No exact process-level PID binding. Grok passive parsing reads session summary/updates files without requiring a bridge, though update timing depends on disk flushes. |
| **Native Bridge** | Installs hooks/extensions in agent configuration | Grok CLI (`.grok\hooks\agent-observer.json`), Pi Coding Agent (`.pi\agent\extensions\agent-observer-bridge.ts`) | Installed via `tools/install-native-agent-bridges.ps1`. The agent triggers the bridge on lifecycle events (e.g., prompt submission, tool execution, session finish), writing structured snapshots to disk. Operates within the agent's normal lifecycle without wrapping its executable. Grok bridge push events provide immediate hook evidence, complementing passive discovery. |
| **Controlled Run** | Observer spawns the agent child | Claude CLI, Codex CLI, Pi RPC | Executed via `agent-observer-poc run <family>`. Spawns child in a Windows Job Object with exact PID and process creation time. Provides active invocation tracking, termination detection, and precise `LOST` reporting upon abnormal exits. |

---

## 5. HUD Admission, Retention, and Title Fallback

The Traffic Light Attention HUD (`AgentObserver.Hud/Models.cs`) applies specific admission, retention, and title resolution logic:

### 5.1 Admission Rules and Color Mapping
A session snapshot is admitted to the HUD **only** when all of the following hold:
1. It maps to a valid traffic light color:
   - **Red (Priority Over Attention)**: If `session_liveness == SessionLiveness.LOST`, the HUD maps directly to Red regardless of attention state.
   - **Yellow**: `attention_state == AttentionState.WORKING`.
   - **Green**: `attention_state == AttentionState.RESULT_READY`.
   - **Red**: `attention_state == AttentionState.NEEDS_ME` or `attention_state == AttentionState.INTERRUPTED` (HUD also tolerates `ERROR` strings from raw JSON).
   - Any other attention value does not map to a traffic light color.
2. Its evidence freshness is either `EvidenceFreshness.FRESH` or `EvidenceFreshness.AGING`.

Sessions that do not map to a light color (e.g. `UNKNOWN` without `LOST`), or sessions first discovered while already `STALE`, are **never admitted** upon initial discovery.

### 5.2 Retention Rules
Once a session has been admitted to the HUD:
- **`STALE` evidence does NOT remove the row and does NOT change its light color.** As long as the session remains present in subsequent valid snapshots, it stays visible with its current light.
- A session row is removed **only** if:
  1. A subsequent valid snapshot completely omits its identity (HUD identity = `agent_family` + `native_session_id`); or
  2. A subsequent valid snapshot updates its state such that it can no longer be mapped to a traffic light color (e.g. `attention_state == UNKNOWN` without `session_liveness == LOST`).
- Note: A `source_error` or parse failure from the watcher process does **not** count as a valid empty snapshot and will not purge existing rows. An `UNKNOWN` attention state is **not** unconditionally purged if `session_liveness == LOST` keeps it mapped to Red.

### 5.3 Title Fallback
Card title rendering in the HUD is deliberately constrained:
1. Uses `session_display_name` if provided (e.g. native journal title or index entry).
2. If missing or empty, falls back to `Session ` followed by the first 8 characters of `native_session_id`.
3. The HUD does **not** derive titles from the first prompt text, does **not** fall back to CWD folder names, and does not translate strings.
