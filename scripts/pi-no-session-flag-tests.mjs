/**
 * Offline checks for the Pi extension --no-session detector.
 *
 * The production predicate is: a process.argv token exactly equal to
 * "--no-session". This script re-evaluates that rule and also asserts the
 * extension source contains it and never persists argv.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

function argvHasExactNoSessionFlag(argv) {
	return argv.some((arg) => arg === "--no-session");
}

const cases = [
	{ name: "exact flag among Pi Desktop title helper argv", argv: ["node", "cli.js", "--print", "--no-session", "--provider", "x"], want: true },
	{ name: "exact flag only", argv: ["--no-session"], want: true },
	{ name: "rpc chat without the flag", argv: ["node", "cli.js", "--mode", "rpc"], want: false },
	{ name: "CLI print without the flag", argv: ["node", "cli.js", "--print"], want: false },
	{ name: "pi -p style print", argv: ["node", "cli.js", "-p"], want: false },
	{ name: "plural --no-sessions", argv: ["node", "cli.js", "--no-sessions"], want: false },
	{ name: "underscore --no_session", argv: ["node", "cli.js", "--no_session"], want: false },
	{ name: "equals form --no-session=true", argv: ["node", "cli.js", "--no-session=true"], want: false },
	{ name: "substring in another token", argv: ["node", "cli.js", "prefix--no-session"], want: false },
	{ name: "empty argv", argv: [], want: false },
];

const failures = [];
for (const test of cases) {
	const got = argvHasExactNoSessionFlag(test.argv);
	if (got !== test.want) {
		failures.push(`${test.name}: got ${got}, want ${test.want}`);
	}
}

const sourcePath = join(dirname(fileURLToPath(import.meta.url)), "..", "integrations", "pi-agent-observer.ts");
const source = readFileSync(sourcePath, "utf8");
const requiredSnippets = [
	"function argvHasExactNoSessionFlag",
	'arg === "--no-session"',
	"const noSession = argvHasExactNoSessionFlag(process.argv)",
	"no_session: noSession",
];
for (const snippet of requiredSnippets) {
	if (!source.includes(snippet)) {
		failures.push(`extension source missing required snippet: ${snippet}`);
	}
}
const forbiddenSnippets = [
	"argv: process.argv",
	"argv:process.argv",
	"command_line",
	"process.argv.join",
	"process.argv.slice",
	"JSON.stringify(process.argv)",
];
for (const snippet of forbiddenSnippets) {
	if (source.includes(snippet)) {
		failures.push(`extension source must not persist argv (${snippet})`);
	}
}
if (/\bargv\s*:/.test(source.replace(/function argvHasExactNoSessionFlag\(argv: readonly string\[\]\)/, ""))) {
	failures.push("extension source must not write an argv field onto hook records");
}

if (failures.length > 0) {
	console.error(`FAIL ${failures.length}`);
	for (const failure of failures) {
		console.error(`- ${failure}`);
	}
	process.exit(1);
}

console.log(`PASS ${cases.length} argv cases + source guards`);
