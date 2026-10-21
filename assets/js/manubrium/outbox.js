// The phone's outbox: puts entries in the queue, sends them in order when
// the network allows, and shows what became of each one (docs/manubrium.md,
// "Offline and conflict rules"). Used by the result page's hook and, on its
// own, by the code-entry page `/m`, where a phone lands when its access
// ends - so what it had waiting is still in front of whoever holds it.
//
// Its words come from the page: `data-t-*` attributes on the outbox element,
// rendered through gettext, with `{n}` / `{board}` left for this file to
// fill in. Nothing here decides anything; the server answers every entry.
//
// Not covered by `mix test` (no browser there). Checked by hand: see the
// "untested" list in docs/manubrium.md.

import * as queue from "./queue";

const BATCH = 25; // the server's `Mobile.Sync.max_batch/0`
const RETRY_MS = 20000; // while anything waits, try again this often
const KEEP_SENT = 30; // sent entries kept on screen, newest first
const KEEP_SENT_MS = 12 * 3600 * 1000;

const isPending = (e) => e.status === "waiting" || e.status === "sending";

export class Outbox {
  // `root` is the #manubrium-outbox element. `opts`:
  //   badges(entries)   - redraw per-board marks (result page only)
  //   onSending(batch)  - a batch is about to go
  //   onSettled(saved)  - these entries were saved
  constructor(root, opts = {}) {
    this.root = root;
    this.opts = opts;
    this.list = root.querySelector("[data-mq-list]");
    this.flushing = false;
    this.problem = null;
    this.online = navigator.onLine !== false;

    this.onOnline = () => {
      this.online = true;
      this.flush();
    };
    this.onOffline = () => {
      this.online = false;
      this.render();
    };
    this.onClick = (e) => this.click(e);
    // Capture, so a Leave link is asked about before anything follows it.
    this.onLeave = (e) => this.leave(e);

    window.addEventListener("online", this.onOnline);
    window.addEventListener("offline", this.onOffline);
    root.addEventListener("click", this.onClick);
    document.addEventListener("click", this.onLeave, true);
    this.timer = setInterval(() => this.flush(), RETRY_MS);

    queue.persistent().then((ok) => {
      const note = root.querySelector("[data-mq-memory]");
      if (note) note.hidden = ok;
    });

    this.render().then(() => this.flush());
  }

  destroy() {
    window.removeEventListener("online", this.onOnline);
    window.removeEventListener("offline", this.onOffline);
    this.root.removeEventListener("click", this.onClick);
    document.removeEventListener("click", this.onLeave, true);
    clearInterval(this.timer);
  }

  t(key, vars = {}) {
    let text = this.root.dataset["t" + key] || key;
    for (const [k, v] of Object.entries(vars)) text = text.split(`{${k}}`).join(String(v));
    return text;
  }

  // A new entry from a tap. A second tap on a board whose first entry has
  // never been in a request replaces it; otherwise the new entry builds on
  // the previous one (its `expected` is what that one said), so the server
  // judges the chain in order.
  async add(entry) {
    const entries = await queue.all();

    if (entry.kind === "result") {
      const prev = entries.filter((e) => e.kind === "result" && e.pairing === entry.pairing && isPending(e)).pop();

      if (prev) {
        if (prev.result === entry.result) return;

        if (prev.status === "waiting" && !prev.tried) {
          await queue.remove(prev.cid);
          entry.expected = prev.expected;
        } else {
          entry.expected = prev.result;
        }
      }
    }

    await queue.put({
      ...entry,
      cid: queue.newId(),
      seq: queue.nextSeq(),
      at: new Date().toISOString(),
      status: "waiting",
      tried: false,
      message: "",
    });

    await this.render();
    this.flush();
  }

  async flush() {
    if (this.flushing) return;
    this.flushing = true;

    try {
      for (;;) {
        const pending = (await queue.all()).filter(isPending);
        if (pending.length === 0) break;

        const batch = slice(pending);
        for (const e of batch) {
          e.status = "sending";
          e.tried = true;
        }
        await queue.putAll(batch);
        this.render();
        if (this.opts.onSending) this.opts.onSending(batch);

        let answers;
        try {
          answers = await post(batch);
          this.online = true;
          this.problem = null;
        } catch (error) {
          // Nothing behind this batch goes first: it is sent again, whole.
          for (const e of batch) e.status = "waiting";
          await queue.putAll(batch);
          if (error.status) this.problem = error.status;
          else this.online = false;
          break;
        }

        const byCid = new Map(answers.map((a) => [a.cid, a]));
        const saved = [];
        let again = false;

        for (const e of batch) {
          const a = byCid.get(e.cid);

          if (!a || a.status === "retry") {
            e.status = "waiting";
            again = true;
          } else {
            e.status = a.status === "saved" ? "sent" : "refused";
            e.answeredAt = Date.now();
            // Answered either way: the photo has done its travelling, and a
            // phone is no place to keep pictures of other people's games.
            delete e.photo;
            if (e.status === "sent") saved.push(e);
          }
          if (a) e.message = a.message || "";
        }

        await queue.putAll(batch);
        if (saved.length && this.opts.onSettled) this.opts.onSettled(saved);
        if (again) break;
      }

      await prune();
    } finally {
      this.flushing = false;
      await this.render();
    }
  }

  async render() {
    const entries = await queue.all();
    const pending = entries.filter(isPending);
    const refused = entries.filter((e) => e.status === "refused");
    const sent = entries.filter((e) => e.status === "sent").reverse();

    for (const el of document.querySelectorAll("[data-mq-count]")) {
      let text, state;
      if (refused.length) [text, state] = [this.t("Refusedcount", {n: refused.length}), "refused"];
      else if (pending.length) [text, state] = [this.t("Waitingcount", {n: pending.length}), "waiting"];
      else [text, state] = [this.t("Allsent"), "sent"];
      // Empty when there is nothing to say: CSS hides an empty count, and
      // it stays in the accessibility tree so its next words are read out.
      if (entries.length === 0) text = "";
      if (el.textContent !== text) el.textContent = text;
      el.dataset.state = state;
    }

    const rows = [...refused, ...pending, ...sent];
    this.list.replaceChildren(...rows.map((e) => this.row(e)));
    this.root.hidden = rows.length === 0 && this.online && !this.problem;

    const show = (sel, on) => {
      const el = this.root.querySelector(sel);
      if (el) el.hidden = !on;
    };
    show("[data-mq-offline]", !this.online && pending.length > 0);
    show("[data-mq-dismiss-all]", refused.length > 1);

    const problem = this.root.querySelector("[data-mq-problem]");
    if (problem) {
      problem.hidden = !this.problem;
      problem.textContent = this.problem ? this.t("Problem", {status: this.problem}) : "";
    }

    if (this.opts.badges) this.opts.badges(entries);
  }

  row(e) {
    const li = document.createElement("li");
    li.className = "mq-row";
    li.dataset.state = e.status;

    const what = document.createElement("span");
    what.className = "mq-what";
    what.textContent = this.t("Board", {board: e.board}) + " · " + e.label;

    const state = document.createElement("span");
    state.className = "mq-state";
    state.textContent = this.t(e.status === "sending" ? "Sending" : e.status[0].toUpperCase() + e.status.slice(1));

    li.append(what, state);

    if (e.message && e.status !== "sent") {
      const msg = document.createElement("p");
      msg.className = "mq-msg";
      msg.textContent = e.message;
      li.append(msg);
    }

    if (e.status === "refused") {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "mq-dismiss";
      b.dataset.mqDismiss = e.cid;
      b.textContent = this.t("Dismiss");
      li.append(b);
    }

    return li;
  }

  async click(e) {
    const one = e.target.closest("[data-mq-dismiss]");
    const all = e.target.closest("[data-mq-dismiss-all]");
    if (!one && !all) return;

    if (one) await queue.remove(one.dataset.mqDismiss);
    if (all) for (const r of (await queue.all()).filter((x) => x.status === "refused")) await queue.remove(r.cid);
    this.render();
  }

  // Leaving drops the enrolment from this browser, so the queue goes with it
  // - after asking, if anything has not been answered yet - and the worker
  // forgets the cached page.
  leave(e) {
    const link = e.target.closest && e.target.closest("[data-mq-leave]");
    if (!link) return;

    e.preventDefault();
    e.stopPropagation();

    queue.all().then(async (entries) => {
      const pending = entries.filter(isPending).length;
      if (pending && !window.confirm(this.t("Leaveconfirm", {n: pending}))) return;

      await queue.clear();
      if (navigator.serviceWorker && navigator.serviceWorker.controller) {
        navigator.serviceWorker.controller.postMessage("manubrium:forget");
      }
      window.location.href = link.href;
    });
  }
}

// The next request's entries, in order: up to BATCH of them, but an entry
// with a photo travels alone - a few of those together would be more than
// the server reads in one request.
function slice(pending) {
  if (pending[0].photo) return [pending[0]];
  const batch = [];
  for (const e of pending) {
    if (e.photo || batch.length >= BATCH) break;
    batch.push(e);
  }
  return batch;
}

async function prune() {
  const now = Date.now();
  const sent = (await queue.all()).filter((e) => e.status === "sent").reverse();

  for (const [i, e] of sent.entries()) {
    if (i >= KEEP_SENT || now - (e.answeredAt || 0) > KEEP_SENT_MS) await queue.remove(e.cid);
  }
}

// What goes over the wire: the entry minus the phone's own bookkeeping.
function wire(e) {
  const fields = ["cid", "enrollment", "kind", "round", "pairing", "board", "white", "black", "result", "expected", "type", "note", "photo", "at"];
  return Object.fromEntries(fields.filter((f) => e[f] !== undefined).map((f) => [f, e[f]]));
}

async function post(batch) {
  const meta = document.querySelector("meta[name='csrf-token']");

  const response = await fetch("/m/sync", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "x-csrf-token": meta ? meta.content : "",
    },
    body: JSON.stringify({entries: batch.map(wire)}),
  });

  if (!response.ok) {
    const error = new Error("sync failed");
    error.status = response.status;
    throw error;
  }

  return (await response.json()).results || [];
}
