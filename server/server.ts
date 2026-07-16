// Conductor companion server: read-only JSON API over Conductor's local SQLite db.
// Run: bun run server.ts   (prints the auth token to give the phone app)
import { Database } from "bun:sqlite";
import { homedir } from "os";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { resolve } from "path";

const DB_PATH = `${homedir()}/Library/Application Support/com.conductor.app/conductor.db`;
const PORT = 8940;

// Persistent bearer token — server can expose chat history, so auth is required.
const tokenDir = `${homedir()}/.conductor-companion`;
const tokenPath = `${tokenDir}/token`;
if (!existsSync(tokenPath)) {
  mkdirSync(tokenDir, { recursive: true });
  writeFileSync(tokenPath, crypto.randomUUID(), { mode: 0o600 });
}
const TOKEN = readFileSync(tokenPath, "utf8").trim();

const db = new Database(DB_PATH, { readonly: true });

// ── v2: sending messages ────────────────────────────────────────────────────
// Turns sent from the phone resume the workspace's Claude Code session and are
// written into Conductor's own session_messages in its native envelope format,
// so the desktop app shows them (after a Conductor restart — it reads the db on
// launch) and both apps stay on one conversation branch. Undocumented schema:
// if a Conductor update changes it, these writes fail loud, not silent.
const wdb = new Database(DB_PATH); // separate read-write connection; WAL handles concurrency
const insertMsg = wdb.prepare(
  `INSERT INTO session_messages (id, session_id, role, content, created_at, sent_at, model, turn_id, queue_order, sender_id, sdk_message_id)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`
);
const updateClaudeSessionId = wdb.prepare(`UPDATE sessions SET claude_session_id = ? WHERE id = ?`);

type Turn = { proc: ReturnType<typeof Bun.spawn> | null; running: boolean; activity: string };
const turns = new Map<string, Turn>();

function sendMessage(sessionId: string, text: string, model?: string) {
  const existing = turns.get(sessionId);
  if (existing?.running) return { error: "agent is already working", status: 409 };

  const session: any = db
    .query(`SELECT s.*, w.workspace_path FROM sessions s JOIN workspaces w ON s.workspace_id = w.id WHERE s.id = ?`)
    .get(sessionId);
  if (!session) return { error: "session not found", status: 404 };
  const agent = session.agent_type ?? "claude";
  if (!["claude", "codex", "cursor", "acp"].includes(agent))
    return { error: `unsupported agent type: ${agent}`, status: 400 };
  if (!session.workspace_path || !existsSync(session.workspace_path))
    return { error: "workspace directory not found on this Mac", status: 400 };

  const turn: Turn = { proc: null, running: true, activity: "Starting agent…" };
  turns.set(sessionId, turn);
  const turnId = crypto.randomUUID();
  const senderId: any = db
    .query(`SELECT sender_id FROM session_messages WHERE session_id = ? AND sender_id IS NOT NULL LIMIT 1`)
    .get(sessionId);
  // Mirror Conductor's row shape exactly: user rows carry model + sender; assistant
  // rows carry the stream event's uuid as sdk_message_id and no model.
  const push = (role: string, content: string, sdkId: string | null = null) => {
    const now = new Date().toISOString();
    const id = role === "user" ? turnId : crypto.randomUUID();
    insertMsg.run(id, sessionId, role, content, now, now,
      role === "user" ? session.model : null, turnId,
      role === "user" ? senderId?.sender_id ?? null : null, sdkId);
  };
  push("user", text);

  const resumeId = session.claude_session_id;
  // Conductor normalizes every harness into claude-style envelopes; for non-claude
  // agents we synthesize them from each CLI's own output format.
  const envelope = (blocks: any[]) =>
    JSON.stringify({ type: "assistant", session_id: resumeId, message: { role: "assistant", content: blocks } });
  const pushEnv = (blocks: any[]) => push("assistant", envelope(blocks), crypto.randomUUID());
  const resultEnv = (extra: any = {}) =>
    push("assistant", JSON.stringify({ type: "result", session_id: resumeId, subtype: "finished", is_error: false, ...extra }), crypto.randomUUID());

  let args: string[];
  let handleLine: (line: string) => void;
  let cursorText = ""; // cursor streams text deltas; final text arrives in its result event

  if (agent === "claude") {
    args = ["claude", "-p", text, "--output-format", "stream-json", "--verbose",
            "--permission-mode", "acceptEdits"]; // ponytail: no remote approval UI yet
    if (resumeId) args.push("--resume", resumeId);
    if (model) args.push("--model", model);
    handleLine = (line) => {
      const ev = JSON.parse(line);
      if (ev.type === "assistant") {
        push("assistant", line, ev.uuid ?? null); // claude's output IS the native format
        for (const b of ev.message?.content ?? [])
          if (b.type === "tool_use") turn.activity = `${b.name} ${summarizeInput(b.input)}`;
      } else if (ev.type === "result") {
        push("assistant", line, ev.uuid ?? null);
        if (ev.session_id) updateClaudeSessionId.run(ev.session_id, sessionId);
      }
    };
  } else if (agent === "codex") {
    if (!resumeId) return { error: "codex session has no resume id", status: 400 };
    // Conductor's bundled codex — the nvm-installed one on PATH is broken.
    const codexBin = `${homedir()}/Library/Application Support/com.conductor.app/bin/codex`;
    args = [existsSync(codexBin) ? codexBin : "codex", "exec", "resume", resumeId, "--json", text];
    handleLine = (line) => {
      const ev = JSON.parse(line);
      const item = ev.item;
      if (ev.type === "item.completed" && item) {
        if (item.type === "agent_message" && item.text) pushEnv([{ type: "text", text: item.text }]);
        else if (item.type === "reasoning" && item.text) pushEnv([{ type: "thinking", thinking: item.text }]);
        else if (item.type === "command_execution") {
          turn.activity = item.command ?? "Running command…";
          pushEnv([{ type: "tool_use", id: crypto.randomUUID(), name: "Bash", input: { command: item.command } }]);
        } else if (item.type === "file_change") {
          turn.activity = "Editing files…";
          pushEnv([{ type: "tool_use", id: crypto.randomUUID(), name: "Edit",
                     input: { file_path: item.changes?.map((c: any) => c.path).join(", ") ?? "" } }]);
        }
      } else if (ev.type === "turn.completed") resultEnv({ usage: ev.usage });
      else if (ev.type === "error") pushEnv([{ type: "text", text: `⚠️ ${ev.message}` }]);
    };
  } else if (agent === "cursor") {
    if (!resumeId) return { error: "cursor session has no resume id", status: 400 };
    // --trust: worktrees Conductor creates aren't in cursor's trusted list; same
    // trust the user already granted this repo on the desktop.
    args = ["cursor-agent", "--resume", resumeId, "-p", text, "--output-format", "stream-json", "--trust"];
    if (session.model) args.push("--model", session.model);
    handleLine = (line) => {
      const ev = JSON.parse(line);
      if (ev.type === "assistant")
        for (const b of ev.message?.content ?? []) if (b.type === "text") cursorText += b.text;
      if (ev.type === "tool_call" || ev.type === "tool_use") turn.activity = "Using tools…";
      if (ev.type === "result") {
        const final = ev.result || cursorText;
        if (final) pushEnv([{ type: "text", text: final }]);
        push("assistant", line, crypto.randomUUID());
      }
    };
  } else {
    // acp = opencode. Plain-text output; one assistant envelope at the end.
    if (!resumeId) return { error: "opencode session has no resume id", status: 400 };
    args = ["opencode", "run", "--session", resumeId, text];
    const m = session.model?.replace(/^opencode:/, "");
    if (m) args.push("--model", m);
    handleLine = () => {}; // buffered below instead
  }

  turn.proc = Bun.spawn(args, { cwd: session.workspace_path, stdout: "pipe", stderr: "pipe" });

  (async () => {
    let buf = "";
    let all = "";
    for await (const chunk of turn.proc!.stdout as any) {
      const s = new TextDecoder().decode(chunk);
      all += s;
      buf += s;
      const lines = buf.split("\n");
      buf = lines.pop()!;
      for (const line of lines) {
        if (!line.trim()) continue;
        try { handleLine(line); } catch {}
      }
    }
    const code = await turn.proc!.exited;
    if (agent === "acp" && all.trim()) {
      pushEnv([{ type: "text", text: all.trim() }]);
      resultEnv();
    }
    if (code !== 0) {
      const err = await new Response(turn.proc!.stderr as any).text().catch(() => "");
      pushEnv([{ type: "text", text: `⚠️ ${agent} exited with code ${code}. ${err.slice(0, 300)}` }]);
    }
    turn.running = false;
    turn.activity = "";
  })();

  return { ok: true };
}

// conductor.db stores 'YYYY-MM-DD HH:MM:SS' (UTC) or ISO strings; normalize to ISO8601.
const iso = (d: string | null) =>
  d ? new Date(d.includes("T") ? d : d.replace(" ", "T") + "Z").toISOString() : null;

const repos = () =>
  db
    .query(
      `SELECT r.id, r.name, r.default_branch,
              (SELECT count(*) FROM workspaces w
                WHERE w.repository_id = r.id AND w.state != 'archived') AS active_workspace_count
         FROM repos r WHERE r.hidden = 0 ORDER BY r.display_order, r.name`
    )
    .all();

const workspaces = (repoId: string) =>
  db
    .query(
      `SELECT w.id, w.repository_id, coalesce(w.workspace_name, w.directory_name) AS name,
              w.branch, coalesce(w.manual_status, w.derived_status) AS status,
              w.unread, w.updated_at,
              (SELECT s.title FROM sessions s WHERE s.workspace_id = w.id
                ORDER BY s.updated_at DESC LIMIT 1) AS last_message_snippet
         FROM workspaces w
        WHERE w.repository_id = ? AND w.state != 'archived'
        ORDER BY w.updated_at DESC`
    )
    .all(repoId)
    .map((w: any) => ({ ...w, unread: !!w.unread, updated_at: iso(w.updated_at) }));

const sessions = (workspaceId: string) =>
  db
    .query(
      `SELECT id, workspace_id, title, model, agent_type, updated_at FROM sessions
        WHERE workspace_id = ? AND is_hidden = 0 ORDER BY updated_at DESC`
    )
    .all(workspaceId)
    .map((s: any) => ({ ...s, updated_at: iso(s.updated_at) }));

// Flatten Claude Code stream-JSON envelopes into displayable messages.
function displayMessages(sessionId: string) {
  const rows = db
    .query(
      `SELECT id, role, content, created_at FROM session_messages
        WHERE session_id = ? AND content IS NOT NULL AND cancelled_at IS NULL
        ORDER BY created_at, id`
    )
    .all(sessionId) as any[];

  const out: { id: string; role: string; content: string; created_at: string }[] = [];
  for (const row of rows) {
    const createdAt = iso(row.created_at)!;
    let env: any;
    try {
      env = JSON.parse(row.content);
    } catch {
      // Plain text (typically the user's typed message).
      out.push({ id: row.id, role: row.role, content: row.content, created_at: createdAt });
      continue;
    }
    const blocks = env?.message?.content;
    if (env?.type === "assistant" && Array.isArray(blocks)) {
      for (const [i, b] of blocks.entries()) {
        if (b.type === "text" && b.text.trim())
          out.push({ id: `${row.id}-${i}`, role: "assistant", content: b.text, created_at: createdAt });
        else if (b.type === "thinking" && b.thinking?.trim())
          out.push({ id: `${row.id}-${i}`, role: "thinking", content: b.thinking, created_at: createdAt });
        else if (b.type === "tool_use")
          out.push({
            id: `${row.id}-${i}`,
            role: "tool",
            content: `${b.name} ${summarizeInput(b.input)}`,
            created_at: createdAt,
          });
      }
    } else if (env?.type === "user") {
      const c = env.message?.content;
      if (typeof c === "string" && c.trim())
        out.push({ id: row.id, role: "user", content: c, created_at: createdAt });
      // tool_result blocks are skipped for v1; the tool row already shows the call.
    }
    else if (env?.type === "result" && env.duration_ms) {
      const s = Math.round(env.duration_ms / 1000);
      const dur = s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`;
      out.push({ id: row.id, role: "duration", content: dur, created_at: createdAt });
    }
    // system envelopes are skipped — internal.
  }
  return out;
}

const summarizeInput = (input: any) => {
  const v = input?.file_path ?? input?.command ?? input?.pattern ?? input?.description ?? "";
  return String(v).slice(0, 80);
};

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
        const { text, model } = await req.json();
        if (!text?.trim()) return Response.json({ error: "empty message" }, { status: 400 });
        const r = sendMessage(m[1], text.trim(), model);
        return Response.json(r, { status: "status" in r ? (r.status as number) : 200 });
      }
      if (req.method === "POST" && (m = path.match(/^\/sessions\/([^/]+)\/stop$/))) {
        const t = turns.get(m[1]);
        t?.proc?.kill();
        return Response.json({ ok: true });
      }
      // Serve workspace-relative attachment files (images pasted into chats live
      // under <workspace>/.context/attachments/).
      if ((m = path.match(/^\/sessions\/([^/]+)\/attachments$/))) {
        const rel = new URL(req.url).searchParams.get("path") ?? "";
        const ws: any = db
          .query(`SELECT w.workspace_path FROM sessions s JOIN workspaces w ON s.workspace_id = w.id WHERE s.id = ?`)
          .get(m[1]);
        if (!ws?.workspace_path) return Response.json({ error: "not found" }, { status: 404 });
        const full = resolve(ws.workspace_path, decodeURIComponent(rel));
        if (!full.startsWith(resolve(ws.workspace_path) + "/"))
          return Response.json({ error: "forbidden" }, { status: 403 });
        if (!existsSync(full)) return Response.json({ error: "not found" }, { status: 404 });
        return new Response(Bun.file(full));
      }
      if ((m = path.match(/^\/sessions\/([^/]+)\/status$/))) {
        const t = turns.get(m[1]);
        return Response.json({ running: !!t?.running, activity: t?.activity ?? "" });
      }
      if (path === "/repos") return Response.json(repos());
      if ((m = path.match(/^\/repos\/([^/]+)\/workspaces$/))) return Response.json(workspaces(m[1]));
      if ((m = path.match(/^\/workspaces\/([^/]+)\/sessions$/))) return Response.json(sessions(m[1]));
      if ((m = path.match(/^\/sessions\/([^/]+)\/messages$/))) return Response.json(displayMessages(m[1]));
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 500 });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  },
});

console.log(`Conductor companion listening on http://0.0.0.0:${PORT}`);
console.log(`Auth token: ${TOKEN}`);
