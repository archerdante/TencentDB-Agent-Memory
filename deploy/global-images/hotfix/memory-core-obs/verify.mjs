// 在镜像内运行：验证 B 补丁的映射 + 装饰器链路（不发起任何 LLM 调用）
const M = await import('/app/src/core/report/metric-tracking-runner.ts');

let fail = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) fail++;
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got) + (ok ? '' : '  want=' + JSON.stringify(want)));
};

console.log('--- 1) taskId → 指标名映射 ---');
check('skill credit name', M.taskIdToMetricName('skill-extract-task-1234abcd'), 'skill_extraction_credit_rate');
check('skill token prefix', M.taskIdToTokenMetricPrefix('skill-extract-task-1234abcd'), 'skill_extraction');
check('skill query-gen prefix', M.taskIdToTokenMetricPrefix('skill-extract-query-task-1234abcd'), 'skill_extraction');
check('回归 l1', M.taskIdToTokenMetricPrefix('l1-extraction'), 'l1_extraction');
check('回归 l1-dedup', M.taskIdToTokenMetricPrefix('l1-conflict-detection'), 'l1_dedup');
check('回归 l2', M.taskIdToTokenMetricPrefix('scene-extract-xyz'), 'l2_extraction');
check('回归 l3', M.taskIdToMetricName('persona-generation'), 'l3_generation_credit_rate');
check('未知 taskId 仍为 undefined', M.taskIdToTokenMetricPrefix('something-else'), undefined);

console.log('--- 2) 装饰器端到端（fake inner runner，无 LLM 调用）---');
// 必须显式初始化可观测性后端：gateway 启动时才做，否则全局落到 Noop（什么都不打）
const F = await import('/app/src/core/report/factory.ts');
await F.initObservabilityBackend({ type: 'console' });
const inner = {
  async run() { return 'ok'; },
  lastUsage: { promptTokens: 12345, completionTokens: 678, totalTokens: 13023 },
};
const runner = new M.MetricTrackingRunner(inner, () => 'default');
const text = await runner.run({ taskId: 'skill-extract-task-e2e', prompt: 'hello', systemPrompt: 'sys', instanceId: 'default' });
check('run() 透传返回值', text, 'ok');
await new Promise(r => setTimeout(r, 600)); // 让 console producer 落盘
console.log('E2E_DONE');
console.log(fail === 0 ? 'ALL_ASSERTS_PASS' : 'ALL_ASSERTS_FAIL:' + fail);
process.exit(fail === 0 ? 0 : 1);
