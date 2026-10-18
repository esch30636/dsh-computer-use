/**
 * Plugin wiring smoke test: runs `apply()` against a fake cordis context with
 * the dev-only @deepseek-ai/dsh-tools shim. Verifies tool registration, prompt
 * section contribution, config validation, and disposal without touching the
 * real desktop.
 *
 *   $env:ELECTRON_RUN_AS_NODE=1
 *   & "D:\Applications\DeepseekHarness\DeepSeek Harness.exe" test\plugin-apply.mjs
 */

import assert from 'node:assert/strict';
import { existsSync, writeFileSync } from 'node:fs';
import { apply, OverlayGuard } from '../lib/index.js';
import { normalizeConfig } from '../lib/config.js';

const registered = [];
const disposers = [];
const sections = [];

const attachments = { saveImage: async () => { throw new Error('not used'); } };
const systemPrompt = { section(entry) { sections.push(entry); return () => {}; } };
const logger = { info() {}, warn() {}, error() {}, debug() {} };

const scope = {
  tools: {
    register(tool) {
      registered.push(tool);
      return () => {};
    },
  },
  effect(fn) {
    const disposer = fn();
    if (typeof disposer === 'function') disposers.push(disposer);
    return disposer;
  },
  get(service) {
    if (service === 'attachments') return attachments;
    return undefined;
  },
  logger,
};

const ctx = {
  logger,
  get(service) {
    if (service === 'systemPrompt') return systemPrompt;
    if (service === 'attachments') return attachments;
    return undefined;
  },
  effect(fn) {
    const disposer = fn();
    if (typeof disposer === 'function') disposers.push(disposer);
    return disposer;
  },
  inject(services, callback) {
    assert.deepEqual(services, ['attachments']);
    callback(scope);
  },
};

apply(ctx, { idleTimeoutMs: 60000 });
assert.equal(registered.length, 5, 'five tools registered');
assert.deepEqual(registered.map((tool) => tool.name).sort(), [
  'computer_action',
  'computer_launch_app',
  'computer_list_windows',
  'computer_observe',
  'computer_sequence',
]);
for (const tool of registered) {
  assert.equal(typeof tool.description, 'string');
  assert.ok(tool.description.length > 40);
  assert.equal(typeof tool.execute, 'function');
  assert.equal(typeof tool.output.render, 'function');
}
assert.equal(sections.length, 1);
assert.equal(sections[0].name, 'tool:computer-use');
assert.ok(sections[0].text.includes('computer_observe'));
assert.ok(sections[0].text.includes('Windows/Meta'));
assert.ok(sections[0].text.includes('USER_ESCAPE'), 'prompt teaches ESC termination');

// Unknown config keys must fail loudly instead of being ignored.
assert.throws(() => apply(ctx, { deleteEverything: true }), /unknown dsh-computer-use config key/);
// Wrong types fail with the offending key named.
assert.throws(() => apply(ctx, { screenshotMaxWidth: 'big' }), /screenshotMaxWidth/);
assert.throws(() => apply(ctx, { overlayEdgeOpacity: 101 }), /overlayEdgeOpacity/);
assert.throws(() => apply(ctx, { overlayMessage: '' }), /overlayMessage/);

// ESC kill switch: a pending stop blocks computer use; a newer user message re-arms it.
{
  const guard = new OverlayGuard({ config: normalizeConfig({}), logger });
  guard.prepare();
  const env = guard.helperEnv('D:/plugin/helper/CuOverlay.ps1');
  assert.equal(env.DSH_CU_OVERLAY, '1');
  assert.ok(env.DSH_CU_STATE_DIR.length > 0);
  const log = [];
  const exec = { agent: { session: { id: 's-test', log } } };
  guard.beginTool('computer_observe', exec);
  writeFileSync(guard.escapePath, String(Date.now() - 10));
  assert.throws(() => guard.beginTool('computer_action', exec), /USER_ESCAPE/);
  log.push({ type: 'user/message', time: Date.now() + 1000 });
  guard.beginTool('computer_observe', exec);
  assert.equal(existsSync(guard.escapePath), false, 'newer user message clears the ESC stop');
  guard.dispose();
  console.log('PASS overlay guard: ESC stop blocks tools, newest user message re-arms');
}

// Disposal must be idempotent and must not throw.
for (const dispose of disposers) dispose();
for (const dispose of disposers) dispose();

console.log(`PASS plugin apply: ${registered.length} tools, 1 prompt section, config validation, disposal (${disposers.length} disposers)`);
