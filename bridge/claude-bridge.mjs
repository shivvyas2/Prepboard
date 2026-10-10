#!/usr/bin/env node
// Prepboard ↔ Claude Code bridge.
// Lets the Prepboard web app on this Mac use YOUR Claude Code (your Claude account) for the planner,
// quizzes and YouTube search. Run:  node bridge/claude-bridge.mjs
//
// Safety:
//  - Listens on 127.0.0.1 only, and checks the Host header (blocks DNS-rebinding).
//  - Only accepts requests whose Origin is the Prepboard web app (PREPBOARD_ORIGINS to change).
//  - Claude Code runs headless with read-only + web tools only (no file edits, no shell).
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PREPBOARD_BRIDGE_PORT || 8787);
const ORIGINS = (process.env.PREPBOARD_ORIGINS || "https://prepboard.shivvyas.com,http://localhost:8765,http://127.0.0.1:8765").split(",");
const WORKDIR = process.env.PREPBOARD_DIR || path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const ALLOWED_TOOLS = new Set(["Read", "Grep", "Glob", "WebSearch", "WebFetch"]);
const MAX_BODY = 300_000;

function run(cmd, args, input, timeoutMs = 300_000) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { cwd: WORKDIR, env: process.env });
    let out = "", err = "";
    const timer = setTimeout(() => p.kill("SIGTERM"), timeoutMs);
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("error", (e) => { clearTimeout(timer); resolve({ code: -1, out, err: String(e) }); });
    p.on("close", (code) => { clearTimeout(timer); resolve({ code, out, err }); });
    if (input) p.stdin.end(input); else p.stdin.end();
  });
}

let statusCache = null;
async function status() {
  if (statusCache && Date.now() - statusCache.at < 30_000) return statusCache.value;
  const v = await run("claude", ["--version"], null, 15_000);
  if (v.code !== 0) return { ok: false, installed: false, error: "Claude Code (`claude`) isn't on PATH." };
  const a = await run("claude", ["auth", "status"], null, 15_000);
  let loggedIn = false;
  try { loggedIn = !!JSON.parse(a.out).loggedIn; } catch { /* older CLI */ }
  const value = { ok: loggedIn, installed: true, loggedIn, version: v.out.trim().split("\n")[0], workdir: WORKDIR };
  statusCache = { at: Date.now(), value };
  return value;
}

function send(res, code, body, origin) {
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Private-Network": "true",
    Vary: "Origin",
  });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const host = (req.headers.host || "").toLowerCase();
  if (host !== `127.0.0.1:${PORT}` && host !== `localhost:${PORT}`) { res.writeHead(403).end(); return; }
  const origin = req.headers.origin || "";
  if (!ORIGINS.includes(origin)) { res.writeHead(403).end("origin not allowed"); return; }
  if (req.method === "OPTIONS") return send(res, 204, {}, origin);

  if (req.method === "GET" && req.url === "/status") return send(res, 200, await status(), origin);

  if (req.method === "POST" && req.url === "/run") {
    let raw = "";
    for await (const chunk of req) { raw += chunk; if (raw.length > MAX_BODY) return send(res, 413, { error: "Request too large" }, origin); }
    let body;
    try { body = JSON.parse(raw); } catch { return send(res, 400, { error: "Invalid JSON" }, origin); }
    const prompt = String(body.prompt || "");
    if (!prompt.trim()) return send(res, 400, { error: "prompt is required" }, origin);
    const tools = String(body.tools || "Read").split(/[\s,]+/).filter((t) => ALLOWED_TOOLS.has(t));
    const args = ["-p", "--output-format", "json", "--allowedTools", ...(tools.length ? tools : ["Read"])];
    if (typeof body.resume === "string" && /^[\w-]{8,64}$/.test(body.resume)) args.push("--resume", body.resume);
    const r = await run("claude", args, prompt);
    try {
      const env = JSON.parse(r.out.slice(r.out.indexOf("{")));
      return send(res, 200, { result: env.result ?? "", session_id: env.session_id ?? null, is_error: !!env.is_error }, origin);
    } catch {
      return send(res, 502, { error: "Claude Code didn't return a result. " + (r.err || r.out).slice(-300) }, origin);
    }
  }
  send(res, 404, { error: "Not found" }, origin);
});

server.listen(PORT, "127.0.0.1", async () => {
  const s = await status();
  console.log(`Prepboard ↔ Claude Code bridge on http://127.0.0.1:${PORT}`);
  console.log(`  Claude Code: ${s.installed ? s.version : "not found"} · ${s.loggedIn ? "signed in" : "NOT signed in (run: claude auth login)"}`);
  console.log(`  Working folder: ${WORKDIR}`);
  console.log(`  Allowed web origins: ${ORIGINS.join(", ")}`);
});
