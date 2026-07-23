// Pi companion server: JSON API over Pi's session files (~/.pi/agent/sessions)
// plus turn-running via `pi --mode rpc`. Everything it touches is documented
// Pi surface (session JSONL v3, RPC protocol) — no undocumented internals.
// Run: bun run server.ts   (prints the auth token to give the phone app)
import { homedir } from "os";
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, statSync, renameSync } from "fs";
import { resolve, basename, dirname } from "path";

const SESSIONS_ROOT = `${homedir()}/.pi/agent/sessions`;
const PORT = Number(process.env.PORT ?? 8940);
// LaunchAgents get a tiny PATH — resolve `pi` explicitly so model listing and
// RPC turns work even when ~/.local/bin isn't on it.
const PI = [
  `${homedir()}/.local/bin/pi`,
  "/opt/homebrew/bin/pi",
  "/usr/local/bin/pi",
].find((p) => existsSync(p)) ?? "pi";

// Persistent bearer token — server can expose chat history, so auth is required.
const tokenDir = `${homedir()}/.pi-companion`;
const tokenPath = `${tokenDir}/token`;
if (!existsSync(tokenPath)) {
  mkdirSync(tokenDir, { recursive: true });
  writeFileSync(tokenPath, crypto.randomUUID(), { mode: 0o600 });
}
const TOKEN = readFileSync(tokenPath, "utf8").trim();

// Extra project cwds with no Pi sessions yet (e.g. fresh worktrees made from
// the phone). Pi discovers projects implicitly by running in a folder; this
// file covers the ones the phone created before their first session.
const projectsPath = `${tokenDir}/projects.json`;
// Entries are {path, added, name?} (older versions stored bare path strings).
// `name` is the phone-facing workspace label (e.g. city) when we create a worktree.
type ProjectEntry = { path: string; added: number; name?: string };
const projectEntries = (): ProjectEntry[] => {
  try {
    return JSON.parse(readFileSync(projectsPath, "utf8")).map((e: any) =>
      typeof e === "string" ? { path: e, added: 0 } : e);
  } catch { return []; }
};
const extraCwds = () => projectEntries().map((e) => e.path);
const addedAt = (cwd: string) => projectEntries().find((e) => e.path === cwd)?.added ?? 0;
const storedName = (cwd: string) => projectEntries().find((e) => e.path === cwd)?.name;
const rememberCwd = (cwd: string, name?: string) => {
  const list = projectEntries();
  const i = list.findIndex((e) => e.path === cwd);
  if (i >= 0) {
    if (name && !list[i].name) list[i] = { ...list[i], name };
    else return;
  } else {
    list.push({ path: cwd, added: Date.now(), ...(name ? { name } : {}) });
  }
  writeFileSync(projectsPath, JSON.stringify(list, null, 2));
};
const forgetCwd = (cwd: string) => {
  writeFileSync(projectsPath, JSON.stringify(projectEntries().filter((e) => e.path !== cwd), null, 2));
};

const git = (cwd: string, ...a: string[]) => {
  const p = Bun.spawnSync(["git", ...a], { cwd, stdout: "pipe", stderr: "pipe" });
  return p.exitCode === 0 ? p.stdout.toString().trim() : null;
};

// ── Project/workspace scan ──────────────────────────────────────────────────
// Pi groups sessions by cwd: one directory per project path under
// SESSIONS_ROOT, named "--<cwd with / → ->--" (lossy — real cwd comes from the
// header line inside each session file). We map onto the phone's existing
// three-level navigation: repo = the git repo's main checkout, workspace = a
// cwd inside that repo (main checkout or any worktree), session = a jsonl file.
//
// Projects are opt-in: only folders the user added from the phone (plus
// worktrees created from the phone) appear — Pi's session dir also collects
// runs from other tools built on Pi (emdash etc.) and scratch folders, which
// would drown the list. Sessions for an added folder are picked up automatically.
const encodeCwd = (cwd: string) => `-${cwd.replaceAll("/", "-")}--`;

type Ws = { cwd: string; dir: string | null; mtime: number; sessionCount: number };
type Scan = { workspaces: Map<string, Ws>; repoOf: Map<string, string>; repoRoots: Map<string, string> };

function scan(): Scan {
  const workspaces = new Map<string, Ws>(); // workspace id (encoded cwd) → info
  const repoOf = new Map<string, string>(); // workspace id → repo id
  const repoRoots = new Map<string, string>(); // repo id → root path
  const cwds = new Map<string, { dir: string | null; mtime: number; sessionCount: number }>();

  const wanted = new Set(extraCwds().filter((c) => existsSync(c)));
  let dirs: string[] = [];
  try { dirs = readdirSync(SESSIONS_ROOT); } catch {}
  for (const dir of dirs) {
    const full = `${SESSIONS_ROOT}/${dir}`;
    let files: string[];
    try { files = readdirSync(full).filter((f) => f.endsWith(".jsonl")); } catch { continue; }
    if (!files.length) continue;
    files.sort();
    const newest = files[files.length - 1];
    let cwd: string;
    try {
      const header = JSON.parse(readFileSync(`${full}/${newest}`, "utf8").split("\n", 1)[0]);
      cwd = header.cwd;
    } catch { continue; }
    if (!wanted.has(cwd)) continue; // not a folder the user added
    cwds.set(cwd, { dir: full, mtime: statSync(`${full}/${newest}`).mtimeMs, sessionCount: files.length });
  }
  // No sessions yet → "last activity" is the moment the user added the folder.
  for (const cwd of wanted)
    if (!cwds.has(cwd)) cwds.set(cwd, { dir: null, mtime: addedAt(cwd) || Date.now(), sessionCount: 0 });

  for (const [cwd, info] of cwds) {
    // Group worktrees with their main checkout: --git-common-dir points at the
    // primary .git for every worktree of a repo. Non-git folders stand alone.
    const common = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir");
    const root = common ? dirname(common) : cwd;
    const wsId = encodeCwd(cwd);
    const repoId = encodeCwd(root);
    workspaces.set(wsId, { cwd, ...info });
    repoOf.set(wsId, repoId);
    if (!repoRoots.has(repoId)) repoRoots.set(repoId, root);
  }
  return { workspaces, repoOf, repoRoots };
}

// Scan shells out to git per project, so cache briefly; phone navigation
// re-fetches often. ponytail: 15s TTL, event-driven invalidation if it lags.
let scanCache: { at: number; data: Scan } | null = null;
const scanned = () => {
  if (!scanCache || Date.now() - scanCache.at > 15_000) scanCache = { at: Date.now(), data: scan() };
  return scanCache.data;
};
const wsById = (id: string) => scanned().workspaces.get(id);

// ── Session files ───────────────────────────────────────────────────────────
type Entry = any; // Pi session JSONL v3 entries
const readEntries = (file: string): Entry[] =>
  readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);

// Sessions form a tree via id/parentId; the live conversation is the path
// from the last-written entry back to the root.
function activeBranch(entries: Entry[]): Entry[] {
  const byId = new Map(entries.filter((e) => e.id).map((e) => [e.id, e]));
  const branch: Entry[] = [];
  let cur = entries[entries.length - 1];
  while (cur) {
    branch.push(cur);
    cur = cur.parentId ? byId.get(cur.parentId) : null;
  }
  return branch.reverse();
}

const sessionFiles = (dir: string) =>
  readdirSync(dir).filter((f) => f.endsWith(".jsonl")).sort().reverse(); // newest first (timestamp prefix)

const sessionIdOf = (file: string) => basename(file).replace(".jsonl", "").split("_")[1] ?? basename(file);

// Find a session file by uuid across all project dirs.
function findSessionFile(sessionId: string): { file: string; cwd: string } | null {
  let dirs: string[] = [];
  try { dirs = readdirSync(SESSIONS_ROOT); } catch {}
  for (const dir of dirs) {
    const full = `${SESSIONS_ROOT}/${dir}`;
    let files: string[] = [];
    try { files = readdirSync(full); } catch { continue; }
    const hit = files.find((f) => f.endsWith(`_${sessionId}.jsonl`));
    if (hit) {
      try {
        const header = JSON.parse(readFileSync(`${full}/${hit}`, "utf8").split("\n", 1)[0]);
        return { file: `${full}/${hit}`, cwd: header.cwd };
      } catch {}
    }
  }
  return null;
}

const textOf = (msg: any) =>
  (msg?.content ?? [])
    .filter((b: any) => b.type === "text")
    .map((b: any) => b.text)
    .join("")
    .trim();

const userImageBlocks = (msg: any) =>
  (msg?.content ?? []).filter((b: any) =>
    b?.type === "image" || b?.type === "image_url" || b?.type === "input_image"
    || (typeof b?.mimeType === "string" && String(b.mimeType).startsWith("image/")));

const userImageCount = (msg: any) => userImageBlocks(msg).length;
const userHasImages = (msg: any) => userImageCount(msg) > 0;

function sessionSummary(file: string, workspaceId: string) {
  const entries = readEntries(file);
  let title = "Untitled";
  let model: string | null = null;
  for (const e of entries) {
    if (title === "Untitled" && e.type === "message" && e.message?.role === "user") {
      const t = textOf(e.message);
      if (t) title = t.slice(0, 80);
    }
    if (e.type === "model_change") model = `${e.provider}/${e.modelId}`;
  }
  return {
    id: sessionIdOf(file),
    workspace_id: workspaceId,
    title,
    model,
    agent_type: "pi",
    updated_at: new Date(statSync(file).mtimeMs).toISOString(),
  };
}

// ── Display messages ────────────────────────────────────────────────────────
// Same row shapes the phone already renders: user / assistant / thinking /
// tool / duration rows in chronological order.
const summarizeInput = (input: any) => {
  const v = input?.file_path ?? input?.path ?? input?.command ?? input?.pattern ?? input?.description ?? "";
  return String(v).slice(0, 80);
};

function displayMessages(sessionId: string) {
  const found = findSessionFile(sessionId);
  if (!found) return { error: "session not found", status: 404 };
  const out: { id: string; role: string; content: string; created_at: string }[] = [];
  let turnStart: number | null = null;
  for (const e of activeBranch(readEntries(found.file))) {
    if (e.type !== "message") continue;
    const msg = e.message;
    const createdAt = e.timestamp;
    if (msg.role === "user") {
      turnStart = new Date(e.timestamp).getTime();
      const t = textOf(msg);
      if (t) {
        out.push({ id: e.id, role: "user", content: t, created_at: createdAt });
      } else if (userHasImages(msg)) {
        // Image-only prompts have no text; still surface a row so the phone
        // can pin the turn and show something in history.
        const n = userImageCount(msg);
        out.push({
          id: e.id,
          role: "user",
          content: n === 1 ? "Photo" : `${n} Photos`,
          created_at: createdAt,
        });
      }
    } else if (msg.role === "assistant") {
      for (const [i, b] of (msg.content ?? []).entries()) {
        if (b.type === "text" && b.text?.trim())
          out.push({ id: `${e.id}-${i}`, role: "assistant", content: b.text, created_at: createdAt });
        else if (b.type === "thinking" && b.thinking?.trim())
          out.push({ id: `${e.id}-${i}`, role: "thinking", content: b.thinking, created_at: createdAt });
        else if (b.type === "toolCall")
          out.push({ id: `${e.id}-${i}`, role: "tool", content: `${b.name} ${summarizeInput(b.arguments)}`, created_at: createdAt });
      }
      if (msg.stopReason === "error" && msg.errorMessage)
        out.push({ id: `${e.id}-err`, role: "assistant", content: `⚠️ ${String(msg.errorMessage).slice(0, 300)}`, created_at: createdAt });
      if (msg.stopReason === "stop" && turnStart) {
        const s = Math.round((new Date(e.timestamp).getTime() - turnStart) / 1000);
        if (s >= 5) out.push({ id: `${e.id}-dur`, role: "duration", content: s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`, created_at: createdAt });
        turnStart = null;
      }
    }
    // toolResult rows are skipped — the tool row already shows the call.
  }
  return out;
}

// ── Models ──────────────────────────────────────────────────────────────────
// Prefer Pi RPC `get_available_models` so we can expose each model's real
// thinking-level set (same rules as Pi's getSupportedThinkingLevels). Falls
// back to `pi --list-models` if RPC isn't available.
type ModelInfo = { id: string; thinking: boolean; images: boolean; thinkingLevels: string[] };
let modelCache: { title: string; models: ModelInfo[] }[] = [];

const EXTENDED_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
function supportedThinkingLevels(model: { reasoning?: boolean; thinkingLevelMap?: Record<string, string | null> }) {
  if (!model.reasoning) return [] as string[]; // no thinking control in the phone UI
  return EXTENDED_THINKING_LEVELS.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}

function refreshModelsFromList() {
  const p = Bun.spawnSync([PI, "--list-models"], { stdout: "pipe", stderr: "pipe" });
  if (p.exitCode !== 0) return false;
  const groups = new Map<string, ModelInfo[]>();
  for (const line of p.stdout.toString().split("\n").slice(1)) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 4) continue;
    const [provider, modelId] = parts;
    if (!provider || !modelId || provider === "provider") continue;
    const images = parts[parts.length - 1] === "yes";
    const reasoning = parts[parts.length - 2] === "yes";
    // Coarse yes/no only — without a level map don't invent controls.
    const thinkingLevels = reasoning ? ["off", "minimal", "low", "medium", "high"] : [];
    const list = groups.get(provider) ?? [];
    list.push({
      id: `${provider}/${modelId}`,
      thinking: thinkingLevels.length > 0,
      images,
      thinkingLevels,
    });
    groups.set(provider, list);
  }
  if (!groups.size) return false;
  modelCache = [...groups].map(([title, models]) => ({ title, models }));
  return true;
}

async function refreshModelsFromRpc() {
  // Keep stdin open until the response arrives (closing early makes pi exit
  // before answering). Ignore fire-and-forget extension_ui_request noise.
  const proc = Bun.spawn([PI, "--mode", "rpc", "--no-session"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  proc.stdin.write(JSON.stringify({ id: "models", type: "get_available_models" }) + "\n");
  proc.stdin.flush();

  const dec = new TextDecoder();
  let buf = "";
  const apply = (models: any[]) => {
    const groups = new Map<string, ModelInfo[]>();
    for (const m of models) {
      const provider = m.provider ?? "unknown";
      const thinkingLevels = supportedThinkingLevels(m);
      const list = groups.get(provider) ?? [];
      list.push({
        id: `${provider}/${m.id}`,
        thinking: thinkingLevels.length > 0,
        images: Array.isArray(m.input) && m.input.includes("image"),
        thinkingLevels,
      });
      groups.set(provider, list);
    }
    if (!groups.size) return false;
    modelCache = [...groups].map(([title, ms]) => ({ title, models: ms }));
    return true;
  };

  try {
    const result = await Promise.race([
      (async () => {
        for await (const chunk of proc.stdout as AsyncIterable<Uint8Array>) {
          buf += dec.decode(chunk, { stream: true });
          const lines = buf.split("\n");
          buf = lines.pop()!;
          for (const line of lines) {
            if (!line.trim()) continue;
            let ev: any;
            try { ev = JSON.parse(line); } catch { continue; }
            if (ev.type === "response" && ev.command === "get_available_models" && ev.success) {
              return apply(ev.data?.models ?? []);
            }
          }
        }
        return false;
      })(),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 15_000)),
    ]);
    return result;
  } finally {
    try { proc.stdin.end(); } catch {}
    proc.kill();
  }
}

async function refreshModels() {
  try {
    if (await refreshModelsFromRpc()) return;
    refreshModelsFromList();
  } catch {
    try { refreshModelsFromList(); } catch {
      // pi missing from PATH — keep whatever cache we have; phone falls back to static list
    }
  }
}
await refreshModels();
setInterval(() => { void refreshModels(); }, 10 * 60_000);

// Bundled Ask-mode gate (also installable via POST /approval-extension/install).
const approvalExt = resolve(import.meta.dir, "pi-mobile-approval/extension.ts");
const approvalPkg = resolve(import.meta.dir, "pi-mobile-approval");
const approvalInstalled = () => {
  try {
    const settings = JSON.parse(readFileSync(`${homedir()}/.pi/agent/settings.json`, "utf8"));
    const pkgs: string[] = settings.packages ?? [];
    return pkgs.some((p) => p.includes("pi-mobile-approval") || resolve(p) === approvalExt || resolve(p) === approvalPkg);
  } catch { return false; }
};

// ── Pi version ──────────────────────────────────────────────────────────────
// Same contract Pi's own CLI uses (`pi.dev/api/latest-version`). Surfaces an
// "run pi update" hint to the phone when the Mac's install is behind.
type PiVersionInfo = {
  current: string | null;
  latest: string | null;
  update_available: boolean;
  update_command: string;
};
let piVersionCache: PiVersionInfo = {
  current: null, latest: null, update_available: false, update_command: "pi update",
};

function parseSemver(v: string): [number, number, number] | null {
  const m = v.trim().match(/^v?(\d+)\.(\d+)\.(\d+)/);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function isOlder(current: string, latest: string): boolean {
  const a = parseSemver(current);
  const b = parseSemver(latest);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i++) {
    if (a[i]! < b[i]!) return true;
    if (a[i]! > b[i]!) return false;
  }
  return false;
}

async function refreshPiVersion() {
  const p = Bun.spawnSync(["pi", "--version"], { stdout: "pipe", stderr: "pipe" });
  const raw = p.exitCode === 0
    ? (p.stdout.toString().trim() || p.stderr.toString().trim())
    : "";
  const current = raw.match(/v?(\d+\.\d+\.\d+)/)?.[1] ?? null;

  let latest: string | null = null;
  try {
    const res = await fetch("https://pi.dev/api/latest-version", {
      headers: { "User-Agent": `pi-companion/${current ?? "unknown"}` },
    });
    if (res.ok) {
      const data = (await res.json()) as { version?: string };
      if (data.version) latest = data.version.replace(/^v/, "");
    }
  } catch { /* offline / API down — leave latest null */ }

  piVersionCache = {
    current,
    latest,
    update_available: !!(current && latest && isOlder(current, latest)),
    update_command: "pi update",
  };
}
refreshPiVersion();
setInterval(refreshPiVersion, 10 * 60_000);

// ── Creating workspaces & sessions ──────────────────────────────────────────
// A session id minted here materializes on disk on first send (pi --session-id
// creates it if missing). Until then remember which cwd it belongs to.
const pendingSessions = new Map<string, string>(); // session id → cwd  (ponytail: in-memory; re-create from the phone if the server restarts)

function createSession(workspaceId: string) {
  const ws = wsById(workspaceId);
  if (!ws) return { error: "workspace not found", status: 404 };
  const id = crypto.randomUUID();
  pendingSessions.set(id, ws.cwd);
  return { id, workspace_id: workspaceId, title: "Untitled", model: null, agent_type: "pi",
           updated_at: new Date().toISOString() };
}

// City/town labels — same idea as Conductor desktop workspaces. Folder + branch
// stay lowercase; the phone-facing `name` is title-cased.
const CITIES = [
  "lisbon","porto","quito","nairobi","hanoi","tbilisi","perth","leipzig","malmo","bergen",
  "cusco","davao","hobart","tampere","galway","split","ankara","doha","manila","seville",
  "maputo","bissau","montreal","stockholm","denver","victoria","baku","oslo","kyoto","riga",
];
const titleCase = (s: string) => s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
const workspaceLabel = (cwd: string) => {
  const stored = storedName(cwd);
  if (stored) return stored;
  const base = basename(cwd);
  // Phone-created worktrees live under ~/pi-workspaces/<repo>/<city>
  if (cwd.startsWith(`${homedir()}/pi-workspaces/`)) return titleCase(base);
  return base; // main checkout / user-added folders keep their folder name
};

function createWorkspace(repoId: string) {
  const root = scanned().repoRoots.get(repoId);
  if (!root || !existsSync(root)) return { error: "repo not found", status: 404 };
  if (!git(root, "rev-parse", "--git-dir")) return { error: "not a git repo", status: 400 };
  const repoName = basename(root);
  const base = `${homedir()}/pi-workspaces/${repoName}`;
  const unused = CITIES.filter((c) => !existsSync(`${base}/${c}`));
  const city = unused.length ? unused[Math.floor(Math.random() * unused.length)] : `mobile-${Date.now()}`;
  const label = titleCase(city);
  const path = `${base}/${city}`;
  const branch = `mobile/${city}`;
  mkdirSync(base, { recursive: true });
  const wt = Bun.spawnSync(["git", "worktree", "add", "-b", branch, path], { cwd: root, stdout: "pipe", stderr: "pipe" });
  if (wt.exitCode !== 0)
    return { error: `git worktree failed: ${wt.stderr.toString().trim()}`, status: 500 };
  rememberCwd(path, label);
  scanCache = null;
  const id = encodeCwd(path);
  return { id, repository_id: repoId, name: label, branch, status: "done", unread: false,
           updated_at: new Date().toISOString(), last_message_snippet: null, session: createSession(id) };
}

// ── Running turns via Pi RPC ────────────────────────────────────────────────
type PendingUI = {
  id: string;
  method: string;
  title?: string;
  message?: string;
  options?: string[];
};
type PromptImage = { data: string; mimeType: string };
type Turn = {
  proc: ReturnType<typeof Bun.spawn> | null;
  running: boolean;
  activity: string;
  cwd: string;
  pendingUI: PendingUI | null;
};
const turns = new Map<string, Turn>();

function sendMessage(
  sessionId: string,
  text: string,
  opts: { model?: string; thinking?: string; approvalMode?: string; images?: PromptImage[] } = {},
) {
  const existing = turns.get(sessionId);
  if (existing?.running) return { error: "agent is already working", status: 409 };

  const found = findSessionFile(sessionId);
  const cwd = found?.cwd ?? pendingSessions.get(sessionId);
  if (!cwd) return { error: "session not found", status: 404 };
  if (!existsSync(cwd)) return { error: "workspace directory not found on this Mac", status: 400 };

  const approvalMode = (opts.approvalMode ?? "auto").toLowerCase() === "ask" ? "ask" : "auto";
  const args = [PI, "--mode", "rpc"];
  if (found) args.push("--session", found.file);
  else args.push("--session-id", sessionId);
  if (opts.model) args.push("--model", opts.model);
  if (opts.thinking) args.push("--thinking", opts.thinking);
  // Ask must fail closed — never start a turn that looks like Ask without the gate.
  if (approvalMode === "ask") {
    if (!existsSync(approvalExt)) {
      return { error: "Ask mode requires the bundled approval extension (re-run server/install.sh)", status: 500 };
    }
    args.push("-e", approvalExt);
  }

  // Leave activity empty so the phone shows its "Working…" placeholder until
  // the first real Pi event (Thinking… / tool name) arrives.
  const turn: Turn = { proc: null, running: true, activity: "", cwd, pendingUI: null };
  turns.set(sessionId, turn);
  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn(args, {
      cwd,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, PI_MOBILE_APPROVAL_MODE: approvalMode },
    });
  } catch (e) {
    turns.delete(sessionId);
    return { error: `failed to start pi: ${String(e)}`, status: 500 };
  }
  turn.proc = proc;
  const images = (opts.images ?? [])
    .filter((img) => img?.data && img?.mimeType)
    .map((img) => ({ type: "image" as const, data: img.data, mimeType: img.mimeType }));
  try {
    proc.stdin.write(JSON.stringify({
      id: "1",
      type: "prompt",
      message: text,
      ...(images.length ? { images } : {}),
    }) + "\n");
    proc.stdin.flush();
  } catch (e) {
    try { proc.kill(); } catch {}
    turns.delete(sessionId);
    return { error: `failed to send prompt: ${String(e)}`, status: 500 };
  }

  // Mark the turn done immediately — don't wait for stdout EOF, which never
  // comes if a tool left a background child holding the pipe open.
  const finish = () => {
    pendingSessions.delete(sessionId); // it's on disk now
    turn.running = false;
    turn.activity = "";
    turn.pendingUI = null;
  };

  // Drain stderr so pi can't block on a full pipe and never emit agent_end.
  (async () => { for await (const _ of proc.stderr as any) {} })();

  (async () => {
    let buf = "";
    for await (const chunk of proc.stdout as any) {
      buf += new TextDecoder().decode(chunk);
      const lines = buf.split("\n");
      buf = lines.pop()!;
      for (const line of lines) {
        if (!line.trim()) continue;
        let ev: any;
        try { ev = JSON.parse(line); } catch { continue; }
        if (ev.type === "extension_ui_request" && (ev.method === "confirm" || ev.method === "select")) {
          turn.pendingUI = {
            id: ev.id,
            method: ev.method,
            title: ev.title,
            message: ev.message,
            options: ev.options,
          };
          turn.activity = ev.title ?? "Waiting for approval…";
        } else if (ev.type === "extension_ui_request" && ev.id) {
          // Unknown UI method the phone can't render — cancel it so pi doesn't
          // block forever waiting for a response that will never come.
          try {
            proc.stdin.write(JSON.stringify({ type: "extension_ui_response", id: ev.id, cancelled: true }) + "\n");
            proc.stdin.flush();
          } catch {}
        } else if (ev.type === "tool_execution_start") {
          turn.pendingUI = null;
          turn.activity = `${ev.toolName ?? "tool"} ${summarizeInput(ev.args)}`;
        } else if (ev.type === "message_start" && ev.message?.role === "assistant")
          turn.activity = "Thinking…";
        else if (ev.type === "response" && ev.success === false)
          turn.activity = `⚠️ ${ev.error ?? "command failed"}`;
        else if (ev.type === "agent_end") {
          finish();
          try { proc.stdin.end(); } catch {}
          proc.kill(); // pi stays resident waiting for more commands; the turn is done
        }
      }
    }
    await proc.exited;
    finish(); // safety net for abnormal exits (crash, kill) with no agent_end
  })();

  return { ok: true };
}

function respondUI(sessionId: string, body: any) {
  const turn = turns.get(sessionId);
  if (!turn?.running || !turn.proc?.stdin) return { error: "no active turn", status: 404 };
  if (!turn.pendingUI || (body.id && body.id !== turn.pendingUI.id))
    return { error: "no pending approval", status: 409 };
  const id = body.id ?? turn.pendingUI.id;
  let payload: Record<string, unknown> = { type: "extension_ui_response", id };
  if (body.cancelled) payload.cancelled = true;
  else if (turn.pendingUI.method === "confirm") payload.confirmed = !!body.confirmed;
  else if (body.value !== undefined) payload.value = body.value;
  else payload.cancelled = true;
  try {
    turn.proc.stdin.write(JSON.stringify(payload) + "\n");
    turn.proc.stdin.flush();
  } catch {
    return { error: "failed to write response", status: 500 };
  }
  turn.pendingUI = null;
  turn.activity = "Continuing…";
  return { ok: true };
}

// ── HTTP API (same shapes the phone already speaks) ─────────────────────────
const repos = () => {
  const { workspaces, repoOf, repoRoots } = scanned();
  return [...repoRoots]
    .map(([id, root]) => ({
      id,
      name: basename(root),
      default_branch: git(root, "symbolic-ref", "--short", "HEAD") ?? "main",
      active_workspace_count: [...repoOf.values()].filter((r) => r === id).length,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
};

const workspacesOf = (repoId: string) => {
  const { workspaces, repoOf } = scanned();
  return [...workspaces]
    .filter(([id]) => repoOf.get(id) === repoId)
    .map(([id, ws]) => {
      const newest = ws.dir ? sessionFiles(ws.dir)[0] : null;
      return {
        id,
        repository_id: repoId,
        name: workspaceLabel(ws.cwd),
        branch: git(ws.cwd, "branch", "--show-current"),
        status: [...turns.values()].some((t) => t.running && t.cwd === ws.cwd) ? "in-progress" : "done",
        unread: false,
        updated_at: new Date(ws.mtime).toISOString(),
        last_message_snippet: newest ? sessionSummary(`${ws.dir}/${newest}`, id).title : null,
      };
    })
    .sort((a, b) => (a.updated_at < b.updated_at ? 1 : -1));
};

const sessionsOf = (workspaceId: string) => {
  const ws = wsById(workspaceId);
  if (!ws?.dir) return [];
  return sessionFiles(ws.dir).map((f) => sessionSummary(`${ws.dir}/${f}`, workspaceId));
};

async function workspaceDiff(workspaceId: string) {
  const ws = wsById(workspaceId);
  if (!ws || !existsSync(ws.cwd)) return { error: "workspace not found", status: 404 };
  const g = (...a: string[]) =>
    new Response(Bun.spawn(["git", ...a], { cwd: ws.cwd, stdout: "pipe" }).stdout as any).text();
  const base = git(ws.cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")?.replace(/^origin\//, "") ?? "main";
  const mergeBase = (await g("merge-base", base, "HEAD").catch(() => "")).trim();
  const ref = mergeBase || base;
  const [stat, diff] = await Promise.all([g("diff", "--stat", ref), g("diff", ref)]);
  return { base, stat, diff };
}

Bun.serve({
  port: PORT,
  hostname: "0.0.0.0",
  async fetch(req) {
    if (req.headers.get("authorization") !== `Bearer ${TOKEN}`)
      return Response.json({ error: "unauthorized" }, { status: 401 });

    const path = new URL(req.url).pathname;
    let m: RegExpMatchArray | null;
    try {
      if (req.method === "POST" && (m = path.match(/^\/sessions\/([^/]+)\/send$/))) {
        const { text, model, thinking, approvalMode, images } = await req.json();
        const hasImages = Array.isArray(images) && images.length > 0;
        if (!text?.trim() && !hasImages) return Response.json({ error: "empty message" }, { status: 400 });
        const r = sendMessage(m[1], (text ?? "").trim(), { model, thinking, approvalMode, images });
        return Response.json(r, { status: "status" in r ? (r.status as number) : 200 });
      }
      if (req.method === "POST" && (m = path.match(/^\/sessions\/([^/]+)\/ui-response$/))) {
        const r = respondUI(m[1], await req.json());
        return Response.json(r, { status: "status" in r ? (r.status as number) : 200 });
      }
      if (path === "/approval-extension") {
        return Response.json({ installed: approvalInstalled(), path: approvalPkg });
      }
      if (req.method === "POST" && path === "/approval-extension/install") {
        if (!existsSync(approvalPkg))
          return Response.json({ error: "bundled approval package missing" }, { status: 500 });
        const p = Bun.spawnSync([PI, "install", approvalPkg], { stdout: "pipe", stderr: "pipe" });
        if (p.exitCode !== 0)
          return Response.json({
            error: p.stderr.toString().trim() || p.stdout.toString().trim() || "install failed",
          }, { status: 500 });
        return Response.json({ ok: true, installed: true });
      }
      // Deleting a chat moves its session file to ~/.pi-companion/trash (recoverable).
      if (req.method === "DELETE" && (m = path.match(/^\/sessions\/([^/]+)$/))) {
        const found = findSessionFile(m[1]);
        if (!found) return Response.json({ error: "session not found" }, { status: 404 });
        const trash = `${tokenDir}/trash`;
        mkdirSync(trash, { recursive: true });
        renameSync(found.file, `${trash}/${basename(found.file)}`);
        scanCache = null;
        return Response.json({ ok: true });
      }
      // "Deleting" a workspace unregisters the folder from the app; nothing on
      // disk is touched (worktrees and session files stay).
      if (req.method === "DELETE" && (m = path.match(/^\/workspaces\/([^/]+)$/))) {
        const ws = wsById(m[1]);
        if (!ws) return Response.json({ error: "workspace not found" }, { status: 404 });
        forgetCwd(ws.cwd);
        scanCache = null;
        return Response.json({ ok: true });
      }
      if (req.method === "POST" && (m = path.match(/^\/sessions\/([^/]+)\/stop$/))) {
        const t = turns.get(m[1]);
        try { t?.proc?.stdin?.write(JSON.stringify({ id: "stop", type: "abort" }) + "\n"); } catch {}
        t?.proc?.kill();
        return Response.json({ ok: true });
      }
      if ((m = path.match(/^\/sessions\/([^/]+)\/attachments$/))) {
        const rel = new URL(req.url).searchParams.get("path") ?? "";
        const found = findSessionFile(m[1]);
        if (!found) return Response.json({ error: "not found" }, { status: 404 });
        const full = resolve(found.cwd, decodeURIComponent(rel));
        if (!full.startsWith(resolve(found.cwd) + "/"))
          return Response.json({ error: "forbidden" }, { status: 403 });
        if (!existsSync(full)) return Response.json({ error: "not found" }, { status: 404 });
        return new Response(Bun.file(full));
      }
      // Browse folders on the Mac for the phone's project picker.
      if (path === "/browse") {
        const q = new URL(req.url).searchParams.get("path") || homedir();
        const dir = resolve(q.startsWith("~/") ? `${homedir()}/${q.slice(2)}` : q);
        if (!existsSync(dir) || !statSync(dir).isDirectory())
          return Response.json({ error: "not a folder" }, { status: 404 });
        const dirs = readdirSync(dir)
          .filter((n) => !n.startsWith(".") && n !== "node_modules")
          .filter((n) => { try { return statSync(`${dir}/${n}`).isDirectory(); } catch { return false; } })
          .sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
        return Response.json({ path: dir, parent: dir === "/" ? null : dirname(dir), dirs });
      }
      // Register a project folder that has no Pi sessions yet.
      if (req.method === "POST" && path === "/projects") {
        const { path: dir } = await req.json();
        const full = dir?.startsWith("~/") ? `${homedir()}/${dir.slice(2)}` : dir;
        if (!full || !existsSync(full) || !statSync(full).isDirectory())
          return Response.json({ error: "folder not found on this Mac" }, { status: 404 });
        rememberCwd(resolve(full));
        scanCache = null;
        return Response.json({ ok: true });
      }
      if (req.method === "POST" && (m = path.match(/^\/repos\/([^/]+)\/workspaces$/))) {
        const r = createWorkspace(m[1]);
        return "error" in r ? Response.json({ error: r.error }, { status: r.status }) : Response.json(r);
      }
      if (req.method === "POST" && (m = path.match(/^\/workspaces\/([^/]+)\/sessions$/))) {
        const r = createSession(m[1]);
        return Response.json(r, { status: "status" in r ? (r.status as number) : 200 });
      }
      if ((m = path.match(/^\/workspaces\/([^/]+)\/diffstat$/))) {
        const ws = wsById(m[1]);
        if (!ws) return Response.json({ error: "not found" }, { status: 404 });
        const short = git(ws.cwd, "diff", "--shortstat", "HEAD") ?? "";
        return Response.json({
          insertions: Number(short.match(/(\d+) insertion/)?.[1] ?? 0),
          deletions: Number(short.match(/(\d+) deletion/)?.[1] ?? 0),
        });
      }
      if ((m = path.match(/^\/workspaces\/([^/]+)\/diff$/))) {
        const r = await workspaceDiff(m[1]);
        return Response.json(r, { status: "status" in r ? (r.status as number) : 200 });
      }
      if ((m = path.match(/^\/sessions\/([^/]+)\/status$/))) {
        const t = turns.get(m[1]);
        return Response.json({
          running: !!t?.running,
          activity: t?.activity ?? "",
          pending_ui: t?.pendingUI ?? null,
        });
      }
      if (path === "/models") return Response.json(modelCache);
      if (path === "/pi-version") return Response.json(piVersionCache);
      if (path === "/repos") return Response.json(repos());
      if ((m = path.match(/^\/repos\/([^/]+)\/workspaces$/))) return Response.json(workspacesOf(m[1]));
      if ((m = path.match(/^\/workspaces\/([^/]+)\/sessions$/))) return Response.json(sessionsOf(m[1]));
      if ((m = path.match(/^\/sessions\/([^/]+)\/messages$/))) {
        const r = displayMessages(m[1]);
        return Response.json(r, { status: "status" in r && !Array.isArray(r) ? (r as any).status : 200 });
      }
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 500 });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  },
});

console.log(`Pi companion listening on http://0.0.0.0:${PORT}`);
console.log(`Auth token: ${TOKEN}`);

// Pairing QR: scan with the iPhone Camera app to open the app with the
// address + token pre-filled.
import { hostname } from "os";
import qrcode from "qrcode-terminal"; // bun auto-installs on first run
const host = hostname().replace(/\.local$/, "");
const pairURL =
  `pi-companion://pair?name=${encodeURIComponent(host)}` +
  `&addr=${encodeURIComponent(`http://${host}.local:${PORT}`)}&token=${TOKEN}`;
qrcode.generate(pairURL, { small: true });
console.log(`Scan with the iPhone camera to pair (same network), or enter the token manually.`);
