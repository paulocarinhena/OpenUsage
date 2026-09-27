// Version and self-update for the widgets. Prints one JSON object.
// Usage: node --experimental-strip-types scripts/update.ts <check|apply>
//   check: { version, commit, behind }  (behind = commits waiting on the remote branch)
//   apply: { version, commit, behind: 0, updated } after a fast-forward pull
// Any failure comes back as { ..., error } with exit code 0, so the widgets can show it.
import { execFile } from "node:child_process"
import { readFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = dirname(dirname(fileURLToPath(import.meta.url)))

function git(...args: string[]): Promise<string> {
  return new Promise((resolve, reject) =>
    execFile("git", args, { cwd: root, timeout: 60_000, windowsHide: true }, (err, stdout, stderr) =>
      err ? reject(new Error((stderr || err.message).trim().split("\n").pop())) : resolve(stdout.trim()),
    ),
  )
}

async function info() {
  const version = await readFile(join(root, "package.json"), "utf8")
    .then((raw) => JSON.parse(raw).version as string)
    .catch(() => "unknown")
  const commit = await git("rev-parse", "--short", "HEAD").catch(() => undefined)
  return { version, commit }
}

async function behind(): Promise<number> {
  await git("fetch", "--quiet")
  return Number(await git("rev-list", "--count", "HEAD..@{u}"))
}

async function main(action: string) {
  const base = await info()
  if (!base.commit) return { ...base, error: "installed without Git" }
  try {
    if (action === "apply") {
      const before = base.commit
      await git("pull", "--ff-only", "--quiet")
      const after = await info()
      return { ...after, behind: 0, updated: after.commit !== before }
    }
    return { ...base, behind: await behind() }
  } catch (e) {
    return { ...base, error: e instanceof Error ? e.message : String(e) }
  }
}

const action = process.argv[2] ?? "check"
if (action !== "check" && action !== "apply") {
  console.error("Usage: update.ts <check|apply>")
  process.exitCode = 2
} else {
  process.stdout.write(JSON.stringify(await main(action)))
}
