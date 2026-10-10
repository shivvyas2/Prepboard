// Prepboard learning: YouTube videos per session, Claude-generated quizzes, and the Scores leaderboard.
(() => {
  "use strict";
  const PB = window.PB;
  const esc = PB.esc;
  const $ = (s, el = document) => el.querySelector(s);

  const css = document.createElement("style");
  css.textContent = `
  .sess-learn { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 6px; }
  .learn-btn { height: 28px; padding: 0 11px; border-radius: 999px; border: 1px solid var(--line-2); background: transparent; font-size: 12px; font-weight: 600; color: var(--ink-2); display: inline-flex; align-items: center; gap: 6px; }
  .learn-btn:hover { border-color: var(--cobalt); color: var(--cobalt); }
  .learn-btn .dotq { width: 7px; height: 7px; border-radius: 50%; background: var(--sun); }
  .sess.current .learn-btn { color: #fff; border-color: rgba(255,255,255,.35); }
  .vids { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(180px, 220px); gap: 10px; overflow-x: auto; margin-top: 8px; padding-bottom: 2px; }
  .vid { border: 1px solid var(--line); background: var(--card); border-radius: 14px; padding: 0; overflow: hidden; text-align: left; display: grid; color: var(--ink); }
  .vid:hover { border-color: var(--cobalt); }
  .vid .th { position: relative; aspect-ratio: 16/9; background: #000 center/cover no-repeat; }
  .vid .th::after { content: "▶"; position: absolute; inset: 0; display: grid; place-items: center; color: #fff; font-size: 22px; text-shadow: 0 2px 8px rgba(0,0,0,.5); }
  .vid .vt { padding: 8px 10px 10px; font-size: 12px; font-weight: 600; line-height: 1.3; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .vid .vc { padding: 0 10px 10px; font-size: 11px; color: var(--muted); margin-top: -6px; }
  .qz { width: min(680px, calc(100vw - 32px)); padding: 0; }
  .qz-head { display: flex; align-items: center; gap: 10px; padding: 18px 22px; border-bottom: 1px solid var(--line); }
  .qz-body { padding: 22px; display: grid; gap: 14px; max-height: min(70vh, 720px); overflow-y: auto; }
  .qz-prog { height: 6px; background: var(--surface); border-radius: 999px; overflow: hidden; }
  .qz-prog i { display: block; height: 100%; background: var(--cobalt); }
  .qz-q { font-size: 19px; font-weight: 650; letter-spacing: -.01em; line-height: 1.35; white-space: pre-wrap; }
  .qz-opt { text-align: left; border: 1.5px solid var(--line-2); background: var(--card); border-radius: 14px; padding: 12px 14px; display: grid; grid-template-columns: 28px minmax(0, 1fr); gap: 10px; align-items: start; font-size: 14px; line-height: 1.4; white-space: pre-wrap; }
  .qz-opt b { width: 24px; height: 24px; border-radius: 8px; display: grid; place-items: center; background: var(--surface); font-family: var(--mono); font-size: 12px; }
  .qz-opt:hover:not(:disabled) { border-color: var(--cobalt); }
  .qz-opt.right { border-color: #2f7d4f; background: #e6f3ea; } .qz-opt.right b { background: #2f7d4f; color: #fff; }
  .qz-opt.wrong { border-color: #c2410c; background: #fbe4d8; } .qz-opt.wrong b { background: #c2410c; color: #fff; }
  .qz-expl { background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 12px 14px; font-size: 14px; line-height: 1.5; }
  .qz-score { display: grid; justify-items: center; gap: 6px; padding: 10px 0; text-align: center; }
  .qz-ring { width: 120px; height: 120px; border-radius: 50%; display: grid; place-items: center; font-size: 30px; font-weight: 800; letter-spacing: -.03em; }
  .qz-review { display: grid; gap: 10px; }
  .qz-review .it { border: 1px solid var(--line); border-radius: 14px; padding: 12px 14px; display: grid; gap: 6px; font-size: 13px; }
  .qz-review .it .ok { color: #2f7d4f; font-weight: 700; } .qz-review .it .no { color: #c2410c; font-weight: 700; }
  .qz-foot { display: flex; gap: 8px; justify-content: flex-end; padding: 14px 22px 20px; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .vp { width: min(920px, calc(100vw - 32px)); padding: 0; overflow: hidden; }
  .vp iframe { width: 100%; aspect-ratio: 16/9; border: 0; display: block; background: #000; }
  .vp .meta { padding: 14px 18px 18px; display: grid; gap: 6px; }
  .lb-row { display: grid; grid-template-columns: 34px minmax(0, 1.2fr) minmax(80px, 1fr) 54px 64px; gap: 12px; align-items: center; padding: 11px 4px; border-bottom: 1px solid var(--line); }
  .lb-row:last-child { border-bottom: 0; }
  .lb-rank { width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; font-family: var(--mono); font-size: 12px; font-weight: 700; background: var(--surface); }
  .lb-rank.g1 { background: var(--sun); color: var(--on-sun); } .lb-rank.g2 { background: var(--cobalt); color: #fff; } .lb-rank.g3 { background: var(--cobalt-soft); color: var(--cobalt); }
  .lb-t { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lb-pct { font-family: var(--mono); font-weight: 700; text-align: right; }
  .lb-n { font-size: 12px; color: var(--muted); text-align: right; }
  .weak { display: grid; gap: 10px; }
  .weak-it { border: 1px solid var(--line); border-radius: 16px; padding: 12px 14px; display: grid; gap: 8px; background: var(--card); }
  .weak-it .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .hist { display: grid; }
  .hist button { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 10px; padding: 12px 4px; border: 0; border-bottom: 1px solid var(--line); background: transparent; text-align: left; }
  .hist button:hover .ht { text-decoration: underline; }
  .scores-grid { display: grid; grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr); gap: 18px; align-items: start; }
  .scores-grid > * { min-width: 0; }
  @media (max-width: 980px) { .scores-grid { grid-template-columns: minmax(0, 1fr); } }
  @media (max-width: 600px) { .lb-row { grid-template-columns: 30px minmax(0, 1fr) 48px; } .lb-row .bar, .lb-row .lb-n { display: none; } }`;
  document.head.appendChild(css);

  // ---------- helpers ----------
  const db = () => PB.db;
  const taskById = (id) => db().tasks.find((t) => t.id === id);
  const docById = (id) => db().docs.find((d) => d.id === id);
  const sectionText = (doc, heading) => {
    if (!doc) return "";
    if (!heading) return doc.body || "";
    const lines = (doc.body || "").split("\n");
    const i = lines.findIndex((l) => l.replace(/^##\s+/, "").trim() === heading.trim());
    if (i < 0) return doc.body || "";
    const j = lines.findIndex((l, k) => k > i && /^##\s/.test(l));
    return lines.slice(i, j < 0 ? undefined : j).join("\n");
  };
  const materialFor = (t) => (t.refs || []).map((r) => {
    const d = docById(r.doc);
    return d ? `### ${d.title}${r.heading ? " › " + r.heading : ""}\n${sectionText(d, r.heading)}` : "";
  }).join("\n\n").slice(0, 40000);
  const pct = (a, b) => (b ? Math.round((100 * a) / b) : 0);

  async function call(body) {
    if (body.mode === "quiz") return window.PBAI.quiz(body.topic, body.material);
    if (body.mode === "videos") return window.PBAI.videos(body.topic, body.context);
    return window.PBCloud.invoke(body);
  }

  // ---------- videos ----------
  function videoStrip(t) {
    if (!(t.videos || []).length) return "";
    return `<div class="vids">${t.videos.map((v) => `<button class="vid" data-play-video="${esc(v.id)}" data-task="${esc(t.id)}" title="${esc(v.why || v.title)}">
      <span class="th" style="background-image:url(https://i.ytimg.com/vi/${esc(v.id)}/mqdefault.jpg)"></span>
      <span class="vt">${esc(v.title)}</span><span class="vc">${esc(v.channel || "YouTube")}</span></button>`).join("")}</div>`;
  }

  async function findVideos(taskId, btn) {
    const t = taskById(taskId); if (!t) return;
    btn && (btn.disabled = true, btn.textContent = "Searching YouTube…");
    try {
      const topic = t.title + ((t.refs || []).length ? " — " + t.refs.map((r) => r.heading || docById(r.doc)?.title || "").filter(Boolean).join(", ") : "");
      const role = db().roles.find((r) => r.id === t.roleId);
      const res = await call({ mode: "videos", topic, context: role ? `${role.company} ${role.title} interview prep` : "interview prep" });
      t.videos = res.videos || [];
      PB.save(); PB.render();
      PB.toast(t.videos.length ? `Found ${t.videos.length} videos` : "No good videos found. Try again later.");
    } catch (e) { PB.toast(e.message); if (btn) { btn.disabled = false; btn.textContent = "Find videos"; } }
  }

  function playVideo(id, taskId) {
    const t = taskById(taskId);
    const v = t?.videos?.find((x) => x.id === id) || { id, title: "Video" };
    let dlg = $("#videoDialog");
    if (!dlg) {
      dlg = document.createElement("dialog"); dlg.id = "videoDialog"; dlg.className = "vp";
      dlg.addEventListener("click", (e) => { if (e.target === dlg || e.target.closest("[data-close]")) dlg.close(); });
      dlg.addEventListener("close", () => { dlg.innerHTML = ""; });
      document.body.appendChild(dlg);
    }
    // YouTube's embed refuses to play without a referrer (error 153), so send our origin.
    const origin = location.origin.startsWith("http") ? `&origin=${encodeURIComponent(location.origin)}` : "";
    dlg.innerHTML = `<iframe src="https://www.youtube-nocookie.com/embed/${encodeURIComponent(v.id)}?autoplay=1&rel=0&playsinline=1${origin}" title="${esc(v.title)}"
        referrerpolicy="strict-origin-when-cross-origin"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen; web-share" allowfullscreen></iframe>
      <div class="meta"><div style="display:flex;gap:10px;align-items:start"><div style="flex:1;min-width:0"><b>${esc(v.title)}</b><div class="muted" style="font-size:13px">${esc(v.channel || "")}</div></div>
        <a class="btn-ghost" target="_blank" rel="noopener" href="https://www.youtube.com/watch?v=${encodeURIComponent(v.id)}">YouTube ↗</a>
        <button class="icon-btn sm" data-close aria-label="Close">✕</button></div>
        ${v.why ? `<div style="font-size:14px;color:var(--ink-2)">${esc(v.why)}</div>` : ""}
        <div class="muted" style="font-size:12px">If the video says it can't play here (some channels block embedding), use “YouTube ↗”.</div></div>`;
    dlg.showModal();
  }

  // ---------- quiz ----------
  let qz = null; // { taskId, topic, questions, i, answers[], phase: 'loading'|'q'|'done'|'review', attempt }
  function quizDialog() {
    let dlg = $("#quizDialog");
    if (!dlg) {
      dlg = document.createElement("dialog"); dlg.id = "quizDialog"; dlg.className = "qz";
      dlg.addEventListener("click", onQuizClick);
      document.body.appendChild(dlg);
    }
    return dlg;
  }

  async function startQuiz(taskId) {
    const t = taskById(taskId); if (!t) return;
    const topic = t.title;
    qz = { taskId, roleId: t.roleId, topic, questions: [], i: 0, answers: [], phase: "loading" };
    paintQuiz(); quizDialog().showModal();
    try {
      const res = await call({ mode: "quiz", topic, material: materialFor(t), count: 6 });
      if (!qz || qz.taskId !== taskId) return;
      qz.questions = res.quiz?.questions || [];
      qz.source = res.source || "cloud";
      if (!qz.questions.length) throw new Error("No questions came back. Try again.");
      qz.phase = "q";
    } catch (e) { qz.phase = "error"; qz.error = e.message; }
    paintQuiz();
  }

  function paintQuiz() {
    const dlg = quizDialog();
    if (!qz) return;
    const n = qz.questions.length;
    let body = "", foot = "";
    if (qz.phase === "loading") {
      body = `<div class="qz-score"><div class="np-typing" style="justify-self:center"><i></i>${window.PBAI?.usingClaudeCode ? "Your Claude Code is writing your quiz…" : "Claude is writing your quiz…"}</div><div class="muted" style="font-size:13px">Based on: ${esc(qz.topic)}</div></div>`;
    } else if (qz.phase === "error") {
      body = `<div class="auth-msg err">${esc(qz.error)}</div>`;
      foot = `<button class="btn-ghost" data-qz="close">Close</button><button class="btn-primary" data-qz="retry">Try again</button>`;
    } else if (qz.phase === "q") {
      const q = qz.questions[qz.i], chosen = qz.answers[qz.i];
      const answered = chosen !== undefined;
      body = `<div class="qz-prog"><i style="width:${pct(qz.i + (answered ? 1 : 0), n)}%"></i></div>
        <div class="label">Question ${qz.i + 1} of ${n}${q.topic ? " · " + esc(q.topic) : ""}</div>
        <div class="qz-q">${esc(q.question)}</div>
        ${q.options.map((o, k) => `<button class="qz-opt ${answered && k === q.answer ? "right" : ""} ${answered && k === chosen && k !== q.answer ? "wrong" : ""}" data-choose="${k}" ${answered ? "disabled" : ""}><b>${"ABCD"[k]}</b><span>${esc(o)}</span></button>`).join("")}
        ${answered ? `<div class="qz-expl"><b>${chosen === q.answer ? "Correct." : `Answer: ${"ABCD"[q.answer]}.`}</b> ${esc(q.explanation)}</div>` : ""}`;
      foot = answered ? `<button class="btn-primary" data-qz="next">${qz.i + 1 < n ? "Next question" : "See results"}</button>` : `<span class="muted" style="font-size:12px;margin-right:auto">Pick an answer</span>`;
    } else if (qz.phase === "done" || qz.phase === "review") {
      const a = qz.attempt;
      const p = pct(a.score, a.total);
      const ring = `conic-gradient(var(--cobalt) ${p * 3.6}deg, var(--surface) 0)`;
      body = `<div class="qz-score">
          <div class="qz-ring" style="background:${ring}"><span style="background:var(--card);width:96px;height:96px;border-radius:50%;display:grid;place-items:center">${p}%</span></div>
          <b style="font-size:18px">${a.score} of ${a.total} correct</b>
          <div class="muted" style="font-size:13px">${esc(a.topic)}</div>
        </div>
        ${a.weak_topics.length ? `<div><div class="label" style="margin-bottom:6px">Learn more</div><div style="display:flex;gap:6px;flex-wrap:wrap">${a.weak_topics.map((w) => `<span class="pchip p-catch">${esc(w)}</span>`).join("")}</div></div>` : `<div class="auth-msg ok">Solid. Nothing flagged to revisit.</div>`}
        <div class="label">Answers</div>
        <div class="qz-review">${a.items.map((it, k) => `<div class="it">
          <div><b>${k + 1}.</b> ${esc(it.question)}</div>
          <div class="${it.chosen === it.answer ? "ok" : "no"}">${it.chosen === it.answer ? "✓ Your answer: " : "✗ Your answer: "}${esc(it.options[it.chosen] ?? "—")}</div>
          ${it.chosen !== it.answer ? `<div class="ok">Correct: ${esc(it.options[it.answer])}</div>` : ""}
          <div class="muted">${esc(it.explanation)}</div></div>`).join("")}</div>`;
      foot = `<button class="btn-ghost" data-qz="close">Close</button>${a.session_id ? `<button class="btn-ghost" data-qz="retake">Retake</button>` : ""}<button class="btn-primary" data-qz="scores">Open Scores</button>`;
    }
    dlg.innerHTML = `<div class="qz-head"><span class="kind k-mock">Quiz</span><b style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(qz.topic)}</b><button class="icon-btn sm" data-qz="close" aria-label="Close">✕</button></div>
      <div class="qz-body">${body}</div>${foot ? `<div class="qz-foot">${foot}</div>` : ""}`;
  }

  function finishQuiz() {
    const items = qz.questions.map((q, k) => ({ question: q.question, options: q.options, answer: q.answer, chosen: qz.answers[k], explanation: q.explanation, topic: q.topic || qz.topic }));
    const score = items.filter((it) => it.chosen === it.answer).length;
    const weak = [...new Set(items.filter((it) => it.chosen !== it.answer).map((it) => it.topic))];
    const attempt = { id: PB.uid("quiz"), role_id: qz.roleId || "", session_id: qz.taskId || "", topic: qz.topic, score, total: items.length,
      items, weak_topics: weak, source: qz.source || "cloud", created_at: new Date().toISOString() };
    (db().quizzes ||= []).push(attempt);
    PB.save();
    qz.attempt = attempt; qz.phase = "done";
    paintQuiz();
  }

  function onQuizClick(e) {
    const dlg = quizDialog();
    if (e.target === dlg) return;
    const ch = e.target.closest("[data-choose]");
    if (ch && qz?.phase === "q") { qz.answers[qz.i] = +ch.dataset.choose; paintQuiz(); return; }
    const act = e.target.closest("[data-qz]")?.dataset.qz;
    if (!act) return;
    if (act === "close") { dlg.close(); qz = null; PB.render(); }
    else if (act === "next") { if (qz.i + 1 < qz.questions.length) { qz.i++; paintQuiz(); } else finishQuiz(); }
    else if (act === "retry" || act === "retake") { const id = qz.taskId; startQuiz(id); }
    else if (act === "scores") { dlg.close(); qz = null; PB.go("scores"); }
  }

  function reviewAttempt(id) {
    const a = (db().quizzes || []).find((q) => q.id === id); if (!a) return;
    qz = { taskId: a.session_id, roleId: a.role_id, topic: a.topic, questions: [], attempt: a, phase: "review" };
    paintQuiz(); quizDialog().showModal();
  }

  // ---------- Scores (leaderboard) ----------
  function viewScores() {
    const quizzes = [...(db().quizzes || [])].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    const topics = {};
    for (const a of quizzes) for (const it of a.items || []) {
      const k = (it.topic || a.topic || "General").trim();
      const t = (topics[k] ||= { topic: k, right: 0, total: 0, last: a.created_at });
      t.total++; if (it.chosen === it.answer) t.right++;
    }
    const board = Object.values(topics).map((t) => ({ ...t, p: pct(t.right, t.total) })).sort((a, b) => b.p - a.p || b.total - a.total);
    const weak = board.filter((t) => t.p < 70).sort((a, b) => a.p - b.p).slice(0, 6);
    const answered = board.reduce((n, t) => n + t.total, 0), right = board.reduce((n, t) => n + t.right, 0);
    const findDocSection = (topic) => {
      const words = topic.toLowerCase().split(/\W+/).filter((w) => w.length > 3);
      for (const d of db().docs) for (const m of (d.body || "").matchAll(/^##\s+(.+)$/gm)) {
        const h = m[1].toLowerCase();
        if (words.some((w) => h.includes(w))) return { doc: d, heading: m[1] };
      }
      return null;
    };
    const sessionFor = (topic) => {
      const words = topic.toLowerCase().split(/\W+/).filter((w) => w.length > 3);
      return db().tasks.find((t) => t.kind !== "break" && words.some((w) => t.title.toLowerCase().includes(w)));
    };
    if (!quizzes.length) {
      return `<div class="stack"><div class="page-head"><div><div class="label">Leaderboard</div><h1 class="h-display">Scores</h1></div></div>
        <div class="card empty" style="padding:60px 20px"><div style="font-size:18px;font-weight:600;color:var(--ink);margin-bottom:6px">No quizzes yet</div>
        Open any session on the timeline and tap <b>Quiz me</b>. Claude writes questions from that session's study guides, then your results land here.
        <div style="margin-top:16px"><button class="btn-primary" data-view-in="timeline">Go to timeline</button></div></div></div>`;
    }
    return `<div class="stack">
      <div class="page-head"><div><div class="label">Leaderboard</div><h1 class="h-display">Scores</h1></div></div>
      <div class="stats">
        <div class="stat"><div class="label">Quizzes taken</div><b>${quizzes.length}</b></div>
        <div class="stat"><div class="label">Accuracy</div><b>${pct(right, answered)}%</b><span class="bar" style="margin-top:8px"><i style="width:${pct(right, answered)}%"></i></span></div>
        <div class="stat"><div class="label">Questions answered</div><b>${answered}</b></div>
        <div class="stat ${weak.length ? "warn" : ""}"><div class="label">Topics to revisit</div><b>${weak.length}</b></div>
      </div>
      <div class="scores-grid">
        <div class="card">
          <div class="card-head"><h3>Topic leaderboard</h3><span class="muted" style="font-size:13px">Ranked by how often you get them right</span></div>
          ${board.map((t, i) => `<div class="lb-row"><span class="lb-rank ${i < 3 ? "g" + (i + 1) : ""}">${i + 1}</span>
            <span class="lb-t" title="${esc(t.topic)}">${esc(t.topic)}</span><span class="bar"><i style="width:${t.p}%;${t.p < 70 ? "background:#c2410c" : ""}"></i></span>
            <span class="lb-pct">${t.p}%</span><span class="lb-n">${t.right}/${t.total}</span></div>`).join("")}
        </div>
        <div class="stack" style="align-content:start">
          <div class="card">
            <div class="card-head"><h3>Learn more</h3><span class="count">${weak.length}</span></div>
            <div class="weak">${weak.map((w) => {
              const sec = findDocSection(w.topic), s = sessionFor(w.topic);
              return `<div class="weak-it"><div class="row"><b style="flex:1;min-width:0">${esc(w.topic)}</b><span class="pchip p-catch">${w.p}%</span></div>
                <div class="row">
                  ${sec ? `<button class="ref" data-open-ref="${esc(sec.doc.id)}" data-heading="${esc(sec.heading)}"><span class="n">${String(sec.doc.order ?? 0).padStart(2, "0")}</span><span class="l">${esc(sec.heading.replace(/[\u{1F300}-\u{1FAFF}⭐]/gu, "").replace(/\s*\(.*$/, ""))}</span></button>` : ""}
                  ${s ? `<button class="learn-btn" data-goto-session="${esc(s.id)}">Session</button>${(s.videos || []).length ? `<button class="learn-btn" data-play-video="${esc(s.videos[0].id)}" data-task="${esc(s.id)}">▶ Video</button>` : `<button class="learn-btn" data-videos-session="${esc(s.id)}">Find videos</button>`}<button class="learn-btn" data-quiz-session="${esc(s.id)}"><span class="dotq"></span>Quiz again</button>` : ""}
                </div></div>`;
            }).join("") || `<div class="auth-msg ok">Everything is at 70% or better. Keep it up.</div>`}</div>
          </div>
          <div class="card">
            <div class="card-head"><h3>History</h3></div>
            <div class="hist">${quizzes.slice(0, 20).map((a) => `<button data-review-quiz="${esc(a.id)}"><span><span class="ht" style="font-weight:600">${esc(a.topic)}</span>
              <span class="muted" style="display:block;font-size:12px">${esc(new Date(a.created_at).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }))}</span></span>
              <span class="lb-pct" style="align-self:center">${a.score}/${a.total}</span></button>`).join("")}</div>
          </div>
        </div>
      </div>
    </div>`;
  }

  // ---------- events ----------
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-quiz-session],[data-videos-session],[data-play-video],[data-review-quiz]");
    if (!b) return;
    if (b.dataset.quizSession) startQuiz(b.dataset.quizSession);
    else if (b.dataset.videosSession) findVideos(b.dataset.videosSession, b);
    else if (b.dataset.playVideo) playVideo(b.dataset.playVideo, b.dataset.task);
    else if (b.dataset.reviewQuiz) reviewAttempt(b.dataset.reviewQuiz);
  });

  window.PBLearn = { videoStrip, viewScores, startQuiz };
  PB.render();
})();
