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
  ├─ session registry:        source path → independent generation/process set
  │                            public metadata → /tmp/jupyter-eval/sessions.json
  ├─ engine launch.py:        kernel spawn; one connection file per session ID
  ├─ per-session input:       stdin JSON-lines {"code"} → ZMQ shell execute
  ├─ per-session output:      ZMQ iopub (SUB b"") → deque(1000) →
  │                            GET /jupyter-eval-events → {"events": [...]}
  │                            SSE /jupyter-eval-events/stream
  │                            GET /jupyter-eval-health → identity/generation
  │                            authorized POST /jupyter-eval-comm → ZMQ shell
  └─ shared renderer:         Vite on 5173; discovers and health-checks sessions;
                               rendermime handles static MIME bundles and
                               html-manager handles widget models/views
```

Event items share the shape
`{"type", "requestId", "content": {...}}`; `execution_started` carries
`code`. All events for one execute share the same `requestId`.

## Renderer coverage

| Output | Supported |
|---|---|
| stream stdout/stderr | ✓ |
| image/png (display_data / execute_result) | ✓ |
| errors (traceback, ANSI-stripped) | ✓ |
| execute_result text/plain | ✓ |
| text/html, markdown, HTML5 video, sanitized SVG, LaTeX | ✓ |
| `update_display_data` | ✓ |
| standard ipywidgets (comm) | ✓ |

## Transport notes

- Current transport uses **SSE** for ordered, session-local kernel events and
  **HTTP POST** for frontend→kernel comm messages. SSE event IDs support
  reconnect/replay from the broker's bounded deque. The original JSON snapshot
  route remains available for diagnostics and compatibility.
- Browser routes allow only the exact shared renderer origin. Comm POSTs also
  require a random capability belonging to the broker's session generation;
  discovery never contains that capability. Keep POST requests serialized in
  the renderer because comm message order is significant.
- Plain `/sessions/<session-id>` URLs construct read-only widget managers.
  Emacs xwidget URLs carry the capability in the fragment, which is not sent
  to the Vite server. Session routes must construct separate event, cell, and
  widget-manager state.
- JupyterLab does browser ↔ WebSocket ↔ server ↔ ZMQ; VSCode does
  Node-side ZMQ (zeromq.js) + internal IPC. Our shape (browser ↔ HTTP
  ↔ broker ↔ ZMQ) is the same pattern.

## Renderer integration details

- `@jupyterlab/rendermime` needs an application-provided Markdown parser and
  LaTeX typesetter. This renderer uses `marked` and KaTeX.
- Jupyter marks SVG rendering unsafe. The renderer removes active and external
  SVG content before passing the sanitized SVG to rendermime as trusted data.
- The HTML sanitizer preserves `src` on `<source>` and `<track>` tags as well
  as `playsinline` attributes on `<video>` to support HTML5 video playback
  (e.g. from Matplotlib's `to_html5_video()`).
- `@jupyter-widgets/html-manager` expects Webpack's
  `__webpack_public_path__`; Vite defines it as an empty string.
- Binary comm buffers are base64-encoded only across HTTP and converted back to
  Jupyter message buffers on each side.
