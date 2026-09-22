// Progressive enhancement only. Everything here has a plain-form fallback;
// this just saves a single row's decision the moment it changes, so working
// through a statement or a due queue doesn't reload the page per click.
//
// `finfryInit(root)` wires the behaviours inside `root`; the plain pages call
// it once for the document, the stage once per pane load.
document.documentElement.classList.add("js");

window.finfryInit = function finfryInit(root) {
root.querySelectorAll("form[data-autosave]").forEach((form) => {
  form.addEventListener("change", async (event) => {
    const el = event.target;
    if (el.form !== form) return; // an input that belongs to another form (the due "adjust" editors)
    const row = el.closest("tr");
    if (!row) return;

    const body = new URLSearchParams();
    form.querySelectorAll("input[data-ctx]").forEach((i) => body.append(i.name, i.value));
    row.querySelectorAll("input, select").forEach((i) => {
      if (i.form !== form) return;
      if (i.type === "checkbox" && !i.checked) return;
      body.append(i.name, i.value);
    });

    row.classList.add("saving");
    try {
      const res = await fetch(form.action, {
        method: "POST",
        headers: { "Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded" },
        body,
      });
      const data = await res.json();
      if (!data.ok) throw new Error(data.message || "not saved");
      apply(form, data);
      if (el.tagName === "SELECT") el.className = "decision " + el.value;
      if (el.type === "checkbox") row.classList.toggle("cleared", el.checked);
      note(el, "saved");
    } catch (err) {
      // Fall back to the plain form so nothing is silently lost.
      alert("Couldn't save: " + err.message);
      location.reload();
    } finally {
      row.classList.remove("saving");
    }
  });
});

// Update any [data-field] the server reported a fresh value for.
function apply(scope, data) {
  document.querySelectorAll("[data-field]").forEach((el) => {
    const key = el.dataset.field;
    if (!(key in data) || data[key] === null) return;
    if (key === "verdict") return;
    const value = data[key];
    if (typeof value === "string" && (value.startsWith("$") || value.startsWith("-$"))) {
      if (el.classList.contains("num")) el.textContent = value;
      else el.innerHTML = `<span class="num${value.startsWith("-") ? " neg" : ""}">${value}</span>`;
    } else {
      el.textContent = value;
    }
  });
  const verdict = document.querySelector("[data-field=verdict]");
  if (verdict && "matches" in data) {
    verdict.dataset.matches = String(data.matches);
    const note = verdict.querySelector(".note");
    if (note) {
      note.innerHTML = data.matches
        ? '<span class="tick">✓</span> matches the cleared balance'
        : `<span class="warn">⚠</span> off by <span data-field="difference"><span class="num${String(data.difference).startsWith("-") ? " neg" : ""}">${data.difference}</span></span>`;
    }
  }
}

function note(el, text) {
  const old = el.parentElement.querySelector(".saved");
  if (old) old.remove();
  const s = document.createElement("span");
  s.className = "saved";
  s.textContent = text;
  el.parentElement.appendChild(s);
  setTimeout(() => s.remove(), 1800);
}

// The record form: a memo you've used before fills in the blanks from its
// last entry (never overwriting what you typed), and a line under the fields
// says what the entry will be — inferred from the accounts, exactly as the
// server infers it.
const record = root.querySelector("form[data-record]");
if (record) {
  const field = (name) => record.querySelector(`[name=${name}]`);
  const kindLine = record.querySelector("[data-kind]");
  const submit = record.querySelector("[data-submit]");

  function describe() {
    const to = field("to").value.trim(), from = field("from").value.trim();
    const amount = field("amount").value.trim();
    let kind = "", verb = "Record";
    if (!to || !from) { kindLine.textContent = ""; submit.textContent = verb; return; }
    if (to.startsWith("Expenses")) { kind = "Expense"; verb = "Record expense"; }
    else if (from.startsWith("Income")) { kind = "Income"; verb = "Record income"; }
    else { kind = "Transfer"; verb = "Record transfer"; }
    const money = amount ? ` of $${amount.replace(/^\$/, "")}` : "";
    kindLine.textContent = `${kind}${money} from ${from} to ${to}`;
    submit.textContent = verb;
  }

  let recalled = null;
  async function recall() {
    const memo = field("memo").value.trim();
    if (!memo || memo.toLowerCase() === recalled) return;
    recalled = memo.toLowerCase();
    try {
      const res = await fetch(`/api/recall?memo=${encodeURIComponent(memo)}`, { headers: { Accept: "application/json" } });
      const data = await res.json();
      if (!data.to) return;
      for (const name of ["amount", "to", "from", "recurrence"]) {
        const el = field(name);
        const untouched = !el.value || el.dataset.filled === el.value || (name === "from" && el.value === el.defaultValue);
        if (untouched && data[name]) { el.value = data[name]; el.dataset.filled = data[name]; }
      }
      describe();
    } catch (_) { /* recall is a convenience; the form works without it */ }
  }

  field("memo").addEventListener("change", recall);
  field("memo").addEventListener("blur", recall);
  ["to", "from", "amount"].forEach((n) => field(n).addEventListener("input", describe));
  describe();
}
};

window.finfryInit(document);
