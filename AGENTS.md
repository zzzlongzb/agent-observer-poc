# Project Agent Rules

## Long-Running Process And Acceptance Safety

These rules are mandatory for every implementation prompt, test harness, live
acceptance run, and review in this repository. A passing functional assertion
does not override a violation of these safety rules.

The execution profiles below define the scope of these rules. They apply to
future work only; they never change the verdict or evidence of a previous run.

1. Never use an unbounded polling loop. Every loop and wait must be clipped to
   an absolute wall-clock deadline and must have a deterministic timeout path.
2. Treat `watch` and other observer modes as persistent services. Never wait for
   them to exit naturally. Their lifecycle owner must explicitly stop them.
3. Put cleanup in a `finally` path that runs after success, assertion failure,
   provider failure, interruption, and timeout. Cleanup failure is a hard FAIL.
4. Track and terminate only processes owned by the run, using PID plus process
   creation time. Never use process-name-wide termination.
5. Eliminate the process-start registration race. A child must be placed in the
   kill-on-close Job Object before it can execute or spawn descendants (for
   example, create suspended, assign to the Job Object, then resume). Do not
   treat an already-exited parent as proof that it left no descendants.
   On Windows PowerShell, prefer a small, lazily loaded C# wrapper added with
   `Add-Type` over defining raw Win32 structures in PowerShell. The wrapper must
   use pointer-size-safe types and close every process, thread, pipe, and Job
   handle on success and failure. If assignment or bookkeeping fails, terminate
   the still-suspended exact process; never resume an unowned process.
6. For local process-based runs, use an external supervisor with its own
   wall-clock deadline. Worker-local
   timeout checks are insufficient because the worker can block inside WMI/CIM,
   filesystem operations, stream reads, or another synchronous command.
7. Locally, never launch PowerShell, Cargo, Node, the Observer, or test scripts as bare
   unsupervised child processes. Console children must be hidden, Job-owned,
   bounded, and included in residual-process verification.
8. Drain stdout and stderr concurrently from process start. Never wait for exit
   before draining redirected streams. Bound captured output or use bounded,
   incrementally written log files.
9. Before Cargo build or binary replacement, prove that no owned process is
   using the target executable. Prefer a unique `CARGO_TARGET_DIR` or staging
   directory per run. Treat access denied / `os error 5` as an immediate FAIL;
   do not retry or wait indefinitely.
10. Success-state waits must fail fast on `INTERRUPTED`, `ERROR`, provider
    failure, unexpected process exit, and other terminally incompatible states.
    Never wait only for `RESULT_READY` until timeout.
11. Run one live Agent scenario at a time. Do not cascade live scenarios or
    retry them automatically. Preserve failed live evidence and stop for review.
    Bounded offline iteration is allowed only under the profiles below.
    For local process-based attempts, enforce one-shot execution with an atomic,
    durable attempt marker created
    before the worker starts. A pre-existing marker for that evidence root must
    refuse another run, with no `-Force` or retry bypass. Never delete the marker
    after PASS, FAIL, BLOCKED, timeout, or crash.
12. `PASS` is allowed only when all assertions passed, the outer deadline was
    respected, cleanup succeeded, and exact residual-process checks found zero
    owned processes. Uncertain observations must be `FAIL` or `BLOCKED`.
13. Validate canonical paths before recursive move or delete operations. All
    disposable, staging, backup, and evidence paths must remain inside their
    explicitly intended roots and must never resolve to a drive or repository
    root.
14. Regression tests must exercise these production safety paths, including
    timeout, incompatible terminal state, stream pressure, cleanup failure,
    file-lock failure, and parent-exits-after-spawning-child cases. Tests must
    themselves be supervised and time-bounded when they start processes.
    Scale regression coverage to changed behavior; do not rerun every historic
    safety scenario for an unrelated document or local parsing change.
15. A worker script must refuse direct execution. It may create TEMP, a Job
    Object, logs, or children only after `-Supervised` and a one-shot start
    gate have been verified and the gate has been consumed by an atomic
    rename (`start-gate.json` -> `start-gate.consumed.json`). There is no
    `-Force`, `-Retry`, `-IgnoreGate`, `-ResetAttempt`, or `-OverwriteEvidence`.
16. Official evidence logs must use `FileMode.CreateNew` in a unique run
    directory. `FileMode.Append` is forbidden. `MaxLogBytes` is the absolute
    whole-file cap: keep draining pipes after the cap, never write past it.
17. `final-summary.json` may be written only by the runner's single terminal
    path. If the runner exits without writing it, keep the attempt marker and
    incremental events as `INCOMPLETE`; do not backfill the summary.
    `actual_duration_ms` is `finished_at - started_at`. Marker `status` is
    `STARTING` / `RUNNING` / `FINISHED`; `final_status` is `OFFLINE` /
    `FAIL` / `BLOCKED` / `TIMEOUT` / `INCOMPLETE`.
18. Set `started_at` and `absolute_deadline_at` immediately after parameter
    parse. Never recompute a fresh full deadline later. Every wait uses
    remaining time. PowerShell cannot prove a process-level hard cutoff of
    the supervisor itself; that property is `UNPROVEN`.
19. Production package, staging, and backup paths must sit strictly under
    `Join-Path $RepoRoot 'artifacts'`. `AllowedRoot` is mandatory on
    `Invoke-LocalPackageAtomicPromotion` and must never be inferred from
    `PackageRoot`'s parent. TEMP fixtures pass their unique disposable TEMP
    root explicitly.

## Prompt-Writing Requirement

Any future prompt that asks another model to implement or run process-based
tests must repeat the applicable rules above explicitly. It must state the
outer deadline, per-step deadlines, cleanup ownership, hidden-window behavior,
allowed model/network call budget, fail-fast states, evidence location, execution
profile, attempt cap, and immediate-stop conditions. A live scenario stops on
its first failure; eligible offline work follows the bounded iteration policy.
State these operational constraints concisely, not the full history of previous
phases. Never assume a model will infer them from prior conversation.

## Execution Profiles And Bounded Iteration

1. Classify the task before running it:
   - Read-only review, documentation, and pure in-host tests: no process harness,
     Job, start gate, or process attempt marker is needed when no child is
     started. Use a stated inspection/test budget and preserve actual results.
   - Isolated offline build, packaging, and deterministic tests: at most three
     verification attempts per agreed task, including the first. An ordinary
     compile/assertion failure may be fixed within scope and rerun in the same
     task without another user confirmation, only after cleanup is verified.
   - Live Agent/model/provider calls, forced termination, and real Agent
     configuration changes: separate explicit authorization; first failure or
     blocked scenario stops the task. Never classify these as offline because
     their launcher or journal is local.
2. Each local process-based attempt has a new directory, immutable logs, and
   its own one-shot marker and gate. A new attempt is not a restart of an old
   evidence root. Preserve all failed attempts; record attempt number, failure,
   fix, and outcome in one task summary. Do not reset the cap by renaming the
   task or switching models. Pure tests also retain their failure output, but
   do not need a new process framework or a formal per-case evidence bundle.
3. A timeout, cleanup failure, residual or unaccounted-for owned process,
   unsafe path/write, access denied/file-lock failure, artifact hash anomaly,
   unauthorized network/configuration change, or uncertain lifecycle ownership
   stops the whole task immediately. Attempts remaining are not permission to
   continue. Missing dependencies outside the authorized acquisition scope
   also require stopping. Never repeat a failed command unchanged to hope it
   succeeds. Intentional negative fixtures must be declared in advance; an
   expected inner failure is acceptable only if outer safety checks succeed.
4. Release integration attempts have a maximum of 20 minutes each and three
   attempts total. Set stage caps and one absolute deadline before execution,
   reserve cleanup time, and never reset a running deadline. Shorter tasks use
   shorter stated budgets. These are execution budgets, not promises about
   model reasoning time or an ability to interrupt synchronous host I/O.
5. An ordinary document/test/build failure does not require a separate handoff
   and review round. Inspect the whole affected path, including real helper
   return values, report assembly, serialization, and finalization. Test the
   same implementation used in production, not a parallel mock-only version.
   After three attempts, stop with one concise summary of completed work,
   remaining blocker, and minimum next action. Do not invent another phase.
6. Reuse existing local lifecycle/stream/finalization helpers. Adapt one
   maintained packaging entry point rather than copying another family of
   supervisor implementations. This policy does not certify existing scripts;
   their actual safety behavior must still satisfy the applicable rules.
7. On GitHub-hosted ephemeral Windows CI runners only, ordinary build and
   offline test steps may use the platform job lifecycle with an explicit
   timeout-minutes of at most 20 instead of nested local supervisors, Jobs,
   and local gates. This exception does not apply to local/self-hosted runners
   or Agent/provider/crash tests. A test starting a persistent Observer must
   still explicitly close its own process and verify cleanup. Use least
   privilege and preserve CI results; cancellation is not success.

## Release Scope And Authorization

The approved release overview is `docs/windows-alpha-release-overview.md`.
It is a roadmap and fixed acceptance boundary, not a command to run all stages.

- Target: clean source plus a self-contained Windows x64 Alpha ZIP, not a
  production-certified product. The working name is not a final brand.
- Preserve private history, existing evidence, and the stable daily-use package.
  Export only allowed source; never publish this private working-copy history.
- Existing checks can support unchanged inputs. Revalidate affected behavior
  and the final deliverable, not the entire project's historical research.
- Necessary release dependencies may be obtained from Microsoft, NuGet,
  Rust/crates.io, and GitHub under stated budgets and pinned versions. Record
  sources; do not infer permission for model calls or unrelated downloads.
- Confirm the destination before any private repository upload/cloud CI run.
  Public visibility, tags, Release publication, and version-control mutations
  still require explicit user authorization. Jujutsu remains the only VCS CLI.
- Block release for substantiated privacy/license defects, unsafe execution,
  core correctness failures, unusable deliverables, or unreliable acceptance
  evidence. Record non-blocking improvements without expanding the gate.

## Prompt Scope And Review Discipline

1. Prefer short task cards with four parts: allowed files, concrete fixes,
   verification, and stop conditions. Do not paste unrelated phase templates.
2. Freeze acceptance criteria before implementation. Separate required fixes
   from deferred improvements; do not turn each review into a larger project.
3. Review the full affected path together where feasible. Report newly found
   issues honestly, but distinguish existing blockers from new requirements.
   New non-blocking improvements are deferred, not added to this round's gate.
4. Before issuing a prompt, check that allowed operations, fixtures, commands,
   file scope, budgets, and cleanup requirements are mutually consistent.
   Explicitly permit disposable fixture writes or copies when tests need them.
5. Distinguish implementation-time estimates from measured test duration and
   enforced process deadlines. A deadline written in a prompt does not itself
   interrupt model reasoning or synchronous I/O. Do not promise otherwise.
6. Preserve all existing safety requirements. Repeat the applicable process
   protections for process-based tests, but do not introduce process harnesses
   into a no-child-process task merely to fill a template. If the execution
   environment cannot meet the agreed constraints, report BLOCKED.
7. Fixed, small, finite loops must not be described as newly discovered
   unbounded polling deadlocks. Existing deadline rules still apply; prioritize
   actual enumeration, waiting, and preventing success after timeout.
8. Keep reviews proportional to the agreed risk and scope. Do not require a
   generic framework when a local fix closes the confirmed defect. Attribute
   execution failures to models or tools only when logs support that conclusion.

## Disk Use And Artifact Retention

1. Before future build/test runs, distinguish durable evidence from disposable
   scratch, declare owned scratch paths and a disk/log budget, and check free
   space. Reuse maintained runners; do not create another cleanup service or
   harness merely to implement this policy.
2. After exact owned-process cleanup, the run's finally path must remove its
   predeclared disposable build outputs (for example isolated target, obj,
   publish and temporary package copies), on success or failure. Retain attempt
   markers, summaries, bounded logs, hashes and necessary reproduction inputs.
   Preserve minimal failure artifacts when needed, with a reason and retirement
   condition. Preserving failed evidence does not require retaining every
   rebuildable intermediate directory.
3. Recursive cleanup must validate canonical containment and reject reparse
   points. Never delete by a broad name glob, age alone, or an assumption that
   an exited parent means its files are unused. Do not clean shared caches,
   source/probe scripts, active binaries or other runs under scratch ownership.
   On uncertain ownership, file locks or cleanup failure, stop and report the
   exact paths and remaining bytes; do not retry indefinitely.
4. Existing historical evidence, snapshots and candidates remain protected.
   Their retirement requires explicit approval of an exact-path cleanup list.
   Keep the stable daily-use package, current candidate and any explicitly
   pinned rollback/toolchain. Superseded large packages and SDK download copies
   should have a documented retirement decision, not indefinite default growth.
5. Bound continuous watch recordings as well as child stdout/stderr. Declare
   per-file and per-run log caps before recording, keep draining after a cap,
   and report truncation. Do not create unlimited duplicate scan/log streams.
6. Run closeout must report scratch cleanup, retained artifacts and remaining
   disk use. These rules govern future work; they do not certify all existing
   scripts as compliant or authorize deletion of old files. Consult
   docs/local-artifact-retention.md before the first historical cleanup.
