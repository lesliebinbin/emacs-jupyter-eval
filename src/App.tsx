import { useState } from 'react'
import './App.css'

type Cell = {
  id: number
  code: string
  output: string
  kind: 'text' | 'chart'
  time: string
  status: 'running' | 'complete'
}

const initialCells: Cell[] = [
  {
    id: 12,
    code: 'import numpy as np\nx = np.linspace(0, 2 * np.pi, 100)\ny = np.sin(x)',
    output: 'Arrays ready: x (100,), y (100,)',
    kind: 'text',
    time: 'just now',
    status: 'complete',
  },
  {
    id: 13,
    code: 'plt.plot(x, y)\nplt.title("Sine wave")\nplt.show()',
    output: 'Sine wave',
    kind: 'chart',
    time: 'just now',
    status: 'complete',
  },
]

function StatusDot({ active }: { active: boolean }) {
  return <span className={`status-dot ${active ? 'active' : ''}`} aria-hidden="true" />
}

function ChartPreview() {
  return (
    <svg className="chart" viewBox="0 0 640 220" role="img" aria-label="Sine wave plot">
      <defs>
        <linearGradient id="fill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor="#7c5cff" stopOpacity=".28" />
          <stop offset="100%" stopColor="#7c5cff" stopOpacity="0" />
        </linearGradient>
      </defs>
      {[35, 85, 135, 185].map((y) => <line key={y} x1="42" x2="614" y1={y} y2={y} />)}
      <path d="M42 110 C65 34 95 33 119 110 S172 186 196 110 S249 34 273 110 S326 186 350 110 S403 34 427 110 S480 186 504 110 S557 34 581 110 S603 159 614 110 V185 H42Z" className="chart-fill" />
      <path d="M42 110 C65 34 95 33 119 110 S172 186 196 110 S249 34 273 110 S326 186 350 110 S403 34 427 110 S480 186 504 110 S557 34 581 110 S603 159 614 110" className="chart-line" />
      <text x="42" y="211">0</text><text x="322" y="211">pi</text><text x="590" y="211">2pi</text>
    </svg>
  )
}

function App() {
  const [connected, setConnected] = useState(false)
  const [cells, setCells] = useState(initialCells)
  const kernelName = import.meta.env.VITE_JUPYTER_EVAL_KERNEL_NAME || 'not selected'

  function addDemoCell() {
    const id = cells.length + 12
    setCells((current) => [...current, {
      id,
      code: 'for step in range(3):\n    print(f"Processing step {step + 1}/3")',
      output: 'Waiting for kernel output...',
      kind: 'text',
      time: 'now',
      status: 'running',
    }])
    window.setTimeout(() => {
      setCells((current) => current.map((cell) => cell.id === id
        ? { ...cell, output: 'Processing step 1/3\nProcessing step 2/3\nProcessing step 3/3', status: 'complete', time: 'complete' }
        : cell))
    }, 1100)
  }

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand"><span className="brand-mark">&gt;_</span><span>Jupyter Eval</span></div>
        <div className="kernel-status"><StatusDot active={connected} />{connected ? 'Kernel connected' : 'Waiting for kernel'}</div>
      </header>

      <section className="intro">
        <div>
          <p className="eyebrow">LOCAL OUTPUT PANEL</p>
          <h1>Execution results,<br /><em>without the notebook chrome.</em></h1>
          <p className="lede">A focused display for code sent from Emacs. Stream output, rich results, and plots appear here as your kernel evaluates them.</p>
        </div>
        <aside className="connection-card">
          <div className="connection-heading"><StatusDot active={connected} /><span>Jupyter connection</span></div>
          <label htmlFor="kernel-name">Selected kernel</label>
          <input id="kernel-name" value={kernelName} readOnly />
          <button type="button" className={connected ? 'connected' : ''} onClick={() => setConnected((value) => !value)}>
            {connected ? 'Disconnect' : 'Connect locally'}
          </button>
          <p>{connected ? 'Ready to receive execution events.' : 'Frontend preview mode - no kernel request is sent yet.'}</p>
        </aside>
      </section>

      <section className="feed-header">
        <div><p className="eyebrow">LIVE FEED</p><h2>Recent evaluations</h2></div>
        <button type="button" className="demo-button" onClick={addDemoCell}>+ Render demo event</button>
      </section>

      <section className="feed" aria-live="polite">
        {cells.map((cell) => (
          <article className="cell-card" key={cell.id}>
            <div className="cell-meta"><span>In [{cell.status === 'running' ? '*' : cell.id}]</span><time>{cell.status === 'running' ? 'executing' : cell.time}</time></div>
            <pre className="source"><code>{cell.code}</code></pre>
            {cell.status === 'complete' && <div className="output">
              <div className="output-meta"><span>Out [{cell.id}]</span><span>{cell.kind === 'chart' ? 'image/svg+xml' : 'stream: stdout'}</span></div>
              {cell.kind === 'chart' ? <><h3>{cell.output}</h3><ChartPreview /></> : <pre>{cell.output}</pre>}
            </div>}
          </article>
        ))}
      </section>
    </main>
  )
}

export default App
