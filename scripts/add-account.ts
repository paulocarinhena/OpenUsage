// Adds another Claude or Codex account: its own config folder in home, a command that opens it
// (e.g. "claude2") and a sign-in. Works on Windows, macOS and Linux; the widgets' "+" button runs it too.
// Usage: npm run add-account -- <claude|codex> [command-name]
import { spawn } from "node:child_process"
import { accessSync, chmodSync, constants, existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { delimiter, dirname, join } from "node:path"
import { createInterface } from "node:readline/promises"
import { PROVIDERS } from "../src/providers/index.ts"

const KINDS = {
  claude: {
    name: "Claude",
    prefix: ".claude",
    envVar: "CLAUDE_CONFIG_DIR",
    command: "claude",
    login: [] as string[],
    hint: "Sign in with the other Claude account, then type /exit.",
  },
  codex: {
    name: "Codex",
    prefix: ".codex",
    envVar: "CODEX_HOME",
    command: "codex",
    login: ["login"],
    hint: "Sign in with the other ChatGPT account in the browser.",
  },
} as const
type Kind = keyof typeof KINDS

const isWin = process.platform === "win32"
const pathDirs = () => (process.env.PATH ?? "").split(delimiter).filter(Boolean)

function isFile(p: string) {
  try {
    return statSync(p).isFile()
  } catch {
    return false
  }
}

function canWrite(dir: string) {
  try {
    accessSync(dir, constants.W_OK)
    return true
  } catch {
    return false
  }
}

/** Full path of a command on PATH, like `which`. */
function which(name: string): string | undefined {
  const exts = isWin ? ["", ...(process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";")] : [""]
  for (const dir of pathDirs()) {
    for (const ext of exts) {
      const p = join(dir, name + ext)
      if (!isFile(p)) continue
      if (isWin ? ext !== "" : isExecutable(p)) return p
    }
  }
}

function isExecutable(p: string) {
  try {
    accessSync(p, constants.X_OK)
    return true
  } catch {
    return false
  }
}

/** "claude2" -> ~/.claude-2, "claude-work" -> ~/.claude-work, "work" -> ~/.claude-work. */
export function accountDir(kind: Kind, name: string): string | undefined {
  const k = KINDS[kind]
  let suffix = name.toLowerCase().startsWith(k.command) ? name.slice(k.command.length) : name
  suffix = suffix.replace(/^[-_]+/, "")
  return suffix ? join(homedir(), `${k.prefix}-${suffix}`) : undefined
}

/** Why a command name can't be used, or undefined when it can. */
export function problem(kind: Kind, name: string): string | undefined {
  const k = KINDS[kind]
  if (!name) return "Type a name."
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name)) return "Use only letters, digits, - and _."
  const dir = accountDir(kind, name)
  if (!dir) return `Pick a name other than ${k.command}.`
  if (which(name)) return `A command named ${name} already exists.`
  if (existsSync(dir)) return `The folder ${dir} already exists.`
}

export function suggestion(kind: Kind): string {
  let n = 2
  while (problem(kind, `${KINDS[kind].command}${n}`)) n++
  return `${KINDS[kind].command}${n}`
}

/** Where the new command goes: next to the real one on Windows, ~/.local/bin (when on PATH) elsewhere. */
function shimDir(real: string): string {
  if (isWin) return dirname(real)
  const local = join(homedir(), ".local", "bin")
  if (pathDirs().includes(local)) return local
  return canWrite(dirname(real)) ? dirname(real) : local
}

function writeShim(kind: Kind, file: string, dir: string) {
  const k = KINDS[kind]
  mkdirSync(dirname(file), { recursive: true })
  if (isWin) {
    // "call" matters when the real command is itself a .cmd (npm's codex.cmd): without it, its endlocal drops the variable.
    writeFileSync(file, `@echo off\r\nsetlocal\r\nset "${k.envVar}=${dir}"\r\ncall ${k.command} %*\r\n`)
  } else {
    const q = `'${dir.replace(/'/g, `'\\''`)}'`
    writeFileSync(file, `#!/bin/sh\n${k.envVar}=${q} exec ${k.command} "$@"\n`)
    chmodSync(file, 0o755)
  }
}

function run(file: string, args: readonly string[]): Promise<number> {
  return new Promise((resolve) => {
    // The child handles Ctrl+C itself; this process must survive it to clean up.
    const ignore = () => {}
    process.on("SIGINT", ignore)
    const child = isWin
      ? spawn(`"${file}"`, args as string[], { stdio: "inherit", shell: true })
      : spawn(file, args as string[], { stdio: "inherit" })
    child.on("error", () => resolve(1))
    child.on("exit", (code) => {
      process.off("SIGINT", ignore)
      resolve(code ?? 1)
    })
  })
}

async function main() {
  const [kindArg, nameArg] = process.argv.slice(2)
  if (kindArg !== "claude" && kindArg !== "codex") {
    console.error("Usage: npm run add-account -- <claude|codex> [command-name]")
    return 2
  }
  const kind: Kind = kindArg
  const k = KINDS[kind]
  const real = which(k.command)
  if (!real) {
    console.error(`${k.command} was not found on PATH. Install ${k.name} first.`)
    return 1
  }

  let name = nameArg?.trim()
  if (!name) {
    const def = suggestion(kind)
    const rl = createInterface({ input: process.stdin, output: process.stdout })
    name = (await rl.question(`Command to open this ${k.name} account [${def}]: `)).trim() || def
    rl.close()
  }
  const err = problem(kind, name)
  if (err) {
    console.error(err)
    return 1
  }

  const dir = accountDir(kind, name)!
  const shim = join(shimDir(real), isWin ? `${name}.cmd` : name)
  mkdirSync(dir, { recursive: true })
  writeShim(kind, shim, dir)
  const undo = () => {
    rmSync(dir, { recursive: true, force: true })
    rmSync(shim, { force: true })
  }

  console.log(`\n\x1b[33m${k.hint}\x1b[0m\n`)
  await run(shim, k.login)

  const provider = PROVIDERS[kind]
  const [added, primary] = await Promise.all([
    provider.account?.(dir).catch(() => undefined),
    provider.account?.().catch(() => undefined),
  ])
  if (!added) {
    undo()
    console.error(`\nNothing was signed in, so ${name} was not added.`)
    return 1
  }
  if (primary && added.toLowerCase() === primary.toLowerCase()) {
    undo()
    console.error(
      `\n${added} is already your main ${k.name} account, so ${name} was not added.` +
        `\nSign out of it in the browser (or use a private window) and try again.`,
    )
    return 1
  }
  console.log(`\n\x1b[32m${added} added.\x1b[0m Open it with: ${name}`)
  if (!pathDirs().includes(dirname(shim))) console.log(`Add ${dirname(shim)} to your PATH to use ${name}.`)
  return 0
}

process.exitCode = await main()
