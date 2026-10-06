// The engine-map mod's session state, kept for the session across hot reloads:
//   said: the messages it has already shown, as `key:<key>` and `text:<text>`
//         entries (hooks/notices.ts), so an identical message is never shown
//         twice;
//   gone: by role, the entries classified unavailable in this process
//         (hooks/chain.ts), so a reload does not put a role back on a dead
//         entry.
export type SdlcEngineMapSaid = string[]
export type SdlcEngineMapGone = Record<string, string[]>

declare module 'claude-code' {
  interface PluginState {
    'sdlc-engine-map': { said: SdlcEngineMapSaid; gone: SdlcEngineMapGone }
  }
}
