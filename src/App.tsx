import { useEffect, useState } from 'react'
import './App.css'

type Cell = {
  id: number
  requestId?: string
  code: string
  output: string
  images: string[]
  time: string
  status: 'running' | 'complete'
}

function appendStream(output: string, text: string) {
  return text.split('\r').reduce((current, segment, index) => {
    if (index === 0) return current + segment
    const lineStart = current.lastIndexOf('\n') + 1
    return current.slice(0, lineStart) + segment
  }, output)
}

function StatusDot({ active }: { active: boolean }) {
  return <span className={`status-dot ${active ? 'active' : ''}`} aria-hidden="true" />
}

function App() {
  const [connected, setConnected] = useState(false)
  const [cells, setCells] = useState<Cell[]>([])
  const kernelName = import.meta.env.VITE_JUPYTER_EVAL_KERNEL_NAME || 'not selected'
  const eventsUrl = import.meta.env.VITE_JUPYTER_EVAL_EVENTS_URL
    || (import.meta.env.DEV
      ? 'http://127.0.0.1:8766/jupyter-eval-events'
      : '/jupyter-eval-events')

  useEffect(() => {
    const seen = new Set<string>()
    const timer = window.setInterval(async () => {
      try {
        const response = await fetch(eventsUrl)
        const { events } = await response.json()
        setConnected(true)
        for (const event of events) {
          const eventKey = JSON.stringify(event)
          if (seen.has(eventKey)) continue
          seen.add(eventKey)
          if (event.type === 'execution_started') {
            setCells((current) => current.some((cell) => cell.requestId === event.requestId) ? current : [...current, { id: 0, requestId: event.requestId, code: event.code, output: '', images: [], time: 'executing', status: 'running' }])
          } else if (event.requestId && event.type === 'stream') {
            setCells((current) => current.map((cell) => cell.requestId === event.requestId ? { ...cell, output: appendStream(cell.output, event.content.text) } : cell))
          } else if (event.requestId && ['display_data', 'execute_result'].includes(event.type) && event.content.data?.['image/png']) {
            const image = `data:image/png;base64,${event.content.data['image/png']}`
            setCells((current) => current.map((cell) => cell.requestId === event.requestId && !cell.images.includes(image) ? { ...cell, images: [...cell.images, image] } : cell))
          } else if (event.requestId && event.type === 'execute_input') {
            setCells((current) => current.map((cell) => cell.requestId === event.requestId ? { ...cell, id: event.content.execution_count } : cell))
          } else if (event.requestId && event.type === 'status' && event.content.execution_state === 'idle') {
            setCells((current) => current.map((cell) => cell.requestId === event.requestId ? { ...cell, status: 'complete', time: 'complete' } : cell))
          }
        }
      } catch {
        setConnected(false)
      }
    }, 250)
    return () => window.clearInterval(timer)
  }, [eventsUrl])

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
          <p>{connected ? 'Receiving execution events.' : 'Waiting for the local bridge.'}</p>
        </aside>
      </section>

      <section className="feed-header">
        <div><p className="eyebrow">LIVE FEED</p><h2>Recent evaluations</h2></div>
      </section>

      <section className="feed" aria-live="polite">
        {cells.length === 0 && <div className="empty-state">Run a code cell from Emacs to begin.</div>}
        {cells.map((cell) => (
          <article className="cell-card" key={cell.id}>
            <div className="cell-meta"><span>In [{cell.status === 'running' ? '*' : cell.id}]</span><time>{cell.status === 'running' ? 'executing' : cell.time}</time></div>
            <pre className="source"><code>{cell.code}</code></pre>
            {(cell.output || cell.images.length > 0) && <div className="output">
              <div className="output-meta"><span>Out [{cell.id}]</span><span>stream: stdout</span></div>
              {cell.output && <pre>{cell.output}</pre>}
              {cell.images.map((image) => <img className="output-image" src={image} alt={`Output for cell ${cell.id}`} key={image} />)}
            </div>}
          </article>
        ))}
      </section>
    </main>
  )
}

export default App
