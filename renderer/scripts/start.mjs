import { createServer } from 'node:net'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const host = '127.0.0.1'

const server = createServer()
server.listen(0, host, () => {
  const { port } = server.address()
  server.close(() => {
    const vite = spawn(
      process.execPath,
      [fileURLToPath(new URL('../node_modules/vite/bin/vite.js', import.meta.url)),
        '--host', host, '--port', String(port), '--strictPort'],
      { stdio: 'inherit', env: process.env },
    )
    vite.on('exit', (code, signal) => process.exitCode = code ?? (signal ? 1 : 0))
  })
})
