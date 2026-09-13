/**
 * agent-observer-poc Pi TUI bridge
 *
 * Emits lifecycle metadata only. Prompt, assistant, tool input/output, model,
 * auth, environment values, and raw argv are deliberately excluded.
 *
 * `no_session` is computed once when this extension process starts: true only
 * when `process.argv` contains a token exactly equal to `--no-session`.
 * Missing, substring, `--no-sessions`, `--no_session`, and `--no-session=...`
 * are not matches. The boolean is written on every record; argv is not.
 */
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

function argvHasExactNoSessionFlag(argv: readonly string[]): boolean {
	return argv.some((arg) => arg === "--no-session");
}

const noSession = argvHasExactNoSessionFlag(process.argv);

export default function (pi: any) {
	const root = process.env.AGENT_OBSERVER_PI_HOOK_ROOT
		?? join(process.env.LOCALAPPDATA ?? ".", "agent-observer-poc", "pi-hooks");

	const write = (event: string, ctx: any, extra: Record<string, unknown> = {}) => {
		try {
			const sessionId = ctx?.sessionManager?.getSessionId?.();
			if (typeof sessionId !== "string" || sessionId.length === 0) return;
			mkdirSync(root, { recursive: true });
			const safeId = sessionId.replace(/[^A-Za-z0-9._-]/g, "_");
			const record = {
				observer_schema: 1,
				source: "pi-extension",
				surface: "cli",
				event,
				session_id: sessionId,
				cwd: typeof ctx?.cwd === "string" ? ctx.cwd : undefined,
				session_name: typeof pi.getSessionName?.() === "string"
					? pi.getSessionName()
					: undefined,
				mode: typeof ctx?.mode === "string" ? ctx.mode : undefined,
				process_id: process.pid,
				observed_at_unix_ms: Date.now(),
				...extra,
				no_session: noSession,
			};
			appendFileSync(join(root, `${safeId}.jsonl`), `${JSON.stringify(record)}\n`, "utf8");
		} catch {
			// Observation must never block or break the agent.
		}
	};

	pi.on("session_start", (event: any, ctx: any) => {
		write("session_start", ctx, { reason: event?.reason });
	});
	pi.on("session_info_changed", (event: any, ctx: any) => {
		write("session_info_changed", ctx, {
			session_name: typeof event?.name === "string" ? event.name : undefined,
		});
	});
	pi.on("agent_start", (_event: any, ctx: any) => write("agent_start", ctx));
	pi.on("turn_start", (event: any, ctx: any) => {
		write("turn_start", ctx, {
			turn_index: Number.isInteger(event?.turnIndex) ? event.turnIndex : undefined,
		});
	});
	pi.on("agent_settled", (_event: any, ctx: any) => write("agent_settled", ctx));
	pi.on("error", (_event: any, ctx: any) => write("error", ctx));
	pi.on("session_shutdown", (_event: any, ctx: any) => write("session_shutdown", ctx));
}
