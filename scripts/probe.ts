// Calls every provider and prints the normalized result.
// Usage: npm run probe [-- claude codex cursor]
import { fetchUsage, PROVIDERS, type ProviderId } from "../src/providers/index.ts"

const ids = (process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(PROVIDERS)) as ProviderId[]
for (const u of await Promise.all(ids.map((id) => fetchUsage(id)))) {
  console.log(
    JSON.stringify(
      { ...u, windows: u.windows.map((w) => ({ ...w, resetsAt: w.resetsAt && new Date(w.resetsAt).toLocaleString() })) },
      null,
      2,
    ),
  )
}
