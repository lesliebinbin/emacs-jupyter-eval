# Jupyter Eval

The Vite frontend is receive-only. During development it runs on port 5173
and polls the local bridge listener directly at
`http://127.0.0.1:8766/jupyter-eval-events`; Vite does not proxy bridge
traffic.

Start each bridge responsibility in a separate terminal:

```bash
# 1. Start the kernel and write its ZMQ connection details.
python3 scripts/jupyter_eval_start_kernel.py \
  --kernel my-causal-ai \
  --connection-file /tmp/jupyter-eval-my-causal-ai.json
```

```bash
# 2. Forward kernel IOPub output to the browser-facing event endpoint.
python3 scripts/jupyter_eval_listen.py \
  --connection-file /tmp/jupyter-eval-my-causal-ai.json
```

```bash
# 3. Serve the receive-only frontend.
VITE_JUPYTER_EVAL_KERNEL_NAME=my-causal-ai npm run dev
```

Submit code from another terminal (or later from Emacs):

```bash
python3 scripts/jupyter_eval_send.py \
  --connection-file /tmp/jupyter-eval-my-causal-ai.json \
  --code 'print("Hello from Jupyter")'
```
