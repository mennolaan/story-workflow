/** The main turn ends since the state file at path last changed (its mtime). */
export type CheckpointAge = { path: string; mtimeMs: number; turns: number }

declare module 'claude-code' {
  interface PluginState {
    'story-workflow': { checkpointAge: CheckpointAge }
  }
}
