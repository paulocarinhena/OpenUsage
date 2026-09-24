// Prints every provider's usage as one JSON array. Used by the desktop widget.
import { fetchUsage, PROVIDERS, type ProviderId } from "../src/providers/index.ts"

const ids = (process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(PROVIDERS)) as ProviderId[]
process.stdout.write(JSON.stringify(await Promise.all(ids.map((id) => fetchUsage(id)))))
