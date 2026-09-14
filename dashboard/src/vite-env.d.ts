/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** API origin for a split-origin deployment. Empty -> same-origin '/api'. */
  readonly VITE_API_URL?: string;
  /** WebSocket origin. Falls back to VITE_API_URL, then to window.location.origin. */
  readonly VITE_WS_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

declare const __APP_VERSION__: string;
declare const __BUILD_TIME__: string;
