import { claude } from "./claude.ts"
import { codex } from "./codex.ts"
import { cursor } from "./cursor.ts"
import { opencodeGo } from "./opencode-go.ts"
import { failed, type Provider, type ProviderId, type ProviderUsage } from "./types.ts"

export * from "./types.ts"

export const PROVIDERS: Readonly<Record<ProviderId, Provider>> = { claude, codex, cursor, "opencode-go": opencodeGo }

/** Never rejects: a failing provider comes back with `error` set. */
export async function fetchUsage(id: ProviderId, signal?: AbortSignal): Promise<ProviderUsage> {
  const p = PROVIDERS[id]
  const [usage, account] = await Promise.all([
    p.fetch(signal).catch((e) => failed(p, e)),
    p.account?.().catch(() => undefined),
  ])
  return account ? { ...usage, account } : usage
}
