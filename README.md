# Jupyter Eval

Jupyter Eval sends code from editor adapters to a Jupyter engine and renders
normalized execution output in a focused browser panel.

## Architecture

The repository is organized by responsibility rather than implementation
language:

| Component | Responsibility | Current implementation |
| --- | --- | --- |
| `jupyter-eval.el` (root) | Coordinator: starts the engine kernel, broker processors, and renderer with proper sequencing | Emacs Lisp |
| `adapters/emacs/` | `code-cells` adaptation: minor mode and region-evaluation integration | Emacs Lisp |
| `broker/` | Pure ZMQ↔HTTP bridge: input processor (code requests) and output processor (normalized kernel events) | Python 3.12, uv |
| `engines/python/` | Kernel lifecycle (launch, list, register kernelspecs) and reproducible runtime | Python 3.12, uv |
| `renderer/` | Receive-only execution output panel | React and TypeScript on Node.js 24 |

The runtime flow is:

```text
adapter -> broker input  -> Jupyter engine
                ^
broker output <-+
     |
     +---- normalized events -> renderer
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
kernel, launches it through the engine, waits for its connection file, starts
the broker input and output processors, and launches the renderer using its
own mise environment.

Select a region and run `M-x jupyter-eval-send-region` to submit it. If
`code-cells` is installed, `code-cells-adapt-mode` (enabled automatically in
Python buffers) registers that command as its region evaluator. Stop
everything with `M-x jupyter-eval-stop`.

The renderer receives events from the loopback-only broker and displays source
code, streamed text, execution state, errors, and PNG output.

If the renderer dependencies are not installed yet (`node_modules` missing),
`jupyter-eval-start` prompts to install them (`npm ci` via mise), like vterm
does for compilation.

Kernel connection and pid files live under `/tmp/jupyter-eval/` with
deterministic names; the OS clears them with its regular temporary-file
cleanup.

> Note: after upgrading from a previous layout of this repository, force a
> reinstall of the package (e.g. delete `~/.emacs.d/elpa/<emacs-version>/develop/jupyter-eval-*`
> and restart Emacs) so the new coordinator is rebuilt from the current tree.

## Independent component development

List kernels and launch one through the engine:

```bash
uv run --project engines/python python launch.py list
uv run --project engines/python python launch.py launch \
  --kernel-id jupyter-eval-python \
  --buffer-path /tmp/fake.py
```

Submit code and serve events through the broker:

```bash
uv run --project broker python main.py input \
  --connection-file /tmp/jupyter-eval/<hash>_<hash>_kernel.json \
  --code 'print("Hello from Jupyter")'

uv run --project broker python main.py output \
  --connection-file /tmp/jupyter-eval/<hash>_<hash>_kernel.json \
  --event-port 8766
```

Start the renderer from its own directory:

```bash
cd renderer
VITE_JUPYTER_EVAL_KERNEL_NAME=jupyter-eval-python mise :dev
```
