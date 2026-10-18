/**
 * Model-facing tools for dsh-computer-use.
 *
 * Four tools, modelled on the Codex Windows Computer Use surface:
 *  - `computer_list_windows` discovers targetable windows (and optional start apps)
 *  - `computer_observe` captures one window state: screenshot and/or UIA tree
 *  - `computer_action` performs exactly one input action against a captured state
 *  - `computer_launch_app` launches an app, then reports its windows
 *
 * The observe → one action → re-observe discipline is enforced by consuming a
 * state on every input action: element indexes and screenshot coordinates are
 * valid only for the observation that produced them.
 *
 * @module dsh-computer-use/tools
 */

import { readFile, rm } from 'node:fs/promises';
import { basename } from 'node:path';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { HelperError } from './helper-client.js';

const MAX_STATES = 12;
const DEFAULT_IMAGE_NOTE = 'coordinates are pixels in the attached image; the screen point is origin + coordinate * coordinate_scale';

/** Strip protocol noise while keeping the model-facing failure attributable. */
function helperFailure(error) {
  if (error instanceof HelperError) {
    const wrapped = new Error(`computer use failed [${error.code}]: ${error.message}`);
    // Keep the protocol code machine-readable so the overlay guard can turn an
    // ESC stop into a stop instruction instead of a generic failure.
    wrapped.cuCode = error.code;
    return wrapped;
  }
  return error instanceof Error ? error : new Error(String(error));
}

function escapeQuoted(value) {
  return String(value ?? '').replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', ' ');
}

/** Extract the UIA control type token and element name from one tree line. */
export function parseElementLine(line) {
  if (typeof line !== 'string') return { controlType: '', name: '' };
  const match = line.match(/^\s*\[(\d+)\]\s+(\S+)\s+"((?:[^"\\]|\\.)*)"/);
  if (match === null) return { controlType: '', name: '' };
  return { controlType: match[2], name: match[3].replaceAll('\\"', '"').replaceAll('\\\\', '\\') };
}

/** Find the formatted tree line for an element index, or undefined. */
export function findElementLine(tree, index) {
  if (typeof tree !== 'string' || !Number.isInteger(index)) return undefined;
  const match = tree.match(new RegExp(`^\\s*\\[${index}\\]\\s+.*$`, 'm'));
  return match === null ? undefined : match[0];
}

/** Build the durable attachment reference an image content block carries. */
function imageBlock(ref) {
  return {
    type: 'image',
    attachment: {
      attachmentId: ref.attachmentId,
      mediaType: ref.mediaType,
      bytes: ref.bytes,
      width: ref.width,
      height: ref.height,
      ...(ref.name === undefined ? {} : { name: ref.name }),
      ...(ref.originalDimensions === undefined ? {} : { originalDimensions: { ...ref.originalDimensions } }),
    },
  };
}

/** Whether the calling model route declares image input. Unknown routes attempt the image. */
async function routeSupportsImages(ctx, exec) {
  try {
    const llm = ctx.get('llm');
    if (llm === undefined) return true;
    const routed = exec.agent?.session?.requestHeader?.()?.config;
    const provider = routed?.provider ?? exec.agent?.options?.provider;
    const model = routed?.model ?? exec.agent?.options?.model;
    if (provider === undefined || model === undefined) return true;
    const info = await llm.resolveModelInfo(provider, model, exec.signal);
    const modalities = info?.inputModalities;
    return Array.isArray(modalities) ? modalities.includes('image') : true;
  } catch {
    return true;
  }
}

/**
 * Resolve a point-of-risk confirmation through the harness approval seam when
 * the session policy allows asking. Returns warnings to attach; throws when the
 * action is refused.
 */
async function maybeConfirm(ctx, config, exec, reason) {
  if (reason === undefined) return [];
  const approvalsDisabled = () => {
    const message = `computer use needs confirmation before this action: ${reason}. The session approval policy is "${exec.agent === undefined ? 'unknown' : 'never'}" (or no approval channel is available), so the action was refused. Ask the user with ask_user_question and, if they explicitly approve, retry.`;
    if (config.warnWhenApprovalUnavailable) {
      return [`WARNING: ${reason}. This action was NOT user-confirmed. Ask the user before treating it as authorized.`];
    }
    throw new Error(message);
  };
  const approval = ctx.get('approval');
  if (approval === undefined || exec.agent === undefined || typeof approval.request !== 'function') return approvalsDisabled();
  let policy = 'ask';
  try {
    if (typeof approval.effectivePolicy === 'function') policy = approval.effectivePolicy(exec.agent.session);
  } catch {
    policy = 'ask';
  }
  if (policy !== 'ask') return approvalsDisabled();
  let outcome;
  try {
    outcome = await approval.request({
      agent: exec.agent,
      toolName: exec.name,
      callId: exec.callId,
      reason,
      displayReason: reason,
      signal: exec.signal,
    });
  } catch (error) {
    if (config.warnWhenApprovalUnavailable) {
      return [`WARNING: ${reason}. Approval could not be requested (${error instanceof Error ? error.message : String(error)}); this action was NOT user-confirmed.`];
    }
    throw error;
  }
  if (outcome === 'allowed-once') return [];
  throw new Error(`computer use blocked: ${reason}. The user did not approve this action (${outcome}); do not retry it without asking the user.`);
}

/**
 * Create the tool definitions bound to one plugin instance.
 *
 * @param {object} runtime
 * @param {import('./helper-client.js').HelperClient} runtime.helper
 * @param {ReturnType<import('./config.js').normalizeConfig>} runtime.config
 * @param {ReturnType<import('./policy.js').createPolicy>} runtime.policy
 * @param {import('@deepseek-ai/cordis').Context} runtime.ctx
 * @param {{info: Function, warn: Function, debug?: Function, error: Function}} runtime.logger
 * @returns {Array<object>} registry-ready tool definitions.
 */
export function createTools(runtime) {
  const { helper, config, policy, ctx } = runtime;
  /** state_id -> observation record. */
  const states = new Map();
  let stateCounter = 0;

  function rememberState(record) {
    stateCounter += 1;
    const stateId = `s-${stateCounter}`;
    record.consumed = false;
    record.createdAt = Date.now();
    states.set(stateId, record);
    if (states.size > MAX_STATES) {
      const oldest = states.keys().next().value;
      if (oldest !== undefined) states.delete(oldest);
    }
    return stateId;
  }

  function requireState(stateId) {
    if (typeof stateId !== 'string' || stateId === '') throw new Error('state_id is required for this action; call computer_observe first');
    const state = states.get(stateId);
    if (state === undefined) {
      throw new Error(`state_id "${stateId}" is unknown or expired; call computer_observe again`);
    }
    if (state.consumed === true) {
      throw new Error(`state_id "${stateId}" was already used by an action; element indexes and coordinates expire after every action — call computer_observe again`);
    }
    return state;
  }

  function consumeState(state) {
    state.consumed = true;
  }

  /** Resolve window metadata without requiring a full observation. */
  async function foregroundWindow(exec) {
    const cursor = await helper.request('cursor_position', undefined, { signal: exec.signal });
    if (!cursor || typeof cursor.foreground_window_id !== 'number' || cursor.foreground_window_id === 0) {
      throw new Error('there is no foreground window to target; ask the user to focus the intended app window');
    }
    return cursor.foreground_window_id;
  }

  async function listWindowsRaw(includeMinimized, exec) {
    const result = await helper.request('list_windows', {
      include_minimized: includeMinimized !== false,
      max: 200,
    }, { signal: exec.signal });
    return Array.isArray(result?.windows) ? result.windows : [];
  }

  function windowText(win) {
    const flags = [];
    if (win.is_foreground === true) flags.push('foreground');
    if (win.is_minimized === true) flags.push('minimized');
    if (win.blocked === true) flags.push('BLOCKED');
    const rect = win.rect ?? {};
    return `[id=${win.window_id}] app=${win.process_name ?? '?'} title="${escapeQuoted(win.title)}" pid=${win.process_id ?? '?'} rect=${rect.x ?? '?'},${rect.y ?? '?'},${rect.width ?? '?'},${rect.height ?? '?'}${flags.length > 0 ? ` ${flags.join(' ')}` : ''}`;
  }

  /** Capture a window state through the helper and commit screenshots as attachments. */
  async function observeWindow(windowId, args, exec) {
    const attachments = ctx.get('attachments');
    if (attachments === undefined) throw new Error('computer_observe requires the attachments service; this composition does not mount one');
    const wantsScreenshot = args.include_screenshot !== false;
    const includeText = args.include_text === true;
    const includeDocumentText = args.include_document_text === true;
    const supportsImages = wantsScreenshot ? await routeSupportsImages(ctx, exec) : false;
    const includeScreenshot = wantsScreenshot && supportsImages;
    let state;
    try {
      state = await helper.request('get_window_state', {
        window_id: windowId,
        include_screenshot: includeScreenshot,
        include_text: includeText,
        include_document_text: includeDocumentText,
        max_depth: args.max_tree_depth ?? config.maxTreeDepth,
        max_elements: args.max_elements ?? config.maxElements,
        max_text_chars: config.maxTextChars,
        screenshot_max_width: config.screenshotMaxWidth,
        screenshot_max_height: config.screenshotMaxHeight,
      }, { signal: exec.signal });
    } catch (error) {
      throw helperFailure(error);
    }
    const window = state?.window;
    if (window === undefined) throw new Error('computer_observe: the helper returned no window information');
    policy.assertWindowAllowed(window);
    const shots = Array.isArray(state.screenshots) ? state.screenshots : [];
    const records = [];
    try {
      for (const shot of shots) {
        let data;
        try {
          data = await readFile(shot.path);
        } catch (error) {
          throw new Error(`computer_observe: the helper screenshot ${shot.path} could not be read: ${error instanceof Error ? error.message : String(error)}`);
        }
        let ref;
        try {
          ref = await attachments.saveImage({ data, mediaType: 'image/png', name: `${basename(shot.path)}` });
        } catch (error) {
          throw new Error(`computer_observe: the screenshot could not be committed as an attachment: ${error instanceof Error ? error.message : String(error)}`);
        }
        records.push({ shot, ref });
        if (!config.keepScreenshots) {
          await rm(shot.path, { force: true }).catch(() => {});
        }
      }
    } catch (error) {
      if (!config.keepScreenshots) {
        for (const shot of shots) await rm(shot.path, { force: true }).catch(() => {});
      }
      throw error;
    }
    const primary = records[0];
    let coordinate;
    if (primary !== undefined) {
      // Image scale = capture pixels per model-visible image pixel (>= 1 when the
      // attachment store downscaled the helper capture further).
      const imageScaleX = primary.ref.width > 0 ? primary.shot.width / primary.ref.width : 1;
      const imageScaleY = primary.ref.height > 0 ? primary.shot.height / primary.ref.height : 1;
      coordinate = {
        origin_x: primary.shot.origin_x,
        origin_y: primary.shot.origin_y,
        scale_x: primary.shot.capture_scale_x * imageScaleX,
        scale_y: primary.shot.capture_scale_y * imageScaleY,
        image_width: primary.ref.width,
        image_height: primary.ref.height,
      };
    }
    const stateId = rememberState({
      windowId,
      window,
      tree: includeText ? (state.accessibility?.tree ?? '') : '',
      accessibility: includeText ? state.accessibility : undefined,
      shots: records.map(({ shot, ref }) => ({
        width: shot.width,
        height: shot.height,
        imageWidth: ref.width,
        imageHeight: ref.height,
        originX: shot.origin_x,
        originY: shot.origin_y,
        captureScaleX: shot.capture_scale_x,
        captureScaleY: shot.capture_scale_y,
        imageScaleX: ref.width > 0 ? shot.width / ref.width : 1,
        imageScaleY: ref.height > 0 ? shot.height / ref.height : 1,
        captureMethod: shot.capture_method,
        ref,
      })),
    });
    const value = {
      state_id: stateId,
      window: {
        window_id: window.window_id,
        title: window.title,
        process_id: window.process_id,
        process_name: window.process_name,
        process_path: window.process_path,
        app_id: window.app_id,
        app_name: window.app_name,
        is_foreground: window.is_foreground,
        is_minimized: window.is_minimized,
        rect: window.rect,
      },
      screenshots: records.map(({ shot, ref }) => ({
        width: shot.width,
        height: shot.height,
        origin_x: shot.origin_x,
        origin_y: shot.origin_y,
        capture_scale_x: shot.capture_scale_x,
        capture_scale_y: shot.capture_scale_y,
        capture_method: shot.capture_method,
        image: {
          attachmentId: ref.attachmentId,
          mediaType: ref.mediaType,
          bytes: ref.bytes,
          width: ref.width,
          height: ref.height,
        },
      })),
      coordinate: coordinate ?? null,
      accessibility: includeText ? {
        tree: state.accessibility?.tree ?? '',
        focused_element: state.accessibility?.focused_element ?? '',
        focused_is_password: state.accessibility?.focused_is_password === true,
        selected_text: state.accessibility?.selected_text ?? '',
        document_text: state.accessibility?.document_text ?? '',
        element_count: state.accessibility?.element_count ?? 0,
        truncated: state.accessibility?.truncated === true,
      } : null,
      ...(wantsScreenshot && !includeScreenshot
        ? { screenshot_suppressed: 'the current model route does not declare image input; observation returned text only' }
        : {}),
      cursor: state.cursor,
      foreground_window_id: state.foreground_window_id,
    };
    return { value, records };
  }

  function observeText(value) {
    const lines = [];
    const win = value.window;
    const rect = win.rect ?? {};
    lines.push(`<window id="${win.window_id}" app="${win.process_name ?? '?'}" title="${escapeQuoted(win.title)}" pid="${win.process_id ?? '?'}" rect="${rect.x ?? '?'},${rect.y ?? '?'},${rect.width ?? '?'},${rect.height ?? '?'}" foreground="${win.is_foreground === true}" minimized="${win.is_minimized === true}" />`);
    lines.push(`<state id="${value.state_id}" note="element indexes and screenshot coordinates are valid only for this observation; the state is consumed by the next input action" />`);
    if (value.screenshots.length > 0) {
      const shot = value.screenshots[0];
      lines.push(`<screenshot image_width="${shot.image?.width ?? shot.width}" image_height="${shot.image?.height ?? shot.height}" capture="${shot.capture_method}" origin_x="${shot.origin_x}" origin_y="${shot.origin_y}" coordinate_scale_x="${value.coordinate?.scale_x?.toFixed?.(4) ?? 1}" coordinate_scale_y="${value.coordinate?.scale_y?.toFixed?.(4) ?? 1}" note="${DEFAULT_IMAGE_NOTE}" />`);
    } else if (value.screenshot_suppressed !== undefined) {
      lines.push(`<screenshot absent="true" note="${value.screenshot_suppressed}" />`);
    }
    if (value.accessibility !== null) {
      const acc = value.accessibility;
      lines.push(`<accessibility elements="${acc.element_count}" truncated="${acc.truncated}" focused_is_password="${acc.focused_is_password}">`);
      if (acc.focused_element !== '') lines.push(`<focused>${acc.focused_element}</focused>`);
      if (acc.selected_text !== '') lines.push(`<selected_text>${acc.selected_text}</selected_text>`);
      if (acc.document_text !== '') lines.push(`<document_text>${acc.document_text}</document_text>`);
      lines.push('<tree>');
      lines.push(acc.tree ?? '');
      lines.push('</tree>');
      lines.push('</accessibility>');
    } else {
      lines.push('<accessibility absent="true" note="call again with include_text=true to capture the accessibility tree with element indexes" />');
    }
    lines.push(`<cursor x="${value.cursor?.x ?? '?'}" y="${value.cursor?.y ?? '?'}" foreground_window_id="${value.foreground_window_id ?? '?'}" />`);
    lines.push('<next>Inspect the screenshot and/or tree, then call computer_action with this state_id. One action per observation; re-observe afterwards.</next>');
    return lines.join('\n');
  }

  /** Build the action payload and run one input action through the helper. */
  async function runAction(action, stateId, args, exec) {
    const state = stateId === undefined ? undefined : requireState(stateId);
    const window = state?.window;
    if (state !== undefined) policy.assertWindowAllowed(window);
    let elementLine;
    let element;
    if (action === 'activate_window') {
      const windowId = args.window_id;
      if (!Number.isInteger(windowId) || windowId <= 0) throw new Error('activate_window requires an integer window_id from computer_list_windows');
      const win = (await listWindowsRaw(true, exec)).find((candidate) => candidate.window_id === windowId);
      if (win === undefined) throw new Error(`window ${windowId} no longer exists; call computer_list_windows again`);
      policy.assertWindowAllowed(win);
      const result = await helper.request('activate_window', { window_id: windowId }, { signal: exec.signal }).catch((error) => { throw helperFailure(error); });
      const warnings = await maybeConfirm(ctx, config, exec, undefined);
      return { summary: `activated window ${windowId} "${escapeQuoted(result?.title ?? win.title)}"`, warnings, windowId };
    }
    if (action === 'wait') {
      const ms = args.ms ?? 500;
      if (!Number.isInteger(ms) || ms < 0 || ms > 10000) throw new Error('wait requires ms between 0 and 10000');
      await helper.request('wait', { ms }, { signal: exec.signal }).catch((error) => { throw helperFailure(error); });
      return { summary: `waited ${ms} ms`, warnings: [] };
    }
    if (state === undefined) throw new Error(`state_id is required for action "${action}"; call computer_observe first`);
    if (state.shots.length === 0 && ['click', 'double_click', 'right_click', 'middle_click', 'scroll', 'drag', 'mouse_move'].includes(action)) {
      throw new Error(`state "${stateId}" was captured without a screenshot, so it has no image coordinate space; call computer_observe with include_screenshot=true (or act by element_index where supported)`);
    }
    if (args.element_index !== undefined) {
      elementLine = findElementLine(state.tree, args.element_index);
      if (elementLine === undefined) throw new Error(`element_index ${args.element_index} is not in the tree of state "${stateId}"; call computer_observe with include_text=true and pick an index from the returned tree`);
      element = parseElementLine(elementLine);
    }
    const assessment = policy.assessAction({
      action,
      args,
      state,
      window,
      elementName: element?.name,
    });
    const warnings = await maybeConfirm(ctx, config, exec, assessment.confirm);
    warnings.push(...assessment.warnings);
    const imageScale = state.shots[0] === undefined ? undefined : { x: state.shots[0].imageScaleX, y: state.shots[0].imageScaleY };
    let helperPromise;
    let summary;
    switch (action) {
      case 'click':
      case 'double_click':
      case 'right_click':
      case 'middle_click': {
        const hasElement = args.element_index !== undefined;
        const hasCoords = typeof args.x === 'number' && typeof args.y === 'number';
        if (hasElement === hasCoords) throw new Error(`${action} requires exactly one of element_index or (x, y)`);
        const button = action === 'right_click' ? 'right' : action === 'middle_click' ? 'middle' : (args.button ?? 'left');
        const clickCount = action === 'double_click' ? 2 : (args.click_count ?? 1);
        if (!['left', 'right', 'middle'].includes(button)) throw new Error('button must be left, right, or middle');
        if (!Number.isInteger(clickCount) || clickCount < 1 || clickCount > 3) throw new Error('click_count must be between 1 and 3');
        const params = { state_id: stateId, button, click_count: clickCount, ...(imageScale === undefined ? {} : { image_scale: imageScale }) };
        if (hasElement) params.element_index = args.element_index;
        else { params.x = args.x; params.y = args.y; }
        helperPromise = helper.request('click', params, { signal: exec.signal });
        summary = hasElement
          ? `${action} element ${args.element_index}${element?.name ? ` "${element.name}"` : ''}`
          : `${action} at image (${args.x}, ${args.y})`;
        break;
      }
      case 'mouse_move':
        if (typeof args.x !== 'number' || typeof args.y !== 'number') throw new Error('mouse_move requires x and y');
        helperPromise = helper.request('move', { state_id: stateId, x: args.x, y: args.y, ...(imageScale === undefined ? {} : { image_scale: imageScale }) }, { signal: exec.signal });
        summary = `moved the cursor to image (${args.x}, ${args.y})`;
        break;
      case 'type': {
        const text = policy.validateText(args.text);
        helperPromise = helper.request('type_text', { state_id: stateId, text }, { signal: exec.signal });
        summary = `typed ${text.length} character(s)`;
        break;
      }
      case 'key': {
        const key = policy.validateKeyChord(args.key);
        const repeat = policy.validateRepeat(args.repeat);
        helperPromise = helper.request('press_key', { state_id: stateId, key, repeat }, { signal: exec.signal });
        summary = `pressed ${key}${repeat > 1 ? ` ×${repeat}` : ''}`;
        break;
      }
      case 'scroll': {
        const shot = state.shots[0];
        const x = typeof args.x === 'number' ? args.x : Math.round(shot.width / 2);
        const y = typeof args.y === 'number' ? args.y : Math.round(shot.height / 2);
        const scrollX = args.scroll_x ?? 0;
        const scrollY = args.scroll_y ?? 0;
        if (!Number.isFinite(scrollX) || !Number.isFinite(scrollY)) throw new Error('scroll_x and scroll_y must be numbers');
        if (scrollX === 0 && scrollY === 0) throw new Error('scroll requires a non-zero scroll_x or scroll_y');
        helperPromise = helper.request('scroll', { state_id: stateId, x, y, scroll_x: scrollX, scroll_y: scrollY, ...(imageScale === undefined ? {} : { image_scale: imageScale }) }, { signal: exec.signal });
        summary = `scrolled by (${scrollX}, ${scrollY}) from image (${x}, ${y})`;
        break;
      }
      case 'drag': {
        for (const field of ['from_x', 'from_y', 'to_x', 'to_y']) {
          if (typeof args[field] !== 'number') throw new Error(`drag requires numeric ${field}`);
        }
        const duration = args.duration_ms ?? 600;
        if (!Number.isInteger(duration) || duration < 100 || duration > 5000) throw new Error('duration_ms must be between 100 and 5000');
        helperPromise = helper.request('drag', { state_id: stateId, from_x: args.from_x, from_y: args.from_y, to_x: args.to_x, to_y: args.to_y, duration_ms: duration, ...(imageScale === undefined ? {} : { image_scale: imageScale }) }, { signal: exec.signal });
        summary = `dragged from (${args.from_x}, ${args.from_y}) to (${args.to_x}, ${args.to_y})`;
        break;
      }
      case 'set_value': {
        if (!Number.isInteger(args.element_index)) throw new Error('set_value requires element_index');
        if (typeof args.value !== 'string') throw new Error('set_value requires a string value');
        helperPromise = helper.request('set_value', { state_id: stateId, element_index: args.element_index, value: args.value }, { signal: exec.signal });
        summary = `set value of element ${args.element_index}${element?.name ? ` "${element.name}"` : ''}`;
        break;
      }
      default:
        throw new Error(`unknown action "${action}"; expected one of click, double_click, right_click, middle_click, mouse_move, type, key, scroll, drag, set_value, wait, activate_window`);
    }
    consumeState(state);
    let result;
    try {
      result = await helperPromise;
    } catch (error) {
      if (error instanceof HelperError && error.code === 'WINDOW_NOT_FOREGROUND') {
        throw new Error(`computer use failed [WINDOW_NOT_FOREGROUND]: ${error.message}. Call computer_action with action="activate_window" and the window_id, then re-observe before retrying.`);
      }
      throw helperFailure(error);
    }
    return {
      summary,
      warnings,
      focusedElement: result?.focused_element,
      foregroundWindowId: result?.foreground_window_id,
      elementLine,
      stateId,
      consumed: true,
    };
  }

  const tools = [];

  tools.push(defineTool({
    name: 'computer_list_windows',
    description: 'List targetable desktop windows (top-level, visible, non-cloaked) with their window_id, process identity, title, rect, foreground/minimized state, and whether the window is blocked by computer-use policy. This is the entry point before observing or acting: choose the app window by its title/process, never guess a window_id. Set include_launchable=true to also list Start-menu apps you can launch.',
    parameters: {
      include_launchable: { type: 'boolean', description: 'Also list launchable Start-menu apps (names accepted by computer_launch_app).' },
      include_minimized: { type: 'boolean', description: 'Include minimized windows (default true).' },
      app_filter: { type: 'string', description: 'Case-insensitive substring filter over process name, app name, and window title.' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, value) => {
        const lines = [`<windows count="${value.windows.length}" foreground_window_id="${value.foreground_window_id ?? '?'}">`];
        for (const win of value.windows) lines.push(windowText(win));
        lines.push('</windows>');
        if (Array.isArray(value.launchable) && value.launchable.length > 0) {
          lines.push(`<launchable count="${value.launchable.length}">`);
          for (const app of value.launchable) lines.push(`- "${escapeQuoted(app.name)}" -> ${app.launch_id}`);
          lines.push('</launchable>');
        }
        lines.push('<next>Call computer_observe with the chosen window_id. Blocked windows are denied by policy.</next>');
        return [{ type: 'text', text: lines.join('\n') }];
      },
    },
    isConcurrencySafe: () => false,
    timeoutMs: 120000,
    async execute(args, exec) {
      let windows = await listWindowsRaw(args.include_minimized, exec).catch((error) => { throw helperFailure(error); });
      const filter = typeof args.app_filter === 'string' ? args.app_filter.trim().toLowerCase() : '';
      if (filter !== '') {
        windows = windows.filter((win) => [win.process_name, win.app_name, win.title].some((field) => typeof field === 'string' && field.toLowerCase().includes(filter)));
      }
      const value = {
        windows,
        foreground_window_id: windows.find((win) => win.is_foreground === true)?.window_id ?? null,
        launchable: [],
      };
      if (args.include_launchable === true) {
        const apps = await helper.request('list_apps', { include_windows: false, include_launchable: true, max: 300 }, { signal: exec.signal }).catch((error) => { throw helperFailure(error); });
        value.launchable = (apps?.apps ?? []).filter((app) => app.launch_id !== undefined).map((app) => ({ name: app.name, launch_id: app.launch_id, app_id: app.app_id }));
      }
      return value;
    },
  }));

  tools.push(defineTool({
    name: 'computer_observe',
    description: 'Observe one desktop window: capture a screenshot and/or its accessibility tree (formatted lines with element indexes and the focused element), returning a state_id plus screenshot coordinate mapping. Captures work even when the window is occluded (PrintWindow). Default is screenshot only; pass include_text=true when you need element indexes or exact text/focus (cheaper than guessing pixels). Every action consumes the state, so observe again after acting.',
    parameters: {
      window_id: { type: 'integer', description: 'Window id from computer_list_windows. Omit to observe the current foreground window.' },
      include_screenshot: { type: 'boolean', description: 'Capture and attach a screenshot (default true). Set false when you only need the accessibility tree.' },
      include_text: { type: 'boolean', description: 'Capture the UI Automation tree with element indexes, focused element, selection and document text (default false).' },
      include_document_text: { type: 'boolean', description: 'Also extract the focused editable document text (default false; requires include_text=true).' },
      max_elements: { type: 'integer', description: 'Cap on tree elements (default 600, max 2000).' },
      max_tree_depth: { type: 'integer', description: 'Cap on tree depth (default 12, max 24).' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, value) => {
        const blocks = [{ type: 'text', text: observeText(value) }];
        for (const shot of value.screenshots) {
          if (shot.image?.attachmentId !== undefined) blocks.push(imageBlock(shot.image));
        }
        return blocks;
      },
    },
    isConcurrencySafe: () => false,
    timeoutMs: 180000,
    async execute(args, exec) {
      const windowId = args.window_id ?? await foregroundWindow(exec);
      if (!Number.isInteger(windowId) || windowId <= 0) throw new Error('window_id must be a positive integer window id from computer_list_windows');
      const { value } = await observeWindow(windowId, args, exec);
      return value;
    },
  }));

  tools.push(defineTool({
    name: 'computer_action',
    description: 'Perform exactly ONE input action on the window captured by the latest computer_observe state. Actions: click / double_click / right_click / middle_click (element_index OR x,y), mouse_move (x,y), type (text), key (X11-style chord such as Control_L+a, Return, alt+Tab), scroll (x,y,scroll_x,scroll_y), drag (from_x,from_y,to_x,to_y,duration_ms), set_value (element_index,value via UI Automation), wait (ms), activate_window (window_id, no state needed). Coordinates are pixels in the attached screenshot; the screen point is origin + coordinate * coordinate_scale. The state is consumed by the action: observe again before the next action. Risky actions may require user confirmation.',
    parameters: {
      action: {
        type: 'string',
        required: true,
        enum: ['click', 'double_click', 'right_click', 'middle_click', 'mouse_move', 'type', 'key', 'scroll', 'drag', 'set_value', 'wait', 'activate_window'],
        description: 'The single action to perform.',
      },
      state_id: { type: 'string', description: 'state_id from computer_observe. Required for every action except wait and activate_window.' },
      window_id: { type: 'integer', description: 'Target window id; required for activate_window.' },
      element_index: { type: 'integer', description: 'Element index from the tree of the same state (click/set_value). Prefer this over guessing coordinates.' },
      x: { type: 'number', description: 'Screenshot-space X for click/mouse_move; scroll origin X when given.' },
      y: { type: 'number', description: 'Screenshot-space Y for click/mouse_move; scroll origin Y when given.' },
      from_x: { type: 'number', description: 'Drag start X (screenshot space).' },
      from_y: { type: 'number', description: 'Drag start Y (screenshot space).' },
      to_x: { type: 'number', description: 'Drag end X (screenshot space).' },
      to_y: { type: 'number', description: 'Drag end Y (screenshot space).' },
      text: { type: 'string', description: 'Literal text for type. Newlines are converted to Enter.' },
      key: { type: 'string', description: 'Key or +-separated chord: letters, digits, Return, Escape, Tab, BackSpace, Delete, arrows, F1-F24, modifiers Control_L/Shift_L/Alt_L, KP_0..9, etc. The Windows/Meta key is forbidden.' },
      repeat: { type: 'integer', description: 'Key repeat count 1..20 (default 1).' },
      scroll_x: { type: 'number', description: 'Horizontal scroll delta in pixels of intent (positive = right).' },
      scroll_y: { type: 'number', description: 'Vertical scroll delta in pixels of intent (positive = down / content up).' },
      button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'Mouse button for click (default left).' },
      click_count: { type: 'integer', description: 'Click count 1..3 for click (default 1).' },
      duration_ms: { type: 'integer', description: 'Drag duration 100..5000 ms (default 600).' },
      value: { type: 'string', description: 'Replacement value for set_value.' },
      ms: { type: 'integer', description: 'Wait duration 0..10000 ms for wait (default 500).' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, value) => {
        const lines = [`<action name="${value.action}" ok="true" state_id="${value.state_id ?? ''}" consumed="${value.consumed === true}">${value.summary}</action>`];
        if (value.focused_element !== undefined && value.focused_element !== '') lines.push(`<focused>${value.focused_element}</focused>`);
        if (value.foreground_window_id !== undefined) lines.push(`<foreground_window_id>${value.foreground_window_id}</foreground_window_id>`);
        if (value.warnings.length > 0) {
          lines.push('<warnings>');
          for (const warning of value.warnings) lines.push(`<warning>${warning}</warning>`);
          lines.push('</warnings>');
        }
        lines.push(value.consumed === true
          ? '<next>This state is consumed. Call computer_observe again to verify the effect before the next action.</next>'
          : '<next>Call computer_observe before the next input action.</next>');
        return [{ type: 'text', text: lines.join('\n') }];
      },
    },
    isConcurrencySafe: () => false,
    timeoutMs: 120000,
    async execute(args, exec) {
      const action = args.action;
      if (typeof action !== 'string' || action === '') throw new Error('action is required');
      const result = await runAction(action, args.state_id, args, exec);
      return {
        action,
        state_id: result.stateId ?? null,
        consumed: result.consumed === true,
        summary: result.summary,
        warnings: result.warnings,
        ...(result.elementLine === undefined ? {} : { element: result.elementLine }),
        ...(result.focusedElement === undefined ? {} : { focused_element: result.focusedElement }),
        ...(result.foregroundWindowId === undefined ? {} : { foreground_window_id: result.foregroundWindowId }),
      };
    },
  }));

  tools.push(defineTool({
    name: 'computer_sequence',
    description: 'Run an ordered batch of input steps on ONE window in a single call, without re-observing between steps. Coordinates are absolute SCREEN pixels (desktop space), not screenshot space. Use this for repetitive GUI work (drawing a diagram, filling a grid, stepping through a wizard) where the observe→act round trip dominates; verify the result with computer_observe afterwards, or pass screenshot=true to get one final screenshot in the same call. Steps: {action:"click",x,y,button?,click_count?}, {action:"drag",from_x,from_y,to_x,to_y,duration_ms?}, {action:"move",x,y}, {action:"type",text}, {action:"key",key,repeat?}, {action:"wait",ms}, {action:"wheel",x?,y?,scroll_x?,scroll_y?}. Blocked windows and password fields are still refused.',
    parameters: {
      window_id: { type: 'integer', required: true, description: 'Target window id from computer_list_windows.' },
      steps: { type: 'array', required: true, description: 'Ordered steps (1..100). Each step is an object: {action:"click",x,y} / {action:"drag",from_x,from_y,to_x,to_y,duration_ms} / {action:"type",text} / {action:"key",key,repeat} / {action:"wait",ms} / {action:"wheel",x,y,scroll_x,scroll_y}. Coordinates are absolute screen pixels.' },
      screenshot: { type: 'boolean', description: 'Capture and attach one screenshot after the sequence (default false).' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, value) => {
        const blocks = [];
        const lines = [`<sequence window_id="${value.window_id}" steps="${value.steps}" elapsed_ms="${value.elapsed_ms ?? '?'}" ok="${value.ok === true}">`];
        for (const line of value.actions) lines.push(`  <step>${line}</step>`);
        lines.push('</sequence>');
        if (value.focused_element !== '') lines.push(`<focused>${value.focused_element}</focused>`);
        lines.push('<next>Call computer_observe to verify the result before the next batch.</next>');
        blocks.push({ type: 'text', text: lines.join('\n') });
        if (value.screenshot?.attachmentId !== undefined) blocks.push(imageBlock(value.screenshot));
        return blocks;
      },
    },
    isConcurrencySafe: () => false,
    timeoutMs: 180000,
    async execute(args, exec) {
      const windowId = args.window_id;
      if (!Number.isInteger(windowId) || windowId <= 0) throw new Error('window_id must be a positive integer from computer_list_windows');
      const steps = Array.isArray(args.steps) ? args.steps : [];
      if (steps.length === 0) throw new Error('steps must be a non-empty array of step objects');
      if (steps.length > 100) throw new Error('steps supports at most 100 entries');
      const win = (await listWindowsRaw(true, exec)).find((candidate) => candidate.window_id === windowId);
      if (win === undefined) throw new Error(`window ${windowId} no longer exists; call computer_list_windows again`);
      policy.assertWindowAllowed(win);
      let result;
      try {
        result = await helper.request('sequence', { window_id: windowId, steps }, { signal: exec.signal });
      } catch (error) {
        throw helperFailure(error);
      }
      const value = {
        ok: result?.ok === true,
        window_id: result?.window_id ?? windowId,
        steps: result?.steps ?? steps.length,
        elapsed_ms: result?.elapsed_ms ?? null,
        actions: Array.isArray(result?.actions) ? result.actions.map(String) : [],
        focused_element: result?.focused_element ?? '',
        screenshot: null,
      };
      if (args.screenshot === true) {
        const { value: observed } = await observeWindow(windowId, { include_screenshot: true }, exec);
        const shot = observed.screenshots?.[0];
        if (shot?.image?.attachmentId !== undefined) {
          value.screenshot = {
            attachmentId: shot.image.attachmentId,
            mediaType: shot.image.mediaType,
            bytes: shot.image.bytes,
            width: shot.image.width,
            height: shot.image.height,
          };
        }
      }
      return value;
    },
  }));

  tools.push(defineTool({
    name: 'computer_launch_app',
    description: 'Launch a desktop app (exe path, exe name, Start-menu app display name, .lnk path, or shell:AppsFolder AUMID), then report the windows it opened. Use computer_list_windows(include_launchable=true) to discover start-menu names. Terminal shells and blocked apps are refused.',
    parameters: {
      app: { type: 'string', required: true, description: 'App to launch: "notepad.exe", "C:\\Path\\App.exe", "Visual Studio Code" (start-menu name), a .lnk path, or shell:AppsFolder\\<AUMID>.' },
      wait_ms: { type: 'integer', description: 'How long to wait for a window (0..15000, default 4000).' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, value) => {
        const lines = [`<launched app="${escapeQuoted(value.app)}" pid="${value.pid ?? '?'}" resolved="${escapeQuoted(value.resolved ?? '')}" />`];
        lines.push(`<windows count="${value.windows.length}">`);
        for (const win of value.windows) lines.push(windowText(win));
        lines.push('</windows>');
        lines.push('<next>Call computer_observe with one of the window ids above.</next>');
        return [{ type: 'text', text: lines.join('\n') }];
      },
    },
    isConcurrencySafe: () => false,
    timeoutMs: 120000,
    async execute(args, exec) {
      const app = typeof args.app === 'string' ? args.app.trim() : '';
      if (app === '') throw new Error('app is required');
      const waitMs = args.wait_ms ?? 4000;
      if (!Number.isInteger(waitMs) || waitMs < 0 || waitMs > 15000) throw new Error('wait_ms must be between 0 and 15000');
      let launched;
      try {
        launched = await helper.request('launch_app', { app }, { signal: exec.signal });
      } catch (error) {
        throw helperFailure(error);
      }
      const deadline = Date.now() + waitMs;
      let windows = [];
      while (Date.now() <= deadline) {
        const all = await listWindowsRaw(true, exec).catch(() => []);
        windows = all.filter((win) => (launched?.pid !== undefined && win.process_id === launched.pid) || (launched?.resolved !== undefined && typeof win.process_path === 'string' && win.process_path.toLowerCase() === String(launched.resolved).toLowerCase()));
        if (windows.length > 0) break;
        await new Promise((resolve) => setTimeout(resolve, 300));
      }
      if (windows.length === 0) {
        const all = await listWindowsRaw(true, exec).catch(() => []);
        windows = all.filter((win) => typeof win.process_name === 'string' && app.toLowerCase().endsWith(win.process_name.toLowerCase()));
      }
      return {
        app,
        pid: launched?.pid ?? null,
        resolved: launched?.resolved ?? null,
        windows,
        warnings: windows.length === 0 ? [`no window appeared within ${waitMs} ms; the app may still be starting — call computer_list_windows again`] : [],
      };
    },
  }));

  // Internal accessor for tests: exposes the state registry shape without
  // registering anything on the real registry.
  tools.__states = states;
  return tools;
}
