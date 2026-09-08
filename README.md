# Jupyter Eval

Jupyter Eval sends code from editor adapters to a Jupyter engine and renders
normalized execution output in a focused browser panel.

## Architecture

The repository is organized by responsibility rather than implementation
language:

| Component | Responsibility | Current implementation |
| --- | --- | --- |
| `jupyter-eval.el` (root) | Coordinator: manages buffer-associated sessions, their kernels and brokers, and one shared renderer | Emacs Lisp |
| `adapters/emacs/` | `code-cells` adaptation: minor mode and region-evaluation integration | Emacs Lisp |
| `broker/` | Pure ZMQ↔HTTP bridge: input processor (code requests) and output processor (normalized kernel events) | Python 3.12, uv |
| `engines/python/` | Kernel lifecycle (launch, list, register kernelspecs) and reproducible runtime | Python 3.12, uv |
| `renderer/` | Rich execution output and interactive widget panel | React and TypeScript on Node.js 24 |

The runtime flow is:

```text
source buffer -> session input broker -> Jupyter kernel
                         ^
session output broker <---+
         |
         +---- events and authorized comms -> shared renderer
```

The broker and engine are uv-managed Python projects; the renderer keeps its
`mise.toml` for Node.js. The root `mise.toml` only declares the mise monorepo
and aggregates renderer tasks.

## Setup

Python 3.12 and all dependencies are managed by [uv](https://docs.astral.sh/uv).
The first `uv run` downloads a managed CPython 3.12 plus wheels, so pre-warm
both projects once:

```bash
uv sync --project broker
uv sync --project engines/python
```

Register the included Python engine as a Jupyter kernelspec:

```bash
uv run --project engines/python python launch.py register
```

Install renderer dependencies:

```bash
mise install --monorepo
mise setup
```

Run the currently enabled checks:

```bash
mise check
```

Emacs Lisp tests are intentionally separate while the Emacs environment is
being rebuilt:

```bash
mise //adapters/emacs:test
```

## Emacs workflow

Install the package (e.g. via quelpa with `:files ("*")`) and `require`
`jupyter-eval`; the root file loads the `code-cells-adapt` adapter itself.
Visit a Python file and run `M-x jupyter-eval-start`. The coordinator picks a
kernel, creates or reopens that file's session, waits for its connection file,
and starts session-local input and output brokers. Other buffers can keep
independent sessions running, including sessions that use the same kernelspec.
One renderer process serves the session index at `http://127.0.0.1:5173/` and
each feed at `/sessions/<session-id>`.

Select a region and run `M-x jupyter-eval-send-region` to submit it. If
`code-cells` is installed, `code-cells-adapt-mode` (enabled automatically in
Python buffers) registers that command as its region evaluator.
`M-x jupyter-eval-stop` stops only the current buffer's session;
`M-x jupyter-eval-stop-all` stops every managed session. Killing a source
buffer does not stop its session, and reopening the same file reuses it.

The renderer discovers live sessions from an atomic runtime registry and
validates each entry against its loopback-only broker. It receives events over
SSE and displays source code, streams, errors, rich Jupyter MIME output, and
ipywidgets. Plain browser URLs are read-only. Emacs xwidget URLs carry a
random, session-generation-scoped capability in the URL fragment; widget state
changes return through a broker endpoint that independently validates that
capability.

If the renderer dependencies are not installed yet (`node_modules` missing),
`jupyter-eval-start` prompts to install them (`npm ci` via mise), like vterm
does for compilation.

Kernel connection files, pid files, and the public `sessions.json` discovery
registry live under `/tmp/jupyter-eval/`. The registry contains no interactive
capabilities, and the renderer filters entries whose broker identity and
generation health check no longer match.

> Note: after upgrading from a previous layout of this repository, force a
> reinstall of the package (e.g. delete `~/.emacs.d/elpa/<emacs-version>/develop/jupyter-eval-*`
> and restart Emacs) so the new coordinator is rebuilt from the current tree.

## Independent component development

List kernels and launch one through the engine:

```bash
uv run --project engines/python python launch.py list
uv run --project engines/python python launch.py launch \
  --kernel-id jupyter-eval-python \
  --buffer-path /tmp/fake.py \
  --session-id manual-test
```

Submit code and serve events through the broker:

```bash
uv run --project broker python main.py input \
  --connection-file /tmp/jupyter-eval/<session-id>_kernel.json \
  --code 'print("Hello from Jupyter")'

uv run --project broker python main.py output \
  --connection-file /tmp/jupyter-eval/<session-id>_kernel.json \
  --event-port 8766 \
  --allowed-origin http://127.0.0.1:5173 \
  --session-id manual-test \
  --generation manual-generation \
  --interactive-capability "$(openssl rand -hex 32)"
```

Start the renderer from its own directory:

```bash
cd renderer
mise :dev
```
