window.__ModuleLoader__.load({
	id: "dsh-computer-use",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");

		// A monitor with a pointer arrow: the visual metaphor for "operate the
		// desktop". Kept as an inline SVG component so the entry needs no extra
		// asset or icon-package import.
		function ComputerUseIcon(props) {
			const className = props === undefined || props === null ? undefined : props.className;
			const size = props === undefined || props === null || props.size === undefined ? 16 : props.size;
			return react.createElement(
				"svg",
				{
					viewBox: "0 0 16 16",
					width: size,
					height: size,
					className,
					"aria-hidden": "true",
					focusable: "false",
					fill: "none",
					stroke: "currentColor",
					strokeWidth: 1.2,
					strokeLinecap: "round",
					strokeLinejoin: "round"
				},
				react.createElement("rect", { x: 1.6, y: 2.2, width: 12.8, height: 8.2, rx: 1.4 }),
				react.createElement("path", { d: "M4.6 13.4h6.8M8 10.4v3" }),
				react.createElement("path", { d: "M5.9 4.9l3.7 2.1-3.7 2.1z", fill: "currentColor", stroke: "none" })
			);
		}

		/** Prompt inserted into the composer; the user can refine it before sending. */
		const PROMPT = "用 computer use 帮我操作桌面：";

		/** Best-effort draft insertion; a failed draft never breaks the menu. */
		function insertPrompt(ctx, session) {
			try {
				const sessions = ctx.get("sessions");
				const sessionId = session === undefined || session === null ? undefined : session.sessionId;
				const actx = sessions === undefined || sessions === null || sessionId === undefined ? undefined : sessions.scope(sessionId);
				const conversation = (actx === undefined ? undefined : actx.get("conversation")) ?? ctx.get("conversation");
				const input = conversation === undefined || conversation === null || actx === undefined ? undefined : conversation.input.for(actx);
				if (input === undefined || input === null) return;
				if (typeof input.setDraft === "function") input.setDraft(PROMPT);
				else if (typeof input.actions === "object" && input.actions !== null && typeof input.actions.setDraft === "function") input.actions.setDraft(PROMPT);
				else return;
				if (typeof input.notify === "function") input.notify("info", "已插入 computer use 指令，补充要求后按 Enter 发送");
			} catch (error) {
				if (typeof console !== "undefined" && console.warn !== undefined) console.warn("computer-use: could not insert the prompt", error);
			}
		}

		const inject = ["commandUi", "sessions"];

		/** Register the "电脑操作 computer use" row in the composer's add/command menu. */
		function apply(ctx) {
			ctx.inject(["commandUi"], (scope) => {
				const commandUi = scope.get("commandUi");
				scope.effect(() => commandUi.register({
					name: "computer-use",
					label: () => "电脑操作",
					description: () => "computer use · 截图与鼠标键盘控制 Windows 桌面应用",
					icon: ComputerUseIcon,
					available: () => true,
					ui: { kind: "action", run: (session) => insertPrompt(ctx, session) }
				}), "computer-use: composer menu entry");
			});
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
