// Dev notes — served only under `finfry serve --dev`.
//
// Press the ✎ button (or Alt+N) to enter pick mode, click any element — a
// button or input is picked, not triggered — and describe what's wrong with
// it. The note lands in the notes file with the page, the view (which maps to
// its template), a CSS path to the element, its text, and its table context,
// so the reader can find the exact spot without a description of it.
(() => {
  const NOTE_URL = "/dev/note";
  let picking = false;
  let hovered = null;

  // --- chrome -----------------------------------------------------------
  const style = document.createElement("style");
  style.textContent = `
    .dev-btn { position: fixed; right: 18px; bottom: 18px; z-index: 900; font: 600 13px system-ui, sans-serif;
      background: #24476b; color: #fff; border: 0; border-radius: 20px; padding: 8px 14px; cursor: pointer;
      box-shadow: 0 2px 8px rgba(0,0,0,.25); }
    .dev-btn.on { background: #b3382c; }
    body.dev-picking, body.dev-picking * { cursor: crosshair !important; }
    .dev-hover { outline: 2px solid #b3382c !important; outline-offset: 1px; background: rgba(179,56,44,.08) !important; }
    dialog.dev-dialog { border: 1px solid #8ba488; border-radius: 8px; padding: 18px 20px; width: min(640px, 92vw);
      font: 14px system-ui, sans-serif; color: #1b2620; background: #f6f9f3; }
    dialog.dev-dialog::backdrop { background: rgba(27,38,32,.35); }
    .dev-dialog h3 { margin: 0 0 10px; font: 500 18px "Iowan Old Style", Palatino, Georgia, serif; }
    .dev-dialog .meta { font: 12px ui-monospace, Menlo, monospace; background: #e2eadc; padding: 8px 10px; border-radius: 4px;
      white-space: pre-wrap; word-break: break-all; margin-bottom: 10px; max-height: 160px; overflow: auto; }
    .dev-dialog textarea { width: 100%; min-height: 110px; font: inherit; padding: 8px; border: 1px solid #b9cab5; border-radius: 4px; box-sizing: border-box; }
    .dev-dialog .row { display: flex; gap: 8px; justify-content: flex-end; margin-top: 10px; }
    .dev-dialog button { font: inherit; padding: 6px 14px; border-radius: 4px; border: 1px solid #8ba488; background: #fff; cursor: pointer; }
    .dev-dialog button.primary { background: #24476b; border-color: #24476b; color: #fff; font-weight: 600; }
    .dev-toast { position: fixed; left: 50%; bottom: 64px; transform: translateX(-50%); background: #1b2620; color: #fff;
      padding: 8px 14px; border-radius: 6px; font: 13px system-ui, sans-serif; z-index: 901; opacity: 0; transition: opacity .2s; }
    .dev-toast.show { opacity: 1; }
  `;
  document.head.appendChild(style);

  const btn = document.createElement("button");
  btn.className = "dev-btn";
  btn.type = "button";
  btn.title = "Note a UI issue (Alt+N)";
  btn.textContent = "✎ Note";
  document.body.appendChild(btn);

  const toast = document.createElement("div");
  toast.className = "dev-toast";
  document.body.appendChild(toast);
  function say(text) {
    toast.textContent = text;
    toast.classList.add("show");
    setTimeout(() => toast.classList.remove("show"), 2200);
  }

  const dialog = document.createElement("dialog");
  dialog.className = "dev-dialog";
  dialog.innerHTML = `
    <h3>What's wrong here?</h3>
    <div class="meta" data-meta></div>
    <textarea placeholder="Describe the issue, or what you'd rather see." data-note></textarea>
    <div class="row"><button type="button" data-cancel>Cancel</button><button type="button" class="primary" data-save>Save note</button></div>`;
  document.body.appendChild(dialog);

  // --- pick mode --------------------------------------------------------
  function setPicking(on) {
    picking = on;
    document.body.classList.toggle("dev-picking", on);
    btn.classList.toggle("on", on);
    btn.textContent = on ? "✕ Cancel" : "✎ Note";
    if (!on && hovered) { hovered.classList.remove("dev-hover"); hovered = null; }
  }

  btn.addEventListener("click", () => setPicking(!picking));
  document.addEventListener("keydown", (e) => {
    if (e.altKey && (e.key === "n" || e.key === "N")) { e.preventDefault(); setPicking(!picking); }
    if (e.key === "Escape" && picking) setPicking(false);
  });

  document.addEventListener("mousemove", (e) => {
    if (!picking) return;
    const el = e.target;
    if (el === hovered || el === btn || btn.contains(el)) return;
    if (hovered) hovered.classList.remove("dev-hover");
    hovered = el;
    hovered.classList.add("dev-hover");
  }, true);

  // Capture phase, so a picked button/link/checkbox never fires.
  ["click", "mousedown", "mouseup"].forEach((type) => {
    document.addEventListener(type, (e) => {
      if (!picking || e.target === btn || btn.contains(e.target)) return;
      e.preventDefault();
      e.stopPropagation();
      if (type === "click") {
        const target = e.target;
        setPicking(false);
        open(describe(target));
      }
    }, true);
  });

  // --- describing the element -------------------------------------------
  function segment(el) {
    let s = el.tagName.toLowerCase();
    if (el.id) return `${s}#${el.id}`;
    const cls = [...el.classList].filter((c) => c !== "dev-hover").slice(0, 2);
    if (cls.length) s += "." + cls.join(".");
    const name = el.getAttribute("name");
    if (name) s += `[name=${name}]`;
    const field = el.dataset && el.dataset.field;
    if (field) s += `[data-field=${field}]`;
    const parent = el.parentElement;
    if (parent) {
      const siblings = [...parent.children].filter((c) => c.tagName === el.tagName);
      if (siblings.length > 1) s += `:nth-of-type(${siblings.indexOf(el) + 1})`;
    }
    return s;
  }

  function describe(el) {
    const path = [];
    for (let n = el; n && n.tagName !== "BODY"; n = n.parentElement) {
      path.unshift(segment(n));
      if (n.tagName === "MAIN" || n.tagName === "NAV") break;
    }
    const text = (el.innerText || el.value || el.getAttribute("placeholder") || el.getAttribute("aria-label") || "").trim().replace(/\s+/g, " ").slice(0, 120);
    const info = {
      page: location.pathname + location.search,
      view: (document.querySelector("main[data-view]") || {}).dataset?.view || "",
      path: path.join(" > "),
      tag: el.tagName.toLowerCase(),
      text,
      html: el.outerHTML.replace(/\s+/g, " ").slice(0, 300),
    };
    const cell = el.closest("td, th");
    if (cell) {
      const table = cell.closest("table");
      const idx = [...cell.parentElement.children].indexOf(cell);
      const header = table && table.tHead && table.tHead.rows[0] && table.tHead.rows[0].cells[idx];
      info.column = header ? header.innerText.trim() : "";
      const row = cell.parentElement;
      info.row = row.cells[0] ? row.cells[0].innerText.trim().slice(0, 60) : "";
      if (row.rowIndex) info.rowIndex = row.rowIndex;
    }
    const label = el.closest("label");
    if (label) info.label = label.innerText.trim().split("\n")[0].slice(0, 60);
    const section = el.closest("section, form, header, .card");
    const heading = section && section.querySelector("h1, h2, h3");
    if (heading) info.section = heading.innerText.trim().slice(0, 60);
    return info;
  }

  // --- the dialog -----------------------------------------------------
  let current = null;
  function open(info) {
    current = info;
    const lines = [`page:    ${info.page}`, `view:    ${info.view}`, `element: ${info.path}`];
    if (info.section) lines.push(`section: ${info.section}`);
    if (info.label) lines.push(`label:   ${info.label}`);
    if (info.column !== undefined) lines.push(`cell:    column "${info.column}", row ${info.rowIndex || "?"} (${info.row})`);
    if (info.text) lines.push(`text:    "${info.text}"`);
    dialog.querySelector("[data-meta]").textContent = lines.join("\n");
    const note = dialog.querySelector("[data-note]");
    note.value = "";
    dialog.showModal();
    note.focus();
  }
  dialog.querySelector("[data-cancel]").addEventListener("click", () => dialog.close());
  dialog.querySelector("[data-save]").addEventListener("click", save);
  dialog.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) save(); });

  async function save() {
    const note = dialog.querySelector("[data-note]").value.trim();
    if (!note) { dialog.querySelector("[data-note]").focus(); return; }
    try {
      const res = await fetch(NOTE_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...current, note }) });
      const data = await res.json();
      if (!data.ok) throw new Error(data.message || "not saved");
      dialog.close();
      say(`Noted → ${data.file}`);
    } catch (err) {
      say("Couldn't save: " + err.message);
    }
  }
})();
