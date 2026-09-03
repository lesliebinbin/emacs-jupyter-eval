import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  define: {
    __webpack_public_path__: JSON.stringify(''),
  },
  plugins: [react()],
})
