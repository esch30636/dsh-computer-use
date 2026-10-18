/**
 * Visual check: capture a Notepad window through the real helper, keep the PNG
 * on disk so a human/agent can inspect it with read_image.
 *
 *   $env:ELECTRON_RUN_AS_NODE=1
 *   & "D:\Applications\DeepseekHarness\DeepSeek Harness.exe" test\visual-check.mjs
 */

import { copyFileSync } from 'node:fs';
import { HelperClient } from '../lib/helper-client.js';
import { normalizeConfig, helperPolicyFor } from '../lib/config.js';

const logger = { info() {}, warn() {}, debug() {}, error() {} };
const config = normalizeConfig({});
const helper = new HelperClient({
  scriptPath: undefined,
  powershellPath: 'powershell.exe',
  policy: helperPolicyFor(config),
  startupTimeoutMs: config.startupTimeoutMs,
  requestTimeoutMs: config.requestTimeoutMs,
  idleTimeoutMs: 60000,
  logger,
});

let notepadPid;
try {
  const launched = await helper.request('launch_app', { app: 'notepad.exe' });
  notepadPid = launched.pid;
  let window;
  for (let i = 0; i < 30; i += 1) {
    const listed = await helper.request('list_windows', {});
    window = (listed.windows ?? []).find((candidate) => candidate.process_id === notepadPid) ?? (listed.windows ?? []).find((candidate) => /notepad/i.test(candidate.process_name ?? ''));
    if (window !== undefined) break;
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  if (window === undefined) throw new Error('notepad window not found');
  console.log(`window id=${window.window_id} title=${JSON.stringify(window.title)} rect=${JSON.stringify(window.rect)}`);
  const state = await helper.request('get_window_state', { window_id: window.window_id, include_text: true, include_screenshot: true });
  const shot = state.screenshots[0];
  const target = 'D:\\DeepseekHarness\\_cu_recon\\notepad-state.png';
  copyFileSync(shot.path, target);
  console.log(`screenshot: ${target} (${shot.width}x${shot.height}, origin=${shot.origin_x},${shot.origin_y}, method=${shot.capture_method})`);
  console.log(`tree elements=${state.accessibility.element_count} truncated=${state.accessibility.truncated}`);
  console.log(state.accessibility.tree.split('\n').slice(0, 15).join('\n'));
} finally {
  try { await helper.request('wait', { ms: 100 }); } catch { /* ignore */ }
  if (notepadPid !== undefined) { try { process.kill(notepadPid); } catch { /* ignore */ } }
  await helper.dispose();
}
