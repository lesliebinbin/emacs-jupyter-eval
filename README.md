# Jupyter Eval

Jupyter Eval sends code from editor adapters to a Jupyter engine and renders
normalized execution output in a focused browser panel.

## Architecture

The repository is organized by responsibility rather than implementation
language:

| Component | Responsibility | Current implementation |
| --- | --- | --- |
| `adapters/emacs/` | Emacs commands, code extraction, and local service orchestration | Emacs Lisp |
| `broker/` | Kernel discovery and lifecycle, execution submission, ZMQ transport, and normalized events | Python 3.12 |
| `engines/python/` | Reproducible Python/IPython runtime and kernelspec registration | Python 3.12 |
| `renderer/` | Receive-only execution output panel | React and TypeScript on Node.js 24 |

The runtime flow is:

```text
adapter -> broker -> Jupyter engine
              |
              +---- normalized events -> renderer
```

Each component owns a `mise.toml`, dependencies, and tasks. This keeps the
components independently runnable and allows the broker, renderer, adapters,
or engines to become separate repositories or Git submodules later.

The root `mise.toml` only declares the mise monorepo and aggregates common
tasks.

## Setup

Install all managed runtimes and dependencies:

```bash
mise install --monorepo
mise setup
```

Register the included Python engine as a Jupyter kernelspec:

```bash
mise //engines/python:register
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

Tasks can be run from the root:

```bash
mise //broker:check
mise //renderer:dev
mise //renderer:build
mise //renderer:lint
```

They can also be run from within a component:

```bash
cd renderer
mise :dev
```

## Emacs workflow

Load `adapters/emacs/jupyter-eval.el`, visit a Python file, and run
`M-x run-jupyter-eval`. The adapter asks the broker for available engines,
starts the selected Jupyter kernel, starts the broker's publisher and event
subscriber, and launches the renderer using its own mise environment.

Select a region and run `M-x jupyter-eval-send-region` to submit it. If
`code-cells` is installed, `jupyter-eval-mode` also registers that command as
its region evaluator.

The renderer receives events from the loopback-only broker and displays source
code, streamed text, execution state, and PNG output.

## Independent component development

The broker includes standalone listener and sender commands:

```bash
cd broker
mise :setup

python scripts/jupyter_eval_listen.py \
  --connection-file /tmp/jupyter-eval-python.json

python scripts/jupyter_eval_send.py \
  --connection-file /tmp/jupyter-eval-python.json \
  --code 'print("Hello from Jupyter")'
```

The engine launcher can be used independently:

```bash
cd engines/python
mise :setup

python scripts/jupyter_eval_start_kernel.py \
  --kernel jupyter-eval-python \
  --connection-file /tmp/jupyter-eval-python.json
```

Start the renderer from its own directory:

```bash
cd renderer
VITE_JUPYTER_EVAL_KERNEL_NAME=jupyter-eval-python mise :dev
```
