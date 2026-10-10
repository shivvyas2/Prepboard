// Prepboard cloud layer: Supabase accounts, per-user sync, and the "Start something new" planner chat.
// Loaded after index.html's main script, which exposes window.PB.
(() => {
  "use strict";
  const PB = window.PB;
  const cfg = window.PREPBOARD_CONFIG || {};
  const configured = !!(cfg.supabaseUrl && cfg.supabaseAnonKey && window.supabase?.createClient);
  const sb = configured ? window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey) : null;
  const esc = PB.esc;

  // ---------- styles ----------
  const css = document.createElement("style");
  css.textContent = `
  .auth { position: fixed; inset: 0; z-index: 50; background: linear-gradient(180deg, var(--bg), var(--bg-2)); display: grid; place-items: center; padding: 24px 16px; overflow-y: auto; }
  .auth-card { width: min(940px, 100%); display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); background: var(--card); border: 1px solid var(--line); border-radius: 32px; box-shadow: var(--shadow); overflow: hidden; }
  .auth-art { background: var(--cobalt); color: #fff; padding: 36px; display: grid; align-content: space-between; gap: 28px; min-width: 0; }
  .auth-art h1 { font-size: clamp(30px, 4vw, 44px); letter-spacing: -.04em; line-height: 1.02; margin: 0; }
  .auth-art p { color: rgba(255,255,255,.75); margin: 10px 0 0; line-height: 1.5; }
  .auth-faces { display: flex; }
  .auth-faces .avatar { width: 52px; height: 52px; margin-left: -10px; box-shadow: 0 0 0 3px var(--cobalt); }
  .auth-faces .avatar:first-child { margin-left: 0; }
  .auth-pill { justify-self: start; display: flex; align-items: center; gap: 12px; color: #fff; font-weight: 700; font-size: 22px; letter-spacing: -.02em; }
  .auth-pill img { width: 52px; height: 52px; border-radius: 14px; }
  .auth-form { padding: 36px; display: grid; gap: 14px; align-content: center; min-width: 0; }
  .auth-form h2 { margin: 0; font-size: 24px; letter-spacing: -.02em; }
  .auth-msg { font-size: 13px; padding: 10px 12px; border-radius: 12px; }
  .auth-msg.err { background: #fbe4d8; color: #9a3412; } .auth-msg.ok { background: var(--cobalt-soft); color: var(--cobalt); }
  .auth-switch { border: 0; background: transparent; color: var(--cobalt); font-weight: 600; padding: 0; }
  .sync-pill { height: 32px; padding: 0 12px; border-radius: 999px; border: 1px solid var(--line); background: var(--card); display: inline-flex; align-items: center; gap: 8px; font-size: 12px; color: var(--ink-2); white-space: nowrap; }
  .sync-pill i { width: 8px; height: 8px; border-radius: 50%; background: #2f7d4f; }
  .sync-pill.busy i { background: var(--sun); } .sync-pill.err i { background: #c2410c; } .sync-pill.local i { background: var(--faint); }
  .np { position: fixed; inset: 0; z-index: 40; background: linear-gradient(180deg, var(--bg), var(--bg-2)); display: grid; grid-template-rows: auto 1fr auto; }
  .np-top { display: flex; align-items: center; gap: 12px; padding: 18px clamp(16px, 4vw, 40px); }
  .np-top .muted { font-size: 13px; }
  .np-scroll { overflow-y: auto; padding: 0 16px; }
  .np-inner { max-width: 760px; margin: 0 auto; padding: 24px 0 40px; display: grid; gap: 16px; }
  .np-hero { text-align: center; padding: 6vh 0 12px; display: grid; gap: 10px; justify-items: center; }
  .np-hero h1 { font-size: clamp(32px, 5vw, 52px); letter-spacing: -.045em; margin: 0; line-height: 1.02; }
  .np-hero p { color: var(--muted); margin: 0; max-width: 520px; }
  .np-sugg { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; margin-top: 8px; }
  .np-msg { max-width: 88%; padding: 12px 16px; border-radius: 20px; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere; }
  .np-msg.user { justify-self: end; background: var(--cobalt); color: #fff; border-bottom-right-radius: 6px; }
  .np-msg.assistant { justify-self: start; background: var(--card); border: 1px solid var(--line); border-bottom-left-radius: 6px; }
  .np-typing { justify-self: start; color: var(--muted); font-size: 13px; display: flex; gap: 8px; align-items: center; }
  .np-typing i { width: 8px; height: 8px; border-radius: 50%; background: var(--cobalt); animation: npb 1s infinite alternate; }
  @keyframes npb { to { opacity: .2; } }
  .np-plan { background: var(--card); border: 1px solid var(--line); border-radius: 24px; padding: 20px; display: grid; gap: 14px; box-shadow: var(--shadow); }
  .np-plan h3 { margin: 0; font-size: 20px; letter-spacing: -.02em; }
  .np-plan .grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
  .np-plan .grid div { background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 12px; }
  .np-plan .grid b { display: block; font-size: 22px; letter-spacing: -.02em; }
  .np-plan ul { margin: 0; padding-left: 18px; color: var(--ink-2); display: grid; gap: 4px; }
  .np-input { padding: 12px 16px 20px; }
  .np-box { max-width: 760px; margin: 0 auto; display: flex; gap: 10px; align-items: flex-end; background: var(--card); border: 1px solid var(--line-2); border-radius: 26px; padding: 8px 8px 8px 18px; box-shadow: var(--shadow); }
  .np-box textarea { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; resize: none; font-size: 15px; line-height: 1.5; max-height: 200px; padding: 8px 0; }
  .np-send { width: 42px; height: 42px; border-radius: 50%; border: 0; background: var(--cobalt); color: #fff; font-size: 18px; flex: none; }
  .np-send:disabled { opacity: .4; }
  @media (max-width: 760px) {
    .auth-card { grid-template-columns: minmax(0, 1fr); }
    .auth-art { padding: 26px; } .auth-form { padding: 26px; }
    .np-plan .grid { grid-template-columns: minmax(0, 1fr); }
  }`;
  document.head.appendChild(css);

  // ---------- row mapping ----------
  const roleToRow = (r) => ({ id: r.id, company: r.company || "", title: r.title || "", team: r.team || "", location: r.location || "",
    role_number: r.roleNumber || "", salary: r.salary || "", link: r.link || "", stage: r.stage || "Saved",
    interview_at: r.interviewAt || null, interview_note: r.interviewNote || "", notes: r.notes || "",
    created_at: r.createdAt || new Date().toISOString() });
  const roleFromRow = (x) => ({ id: x.id, company: x.company, title: x.title, team: x.team, location: x.location, roleNumber: x.role_number,
    salary: x.salary, link: x.link, stage: x.stage, interviewAt: x.interview_at || "", interviewNote: x.interview_note, notes: x.notes, createdAt: x.created_at });
  const docToRow = (d) => ({ id: d.id, role_id: d.roleId || "", title: d.title || "", body: d.body || "", tags: d.tags || [],
    sort_order: d.order ?? 999, file_type: d.fileType || "md", file_path: d.filePath || "", updated_at: d.updatedAt || new Date().toISOString() });
  const docFromRow = (x) => ({ id: x.id, roleId: x.role_id, title: x.title, body: x.body, tags: x.tags || [], order: x.sort_order, fileType: x.file_type || "md", filePath: x.file_path || "", updatedAt: x.updated_at });
  const taskToRow = (t) => ({ id: t.id, role_id: t.roleId || "", title: t.title || "", start_at: t.start, end_at: t.end,
    kind: t.kind || "study", refs: t.refs || [], videos: t.videos || [], done: !!t.done });
  const taskFromRow = (x) => ({ id: x.id, roleId: x.role_id, title: x.title, start: x.start_at, end: x.end_at, kind: x.kind,
    refs: x.refs || [], videos: x.videos || [], done: x.done, due: (x.start_at || "").slice(0, 10) });
  const quizToRow = (q) => ({ id: q.id, role_id: q.role_id || "", session_id: q.session_id || "", topic: q.topic || "", score: q.score, total: q.total,
    items: q.items || [], weak_topics: q.weak_topics || [], source: q.source || "cloud", created_at: q.created_at });
  const quizFromRow = (x) => ({ id: x.id, role_id: x.role_id, session_id: x.session_id, topic: x.topic, score: x.score, total: x.total,
    items: x.items || [], weak_topics: x.weak_topics || [], source: x.source, created_at: x.created_at });
  const profileToRow = (p) => ({ name: p?.name || "", headline: p?.headline || "", avatar: p?.avatar || 0, photo: p?.photo || "" });
  const COLLECTIONS = [
    { key: "roles", table: "pb_roles", to: roleToRow },
    { key: "docs", table: "pb_docs", to: docToRow },
    { key: "tasks", table: "pb_sessions", to: taskToRow },
    { key: "quizzes", table: "pb_quiz_attempts", to: quizToRow },
  ];

  // ---------- sync state ----------
  let user = null;
  let synced = null;          // { roles: {id: json}, docs: {...}, tasks: {...}, profile: json }
  let pushTimer = null, pushing = false, pushAgain = false;
  let status = configured ? "busy" : "local";

  function snapshot(db) {
    const snap = { profile: JSON.stringify(profileToRow(db.profile)) };
    for (const c of COLLECTIONS) snap[c.key] = Object.fromEntries((db[c.key] || []).map((x) => [x.id, JSON.stringify(c.to(x))]));
    return snap;
  }

  function setStatus(s, title) {
    status = s;
    const el = document.getElementById("syncPill");
    if (!el) return;
    el.className = "sync-pill " + s;
    el.title = title || "";
    el.querySelector("span").textContent = { ok: "Synced", busy: "Syncing…", err: "Sync error", local: "Local only", offline: "Offline" }[s] || s;
  }

  async function pull() {
    setStatus("busy");
    const [roles, docs, tasks, prof, quizzes] = await Promise.all([
      sb.from("pb_roles").select("*"),
      sb.from("pb_docs").select("*"),
      sb.from("pb_sessions").select("*"),
      sb.from("pb_profiles").select("*").eq("user_id", user.id).maybeSingle(),
      sb.from("pb_quiz_attempts").select("*").order("created_at", { ascending: false }).limit(500),
    ]);
    const err = roles.error || docs.error || tasks.error || prof.error || quizzes.error;
    if (err) throw err;
    return {
      roles: roles.data.map(roleFromRow),
      docs: docs.data.map(docFromRow),
      tasks: tasks.data.map(taskFromRow),
      quizzes: quizzes.data.map(quizFromRow),
      profile: prof.data ? { name: prof.data.name, headline: prof.data.headline, avatar: prof.data.avatar, photo: prof.data.photo }
                         : { name: user.user_metadata?.name || "", headline: "", avatar: 0, photo: "" },
    };
  }

  async function push() {
    if (!user || !synced) return;
    if (pushing) { pushAgain = true; return; }
    pushing = true;
    setStatus("busy");
    try {
      const db = PB.db;
      const now = snapshot(db);
      for (const c of COLLECTIONS) {
        const changed = (db[c.key] || []).filter((x) => now[c.key][x.id] !== synced[c.key][x.id]).map((x) => ({ ...c.to(x), user_id: user.id, updated_at: new Date().toISOString() }));
        const removed = Object.keys(synced[c.key]).filter((id) => !(id in now[c.key]));
        if (changed.length) { const { error } = await sb.from(c.table).upsert(changed, { onConflict: "user_id,id" }); if (error) throw error; }
        if (removed.length) { const { error } = await sb.from(c.table).delete().eq("user_id", user.id).in("id", removed); if (error) throw error; }
      }
      if (now.profile !== synced.profile) {
        const { error } = await sb.from("pb_profiles").upsert({ ...profileToRow(db.profile), user_id: user.id, updated_at: new Date().toISOString() });
        if (error) throw error;
      }
      synced = now;
      setStatus("ok", "All changes saved to your account");
    } catch (e) {
      console.error("Prepboard sync failed", e);
      setStatus(navigator.onLine ? "err" : "offline", e.message || String(e));
    } finally {
      pushing = false;
      if (pushAgain) { pushAgain = false; schedulePush(); }
    }
  }

  function schedulePush() {
    if (!user) return;
    clearTimeout(pushTimer);
    pushTimer = setTimeout(push, 700);
  }

  async function startSession(session) {
    user = session.user;
    const cacheKey = "prepboard.v2." + user.id;
    const cached = PB.loadCached(cacheKey);
    if (cached) PB.setDb(cached, cacheKey);
    hideAuth();
    try {
      const remote = await pull();
      const remoteEmpty = !remote.roles.length && !remote.docs.length && !remote.tasks.length;
      if (remoteEmpty) {
        // New account: start empty and go straight to the planner chat.
        synced = { roles: {}, docs: {}, tasks: {}, quizzes: {}, profile: "" };
        PB.setDb({ ...PB.blank(), profile: remote.profile }, cacheKey);
        await push();
        openNewPrep();
      } else {
        PB.setDb(remote, cacheKey);
        synced = snapshot(PB.db);
        setStatus("ok", "Synced with your account");
      }
    } catch (e) {
      console.error(e);
      setStatus("err", e.message);
      PB.toast("Couldn't reach your account. Working from this device.");
      synced = synced || snapshot(PB.db);
    }
    paintAccount();
  }

  function stopSession() {
    user = null; synced = null;
    PB.setDb(PB.blank(), "prepboard.v2.signed-out");
    showAuth();
  }

  // ---------- auth screen ----------
  let authMode = "signin";
  function showAuth(message) {
    let el = document.getElementById("auth");
    if (!el) { el = document.createElement("div"); el.id = "auth"; el.className = "auth"; document.body.appendChild(el); }
    const faces = [0, 1, 2, 3, 4].map((i) => `<span class="avatar">${window.PBAvatar ? window.PBAvatar(i) : ""}</span>`).join("");
    el.innerHTML = `<div class="auth-card">
      <div class="auth-art">
        <span class="auth-pill"><img src="logo.svg" alt="">PrepBoard</span>
        <div><h1>Prepare for the job you want, one session at a time.</h1>
          <p>Plan every interview on a timeline, keep your notes next to the hour you'll use them, and pick up on any device.</p></div>
        <div class="auth-faces">${faces}</div>
      </div>
      <form class="auth-form" id="authForm" novalidate>
        <h2>${authMode === "signup" ? "Create your account" : authMode === "reset" ? "Reset your password" : "Welcome back"}</h2>
        ${message ? `<div class="auth-msg ${message.type}">${esc(message.text)}</div>` : ""}
        ${authMode === "signup" ? `<label class="field"><span class="label">Name</span><input name="name" autocomplete="name" required></label>` : ""}
        <label class="field"><span class="label">Email</span><input name="email" type="email" autocomplete="email" required></label>
        ${authMode !== "reset" ? `<label class="field"><span class="label">Password</span><input name="password" type="password" autocomplete="${authMode === "signup" ? "new-password" : "current-password"}" minlength="8" required></label>` : ""}
        <button class="btn-primary" type="submit" style="justify-content:center">${authMode === "signup" ? "Create account" : authMode === "reset" ? "Send reset link" : "Sign in"}</button>
        <div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;font-size:13px">
          ${authMode === "signin" ? `<span>New here? <button type="button" class="auth-switch" data-mode="signup">Create an account</button></span><button type="button" class="auth-switch" data-mode="reset">Forgot password?</button>`
            : `<span>Have an account? <button type="button" class="auth-switch" data-mode="signin">Sign in</button></span>`}
        </div>
      </form>
    </div>`;
    el.hidden = false;
    el.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => { authMode = b.dataset.mode; showAuth(); }));
    el.querySelector("#authForm").addEventListener("submit", onAuthSubmit);
    setTimeout(() => el.querySelector("input")?.focus(), 30);
  }
  function hideAuth() { const el = document.getElementById("auth"); if (el) el.hidden = true; }

  async function onAuthSubmit(e) {
    e.preventDefault();
    const f = e.target.elements;
    const email = f.email.value.trim(), password = f.password?.value || "";
    const btn = e.target.querySelector("button[type=submit]");
    btn.disabled = true;
    try {
      if (authMode === "signup") {
        const { data, error } = await sb.auth.signUp({ email, password, options: { data: { name: f.name.value.trim() }, emailRedirectTo: location.origin + location.pathname } });
        if (error) throw error;
        if (!data.session) { authMode = "signin"; showAuth({ type: "ok", text: "Check your email to confirm your account, then sign in." }); return; }
      } else if (authMode === "reset") {
        const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
        if (error) throw error;
        authMode = "signin"; showAuth({ type: "ok", text: "If that email has an account, a reset link is on its way." }); return;
      } else {
        const { error } = await sb.auth.signInWithPassword({ email, password });
        if (error) throw error;
      }
    } catch (err) {
      showAuth({ type: "err", text: err.message || "Something went wrong." });
    } finally { btn.disabled = false; }
  }

  // ---------- account controls (topbar pill + profile dialog) ----------
  function paintAccount() {
    const topbar = document.querySelector(".topbar");
    if (topbar && !document.getElementById("syncPill")) {
      const pill = document.createElement("button");
      pill.id = "syncPill"; pill.className = "sync-pill"; pill.type = "button";
      pill.innerHTML = "<i></i><span></span>";
      pill.addEventListener("click", () => { if (user) push(); });
      topbar.insertBefore(pill, document.getElementById("newBtn"));
      setStatus(status);
    }
    const form = document.getElementById("profileForm");
    let box = document.getElementById("accountBox");
    if (form && !box) {
      box = document.createElement("div"); box.id = "accountBox";
      box.style.cssText = "display:flex;gap:10px;align-items:center;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:14px";
      form.appendChild(box);
    }
    if (box) box.innerHTML = !configured
      ? `<span class="muted" style="font-size:12px">Accounts aren't connected yet. Your data is saved on this device.</span>`
      : user ? `<span style="font-size:13px">Signed in as <b>${esc(user.email)}</b></span><button type="button" class="btn-ghost" id="signOutBtn" style="margin-left:auto">Sign out</button>` : "";
    document.getElementById("signOutBtn")?.addEventListener("click", async () => {
      document.getElementById("profileDialog")?.close();
      await push(); await sb.auth.signOut();
    });
  }

  // ---------- "Start something new" planner chat ----------
  let chat = [], thinking = false, plan = null;
  const SUGGESTIONS = [
    "I have a Google L5 Android interview in 2 weeks",
    "Help me prep for a product design onsite on Friday",
    "I'll paste a job posting",
  ];

  async function invoke(body) {
    if (!sb) throw new Error("Connect Supabase to use the planner.");
    const { data, error } = await sb.functions.invoke("prep-chat", {
      body: { ...body, now: new Date().toISOString(), timezone: Intl.DateTimeFormat().resolvedOptions().timeZone },
    });
    if (error) throw new Error(error.context?.statusText ? `${error.message} (${error.context.statusText})` : error.message);
    if (data?.error) throw new Error(data.error);
    return data;
  }

  function openNewPrep() {
    chat = []; plan = null; thinking = false;
    window.PBAI?.resetChat();
    let el = document.getElementById("newPrep");
    if (!el) { el = document.createElement("div"); el.id = "newPrep"; el.className = "np"; document.body.appendChild(el); }
    el.hidden = false;
    paintChat();
  }
  function closeNewPrep() { const el = document.getElementById("newPrep"); if (el) el.hidden = true; }

  function paintChat() {
    const el = document.getElementById("newPrep");
    const msgs = chat.map((m) => `<div class="np-msg ${m.role}">${esc(m.content)}</div>`).join("");
    const planCard = plan ? planHTML(plan) : "";
    el.innerHTML = `
      <div class="np-top">
        <button class="icon-btn" id="npClose" aria-label="Close">✕</button>
        <div><b>Start something new</b><div class="muted">Chat to build a prep plan</div></div>
      </div>
      <div class="np-scroll" id="npScroll"><div class="np-inner">
        ${chat.length ? "" : `<div class="np-hero">
          <span class="avatar" style="width:64px;height:64px">${window.PBAvatar ? window.PBAvatar(PB.db.profile?.avatar || 0) : ""}</span>
          <h1>What are you preparing for?</h1>
          <p>Tell me the role, paste the job posting, and when the interview is. I'll build your timeline, sessions and study guides.</p>
          <p class="muted" style="font-size:12px;margin-top:4px">${window.PBAI?.usingClaudeCode ? "Using your Claude Code" : "Using your Anthropic key (Profile → AI)"}</p>
          <div class="np-sugg">${SUGGESTIONS.map((s) => `<button class="btn-ghost" data-sugg="${esc(s)}">${esc(s)}</button>`).join("")}</div>
        </div>`}
        ${msgs}
        ${thinking ? `<div class="np-typing"><i></i>Thinking…</div>` : ""}
        ${planCard}
      </div></div>
      <div class="np-input"><form class="np-box" id="npForm">
        <textarea id="npText" rows="1" placeholder="${plan ? "Ask for changes, e.g. “less on Saturday, more mocks”" : "Describe the role, or paste the job posting…"}"></textarea>
        <button class="np-send" id="npSend" aria-label="Send" ${thinking ? "disabled" : ""}>↑</button>
      </form></div>`;
    el.querySelector("#npClose").addEventListener("click", closeNewPrep);
    el.querySelectorAll("[data-sugg]").forEach((b) => b.addEventListener("click", () => send(b.dataset.sugg)));
    const ta = el.querySelector("#npText");
    ta.addEventListener("input", () => { ta.style.height = "auto"; ta.style.height = ta.scrollHeight + "px"; });
    ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(ta.value); } });
    el.querySelector("#npForm").addEventListener("submit", (e) => { e.preventDefault(); send(ta.value); });
    el.querySelector("#npCreate")?.addEventListener("click", applyPlan);
    const sc = el.querySelector("#npScroll"); sc.scrollTop = sc.scrollHeight;
    if (!thinking) ta.focus();
  }

  function planHTML(p) {
    const work = p.sessions.filter((s) => s.kind !== "break");
    const hours = work.reduce((n, s) => n + (new Date(s.end) - new Date(s.start)), 0) / 36e5;
    const days = new Set(p.sessions.map((s) => PB.dayKey(new Date(s.start)))).size;
    return `<div class="np-plan">
      <div class="label">Your plan</div>
      <h3>${esc(p.role.company)} — ${esc(p.role.title)}</h3>
      <div class="muted">${p.role.interview_at ? esc(new Date(p.role.interview_at).toLocaleString(undefined, { weekday: "long", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })) + " · " : ""}${esc(p.role.interview_note || "")}</div>
      <p style="margin:0;line-height:1.55">${esc(p.summary)}</p>
      <div class="grid"><div><span class="label">Days</span><b>${days}</b></div><div><span class="label">Sessions</span><b>${work.length}</b></div><div><span class="label">Prep hours</span><b>${hours.toFixed(1)}</b></div></div>
      <div><div class="label" style="margin-bottom:6px">Study guides</div><ul>${p.docs.map((d) => `<li>${esc(d.title)}</li>`).join("")}</ul></div>
      <div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn-primary" id="npCreate">Create plan</button><span class="muted" style="font-size:12px;align-self:center">You can keep chatting to change it first.</span></div>
    </div>`;
  }

  async function send(text) {
    text = (text || "").trim();
    if (!text || thinking) return;
    chat.push({ role: "user", content: text });
    thinking = true; paintChat();
    try {
      const res = await window.PBAI.chat(chat);
      chat.push({ role: "assistant", content: res.reply || "…" });
      if (res.plan) plan = res.plan;
    } catch (e) {
      chat.push({ role: "assistant", content: "Sorry — " + (e.message || "something went wrong.") });
    } finally { thinking = false; paintChat(); }
  }

  async function applyPlan() {
    const p = plan; if (!p) return;
    const db = PB.db, now = new Date().toISOString();
    const roleId = PB.uid("role");
    db.roles.push({ id: roleId, company: p.role.company, title: p.role.title, team: p.role.team, location: p.role.location,
      roleNumber: "", salary: "", link: p.role.link, stage: p.role.stage || "Saved", interviewAt: p.role.interview_at || "",
      interviewNote: p.role.interview_note, notes: p.role.notes, createdAt: now });
    const docIds = {};
    p.docs.forEach((d, i) => {
      const id = PB.uid("doc"); docIds[d.key] = id;
      db.docs.push({ id, roleId, title: d.title, tags: ["guide"], order: i, updatedAt: now,
        body: `_Writing this guide…_\n\n${d.headings.map((h) => `## ${h}\n`).join("\n")}` });
    });
    for (const s of p.sessions) {
      if (!(new Date(s.end) > new Date(s.start))) continue;
      db.tasks.push({ id: PB.uid("task"), roleId, title: s.title, kind: s.kind, done: false,
        start: new Date(s.start).toISOString(), end: new Date(s.end).toISOString(), due: s.start.slice(0, 10),
        refs: s.refs.filter((r) => docIds[r.doc_key]).map((r) => ({ doc: docIds[r.doc_key], heading: r.heading || "" })) });
    }
    PB.save();
    closeNewPrep();
    PB.go("dashboard", { tlRole: roleId });
    PB.toast("Plan created. Writing your study guides…");
    // Write each guide in parallel; fill them in as they finish.
    const role = p.role;
    await Promise.all(p.docs.map(async (d) => {
      try {
        const res = await window.PBAI.doc(role, { key: d.key, title: d.title, headings: d.headings });
        const doc = PB.db.docs.find((x) => x.id === docIds[d.key]);
        if (doc && res.body) { doc.body = res.body; doc.updatedAt = new Date().toISOString(); PB.save(); PB.render(); }
      } catch (e) { console.error("doc failed", d.title, e); }
    }));
    PB.toast("Study guides ready");
  }

  // Entry points: the + New menu gets a first option, and Roles gets a button.
  const newDialog = document.getElementById("newDialog");
  if (newDialog) {
    const list = newDialog.querySelector("div[style*='grid']");
    const b = document.createElement("button");
    b.className = "doc-row"; b.type = "button";
    b.innerHTML = `<span class="doc-ico" style="background:var(--sun);border-color:var(--sun);color:var(--on-sun)">✦</span><span class="t"><div>Start something new</div><div class="muted">Chat to build a full prep plan for a new role</div></span>`;
    b.addEventListener("click", () => { newDialog.close(); openNewPrep(); });
    list?.prepend(b);
  }
  window.PBCloud = { configured, schedulePush, openNewPrep, invoke, sb, get user() { return user; } };

  // ---------- boot ----------
  paintAccount();
  if (!configured) { setStatus("local", "Accounts not connected"); return; }
  window.addEventListener("online", schedulePush);
  document.addEventListener("visibilitychange", async () => {
    if (document.visibilityState !== "visible" || !user || pushing) return;
    try { await push(); const remote = await pull(); PB.setDb(remote); synced = snapshot(PB.db); setStatus("ok"); } catch (_) {}
  });
  sb.auth.onAuthStateChange((event, session) => {
    if (event === "SIGNED_OUT") stopSession();
    else if (session && (!user || user.id !== session.user.id)) setTimeout(() => startSession(session), 0);
  });
  sb.auth.getSession().then(({ data }) => { if (!data.session) showAuth(); });
})();
