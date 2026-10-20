// Manubrium's queue on the phone: one IndexedDB object store of entries,
// keyed by the entry's client id (docs/manubrium.md, "Entries").
//
// An entry's `status` is one of
//   "waiting"  - made, not yet answered by the server
//   "sending"  - in a request right now
//   "sent"     - the server answered "saved"
//   "refused"  - the server answered "refused"; kept, with its message,
//                until the person holding the phone dismisses it
// and `tried` says it has been in at least one request, which is what
// stops a later tap from rewriting it (the server may already have it).
//
// Where IndexedDB is missing or refuses to open (some private windows),
// entries live in memory instead: the page still works, but closing it
// loses what has not been sent. `persistent()` says which it is.

const DB_NAME = "manubrium";
const STORE = "entries";

let dbPromise = null;
let memory = null;

function open() {
  if (dbPromise) return dbPromise;

  dbPromise = new Promise((resolve) => {
    let request;
    try {
      request = indexedDB.open(DB_NAME, 1);
    } catch (_) {
      return resolve(null);
    }
    request.onupgradeneeded = () => request.result.createObjectStore(STORE, {keyPath: "cid"});
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => resolve(null);
    request.onblocked = () => resolve(null);
  }).then((db) => {
    if (!db) memory = memory || new Map();
    return db;
  });

  return dbPromise;
}

function run(mode, fn) {
  return open().then(
    (db) =>
      new Promise((resolve, reject) => {
        if (!db) return resolve(fn(null));
        const tx = db.transaction(STORE, mode);
        const result = fn(tx.objectStore(STORE));
        tx.oncomplete = () => resolve(result instanceof IDBRequest ? result.result : result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      })
  );
}

export async function persistent() {
  return (await open()) !== null;
}

// Every entry, oldest first.
export async function all() {
  const rows = await run("readonly", (store) => (store ? store.getAll() : [...memory.values()]));
  return (rows || []).slice().sort((a, b) => a.seq - b.seq);
}

export function put(entry) {
  return run("readwrite", (store) => (store ? store.put(entry) : memory.set(entry.cid, entry)));
}

export async function putAll(entries) {
  for (const entry of entries) await put(entry);
}

export function remove(cid) {
  return run("readwrite", (store) => (store ? store.delete(cid) : memory.delete(cid)));
}

export function clear() {
  return run("readwrite", (store) => (store ? store.clear() : memory.clear()));
}

// Ordered even when two taps land in the same millisecond.
let lastSeq = 0;
export function nextSeq() {
  lastSeq = Math.max(Date.now(), lastSeq + 1);
  return lastSeq;
}

export function newId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  // Older Safari: same shape, same source of randomness.
  const b = crypto.getRandomValues(new Uint8Array(16));
  return [...b].map((x, i) => ([4, 6, 8, 10].includes(i) ? "-" : "") + x.toString(16).padStart(2, "0")).join("");
}
