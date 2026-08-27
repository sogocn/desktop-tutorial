import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import path from 'node:path'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  // PGlite ships a large WASM + a fs bundle; keep it out of the optimizer so the
  // worker/asset URLs resolve correctly, and let it land in its own lazy chunk.
  optimizeDeps: { exclude: ['@electric-sql/pglite'] },
  // 自托管后端模式本地联调：把 /api 代理到本地 Node API（npm run server）
  server: {
    proxy: {
      '/api': { target: 'http://localhost:3000', changeOrigin: true },
    },
  },
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('@electric-sql/pglite')) return 'pglite'
        },
      },
    },
  },
})
