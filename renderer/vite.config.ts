import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { readFile } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'

type Session = {
  id: string
  generation: string
  label: string
  kernelName: string
  eventUrl: string
}

const registryFile = process.env.JUPYTER_EVAL_REGISTRY_FILE
  ?? '/tmp/jupyter-eval/sessions.json'

async function liveSession(session: Session) {
  try {
    const healthUrl = new URL(session.eventUrl)
    healthUrl.pathname = '/jupyter-eval-health'
    const response = await fetch(healthUrl, {
      signal: AbortSignal.timeout(500),
    })
    if (!response.ok) return false
    const health = await response.json() as {
      sessionId?: string
      generation?: string
      status?: string
    }
    return health.sessionId === session.id
      && health.generation === session.generation
      && health.status === 'running'
  } catch {
    return false
  }
}

async function serveSessions(
  _request: IncomingMessage,
  response: ServerResponse,
) {
  try {
    const registry = JSON.parse(await readFile(registryFile, 'utf8')) as {
      sessions?: Session[]
    }
    const sessions = Array.isArray(registry.sessions)
      ? registry.sessions.filter((session) => session
          && typeof session.id === 'string'
          && typeof session.generation === 'string'
          && typeof session.label === 'string'
          && typeof session.kernelName === 'string'
          && typeof session.eventUrl === 'string')
      : []
    const live = await Promise.all(sessions.map(liveSession))
    response.statusCode = 200
    response.setHeader('Content-Type', 'application/json')
    response.setHeader('Cache-Control', 'no-store')
    response.end(JSON.stringify({
      sessions: sessions.filter((_session, index) => live[index]),
    }))
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      response.statusCode = 200
      response.setHeader('Content-Type', 'application/json')
      response.end('{"sessions":[]}')
      return
    }
    response.statusCode = 500
    response.end('Could not read the Jupyter Eval session registry')
  }
}

// https://vite.dev/config/
export default defineConfig({
  define: {
    __webpack_public_path__: JSON.stringify(''),
  },
  server: {
    host: '127.0.0.1',
  },
  plugins: [
    react(),
    {
      name: 'jupyter-eval-session-discovery',
      configureServer(server) {
        server.middlewares.use(
          '/api/jupyter-eval/sessions',
          (request, response) => {
            void serveSessions(request, response)
          },
        )
      },
    },
  ],
})
