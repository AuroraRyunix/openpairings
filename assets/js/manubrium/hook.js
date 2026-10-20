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

// A photo is shrunk on the phone before it is queued: 1600 pixels on the
// longest side, JPEG. A 12-megapixel original would be several megabytes
// in a queue that has to survive the wifi; this is a few hundred kB and
// still reads a scoresheet. The server caps it again (`Incidents.photo_max`).
const PHOTO_EDGE = 1600;
const PHOTO_QUALITY = 0.8;

// Per-phone settings, not shared and not important: storage that throws
// (a private window) just means the toggle starts off.
const store = {
  get(k) {
    try {
      return window.localStorage.getItem(k);
    } catch (_e) {
      return null;
    }
  },
  set(k, v) {
    try {
      if (v) window.localStorage.setItem(k, "1");
      else window.localStorage.removeItem(k);
    } catch (_e) {
      // nothing to keep it in
    }
  },
};

function loadImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("not an image"));
    };
    img.src = url;
  });
}

// The file from the camera input, as base64 JPEG bytes (no `data:` prefix).
async function shrinkPhoto(file) {
  const img = await loadImage(file);
  const scale = Math.min(1, PHOTO_EDGE / Math.max(img.naturalWidth, img.naturalHeight));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
  canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
  canvas.getContext("2d").drawImage(img, 0, 0, canvas.width, canvas.height);

  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", PHOTO_QUALITY));
  if (!blob) throw new Error("could not encode");

  const dataUrl = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });

  return {b64: String(dataUrl).split(",", 2)[1] || "", bytes: blob.size};
}

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

      this.photoInput = this.dialog.querySelector("[data-mq-photo]");
      this.photoState = this.dialog.querySelector("[data-mq-photo-state]");
      if (this.photoInput) {
        this.onPhoto = () => this.preparePhoto();
        this.photoInput.addEventListener("change", this.onPhoto);
      }
    }

    this.setupToggles();

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
      if (this.photoInput) this.photoInput.removeEventListener("change", this.onPhoto);
    }
    if (this.toggles) this.toggles.removeEventListener("click", this.onToggle);
    document.removeEventListener("visibilitychange", this.onVisible);
    this.releaseWake();
  },

  // ---- the header's two switches: keep the screen on, one-handed ----

  setupToggles() {
    this.toggles = document.getElementById("manubrium-toggles");
    if (!this.toggles) return;

    const wake = this.toggles.querySelector("[data-mq-wake]");
    // No Screen Wake Lock in this browser (older iOS, some in-app
    // browsers): no button, rather than one that does nothing.
    if (wake) wake.hidden = !("wakeLock" in navigator);

    this.onToggle = (e) => {
      const b = e.target.closest("[data-mq-wake], [data-mq-hand]");
      if (!b) return;
      if (b.hasAttribute("data-mq-wake")) this.setWake(b.getAttribute("aria-pressed") !== "true");
      else this.setHand(b.getAttribute("aria-pressed") !== "true");
    };
    this.toggles.addEventListener("click", this.onToggle);

    // The browser drops a wake lock whenever the page is hidden; coming
    // back takes it again if it was on.
    this.onVisible = () => {
      if (document.visibilityState === "visible" && this.wakeWanted) this.takeWake();
    };
    document.addEventListener("visibilitychange", this.onVisible);

    this.setHand(store.get("manubrium:onehand") === "1");
    if (store.get("manubrium:wake") === "1") this.setWake(true);
  },

  setHand(on) {
    document.documentElement.classList.toggle("mq-onehand", on);
    store.set("manubrium:onehand", on);
    const b = this.toggles && this.toggles.querySelector("[data-mq-hand]");
    if (b) b.setAttribute("aria-pressed", String(on));
  },

  setWake(on) {
    this.wakeWanted = on;
    store.set("manubrium:wake", on);
    const b = this.toggles && this.toggles.querySelector("[data-mq-wake]");
    if (b) b.setAttribute("aria-pressed", String(on));
    if (on) this.takeWake();
    else this.releaseWake();
  },

  async takeWake() {
    if (!("wakeLock" in navigator) || this.wakeLock) return;
    try {
      this.wakeLock = await navigator.wakeLock.request("screen");
      this.wakeLock.addEventListener("release", () => {
        this.wakeLock = null;
      });
    } catch (_refused) {
      // Battery saver, or a page not in front: nothing to do but try again
      // when it is (`onVisible`).
      this.wakeLock = null;
    }
  },

  releaseWake() {
    if (this.wakeLock) {
      this.wakeLock.release().catch(() => {});
      this.wakeLock = null;
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
    this.photo = null;
    this.photoJob = null;
    this.showPhotoState("");
    this.dialog.showModal();
  },

  preparePhoto() {
    const file = this.photoInput.files && this.photoInput.files[0];
    this.photo = null;
    if (!file) {
      this.photoJob = null;
      this.showPhotoState("");
      return;
    }

    const job = shrinkPhoto(file).then(
      (photo) => {
        if (this.photoJob !== job) return null;
        this.photo = photo;
        this.showPhotoState(this.dialogText("photoready").split("{kb}").join(Math.round(photo.bytes / 1024)));
        return photo;
      },
      () => {
        if (this.photoJob !== job) return null;
        this.photoInput.value = "";
        this.showPhotoState(this.dialogText("photoerror"));
        return null;
      }
    );
    this.photoJob = job;
  },

  dialogText(key) {
    return this.dialog.dataset["t" + key] || "";
  },

  showPhotoState(text) {
    if (!this.photoState) return;
    this.photoState.textContent = text;
    this.photoState.hidden = !text;
  },

  async saveIncident() {
    const type = this.form.querySelector("input[name='type']:checked");
    if (!type || !this.incidentBoard) return;

    const {expected: _unused, ...board} = this.incidentBoard;
    const label = type.closest("label") ? type.closest("label").textContent.trim() : type.value;
    const note = this.form.querySelector("textarea[name='note']").value.trim();

    // Still shrinking: wait for it, it is a fraction of a second.
    const photo = this.photoJob ? await this.photoJob : null;

    const entry = {...board, kind: "incident", type: type.value, note, label};
    if (photo && photo.b64) {
      entry.photo = photo.b64;
      entry.label = label + " · 📷";
    }

    this.outbox.add(entry);
    this.photo = null;
    this.photoJob = null;
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
