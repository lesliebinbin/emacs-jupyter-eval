# Task: Integrate JupyterLab rendering components into the renderer

- **status:** complete
- **owner:** Copilot CLI
- **depends on:** PR #4 (CRLF stream fix) merged; branch from master afterwards
- **created:** 2026-09-03
- **completed:** 2026-09-03

## Outcome

Integrated rendermime with safe HTML/SVG rendering, Markdown, KaTeX, and
display updates. Added ordered SSE delivery, an origin-checked HTTP comm
back-channel with binary-buffer support, and html-manager widget views.
Standard `IntSlider` state was verified round-trip against a live kernel.

## Mission

Hand over to another AI agent the implementation of two Jupyter output
features in the renderer:

1. Rich static output via **`@jupyterlab/rendermime`** (text/plain,
   text/html, image/png, text/markdown, LaTeX, SVG)
2. Interactive widgets via **`@jupyter-widgets/html-manager`**
   (ipywidgets frontend, comm-based)

## Background

Read `agents/references/jupyter-rendering-stack.md` for the full
architecture map. Summary:

- Emacs coordinator spawns an engine kernel, broker input/output
  processors, and the Vite renderer.
- Broker = ZMQ↔HTTP bridge: input processor executes code on the kernel
  shell channel (REQ); output processor subscribes to iopub (SUB),
  normalizes events, and serves them at
  `GET /jupyter-eval-events` as `{"events": [...]}` (CORS `*`).
- Renderer (`renderer/src/App.tsx`) polls that endpoint every 250 ms and
  renders cells from events (see the reference for the current coverage
  table).

## Scope

### Feature 1 — rendermime for static output

- Replace/extend the hand-rolled event handling in `App.tsx` so that
  `execute_result` and `display_data` events render their full mime
  bundle through `@jupyterlab/rendermime`, not just `image/png`.
- Must keep: the cell model, stream handling (including the CRLF fix
  from PR #4), error display, and the existing visual design.

### Feature 2 — html-manager for ipywidgets

This spans repo components — it is not renderer-only:

- **Broker:** relay comm traffic. `comm_open`/`comm_msg` from the
  kernel arrive on iopub (they already flow into the event stream as
  raw messages — verify shape and coverage). Frontend→kernel comm
  messages need a back-channel: the broker must accept them over HTTP
  and send them to the kernel (shell channel, or the control channel).
- **Events push:** polling at 250 ms is too slow for interactive
  widgets. Upgrade the events channel to **SSE** (minimal change to the
  existing `ThreadingHTTPServer`, one-way push) with HTTP POST for the
  back-channel — a full WebSocket replacement is acceptable but not
  required.
- **Renderer:** embed `@jupyter-widgets/html-manager`, wire it to the
  comm transport above, and render widget views in cells.

### Non-goals

- stdin prompts (`input()` in cells stays `allow_stdin=False`)
- Changes to the engine, the coordinator's process model, or the
  Spacemacs side

## Constraints

- Node 24, Vite/React 19, TypeScript — keep the existing build
  (`mise //renderer:build` must pass)
- Renderer stays a pure web page; all system work remains in the host
  side (Emacs + broker)
- Follow `agents/runbooks/renderer-component-integration.md`

## Definition of done

1. A bare expression (`1+1`) renders its `text/plain` result in a cell
2. HTML/markdown display output renders safely (no unsandboxed JS)
3. A cell with `ipywidgets.IntSlider()` shows a working slider whose
   state round-trips to the kernel
4. `mise //renderer:build` passes; the e2e flow (start → send-region →
   events → stop) still passes
5. PR against `master` with the broker + renderer changes; brief
   archived afterwards
