export type ProviderId = "claude" | "codex" | "cursor" | "opencode-go"

/** One rate-limit window, e.g. Claude "5-Hour". */
export interface UsageWindow {
  readonly label: string
  /** 0..100 */
  readonly usedPct: number
  /** Epoch millis when the window resets, if known. */
  readonly resetsAt?: number
}

/** A non-percentage line, e.g. Codex "Credits Balance  $0.00". */
export interface UsageExtra {
  readonly label: string
  readonly value: string
}

export interface ProviderUsage {
  readonly id: ProviderId
  readonly name: string
  readonly windows: readonly UsageWindow[]
  readonly extras: readonly UsageExtra[]
  /** Plan name shown next to the provider, e.g. "max", "pro". */
  readonly plan?: string
  /** Signed-in account, usually its email. */
  readonly account?: string
  /** Short, user-facing reason when the provider could not be read. */
  readonly error?: string
  readonly fetchedAt: number
}

export interface Provider {
  readonly id: ProviderId
  readonly name: string
  fetch(signal?: AbortSignal): Promise<ProviderUsage>
  /** Reads the signed-in account from local files only; resolves undefined when unknown. */
  account?(): Promise<string | undefined>
}

export class ProviderError extends Error {}

export async function getJson(url: string, init: RequestInit, what: string): Promise<any> {
  const res = await fetch(url, { ...init, signal: init.signal ?? AbortSignal.timeout(15_000) })
  if (res.status === 401 || res.status === 403) throw new ProviderError(`${what}: sign in again`)
  if (res.status === 429) throw new ProviderError(`${what}: rate limited, will retry`)
  if (!res.ok) throw new ProviderError(`${what}: HTTP ${res.status}`)
  return res.json()
}

/** First row of a read-only query against a local SQLite file. */
export async function sqliteGet(path: string, sql: string, ...params: unknown[]): Promise<any> {
  const { DatabaseSync } = await import("node:sqlite")
  const db = new DatabaseSync(path, { readOnly: true })
  try {
    return db.prepare(sql).get(...(params as never[]))
  } finally {
    db.close()
  }
}

/** Decodes a JWT payload without verifying it. */
export function jwtPayload(jwt: string): any {
  try {
    return JSON.parse(Buffer.from(jwt.split(".")[1]!, "base64url").toString("utf8"))
  } catch {
    return undefined
  }
}

export function clampPct(n: unknown): number {
  const v = typeof n === "number" ? n : Number(n)
  if (!Number.isFinite(v)) return 0
  return Math.max(0, Math.min(100, v))
}

/** Accepts ISO strings, epoch seconds or epoch millis. */
export function toMillis(v: unknown): number | undefined {
  if (v == null || v === "") return undefined
  if (typeof v === "number") return v < 1e12 ? v * 1000 : v
  const n = Number(v)
  if (Number.isFinite(n)) return toMillis(n)
  const t = Date.parse(String(v))
  return Number.isNaN(t) ? undefined : t
}

export function failed(p: Pick<Provider, "id" | "name">, e: unknown): ProviderUsage {
  const error = e instanceof ProviderError ? e.message : e instanceof Error ? e.message : String(e)
  return { id: p.id, name: p.name, windows: [], extras: [], error, fetchedAt: Date.now() }
}
