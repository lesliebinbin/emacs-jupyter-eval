import { useEffect, useMemo, useState } from 'react'
import type { JSONObject, JSONValue } from '@lumino/coreutils'
import {
  BrowserWidgetManager,
  MimeOutput,
  WidgetOutput,
  type JupyterEvent,
  type MimeBundle,
} from './jupyter'
import './App.css'

const WIDGET_MIME = 'application/vnd.jupyter.widget-view+json'

type RichOutput = {
  id: string
  displayId?: string
  data: MimeBundle
  metadata: JSONObject
}

type Cell = {
  requestId: string
  id: number
  code: string
  output: string
  error: string
  richOutputs: RichOutput[]
  time: string
  status: 'running' | 'complete'
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asJSONObject(value: unknown): JSONObject {
  return isRecord(value) ? value as JSONObject : {}
}

function asMimeBundle(value: unknown): MimeBundle | undefined {
  return isRecord(value) ? value as Record<string, JSONValue> : undefined
}

function stripAnsi(text: string) {
  return text.replace(/\[[0-9;]*m/g, '')
}

function appendStream(output: string, text: string) {
  return text.split('\r').reduce((current, segment, index) => {
    if (index === 0) return current + segment
    if (segment.startsWith('\n')) return current + segment
    const lineStart = current.lastIndexOf('\n') + 1
    return current.slice(0, lineStart) + segment
  }, output)
}

function relatedUrl(eventsUrl: string, suffix: 'stream' | 'comm') {
  const url = new URL(eventsUrl, window.location.href)
  if (suffix === 'stream') {
    url.pathname = `${url.pathname.replace(/\/$/, '')}/stream`
  } else {
    url.pathname = url.pathname.replace(/\/jupyter-eval-events\/?$/, '/jupyter-eval-comm')
  }
  return url.toString()
}

function StatusDot({ active }: { active: boolean }) {
  return <span className={`status-dot ${active ? 'active' : ''}`} aria-hidden="true" />
}

function RichCellOutput({
  output,
  manager,
}: {
  output: RichOutput
  manager: BrowserWidgetManager
}) {
  const widgetData = output.data[WIDGET_MIME]
  const modelId = isRecord(widgetData) ? widgetData.model_id : undefined
  return typeof modelId === 'string'
    ? <WidgetOutput manager={manager} modelId={modelId} />
    : <MimeOutput data={output.data} metadata={output.metadata} />
}

function App() {
  const [connected, setConnected] = useState(false)
  const [cells, setCells] = useState<Cell[]>([])
  const kernelName = import.meta.env.VITE_JUPYTER_EVAL_KERNEL_NAME || 'not selected'
  const eventsUrl = import.meta.env.VITE_JUPYTER_EVAL_EVENTS_URL
    || (import.meta.env.DEV
      ? 'http://127.0.0.1:8766/jupyter-eval-events'
      : '/jupyter-eval-events')
  const streamUrl = useMemo(() => relatedUrl(eventsUrl, 'stream'), [eventsUrl])
  const manager = useMemo(
    () => new BrowserWidgetManager(relatedUrl(eventsUrl, 'comm')),
    [eventsUrl],
  )

  useEffect(() => {
    const events = new EventSource(streamUrl)
    events.onopen = () => setConnected(true)
    events.onerror = () => setConnected(false)
    events.onmessage = (message) => {
      let event: JupyterEvent
      try {
        event = JSON.parse(message.data) as JupyterEvent
      } catch (error) {
        console.error('Could not parse a Jupyter event', error)
        return
      }

      manager.handleEvent(event)
      const content = event.content ?? {}
      if (event.type === 'execution_started'
        && event.requestId
        && typeof event.code === 'string') {
        setCells((current) => current.some((cell) => cell.requestId === event.requestId)
          ? current
          : [...current, {
              requestId: event.requestId!,
              id: 0,
              code: event.code!,
              output: '',
              error: '',
              richOutputs: [],
              time: 'executing',
              status: 'running',
            }])
      } else if (event.requestId
        && event.type === 'stream'
        && typeof content.text === 'string') {
        setCells((current) => current.map((cell) => cell.requestId === event.requestId
          ? { ...cell, output: appendStream(cell.output, content.text as string) }
          : cell))
      } else if (event.requestId && event.type === 'error') {
        const traceback = Array.isArray(content.traceback)
          ? content.traceback
              .filter((line): line is string => typeof line === 'string')
              .map((line) => stripAnsi(line).replace(/\n$/, ''))
          : []
        const text = traceback.length > 0
          ? traceback.join('\n')
          : stripAnsi(`${typeof content.ename === 'string' ? content.ename : 'Error'}: ${typeof content.evalue === 'string' ? content.evalue : ''}`)
        setCells((current) => current.map((cell) => cell.requestId === event.requestId
          ? { ...cell, error: cell.error ? `${cell.error}\n${text}` : text }
          : cell))
      } else if (event.requestId
        && ['display_data', 'execute_result'].includes(event.type)) {
        const data = asMimeBundle(content.data)
        if (!data) return
        const transient = isRecord(content.transient) ? content.transient : {}
        const displayId = typeof transient.display_id === 'string'
          ? transient.display_id
          : undefined
        const output: RichOutput = {
          id: `${event.requestId}-${message.lastEventId}`,
          displayId,
          data,
          metadata: asJSONObject(content.metadata),
        }
        setCells((current) => current.map((cell) => cell.requestId === event.requestId
          ? { ...cell, richOutputs: [...cell.richOutputs, output] }
          : cell))
      } else if (event.type === 'update_display_data') {
        const data = asMimeBundle(content.data)
        const transient = isRecord(content.transient) ? content.transient : {}
        const displayId = transient.display_id
        if (!data || typeof displayId !== 'string') return
        setCells((current) => current.map((cell) => ({
          ...cell,
          richOutputs: cell.richOutputs.map((output) => output.displayId === displayId
            ? {
                ...output,
                data,
                metadata: asJSONObject(content.metadata),
              }
            : output),
        })))
      } else if (event.requestId
        && event.type === 'execute_input'
        && typeof content.execution_count === 'number') {
        setCells((current) => current.map((cell) => cell.requestId === event.requestId
          ? { ...cell, id: content.execution_count as number }
          : cell))
      } else if (event.requestId
        && event.type === 'status'
        && content.execution_state === 'idle') {
        setCells((current) => current.map((cell) => cell.requestId === event.requestId
          ? { ...cell, status: 'complete', time: 'complete' }
          : cell))
      }
    }
    return () => events.close()
  }, [manager, streamUrl])

  useEffect(() => () => manager.disconnect(), [manager])

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
          <article className="cell-card" key={cell.requestId}>
            <div className="cell-meta"><span>In [{cell.status === 'running' ? '*' : cell.id}]</span><time>{cell.status === 'running' ? 'executing' : cell.time}</time></div>
            <pre className="source"><code>{cell.code}</code></pre>
            {(cell.output || cell.richOutputs.length > 0) && <div className="output">
              <div className="output-meta"><span>Out [{cell.id}]</span><span>kernel output</span></div>
              {cell.output && <pre>{cell.output}</pre>}
              {cell.richOutputs.map((output) => (
                <RichCellOutput output={output} manager={manager} key={output.id} />
              ))}
            </div>}
            {cell.error && <div className="error-output">
              <div className="output-meta"><span>Out [{cell.id}]</span><span>error</span></div>
              <pre>{cell.error}</pre>
            </div>}
          </article>
        ))}
      </section>
    </main>
  )
}

export default App
