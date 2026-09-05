import { defineConfig } from 'vite';

export default defineConfig({
  // Relative so the built game runs from any path a hub drops it at.
  base: './',
  build: {
    target: 'es2020',
    assetsInlineLimit: 0,
  },
});
