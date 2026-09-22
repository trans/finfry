// The stage: the same server-rendered pages, as panes on a ring.
//
// Three panes are visible — a focal one at full size, its two neighbours
// beside it — the rest are parked on the rails. A pane loads its page as a
// fragment (the server drops the layout when asked with X-Finfry-Fragment),
// and links and forms inside a pane stay inside the stage: a link to another
// view opens that view's pane *beside* the one you're in, a form posts and
// the pane shows the result. The plain pages are untouched and one click away.
(() => {
  const VIEWS = [
    { id: "overview",  title: "Overview",        path: "/" },
    { id: "register",  title: "Register",        path: "/register" },
    { id: "ledger",    title: "General ledger",  path: "/ledger" },
    { id: "balances",  title: "Balances",        path: "/balances" },
    { id: "income",    title: "Income statement", path: "/income" },
    { id: "balance-sheet", title: "Balance sheet", path: "/balance-sheet" },
    { id: "daily",     title: "Daily cost",      path: "/daily" },
    { id: "accounts",  title: "Accounts",        path: "/accounts" },
    { id: "budgets",   title: "Budgets",         path: "/budgets" },
    { id: "recurring", title: "Recurring",       path: "/recurring" },
    { id: "due",       title: "Due",             path: "/due" },
    { id: "reconcile", title: "Reconcile",       path: "/reconcile" },
    { id: "history",   title: "History",         path: "/history" },
    { id: "record",    title: "Record",          path: "/record" },
    { id: "assistant", title: "Assistant",       path: null },
  ];
  // The opening arrangement: reconcile | register | assistant.
  const INITIAL = { order: ["reconcile", "register", "assistant"], focal: "register" };

  const stage  = document.querySelector("[data-stage]");
  const slots  = { left: stage.querySelector("[data-slot=left]"), focal: stage.querySelector("[data-slot=focal]"), right: stage.querySelector("[data-slot=right]") };
  const rails  = { left: stage.querySelector("[data-rail=left]"), right: stage.querySelector("[data-rail=right]") };
  const holder = stage.querySelector("[data-holder]");


  // ---- panes -------------------------------------------------------------
  const panes = new Map();
  for (const v of VIEWS) panes.set(v.id, makePane(v));

  function makePane(view) {
    const el = document.createElement("section");
    el.className = "pane";
    el.dataset.pane = view.id;
    el.innerHTML = `
      <div class="pane-bar">
        <span class="pane-title">${view.title}<small data-subtitle></small></span>
        <span class="spacer"></span>
        <button type="button" data-act="reload" title="Reload">↻</button>
        <button type="button" data-act="park" title="Park on the rail">▁</button>
      </div>
      <div class="pane-body" data-body></div>`;
    const pane = { ...view, el, body: el.querySelector("[data-body]"), url: view.path, loaded: false };
    el.querySelector("[data-act=reload]").addEventListener("click", (e) => { e.stopPropagation(); load(pane, pane.url); });
    el.querySelector("[data-act=park]").addEventListener("click", (e) => { e.stopPropagation(); park(pane.id); });
    el.querySelector(".pane-bar").addEventListener("click", () => { if (slotOf(pane) !== "focal") focus(pane.id); });
    if (view.id === "assistant") {
      pane.body.innerHTML = `<div class="fragment"><header class="page-head"><h1>Assistant</h1>
        <p class="sub">Not wired yet. When it is, it sees what you see: the panes on the stage and the row you've selected. It proposes; you approve. Its cards land in the strip below, and it can point at things.</p></header>
        <p class="empty">Ask it something in the bar at the bottom — soon.</p></div>`;
      pane.loaded = true;
    }
    holder.appendChild(el);
    return pane;
  }

  // ---- the ring --------------------------------------------------------
  // ring: ordered ids; focalIndex into it. Parked panes are not in the ring.
  let ring = INITIAL.order.slice();
  let focalIndex = ring.indexOf(INITIAL.focal);
  const idx = (offset) => ((focalIndex + offset) % ring.length + ring.length) % ring.length;
  const at  = (offset) => panes.get(ring[idx(offset)]);
  function slotOf(pane) {
    for (const k of Object.keys(slots)) if (slots[k].firstElementChild === pane.el) return k;
    return null;
  }

  function render() {
    const wanted = { left: ring.length > 1 ? at(-1) : null, focal: at(0), right: ring.length > 2 ? at(+1) : null };
    if (ring.length === 2) wanted.left = null; // two panes: focal + right
    for (const [k, slot] of Object.entries(slots)) {
      const pane = wanted[k];
      if (pane) {
        if (slot.firstElementChild !== pane.el) { slot.replaceChildren(pane.el); }
        if (!pane.loaded) load(pane, pane.url);
      } else if (slot.firstElementChild) {
        holder.appendChild(slot.firstElementChild);
      }
    }
    for (const pane of panes.values()) {
      if (!Object.values(wanted).includes(pane) && pane.el.parentElement !== holder) holder.appendChild(pane.el);
    }
    renderRails(wanted);
  }

  function renderRails(wanted) {
    const visible = new Set(Object.values(wanted).filter(Boolean).map((p) => p.id));
    const parked = VIEWS.filter((v) => !visible.has(v.id));
    const half = Math.ceil(parked.length / 2);
    for (const [side, items] of [["left", parked.slice(0, half)], ["right", parked.slice(half)]]) {
      rails[side].replaceChildren(...items.map((v) => {
        const b = document.createElement("button");
        b.type = "button"; b.textContent = v.title; b.title = `Open ${v.title} here`;
        b.addEventListener("click", () => show(v.id, side));
        return b;
      }));
    }
  }

  // Bring a view to the focal slot (joining the ring beside the focal pane if parked).
  function focus(id) {
    if (!ring.includes(id)) ring.splice(idx(+1), 0, id);
    focalIndex = ring.indexOf(id);
    render();
  }
  // Show a view in a side slot without stealing focus — the "beside you" move.
  function show(id, side = "right") {
    const offset = side === "left" ? -1 : +1;
    if (ring.includes(id)) {
      if (ring[idx(0)] === id) return;                       // already focal
      if (ring[idx(offset)] === id) return;                  // already there
      // swap it into that neighbour slot
      const i = ring.indexOf(id), j = idx(offset);
      [ring[i], ring[j]] = [ring[j], ring[i]];
    } else {
      ring.splice(offset > 0 ? idx(0) + 1 : idx(0), 0, id);
      if (offset < 0) focalIndex++;
    }
    render();
  }
  function park(id) {
    if (ring.length <= 1) return;
    const i = ring.indexOf(id);
    if (i === -1) return;
    ring.splice(i, 1);
    if (i < focalIndex || focalIndex >= ring.length) focalIndex = Math.max(0, focalIndex - 1);
    render();
  }
  function rotate(dir) { focalIndex = idx(dir); render(); }

  // ---- loading fragments ------------------------------------------------
  async function load(pane, url, { method = "GET", body = null } = {}) {
    if (!url) return;
    pane.body.classList.add("loading");
    try {
      const res = await fetch(url, { method, body, headers: { "X-Finfry-Fragment": "1" }, credentials: "same-origin" });
      const html = await res.text();
      // A POST redirected to a page: that page's view is where the result belongs.
      const landed = new URL(res.url, location.href);
      const target = viewFor(landed.pathname) || pane;
      target.body.innerHTML = html;
      target.url = landed.pathname + landed.search;
      target.loaded = true;
      const frag = target.body.querySelector(".fragment");
      const h1 = frag && frag.querySelector("h1");
      const sub = target.el.querySelector("[data-subtitle]");
      sub.textContent = h1 && h1.querySelector(".muted") ? h1.querySelector(".muted").textContent : "";
      wire(target);
      if (window.finfryInit) window.finfryInit(target.body);
      if (target !== pane && !isVisible(target)) show(target.id, slotOf(pane) === "left" ? "left" : "right");
    } catch (err) {
      pane.body.innerHTML = `<p class="empty">Couldn't load: ${err.message}</p>`;
    } finally {
      pane.body.classList.remove("loading");
    }
  }
  const isVisible = (pane) => slotOf(pane) !== null;

  // Which view a path belongs to.
  function viewFor(pathname) {
    const exact = VIEWS.find((v) => v.path === pathname);
    if (exact) return panes.get(exact.id);
    return null;
  }

  // Links open their view beside you; forms post and show where they land.
  function wire(pane) {
    pane.body.querySelectorAll("a[href]").forEach((a) => {
      const url = new URL(a.getAttribute("href"), location.href);
      if (url.origin !== location.origin) return;
      a.addEventListener("click", (e) => {
        const target = viewFor(url.pathname);
        if (!target) return; // not a stage view (e.g. /stage, external) — let it navigate
        e.preventDefault();
        if (target === pane) { load(pane, url.pathname + url.search); return; }
        load(target, url.pathname + url.search);
        if (!isVisible(target)) show(target.id, slotOf(pane) === "left" ? "left" : "right");
      });
    });
    pane.body.querySelectorAll("form").forEach((form) => {
      form.addEventListener("submit", (e) => {
        if (form.dataset.autosave !== undefined && e.submitter && e.submitter.classList.contains("nojs-only")) { /* plain save */ }
        e.preventDefault();
        const method = (form.getAttribute("method") || "get").toUpperCase();
        const action = new URL(form.getAttribute("action") || pane.url, location.href);
        const data = new FormData(form, e.submitter);
        if (method === "GET") {
          const q = new URLSearchParams(data).toString();
          load(pane, action.pathname + (q ? "?" + q : ""));
        } else {
          load(pane, action.pathname + action.search, { method, body: new URLSearchParams(data) });
        }
      });
    });
  }

  // ---- keys & wheel ---------------------------------------------------------
  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input, textarea, select")) return;
    if (e.key === "ArrowLeft" && e.altKey) rotate(-1);
    if (e.key === "ArrowRight" && e.altKey) rotate(+1);
  });
  stage.addEventListener("wheel", (e) => {
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY) && Math.abs(e.deltaX) > 40) { e.preventDefault(); rotate(e.deltaX > 0 ? 1 : -1); }
  }, { passive: false });

  render();
  window.finfryStage = { focus, show, park, rotate, panes, get ring() { return ring.slice(); } };
})();
