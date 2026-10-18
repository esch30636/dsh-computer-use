/**
 * Tool-layer smoke test for dsh-computer-use.
 *
 * Runs the real plugin layer (config, policy, tools, helper client) against the
 * real Windows helper and a mocked host: a fake attachments store (PNG header
 * dimensions), a fake context, and the dev-only @deepseek-ai/dsh-tools shim.
 *
 * It launches Notepad itself, automates only that window, and cleans up. Never
 * run this against a real user session you do not want disturbed.
 *
 * Usage (Electron-as-node, no npm install needed):
 *   $env:ELECTRON_RUN_AS_NODE=1
 *   & "D:\Applications\DeepseekHarness\DeepSeek Harness.exe" test\tool-smoke.mjs
 */

import assert from 'node:assert/strict';
import { HelperClient } from '../lib/helper-client.js';
import { normalizeConfig, helperPolicyFor } from '../lib/config.js';
import { createPolicy } from '../lib/policy.js';
import { createTools } from '../lib/tools.js';

const results = [];
let failures = 0;

async function check(name, fn) {
  const started = Date.now();
  try {
    await fn();
    results.push(`PASS ${name} (${Date.now() - started} ms)`);
    console.log(results[results.length - 1]);
  } catch (error) {
    failures += 1;
    results.push(`FAIL ${name}: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
    console.error(results[results.length - 1]);
  }
}

/** Parse PNG IHDR width/height (mimics the attachment store's normalized size). */
function pngDimensions(buffer) {
  if (buffer.length < 24) throw new Error('not a PNG');
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

const savedImages = [];
const attachments = {
  imageLimits: { mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'], maxImageBytes: 20 * 1024 * 1024, maxMessageImageBytes: 20 * 1024 * 1024, maxImageDimension: 8192, maxImagePixels: 64_000_000 },
  async saveImage({ data, mediaType, name }) {
    const { width, height } = pngDimensions(data);
    const ref = { attachmentId: `att-${savedImages.length + 1}`, mediaType, bytes: data.byteLength, width, height, name };
    savedImages.push(ref);
    return ref;
  },
};

const ctx = {
  get(service) {
    if (service === 'attachments') return attachments;
    return undefined;
  },
  logger: { info() {}, warn() {}, error() {}, debug() {} },
};

const signal = new AbortController().signal;
const exec = { agent: undefined, callId: 'call-1', signal };

function execFor(name) {
  return { ...exec, name };
}

const config = normalizeConfig({
  idleTimeoutMs: 120000,
  startupTimeoutMs: 90000,
  requestTimeoutMs: 45000,
});
const policy = createPolicy(config);
const helper = new HelperClient({
  scriptPath: undefined,
  powershellPath: 'powershell.exe',
  policy: helperPolicyFor(config),
  startupTimeoutMs: config.startupTimeoutMs,
  requestTimeoutMs: config.requestTimeoutMs,
  idleTimeoutMs: config.idleTimeoutMs,
  logger: ctx.logger,
});
const tools = createTools({ helper, config, policy, ctx, logger: ctx.logger });
const byName = new Map(tools.map((tool) => [tool.name, tool]));

function call(name, args) {
  const tool = byName.get(name);
  assert.ok(tool !== undefined, `tool ${name} is registered`);
  return tool.execute(args, execFor(name));
}

function render(name, args, value) {
  const tool = byName.get(name);
  const blocks = tool.output.render(args, value);
  return blocks;
}

let launchedPid;
let windowId;

async function main() {
  await check('register: five tools with expected names', async () => {
    assert.deepEqual([...byName.keys()].sort(), ['computer_action', 'computer_launch_app', 'computer_list_windows', 'computer_observe', 'computer_sequence']);
  });

  await check('helper: ping through the client', async () => {
    const pong = await helper.request('ping');
    assert.equal(pong.ok, true);
    assert.ok(Array.isArray(pong.displays) && pong.displays.length >= 1);
    console.log(`      displays: ${pong.displays.length}, foreground: ${pong.foreground_window_id}`);
  });

  await check('launch notepad and find its window', async () => {
    const launched = await call('computer_launch_app', { app: 'notepad.exe', wait_ms: 8000 });
    assert.ok(Array.isArray(launched.windows) && launched.windows.length >= 1, 'notepad window appeared');
    launchedPid = launched.pid;
    windowId = launched.windows[0].window_id;
    console.log(`      pid=${launchedPid} window=${windowId} title=${JSON.stringify(launched.windows[0].title)}`);
  });

  await check('list_windows includes notepad and flags nothing blocked for it', async () => {
    const listed = await call('computer_list_windows', {});
    const win = listed.windows.find((candidate) => candidate.window_id === windowId);
    assert.ok(win !== undefined, 'notepad window listed');
    assert.equal(win.blocked, false);
    const blocks = render('computer_list_windows', {}, listed);
    assert.equal(blocks[0].type, 'text');
    assert.match(blocks[0].text, /notepad/i);
  });

  let treeState;
  await check('observe: screenshot + tree returns state, image block and element indexes', async () => {
    const value = await call('computer_observe', { window_id: windowId, include_text: true });
    assert.ok(value.state_id);
    assert.equal(value.screenshots.length, 1);
    const image = value.screenshots[0].image;
    assert.ok(image.attachmentId);
    assert.ok(image.width > 0 && image.height > 0);
    assert.ok(value.coordinate.scale_x > 0);
    assert.ok(value.accessibility.tree.length > 0, 'tree is non-empty');
    assert.match(value.accessibility.tree, /\[0\] Window/i);
    treeState = value;
    const blocks = render('computer_observe', { window_id: windowId, include_text: true }, value);
    assert.equal(blocks[0].type, 'text');
    const imageBlocks = blocks.filter((block) => block.type === 'image');
    assert.equal(imageBlocks.length, 1);
    assert.ok(imageBlocks[0].attachment.attachmentId);
    console.log(`      tree elements=${value.accessibility.element_count} image=${image.width}x${image.height}`);
  });

  let editIndex;
  await check('tree: find the editable element index', async () => {
    const lines = treeState.accessibility.tree.split('\n');
    const editLine = lines.find((line) => /\]\s+(Edit|Document)\s+/.test(line) && !/Menu/i.test(line));
    assert.ok(editLine !== undefined, `editable element present in tree:\n${treeState.accessibility.tree.slice(0, 2000)}`);
    editIndex = Number(editLine.match(/^\s*\[(\d+)\]/)[1]);
    console.log(`      edit index=${editIndex} line=${editLine.trim()}`);
  });

  await check('action: click the edit control by element_index', async () => {
    const value = await call('computer_action', { action: 'click', state_id: treeState.state_id, element_index: editIndex });
    assert.equal(value.action, 'click');
    assert.equal(value.consumed, true);
    const blocks = render('computer_action', {}, value);
    assert.match(blocks[0].text, /click/);
  });

  await check('state consumption: reusing the state is refused', async () => {
    await assert.rejects(
      () => call('computer_action', { action: 'click', state_id: treeState.state_id, element_index: editIndex }),
      /already used/,
    );
  });

  let typedState;
  await check('observe again + type text, then observe and read it back', async () => {
    typedState = await call('computer_observe', { window_id: windowId, include_text: true });
    await call('computer_action', { action: 'type', state_id: typedState.state_id, text: 'Hello, DSH computer use! 你好！' });
    const after = await call('computer_observe', { window_id: windowId, include_text: true, include_document_text: true });
    const haystack = `${after.accessibility.tree}\n${after.accessibility.document_text}\n${after.accessibility.focused_element}`;
    assert.match(haystack, /Hello, DSH computer use! 你好！/, `typed text visible; haystack:\n${haystack.slice(0, 4000)}`);
  });

  await check('key chord: Control_L+a then type replacement', async () => {
    const before = await call('computer_observe', { window_id: windowId, include_text: true });
    await call('computer_action', { action: 'key', state_id: before.state_id, key: 'Control_L+a' });
    const focused = await call('computer_observe', { window_id: windowId, include_text: true });
    await call('computer_action', { action: 'type', state_id: focused.state_id, text: 'replaced' });
    const after = await call('computer_observe', { window_id: windowId, include_text: true, include_document_text: true });
    const haystack = `${after.accessibility.tree}\n${after.accessibility.document_text}`;
    assert.match(haystack, /replaced/);
    assert.doesNotMatch(haystack, /Hello, DSH computer use/);
  });

  await check('forbidden key: Windows/Meta is refused by policy', async () => {
    const state = await call('computer_observe', { window_id: windowId });
    await assert.rejects(
      () => call('computer_action', { action: 'key', state_id: state.state_id, key: 'Meta+r' }),
      /Windows\/Meta key family|FORBIDDEN_KEY|forbidden/i,
    );
  });

  await check('policy: terminal windows are denied', async () => {
    const denial = policy.windowDenial({ window_id: 1, process_name: 'cmd.exe', process_path: 'C:\\Windows\\System32\\cmd.exe', title: 'Command Prompt' });
    assert.ok(denial !== undefined);
    assert.match(denial, /blocked by policy/);
  });

  await check('set_value: works or reports ELEMENT_UNSUPPORTED without crashing', async () => {
    const state = await call('computer_observe', { window_id: windowId, include_text: true });
    try {
      await call('computer_action', { action: 'set_value', state_id: state.state_id, element_index: editIndex, value: 'set by value pattern' });
      const after = await call('computer_observe', { window_id: windowId, include_text: true, include_document_text: true });
      assert.match(`${after.accessibility.tree}\n${after.accessibility.document_text}`, /set by value pattern/);
    } catch (error) {
      assert.match(String(error.message), /ELEMENT_UNSUPPORTED|computer use failed/i);
    }
  });

  await check('scroll: returns ok (no strict layout assertion)', async () => {
    const state = await call('computer_observe', { window_id: windowId });
    const value = await call('computer_action', { action: 'scroll', state_id: state.state_id, scroll_y: 120 });
    assert.equal(value.action, 'scroll');
  });

  await check('activate_window works without a state', async () => {
    const value = await call('computer_action', { action: 'activate_window', window_id: windowId });
    assert.equal(value.action, 'activate_window');
  });

  await check('launch_app rejects blocked terminals', async () => {
    await assert.rejects(() => call('computer_launch_app', { app: 'cmd.exe', wait_ms: 1000 }), /BLOCKED_APP|blocked by policy|computer use failed/i);
  });

  await check('cleanup: helper shutdown + notepad killed', async () => {
    await helper.dispose();
    if (launchedPid !== undefined) {
      try {
        process.kill(launchedPid);
      } catch {
        // Notepad already exited.
      }
    }
    assert.equal(helper.running, false);
  });

  console.log(`\n${results.length - failures}/${results.length} checks passed`);
  if (failures > 0) {
    console.error(`${failures} check(s) failed`);
    process.exitCode = 1;
  }
}

main().catch(async (error) => {
  console.error('fatal:', error);
  try { await helper.dispose(); } catch { /* ignore */ }
  if (launchedPid !== undefined) { try { process.kill(launchedPid); } catch { /* ignore */ } }
  process.exitCode = 1;
});
