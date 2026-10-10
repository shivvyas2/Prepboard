// Prepboard files: PDF documents (upload to private Supabase Storage, render with PDF.js) and PDF export of written docs.
(() => {
  "use strict";
  const PB = window.PB;
  const esc = PB.esc;
  const PDFJS = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174";
  const BUCKET = "pb-files";

  const css = document.createElement("style");
  css.textContent = `
  .pdf-view { display: grid; gap: 14px; justify-items: center; padding: 6px 0 30px; }
  .pdf-view canvas { width: 100%; max-width: 900px; height: auto; background: #fff; border-radius: 6px; box-shadow: 0 2px 10px rgba(43,36,16,.12); }
  .pdf-bar { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 14px; }
  .pdf-status { color: var(--muted); padding: 40px 0; text-align: center; }
  @media print {
    body * { visibility: hidden !important; }
    #printArea, #printArea * { visibility: visible !important; }
    #printArea { position: absolute; left: 0; top: 0; width: 100%; padding: 0 8mm; }
    #printArea pre, #printArea table { break-inside: avoid; }
    #printArea h2 { break-after: avoid; }
  }`;
  document.head.appendChild(css);

  let pdfjs = null;
  function loadPdfJs() {
    if (pdfjs) return pdfjs;
    pdfjs = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = `${PDFJS}/pdf.min.js`;
      s.onload = async () => {
        try {
          // Run the worker from a same-origin blob URL: cross-origin workers are blocked or stall in some browsers.
          const code = await (await fetch(`${PDFJS}/pdf.worker.min.js`)).text();
          window.pdfjsLib.GlobalWorkerOptions.workerSrc = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
          resolve(window.pdfjsLib);
        } catch (e) { pdfjs = null; reject(new Error("Couldn't load the PDF viewer. Check your connection.")); }
      };
      s.onerror = () => { pdfjs = null; reject(new Error("Couldn't load the PDF viewer. Check your connection.")); };
      document.head.appendChild(s);
    });
    return pdfjs;
  }

  const cache = new Map(); // doc id -> ArrayBuffer

  async function fetchPdf(doc) {
    if (cache.has(doc.id)) return cache.get(doc.id);
    const sb = window.PBCloud?.sb;
    if (!sb || !window.PBCloud.user) throw new Error("Sign in to view PDFs stored in your account.");
    const { data, error } = await sb.storage.from(BUCKET).download(doc.filePath);
    if (error) throw new Error(error.message || "Couldn't download the PDF.");
    const buf = await data.arrayBuffer();
    cache.set(doc.id, buf);
    return buf;
  }

  let renderToken = 0;
  async function renderPdf(el) {
    const token = ++renderToken;
    const doc = PB.db.docs.find((d) => d.id === el.dataset.doc);
    if (!doc) return;
    el.innerHTML = `<div class="pdf-status">Loading PDF…</div>`;
    try {
      const [lib, buf] = await Promise.all([loadPdfJs(), fetchPdf(doc)]);
      const pdf = await lib.getDocument({ data: buf.slice(0) }).promise;
      if (token !== renderToken) return;
      el.innerHTML = "";
      const width = Math.min(900, el.clientWidth || 800);
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      // Render pages lazily as they scroll into view.
      const io = new IntersectionObserver((entries) => {
        for (const e of entries) if (e.isIntersecting && !e.target.dataset.done) { e.target.dataset.done = "1"; drawPage(pdf, +e.target.dataset.page, e.target, width, dpr); }
      }, { rootMargin: "800px 0px" });
      for (let i = 1; i <= pdf.numPages; i++) {
        const c = document.createElement("canvas");
        c.dataset.page = i;
        c.setAttribute("aria-label", `Page ${i} of ${pdf.numPages}`);
        const page = i === 1 ? await pdf.getPage(1) : null;
        const ratio = page ? page.getViewport({ scale: 1 }).height / page.getViewport({ scale: 1 }).width : 1.294;
        c.style.aspectRatio = `1 / ${ratio}`;
        el.appendChild(c);
        io.observe(c);
      }
    } catch (e) {
      if (token === renderToken) el.innerHTML = `<div class="pdf-status">${esc(e.message)}</div>`;
    }
  }

  async function drawPage(pdf, n, canvas, width, dpr) {
    const page = await pdf.getPage(n);
    const base = page.getViewport({ scale: 1 });
    const vp = page.getViewport({ scale: (width / base.width) * dpr });
    canvas.width = Math.floor(vp.width);
    canvas.height = Math.floor(vp.height);
    canvas.style.aspectRatio = `${vp.width} / ${vp.height}`;
    await page.render({ canvasContext: canvas.getContext("2d"), viewport: vp }).promise;
  }

  async function uploadPdf(file, roleId) {
    const cloud = window.PBCloud;
    if (!cloud?.sb || !cloud.user) { PB.toast("Sign in to upload PDFs."); return; }
    if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) { PB.toast("Choose a PDF file."); return; }
    if (file.size > 25 * 1024 * 1024) { PB.toast("PDFs up to 25 MB are supported."); return; }
    const id = PB.uid("doc");
    const path = `${cloud.user.id}/${id}.pdf`;
    PB.toast("Uploading PDF…");
    const { error } = await cloud.sb.storage.from(BUCKET).upload(path, file, { contentType: "application/pdf", upsert: true });
    if (error) { PB.toast("Upload failed: " + error.message); return; }
    cache.set(id, await file.arrayBuffer());
    PB.db.docs.unshift({ id, roleId: roleId || "", title: file.name.replace(/\.pdf$/i, ""), body: "", tags: ["pdf"], order: 950,
      updatedAt: new Date().toISOString(), fileType: "pdf", filePath: path });
    PB.save();
    PB.go("docs", { docId: id, docMode: "read", docFilter: "all" });
  }

  async function deleteStoredFile(doc) {
    if (doc?.fileType === "pdf" && doc.filePath && window.PBCloud?.sb) await window.PBCloud.sb.storage.from(BUCKET).remove([doc.filePath]);
  }

  function exportPdf() {
    const prose = document.getElementById("prose");
    const title = document.querySelector(".title-input")?.value || "Document";
    if (!prose) { PB.toast("Switch to Read to export."); return; }
    let area = document.getElementById("printArea");
    if (!area) { area = document.createElement("div"); area.id = "printArea"; document.body.appendChild(area); }
    area.innerHTML = `<h1 style="font-size:28px;letter-spacing:-.02em">${esc(title)}</h1>` + prose.innerHTML;
    area.className = "prose";
    const prev = document.title; document.title = title;
    window.print();
    document.title = prev;
    setTimeout(() => (area.innerHTML = ""), 500);
  }

  // Wire into the app: render after each view render; handle buttons.
  (PB.afterRender ||= []).push(() => { const el = document.getElementById("pdfView"); if (el) renderPdf(el); });
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-upload-pdf],[data-export-pdf]");
    if (!b) return;
    if (b.dataset.exportPdf !== undefined) return exportPdf();
    const input = document.createElement("input");
    input.type = "file"; input.accept = "application/pdf,.pdf";
    input.onchange = () => input.files[0] && uploadPdf(input.files[0], b.dataset.uploadPdf);
    input.click();
  });
  window.PBFiles = { deleteStoredFile };
  PB.render();
})();
