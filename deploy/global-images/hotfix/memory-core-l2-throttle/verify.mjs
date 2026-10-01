// In-container self test for the l2-task-throttle hotfix. No LLM calls, no writes.
//
// Run by build.ps1 as:
//   docker run --rm -w /app -v <thisfile>:/tmp/verify.mjs:ro <tag> node --import tsx /tmp/verify.mjs
// NOTE: bare specifiers (e.g. "js-yaml") do not resolve from /tmp, so this file
// only uses node builtins and absolute /app/... imports.
import fs from "node:fs";

const cfgMod = await import("/app/src/config.ts");
const fac = await import("/app/src/utils/pipeline-factory.ts");

let failures = 0;
function check(name, ok, detail) {
  console.log(`${ok ? "PASS " : "FAIL "} ${name}${detail ? ` -- ${detail}` : ""}`);
  if (!ok) failures++;
}

// ---------- 1. config parsing ----------
const parsed = cfgMod.parseConfig({
  pipeline: {
    l2TaskThrottle: [
      { taskId: "task-033p0atop6", minRecords: 10, maxDeferHours: 24 },
      { taskId: "   ", minRecords: 0 },
      { taskId: "broken", minRecords: "abc" },
      { taskId: "task-coerced", minRecords: "25" },
    ],
  },
});
const rules = parsed.pipeline.l2TaskThrottle;
check("parse: valid rule kept", rules.length === 2, JSON.stringify(rules));
check("parse: blank taskId dropped", !rules.some((r) => r.taskId === "   " || r.taskId === ""));
check("parse: non-numeric minRecords dropped", !rules.some((r) => r.taskId === "broken"));
check("parse: maxDeferHours preserved", rules[0]?.maxDeferHours === 24);
check("parse: numeric string coerced", rules.some((r) => r.taskId === "task-coerced" && r.minRecords === 25));
check(
  "parse: absent key -> empty array",
  cfgMod.parseConfig({ pipeline: {} }).pipeline.l2TaskThrottle.length === 0,
);

// ---------- 2. the L2 gate ----------
const KEY = "profile:team:team-xfpeozbd7l|agent:agt-xf84etboax|session:session-feishu-verify";

function rows(taskId, n, ageMs) {
  const t = new Date(Date.now() - ageMs).toISOString();
  return Array.from({ length: n }, (_, i) => ({
    record_id: `r${i}`, content: "x", type: "episodic", priority: 1, scene_name: null,
    session_key: KEY, session_id: "session-feishu-verify", team_id: "team-xfpeozbd7l",
    task_id: taskId, user_id: "usr-x", version: 1, timestamp_str: t, timestamp_start: t,
    timestamp_end: t, created_time: t, updated_time: t, metadata_json: "{}",
  }));
}

const silentLogger = { debug() {}, info() {}, warn() {}, error() {} };

async function runGate(cfg, taskId, n, ageMs) {
  let llmCalls = 0;
  const store = { isDegraded: () => false, queryL1Records: async () => rows(taskId, n, ageMs) };
  const runner = fac.createL2Runner({
    pluginDataDir: "/tmp/l2-verify-data", cfg, openclawConfig: {},
    vectorStore: store, logger: silentLogger,
    llmRunner: async () => { llmCalls++; throw new Error("llm stub invoked"); },
  });
  let result;
  try {
    result = await runner(KEY, undefined);
  } catch {
    result = undefined; // reached the extractor, i.e. not throttled
  }
  return { throttled: result?.throttled === true, skipped: result?.skipped === true, llmCalls };
}

const HOUR = 3600 * 1000;
const throttledCfg = cfgMod.parseConfig({
  pipeline: { l2TaskThrottle: [{ taskId: "task-033p0atop6", minRecords: 10, maxDeferHours: 24 }] },
});
const noRulesCfg = cfgMod.parseConfig({ pipeline: {} });

const below = await runGate(throttledCfg, "task-033p0atop6", 3, 60 * 1000);
check("gate: throttled task, 3 fresh records -> defers", below.throttled && below.skipped, JSON.stringify(below));
check("gate: deferral makes no LLM call", below.llmCalls === 0, `llmCalls=${below.llmCalls}`);

const atFloor = await runGate(throttledCfg, "task-033p0atop6", 10, 60 * 1000);
check("gate: exactly minRecords -> proceeds", !atFloor.throttled, JSON.stringify(atFloor));

const above = await runGate(throttledCfg, "task-033p0atop6", 12, 60 * 1000);
check("gate: above minRecords -> proceeds", !above.throttled, JSON.stringify(above));

const aged = await runGate(throttledCfg, "task-033p0atop6", 5, 30 * HOUR);
check("gate: maxDeferHours safety valve releases", !aged.throttled, JSON.stringify(aged));

const other = await runGate(throttledCfg, "task-0yrtwmh03t", 3, 60 * 1000);
check("gate: non-throttled task unaffected", !other.throttled, JSON.stringify(other));

const noRules = await runGate(noRulesCfg, "task-033p0atop6", 3, 60 * 1000);
check("gate: no rules configured -> legacy behavior", !noRules.throttled, JSON.stringify(noRules));

// ---------- 3. regression guard: this hotfix must not revert the read-cap ----------
const STORAGE_TOOLS = "/app/src/adapters/standalone/storage-tools.ts";
check(
  "guard: L2 read-cap still present (MAX_READ_CHARS)",
  fs.existsSync(STORAGE_TOOLS) && fs.readFileSync(STORAGE_TOOLS, "utf8").includes("MAX_READ_CHARS"),
  STORAGE_TOOLS,
);

// ---------- 4. distributed-path plumbing ----------
const workerSrc = fs.readFileSync("/app/src/services/pipeline-worker.ts", "utf8");
const serverSrc = fs.readFileSync("/app/src/gateway/server.ts", "utf8");
const coreSrc = fs.readFileSync("/app/src/core/tdai-core.ts", "utf8");
check("wiring: worker re-arms on _l2Throttled", workerSrc.includes("_l2Throttled"));
check("wiring: gateway sets _l2Throttled", serverSrc.includes("_l2Throttled"));
check("wiring: core surfaces throttled", coreSrc.includes("throttled"));

console.log("");
if (failures === 0) {
  console.log("ALL_ASSERTS_PASS");
} else {
  console.log(`ALL_ASSERTS_FAILED (${failures})`);
  process.exit(1);
}
