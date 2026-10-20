// The result page's half of Manubrium (docs/manubrium.md): turns taps on
// result buttons and the incident dialog into queued entries, and keeps a
// small mark on each board saying what the phone still has for it.
//
// The result buttons keep their `phx-click="set_result"`. This hook catches
// the click first (on the boards container, before LiveView's listener on
// the window) and stops it there, so with the hook running every result
// goes through the queue - online or not - and without it (a page whose
// script failed, a test) the button still works the old, direct way.
//
// Not covered by `mix test`; see the "untested" list in docs/manubrium.md.

import {Outbox} from "./outbox";

const num = (v) => (v === undefined || v === "" ? null : Number(v));

export const Manubrium = {
  mounted() {
    this.enrollment = num(this.el.dataset.enrollment);

    this.outbox = new Outbox(document.getElementById("manubrium-outbox"), {
      badges: (entries) => this.badges(entries),
      onSending: (batch) => this.push("manubrium_hold", batch),
      onSettled: (saved) => this.push("manubrium_settle", saved),
    });

    this.onClick = (e) => {
      const result = e.target.closest("[data-entry]");
      const incident = e.target.closest("[data-incident]");
      const target = result || incident;
      if (!target || !this.el.contains(target)) return;

      e.preventDefault();
      e.stopPropagation();
      if (target.disabled) return;

      if (result) this.tapResult(result);
      else this.openIncident(incident);
    };
    this.el.addEventListener("click", this.onClick);

    this.dialog = document.getElementById("manubrium-incident");
    if (this.dialog) {
      this.form = this.dialog.querySelector("form");
      this.onSubmit = (e) => {
        e.preventDefault();
        e.stopPropagation();
        this.saveIncident();
      };
      this.onCancel = (e) => {
        if (e.target.closest("[data-mq-cancel]")) this.dialog.close();
      };
      this.form.addEventListener("submit", this.onSubmit);
      this.dialog.addEventListener("click", this.onCancel);
    }

    // LiveView redraws boards as results come in; the marks live in
    // `phx-update="ignore"` spans, so only NEW boards need one drawn.
    this.entries = [];
    this.observer = new MutationObserver(() => this.drawBadges());
    this.observer.observe(this.el, {childList: true, subtree: true});
  },

  reconnected() {
    this.outbox.flush();
  },

  destroyed() {
    this.outbox.destroy();
    this.observer.disconnect();
    if (this.dialog) {
      this.form.removeEventListener("submit", this.onSubmit);
      this.dialog.removeEventListener("click", this.onCancel);
    }
  },

  boardOf(el) {
    const b = el.closest("[data-pairing]");
    return {
      enrollment: this.enrollment,
      round: num(b.dataset.round),
      pairing: num(b.dataset.pairing),
      board: num(b.dataset.board),
      white: num(b.dataset.white),
      black: num(b.dataset.black),
      expected: b.dataset.result || "",
    };
  },

  tapResult(button) {
    this.outbox.add({
      ...this.boardOf(button),
      kind: "result",
      result: button.dataset.entry,
      label: button.textContent.trim(),
    });
  },

  openIncident(button) {
    if (!this.dialog) return;
    this.incidentBoard = this.boardOf(button);
    const title = this.dialog.querySelector("[data-mq-incident-title]");
    title.textContent = (this.dialog.dataset.title || "").split("{board}").join(this.incidentBoard.board);
    this.form.reset();
    this.dialog.showModal();
  },

  saveIncident() {
    const type = this.form.querySelector("input[name='type']:checked");
    if (!type || !this.incidentBoard) return;

    const {expected: _unused, ...board} = this.incidentBoard;
    const label = type.closest("label") ? type.closest("label").textContent.trim() : type.value;

    this.outbox.add({
      ...board,
      kind: "incident",
      type: type.value,
      note: this.form.querySelector("textarea[name='note']").value.trim(),
      label,
    });

    this.dialog.close();
  },

  // A board keeps a mark while the phone has something for it that the
  // server has not taken: waiting, being sent, or refused.
  badges(entries) {
    this.entries = entries;
    this.drawBadges();
  },

  drawBadges() {
    const latest = new Map();
    for (const e of this.entries) if (e.status !== "sent") latest.set(e.pairing, e);

    for (const board of this.el.querySelectorAll("[data-pairing]")) {
      const holder = board.querySelector("[data-mq-badge]");
      if (!holder) continue;

      const e = latest.get(num(board.dataset.pairing));
      const state = e ? e.status : "";
      const text = e ? `${this.outbox.t(state === "refused" ? "Refused" : "Waiting")} · ${e.label}` : "";

      // The holder is `phx-update="ignore"`: LiveView leaves its children
      // alone but not its attributes, so the mark is a child of it.
      // Written only when it changes: this runs from a MutationObserver,
      // and an unconditional write would observe itself forever.
      let mark = holder.firstElementChild;
      if (!mark && !text) continue;
      if (!mark) {
        mark = document.createElement("span");
        mark.className = "mq-badge";
        holder.append(mark);
      }
      if (mark.textContent !== text) mark.textContent = text;
      if (mark.dataset.state !== state) mark.dataset.state = state;
      mark.hidden = !text;
    }
  },

  push(event, entries) {
    const ids = entries.filter((e) => e.kind === "result").map((e) => e.pairing);
    if (ids.length === 0) return;
    try {
      this.pushEvent(event, {ids});
    } catch (_disconnected) {
      // Only a courtesy (keeps a board on screen while its result travels);
      // without a connection there is no screen to keep it on.
    }
  },
};
