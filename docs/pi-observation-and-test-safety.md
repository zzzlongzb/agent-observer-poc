# Pi 观测集成与测试安全机制

本文档阐述 Pi 适配器在双通道观测（Hook / Journal）下的 `no_session` 抑制规则，以及场景测试工具链的安全运行边界。本文档替代内部历史测试与验证报告，仅记录当前代码库中可证实的机制与实现事实。

---

## 1. Pi no_session 抑制规则

### 标记的产生
integrations/pi-agent-observer.ts 在扩展进程启动时检查
process.argv 是否包含精确等于 --no-session 的参数。
结果为布尔值，并写入每条 hook 记录，包括 false。
子串、--no-sessions、--no_session、--no-session=... 不匹配。
扩展不因此保存完整 argv。

### Hook 记录的判定
src/pi.rs 的 parse_hook_log 逐行处理 JSON，
只对 observer_schema=1 且 source="pi-extension" 的记录
累计 no_session 布尔标记：
- 出现布尔 true：记为 saw_no_session_true。
- 出现布尔 false：记为 saw_no_session_false。
- 缺失、null、字符串、数字、对象等不计入任一布尔标记。

仅当 saw_no_session_true && !saw_no_session_false 时，
该 hook 文件不产生 snapshot。

| 文件中符合条件的标记 | 是否因 no_session 抑制 |
| --- | --- |
| 只有 true，或重复 true | 是 |
| true 与缺失/非布尔值混合，且没有 false | 是 |
| 同时出现 true 和 false，无论顺序 | 否 |
| 只有 false，或重复 false | 否 |
| 只有缺失或非布尔值 | 否 |

“否”仅表示不被此规则抑制，不保证记录满足其他解析条件。
非布尔 no_session 不会仅因此导致整个文件解析失败。

### Journal 与历史记录
discover 分别调用 discover_journals 和 discover_hooks。
hook 因 no_session 被抑制，不等于删除文件，
也不意味着同 ID 的合法 journal 被此规则抑制。
旧 hook 记录缺少标记时，不倒推其历史调用模式。
no_session 不能用于区分 Desktop 与 CLI。

---

## 2. 场景测试工具链的安全边界

项目在 `tools/` 目录下提供了一组适配器场景测试与验证脚本（如 `tools/pi-adapter-harness-supervisor.ps1`、`tools/harness-lifecycle.ps1`、`tools/pi-adapter-poc-v1.1.ps1` 和 `tools/pi-adapter-harness-selftest.ps1`）。以下区分项目安全要求、当前实现及已知缺口。本文不构成这些脚本已通过完整安全验收的声明。

### 2.1 单场景运行与门禁隔离 (Single Scenario and Gate)

- **安全要求**：单场景单次运行，严禁级联与自动重试；一次性执行凭证必须原子消费、防重放。
- **已有机制**：
  - 测试主管脚本（`tools/pi-adapter-harness-supervisor.ps1`）强制单场景单次执行原则，禁止级联运行多个 live scenario，禁止单次运行中自动重试失败场景。
  - 每次运行分配独立的 `run_id` 与隔离的工作目录（`run_root`）。
- **已知缺口**：
  - 独立 `run_id` / `run_root` 与原子一次性执行凭证不是一回事。
  - 当前实现中，supervisor 启动 worker 后通过 `Set-Content -LiteralPath $gate -Value 'go'` 创建 gate 文件；worker 仅检查 `-Supervised` 并等待 gate 文件存在（`Test-Path`），尚未实现原子消费或防重放的一次性凭证机制。将这一差距列为尚未保证，当前不修改脚本。

### 2.2 显式调用预算与授权参数 (Explicit Call Budget)

- **安全要求**：未获显式授权时不得启动发起外部模型调用的 live worker。
- **已有机制**：
  - 默认情况下，supervisor 仅运行离线安全自检（`OFFLINE` 模式），不启动 live worker，不发起外部模型调用。
  - 默认仍允许启动离线自检进程（`pwsh.exe -File pi-adapter-harness-selftest.ps1`）。
  - 若需启动真实场景的 live worker，必须在 supervisor 命令行显式提供以下三个联合授权参数：
    1. `-AllowLiveScenario`：显式开关。
    2. `-Scenario <name>`：指定被测场景名称。
    3. `-ConfirmModelCallBudget <budget>`：必须与场景配置的预期模型调用预算严格一致（如预期为 1，传 0 或不传则在零副作用参数断言阶段被拦截退出）。
- **边界说明**：三个授权参数的要求严格限定于 live worker。缺省参数时仍允许执行离线自检，不写成“未给 live 参数就不会启动任何进程”。

### 2.3 墙钟超时机制 (Wall-Clock Deadline)

- **安全要求**：所有等待必须绑定绝对墙钟截止时间，禁止在循环中重置或延长。
- **已有机制**：
  - offline 自检与 live 场景使用独立的生命周期上下文（`New-HarnessLifecycle`）。
  - offline 自检上下文设置固定的超时（120 秒）。
  - live 场景在打开 gate 后调用 `Set-HarnessDeadline -Context $liveContext -TimeoutSeconds $scenarioTimeout -FromNow`，基于当前时刻设定场景截止时间（`absolute_deadline_at`）。
  - 条件等待与进程等待（`Wait-HarnessProcess`、`Wait-HarnessCondition`）均使用当前时刻与绝对截止时间之间的剩余时间作为超时参数；超时触发时记录或抛出超时处理。
- **已知缺口与限制**：
  - offline 自检与 live 场景使用独立 lifecycle，live 在打开 gate 后调用 `Set-HarnessDeadline -FromNow`，不能称为从 supervisor 启动起覆盖全部阶段的单一总截止。
  - 脚本内部检查不证明宿主进程硬截止：脚本内部超时判定属于逻辑保护，无法保证外部宿主（如 PowerShell 宿主自身、WMI/CIM 阻塞、同步文件锁或底层挂起）发生不可中断阻塞时对宿主进程实现物理硬切断。该属性在系统层面属于未证明属性。

### 2.4 快速失败机制 (Fail-Fast)

- **安全要求**：禁止单向等待目标成功状态直到超时，必须对不可恢复异常快速退出。
- **已有机制**：
  - 等待过程中不单向轮询成功标记（如 `RESULT_READY`）。
  - 一旦监测到底层进程异常退出、提供方失败（`BLOCKED` / `BLOCKED_BY_PROVIDER`）、`INTERRUPTED` 或 harness 异常，立即中止等待并快速退出。

### 2.5 进程所有权与清理管控 (Owned-Tree Cleanup)

- **安全要求**：
  - 严禁按进程名全局查杀；必须仅追踪和终止属于当前运行的进程（PID + CreationTime）。
  - **清理失败或存在 owned 残留进程时不得验收通过**。
- **已有机制**：
  - 借助 Windows Job Object 体系管控进程树，在 `finally` 块中执行清理（`Stop-HarnessOwnedProcesses`、`Close-HarnessLifecycle`）。
  - 在 `finally` 阶段调用 `Measure-HarnessCleanup`，执行清理并度量残余进程数（`owned_processes_remaining`）与清理异常（`cleanup_failure`）。
- **已知缺口**：
  - **静态代码发现（未运行复现）**：
    在 `tools/pi-adapter-harness-supervisor.ps1` 中：
    ```powershell
    $passed = $selfTestPassed -and -not $failure -and -not $cleanupFailure -and $cleanupSuccess -and
        (-not $liveAttempted -or ($liveExitCode -eq 0 -and -not $blockedByProvider -and -not $timedOut))
    if ($blockedByProvider -or $timedOut) { $passed = $false; $acceptancePass = $false }
    if ($ownedRemaining -ne 0) { $passed = $false }
    ```
    脚本在清理失败（`$cleanupFailure` 或 `-not $cleanupSuccess`）或存在 owned 残留（`$ownedRemaining -ne 0`）时，会将 `$passed` 置为 `false`，但清理失败/残留分支未同步强制清除 `$acceptancePass`。此前如果 worker 运行通过（返回 PASS），可能留下 `passed = false`、`status = PASS`、`acceptance_pass = true` 的矛盾字段输出。
  - **结论与判定准则**：删除“现有实现已保证清理失败绝不 acceptance PASS”的断言。不得教用户忽略矛盾字段；遇到上述矛盾字段时，应统一判为未通过并停止。

### 2.6 OFFLINE 自检成功与真实验收的边界

- 主管脚本首先执行离线自检套件（`tools/pi-adapter-harness-selftest.ps1`）。
- **OFFLINE 成功仅表示所执行检查通过，不证明防御机制完备或真实 Agent 验收通过**。
- 离线自检仅验证脚本脚手架自身的参数校验逻辑、清理路径及离线状态处理，不能等同于真实业务断言或真实 Agent acceptance PASS。

### 2.7 不提供直接启动真实模型调用的命令

- 本篇文档不提供直接启动真实模型调用的命令。

### 2.8 阶段总结与安全声明

- 上述缺口未关闭前，不以本文作为启动真实验收的安全批准；脚本修复另行授权。

---

## 3. 关联实现与公开文件

相关实现的具体源文件均已包含在公开源码边界内，可查阅：
- `src/pi.rs`：Rust 端 Hook 快照解析与 `no_session` 抑制判断。
- `integrations/pi-agent-observer.ts`：Node/TypeScript 端生命周期事件监听与上下文标记导出。
- `tools/pi-adapter-harness-supervisor.ps1`：场景测试主管脚本，实现预算校验、门禁控制与自检驱动。
- `tools/harness-lifecycle.ps1`：生命周期管理通用库，实现超时管理、进程所有权跟踪与残余校验。
- `tools/pi-adapter-poc-v1.1.ps1`：场景测试 Worker 实现。
- `tools/pi-adapter-harness-selftest.ps1`：脚手架离线安全性自检脚本。
- `docs/observer-design.md`：适配器整体架构设计与运行时语义公开文档。
- `AGENTS.md`：长期运行进程与验收安全准则。
