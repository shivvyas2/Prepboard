// Prepboard AI routing (web): use the person's own Claude Code (via the local bridge) or their Anthropic API key (server).
(() => {
  "use strict";
  const PB = window.PB;
  const esc = PB.esc;
  const BRIDGE = "http://127.0.0.1:8787";
  const PREF = "prepboard.ai.preferClaudeCode";

  const state = { bridge: null, keyStatus: null, prefer: true };
  try { state.prefer = localStorage.getItem(PREF) !== "0"; } catch (_) {}

  async function detectBridge() {
    try {
      const ctrl = new AbortController(); setTimeout(() => ctrl.abort(), 1500);
      const r = await fetch(`${BRIDGE}/status`, { signal: ctrl.signal });
      state.bridge = await r.json();
    } catch (_) { state.bridge = null; }
    return state.bridge;
  }
  const useClaudeCode = () => state.prefer && state.bridge?.ok;

  async function bridgeRun(prompt, tools = "Read", resume = null) {
    const r = await fetch(`${BRIDGE}/run`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ prompt, tools, resume }) });
    const data = await r.json();
    if (!r.ok || data.error) throw new Error(data.error || "Claude Code bridge error");
    if (data.is_error) throw new Error(data.result || "Claude Code returned an error");
    return data;
  }
  function extractJSON(text) {
    const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
    const src = fence ? fence[1] : text;
    const o = src.search(/[[{]/), c = Math.max(src.lastIndexOf("}"), src.lastIndexOf("]"));
    if (o < 0 || c <= o) return null;
    try { return JSON.parse(src.slice(o, c + 1)); } catch (_) { return null; }
  }
  const cloud = (body) => {
    if (!window.PBCloud?.invoke) throw new Error("Sign in, then add your Anthropic key in Profile → AI, or run the Claude Code bridge.");
    return window.PBCloud.invoke(body);
  };
  const now = () => new Date().toISOString();
  const tz = () => Intl.DateTimeFormat().resolvedOptions().timeZone;

  // ---------- capabilities ----------
  async function quiz(topic, material) {
    if (!useClaudeCode()) return { ...(await cloud({ mode: "quiz", topic, material, count: 6 })), source: "cloud" };
    const { result } = await bridgeRun(`Write a 6-question multiple-choice interview-prep quiz on: ${topic}
Test understanding (why/how/trade-offs, predicting behavior, spotting bugs), not trivia. Each question has exactly 4 plausible options and one correct answer; vary the correct index.
Study material:
${material || "(none — use standard knowledge)"}

Reply with ONLY a JSON object, no prose:
{"topic": "...", "questions": [{"question": "...", "options": ["A","B","C","D"], "answer": 0, "explanation": "1-3 sentences", "topic": "short sub-topic"}]}`, "Read");
    const quiz = extractJSON(result);
    if (!quiz?.questions) throw new Error("Claude Code's reply wasn't a quiz. Try again.");
    quiz.questions = quiz.questions.filter((q) => q.options?.length === 4 && q.answer >= 0 && q.answer < 4);
    return { quiz, source: "claude-code" };
  }

  async function videos(topic, context) {
    if (!useClaudeCode()) return cloud({ mode: "videos", topic, context });
    const { result } = await bridgeRun(`Use web search to find 3-4 high-quality YouTube videos that explain: ${topic}
Context: ${context}
Prefer clear explanations from reputable channels. Only include URLs you actually found.
Reply with ONLY a JSON array, no prose:
[{"url": "https://www.youtube.com/watch?v=...", "title": "...", "channel": "...", "why": "one sentence on why it helps"}]`, "WebSearch WebFetch");
    const list = extractJSON(result) || [];
    const seen = new Set();
    return { videos: list.flatMap((v) => {
      const m = String(v.url || "").match(/(?:v=|youtu\.be\/|embed\/|shorts\/)([\w-]{11})/);
      if (!m || seen.has(m[1])) return [];
      seen.add(m[1]);
      return [{ id: m[1], title: v.title || "", channel: v.channel || "", why: v.why || "" }];
    }) };
  }

  let plannerSession = null;
  const PLANNER_RULES = (n, z) => `You are the planner inside PrepBoard, an interview-prep app. The user is starting preparation for something new.
Current time: ${n} (user's timezone: ${z}).
Have a short, friendly conversation, asking at most one or two questions per message, to learn: the role (company, title, ideally the job posting), the interview date/time/format, their background and weak spots, and how many hours per day they can prepare. Infer what you can from what they paste.
When you know enough, reply with ONLY a JSON object in a \`\`\`json fenced block:
{"summary": "2-3 sentences to the user", "role": {"company": "", "title": "", "team": "", "location": "", "link": "", "interview_at": "ISO 8601 with offset or empty", "interview_note": "", "notes": "", "stage": "Saved|Applied|Recruiter|Technical|Onsite|Offer"},
 "docs": [{"key": "slug", "title": "", "headings": ["4-8 section headings"]}],
 "sessions": [{"title": "", "start": "ISO 8601 with offset", "end": "ISO 8601 with offset", "kind": "study|practice|mock|review|logistics|break", "refs": [{"doc_key": "", "heading": "one of that doc's headings or empty"}]}]}
Plan rules: sessions from the next sensible slot until shortly before the interview, respecting daily hours, 30-150 minute blocks, meal breaks, done by ~22:00, fundamentals first, mocks in the middle, light last hours. 4-6 docs tailored to this role.
Otherwise reply in plain text with your next short question. Do not use Markdown headers.`;

  async function chat(messages) {
    if (!useClaudeCode()) return cloud({ mode: "chat", messages });
    const last = messages[messages.length - 1].content;
    const first = !plannerSession || messages.length === 1;
    const prompt = first ? `${PLANNER_RULES(now(), tz())}\n\nUser: ${last}` : last;
    const res = await bridgeRun(prompt, "Read WebFetch", first ? null : plannerSession);
    plannerSession = res.session_id;
    const plan = extractJSON(res.result);
    if (plan?.sessions && plan?.role) return { reply: plan.summary || "Here's your plan.", plan };
    return { reply: res.result.trim() };
  }
  function resetChat() { plannerSession = null; }

  async function doc(role, d) {
    if (!useClaudeCode()) return cloud({ mode: "doc", role, doc: d });
    const { result } = await bridgeRun(`Write a concise, practical interview study guide in Markdown.
Role: ${role.company} — ${role.title}. Interview: ${role.interview_at || "unknown"} · ${role.interview_note || ""}. Notes: ${role.notes || ""}
Title: ${d.title}
Start with a one-paragraph overview, then one "## " section per heading below, verbatim and in order:
${d.headings.map((h) => "- " + h).join("\n")}
Prefer checklists, likely interview questions with crisp answer outlines, and short code samples where relevant. 400-900 words. Output only the guide.`, "Read WebFetch");
    return { body: result.trim() };
  }

  // ---------- Profile → AI section ----------
  async function keyCall(body) { return window.PBCloud.invoke(body); }

  async function paintAI() {
    const form = document.getElementById("profileForm");
    if (!form) return;
    let box = document.getElementById("aiBox");
    if (!box) {
      box = document.createElement("div"); box.id = "aiBox";
      box.style.cssText = "display:grid;gap:10px;border-top:1px solid var(--line);padding-top:14px";
      form.insertBefore(box, document.getElementById("accountBox") || null);
    }
    const signedIn = !!window.PBCloud?.user;
    if (signedIn && !state.keyStatus) { try { state.keyStatus = await keyCall({ mode: "key_status" }); } catch (_) { state.keyStatus = null; } }
    const b = state.bridge, k = state.keyStatus;
    box.innerHTML = `<div class="label">AI · how PrepBoard talks to Claude</div>
      <div style="display:grid;grid-template-columns:34px minmax(0,1fr) auto;gap:10px;align-items:center;background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:10px 12px">
        <span style="width:30px;height:30px;border-radius:50%;background:#f5ede4;display:grid;place-items:center;color:#d97757;font-weight:800">✳</span>
        <span><b style="font-size:14px">Claude Code (your Claude account)</b><span class="muted" style="display:block;font-size:12px">${
          b?.ok ? `Connected on this Mac · ${esc(b.version || "")}` : b?.installed ? "Found, but not signed in. Run <code>claude auth login</code>." :
          "Run <code>node Prepboard/bridge/claude-bridge.mjs</code> on your Mac to use your Claude account here."}</span></span>
        ${b?.ok ? `<label style="display:flex;gap:6px;align-items:center;font-size:12px"><input type="checkbox" id="aiPrefer" ${state.prefer ? "checked" : ""}>Use</label>` : `<button type="button" class="btn-ghost" id="aiRecheck">Check</button>`}
      </div>
      <div style="display:grid;gap:8px;background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:10px 12px">
        <div style="display:flex;gap:10px;align-items:center"><b style="font-size:14px;flex:1">Anthropic API key</b>
          ${k?.has_key ? `<span class="chip">Saved ••••${esc(k.hint)}</span><button type="button" class="btn-ghost" id="aiRemoveKey">Remove</button>` : ""}</div>
        ${signedIn ? `<div style="display:flex;gap:8px"><input id="aiKey" type="password" autocomplete="off" placeholder="${k?.has_key ? "Replace with a new key (sk-ant-…)" : "sk-ant-…"}" style="flex:1;min-width:0;border:1px solid var(--line);background:var(--card);border-radius:10px;padding:8px 10px;outline:0">
          <button type="button" class="btn-primary" id="aiSaveKey" style="height:38px">Save</button></div>
          <span class="muted" style="font-size:12px">Works on web, iPad and iPhone. Stored encrypted on the server and never shown again. Get one at console.anthropic.com.</span>`
          : `<span class="muted" style="font-size:12px">Sign in to add your key.</span>`}
        <span id="aiMsg" style="font-size:12px"></span>
      </div>`;
    box.querySelector("#aiPrefer")?.addEventListener("change", (e) => { state.prefer = e.target.checked; try { localStorage.setItem(PREF, state.prefer ? "1" : "0"); } catch (_) {} });
    box.querySelector("#aiRecheck")?.addEventListener("click", async () => { await detectBridge(); paintAI(); });
    box.querySelector("#aiRemoveKey")?.addEventListener("click", async () => { await keyCall({ mode: "delete_key" }); state.keyStatus = null; paintAI(); PB.toast("Key removed"); });
    box.querySelector("#aiSaveKey")?.addEventListener("click", async () => {
      const input = box.querySelector("#aiKey"), msg = box.querySelector("#aiMsg");
      const key = input.value.trim(); if (!key) return;
      msg.textContent = "Checking the key with Anthropic…"; msg.style.color = "var(--muted)";
      try { const r = await keyCall({ mode: "set_key", key }); input.value = ""; state.keyStatus = { has_key: true, hint: r.hint }; paintAI(); PB.toast("Key saved"); }
      catch (e) { msg.textContent = e.message; msg.style.color = "#c2410c"; }
    });
  }

  document.getElementById("profileBtn")?.addEventListener("click", () => setTimeout(paintAI, 0));
  document.addEventListener("click", (e) => { if (e.target.closest("[data-open-profile]")) setTimeout(paintAI, 0); });
  detectBridge();
  window.PBAI = { quiz, videos, chat, doc, resetChat, detectBridge, get usingClaudeCode() { return useClaudeCode(); } };
})();
