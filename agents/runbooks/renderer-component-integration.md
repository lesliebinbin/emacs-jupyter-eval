# Runbook: Adding a JupyterLab component to the renderer

Applies to any task that embeds a `@jupyterlab/*` or `@jupyter-widgets/*`
package into the Vite renderer (rendermime, html-manager, future ones).

## Steps

1. **Branch** from `master` (make sure recently-merged PRs are in).
2. **Install** the package into `renderer/`
   (`mise --cd renderer exec -- npm install <pkg>`). Commit
   `package.json` + `package-lock.json`.
3. **Wire it** in `renderer/src/App.tsx` (and `App.css`). Keep the cell
   model and event branches; extend, don't rewrite.
4. **Build** with `mise //renderer:build` (runs `tsc -b` + vite build).
5. **Verify** against a live event stream — see the verification
   checklist below. Never verify only against synthetic fixtures.
6. **PR** against `master`; promote durable learnings into
   `agents/references/` before the task closes.

## Gotchas (learned from previous integrations)

- **CRLF stream output**: shell escapes (`!cmd`) and pipes emit `\r\n`.
  Stream-append logic must treat a `\n`-starting segment after `\r` as
  a line break, not a progress-bar rewrite (fixed in PR #4).
- **Session endpoints are runtime-discovered**: the coordinator atomically
  writes `/tmp/jupyter-eval/sessions.json`; Vite serves only entries whose
  broker health identity and generation match. Never add capabilities to this
  registry.
- **Error events carry ANSI color codes** in tracebacks — strip before
  rendering.
- **`execute_result` text is the common case**: a bare expression
  arrives as `execute_result` with `text/plain`, not as a stream.
- The event server requires `--allowed-origin` and returns that exact origin.
  Keep this check on snapshot, SSE, health, POST, and preflight routes. Comm
  POSTs additionally require the session-generation capability.
- `@jupyter-widgets/html-manager` references Webpack's
  `__webpack_public_path__`; preserve the Vite `define` shim.
- Browser comm POSTs must remain serialized. `ThreadingHTTPServer` request
  arrival order is not a safe substitute for Jupyter comm ordering.
- If touching the **broker**: the input processor waits for the shell
  reply before closing (prevents dropped executes); iopub on
  ipykernel ≥ 7 uses XPUB topic subscriptions — subscribe to `b""`
  and expect an `iopub_welcome` message first.
- If touching **elisp**: Emacs 31 interns JSON alist keys as symbols
  (`symbol-name` for strings); `call-process` error destination wants a
  file-name string, not a buffer object; `url-retrieve-synchronously`
  hangs in batch Emacs — use `call-process "curl"` in e2e scripts.
- If touching the **engine**: uv venvs have no pip (use
  `uv add --project engines/python pip` if `%pip` is needed); connection
  files live under `/tmp/jupyter-eval/`.

## Verification checklist

1. `mise //renderer:build` passes.
2. Renderer e2e: launch a kernel + broker against a temp kernelspec
   (`--prefix` + `JUPYTER_PATH`), run the vite dev server with the
   events URL of that session, and check the cells visually or via the
   event JSON.
3. Full pipeline e2e in batch Emacs: `jupyter-eval-start` →
   `jupyter-eval-send-region` → events over HTTP → `jupyter-eval-stop`
   (see existing test scripts; stub `jupyter-eval--open-frontend` in
   batch).
4. ERT: `emacs -Q --batch -L . -l test/jupyter-eval-test.el -f
   ert-run-tests-batch-and-exit` from `adapters/emacs/`.
