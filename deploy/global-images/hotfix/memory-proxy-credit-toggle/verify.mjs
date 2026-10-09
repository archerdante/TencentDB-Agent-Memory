// In-container self test for the creditReport.enabled opt-out hotfix.
//
// Invoked by build.ps1 as (note --entrypoint node: the image ENTRYPOINT is
// tini + `node --import tsx/esm src/index.ts`, so anything appended after the
// image name would otherwise become arguments to index.ts and silently boot the
// proxy server instead of this test):
//
//   docker run --rm --entrypoint node -w /app \
//     -v <ctx>/verify.mjs:/tmp/verify.mjs:ro \
//     -v <ctx>/config.verify.yaml:/app/config.yaml:ro \
//     <tag> --import tsx /tmp/verify.mjs
//
// No network and no LLM calls: globalThis.fetch is replaced by a stub that
// counts invocations, so "enabled=false must not report" is a hard assertion
// rather than a timing guess. Prints "ALL_ASSERTS_PASS" on success.

import { readFileSync } from 'node:fs';
import { DEFAULT_CONFIG, buildConfig, loadYamlConfig } from '/app/src/config.ts';
import { tryReportCreditFromPath } from '/app/src/credit-reporter.ts';

let failed = 0;
function check(name, cond, extra = '') {
  if (cond) {
    console.log(`PASS ${name}`);
  } else {
    console.log(`FAIL ${name} ${extra}`);
    failed++;
  }
}

// 1) The default must stay "on" so an existing config behaves exactly as before.
check(
  'DEFAULT_CONFIG.creditReport.enabled === true',
  DEFAULT_CONFIG.creditReport?.enabled === true,
  `got=${JSON.stringify(DEFAULT_CONFIG.creditReport)}`,
);

// 2) Raw YAML load sees the new key (fixture /app/config.yaml has enabled: false).
const raw = loadYamlConfig('/app/config.yaml');
check(
  'loadYamlConfig() sees creditReport.enabled=false',
  raw?.creditReport?.enabled === false,
  `got=${JSON.stringify(raw?.creditReport)}`,
);

// 3) The merge layer honours it: buildConfig() reads YAML over DEFAULT_CONFIG.
const merged = buildConfig({});
check(
  'buildConfig() merges creditReport.enabled=false from YAML',
  merged.creditReport?.enabled === false,
  `got=${JSON.stringify(merged.creditReport)}`,
);

// 4) Source-level guards, so a partially applied patch cannot pass.
const cfgSrc = readFileSync('/app/src/config.ts', 'utf8');
check(
  'config.ts parses creditReport.enabled',
  cfgSrc.includes('enabled: yaml.creditReport?.enabled ?? DEFAULT_CONFIG.creditReport.enabled'),
);
const typeSrc = readFileSync('/app/src/types.ts', 'utf8');
check(
  'CreditReportConfig declares enabled',
  /interface CreditReportConfig \{[\s\S]*?enabled: boolean;/.test(typeSrc),
);

// 5/6) Behaviour of the switch itself, with fetch stubbed out.
const calls = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (url) => {
  calls.push(String(url));
  return new Response('{"code":0,"message":"ok"}', { status: 200 });
};

const PATH = '/dsh/default/v1/chat/completions';
const USAGE = { input_tokens: 10, output_tokens: 5 };
const PRICING = null;
const MODEL = 'deepseek/deepseek-v4.1-flash';
const UPSTREAM = 'https://api.commandcode.ai/provider/v1';

try {
  const off = await tryReportCreditFromPath(
    { enabled: false, url: 'http://127.0.0.1:9/never', timeoutMs: 100 },
    PATH, USAGE, PRICING, MODEL, UPSTREAM, 'usage',
  );
  check('enabled=false -> attempted=false', off.attempted === false, JSON.stringify(off));
  check('enabled=false -> zero fetch calls', calls.length === 0, `calls=${JSON.stringify(calls)}`);

  const on = await tryReportCreditFromPath(
    { enabled: true, url: 'http://stub.invalid/UpdateMemoryPlusUsage', timeoutMs: 100 },
    PATH, USAGE, PRICING, MODEL, UPSTREAM, 'usage',
  );
  check('enabled=true -> exactly one fetch call', calls.length === 1, `calls=${JSON.stringify(calls)}`);
  check('enabled=true -> ok=true via stub', on.ok === true, JSON.stringify(on));
} finally {
  globalThis.fetch = realFetch;
}

if (failed === 0) {
  console.log('ALL_ASSERTS_PASS');
} else {
  console.log(`ALL_ASSERTS_FAILED (${failed})`);
  process.exit(1);
}
