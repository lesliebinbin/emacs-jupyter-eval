# Reference: the Jupyter rendering stack and this repo's touchpoints

## Mime bundles and output events

A Jupyter kernel emits three output shapes on iopub:

- `stream` — `{name: "stdout"|"stderr", text}` (flowing text)
- `execute_result` — `{data: {mime → value}, execution_count}` (the
  value of a bare expression)
- `display_data` — `{data: {mime → value}}` (explicit `display(...)`)

`data` is a **mime bundle**: multiple representations of the same thing
(`text/plain`, `text/html`, `image/png`, `text/markdown`, `application/vnd.jupyter.widget-view+json`
for widgets, ...). The frontend picks one per its preference order.

## `@jupyterlab/rendermime`

The reusable "mime bundle → DOM" layer. A `RenderMimeRegistry` holds
renderer factories (text, image, HTML, markdown, LaTeX, SVG, JSON) plus
a preference order. Knows nothing about kernels/messages — pure input
bundle, output DOM. This is the piece to embed for static rich output.

## `@jupyter-widgets/html-manager`

The ipywidgets frontend for plain-HTML contexts (no full JupyterLab
needed). Bundles the widget manager + base control registry +
output model/views, and **embeds its own rendermime instance** (for
Output widgets). Consumes a comm transport. Higher level than
rendermime, different problem domain (stateful interactive components).

## The comm protocol (what widgets need)

Widgets synchronize over **comm messages** — a bidirectional channel
separate from the execute path:

- kernel → frontend: `comm_open`, `comm_msg`, `comm_close` arrive on
  **iopub** (they already flow into our event stream as raw messages)
- frontend → kernel: sent on the **shell** channel (or control)

A widget's lifecycle: kernel creates a model → `comm_open` (with model
state) → frontend creates a view → user interacts → frontend sends
`comm_msg` state updates back → kernel sees the new value.

## This repo's architecture map

```
Emacs coordinator (jupyter-eval.el)
  ├─ engine launch.py:        kernel spawn; /tmp/jupyter-eval/<sha16>_<sha16>_kernel.json
  ├─ broker input_processor:  stdin JSON-lines {"code"} → ZMQ shell execute
  │                            (waits for shell reply before closing)
  ├─ broker output_processor: ZMQ iopub (SUB b"") → deque(1000) →
  │                            GET /jupyter-eval-events → {"events": [...]}, CORS *
  │                            (execute_input normalized to execution_started)
  └─ renderer:                vite dev on 5173; polls events every 250 ms;
                               App.tsx cell model: {id, requestId, code, output,
                               error, images[], status}
```

Event items share the shape
`{"type", "requestId", "content": {...}}`; `execution_started` carries
`code`. All events for one execute share the same `requestId`.

## Renderer coverage (current vs target)

| Output | Today | After rendermime | After html-manager |
|---|---|---|---|
| stream stdout/stderr | ✓ | ✓ | ✓ |
| image/png (display_data / execute_result) | ✓ | ✓ | ✓ |
| errors (traceback, ANSI-stripped) | ✓ | ✓ | ✓ |
| execute_result text/plain | ✗ | ✓ | ✓ |
| text/html, markdown, SVG, LaTeX | ✗ | ✓ | ✓ |
| ipywidgets (comm) | ✗ | ✗ | ✓ |

## Transport upgrade notes (for widgets)

- Current: 250 ms HTTP polling — fine for executes, too slow for
  interactive widgets.
- Minimal upgrade: **SSE** for the event stream (one-way push, easy in
  the existing ThreadingHTTPServer) + **HTTP POST** for frontend→kernel
  comm messages relayed by the broker onto the shell channel.
- Alternative: full **WebSocket** (JupyterLab-style). Acceptable but
  more machinery.
- JupyterLab does browser ↔ WebSocket ↔ server ↔ ZMQ; VSCode does
  Node-side ZMQ (zeromq.js) + internal IPC. Our shape (browser ↔ HTTP
  ↔ broker ↔ ZMQ) is the same pattern.
