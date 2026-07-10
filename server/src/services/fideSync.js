import { unzipSync } from 'fflate';
import { db } from '../db.js';

// Downloads the combined FIDE rating list (TXT format) and loads it into the
// local fide_players table. The list is published monthly on ratings.fide.com.
const LIST_URL = 'https://ratings.fide.com/download/players_list.zip';

export const syncState = {
  status: 'idle', // idle | downloading | importing | done | error
  progress: '',
  error: null,
  loadedBytes: 0,
  totalBytes: 0,
  importedRows: 0,
  totalRows: 0,
};

export function getStatus() {
  const count = db.prepare('SELECT COUNT(*) AS n FROM fide_players').get().n;
  const last = db.prepare("SELECT value FROM meta WHERE key = 'fide_last_sync'").get();
  return { ...syncState, playerCount: count, lastSync: last?.value ?? null };
}

export async function runSync() {
  if (syncState.status === 'downloading' || syncState.status === 'importing') return;
  syncState.status = 'downloading';
  syncState.progress = 'Contacting FIDE…';
  syncState.error = null;
  syncState.loadedBytes = 0;
  syncState.totalBytes = 0;
  syncState.importedRows = 0;
  syncState.totalRows = 0;
  try {
    const resp = await fetch(LIST_URL);
    if (!resp.ok) throw new Error(`FIDE server answered ${resp.status}`);
    syncState.totalBytes = Number(resp.headers.get('content-length')) || 0;

    const chunks = [];
    const reader = resp.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      syncState.loadedBytes += value.length;
      const mb = (syncState.loadedBytes / 1048576).toFixed(1);
      const totalMb = syncState.totalBytes ? ` of ${(syncState.totalBytes / 1048576).toFixed(1)}` : '';
      syncState.progress = `Downloading rating list… ${mb}${totalMb} MB`;
    }
    const zipData = new Uint8Array(syncState.loadedBytes);
    let offset = 0;
    for (const chunk of chunks) { zipData.set(chunk, offset); offset += chunk.length; }

    syncState.status = 'importing';
    syncState.progress = 'Unpacking…';
    const files = unzipSync(zipData);
    const txtName = Object.keys(files).find((n) => n.toLowerCase().endsWith('.txt'));
    if (!txtName) throw new Error('No .txt file found inside the FIDE zip');
    const text = new TextDecoder('latin1').decode(files[txtName]);

    await importList(text);

    db.prepare(`
      INSERT INTO meta (key, value) VALUES ('fide_last_sync', datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
    `).run();
    syncState.status = 'done';
    syncState.progress = '';
  } catch (err) {
    syncState.status = 'error';
    syncState.error = err.message;
    syncState.progress = '';
  }
}

// The TXT list is fixed-width; column offsets are derived from the header line
// so a layout change between months doesn't silently corrupt fields.
// Header labels in file order — "ID Number" is one column despite the space.
const HEADER_LABELS = [
  'ID Number', 'Name', 'Fed', 'Sex', 'Tit', 'WTit', 'OTit', 'FOA',
  'SRtng', 'SGm', 'SK', 'RRtng', 'RGm', 'Rk', 'BRtng', 'BGm', 'BK',
  'B-day', 'Flag',
];
const FIELD_LABELS = {
  fide_id: 'ID Number',
  name: 'Name',
  federation: 'Fed',
  sex: 'Sex',
  title: 'Tit',
  standard_rating: 'SRtng',
  rapid_rating: 'RRtng',
  blitz_rating: 'BRtng',
  birth_year: 'B-day',
  flag: 'Flag',
};

async function importList(text) {
  const lines = text.split(/\r?\n/);
  const header = lines[0];
  const starts = {};
  let searchFrom = 0;
  for (const label of HEADER_LABELS) {
    const idx = header.indexOf(label, searchFrom);
    if (idx === -1) throw new Error(`FIDE list header is missing the "${label}" column`);
    starts[label] = idx;
    searchFrom = idx + label.length;
  }
  const offsets = Object.entries(FIELD_LABELS).map(([field, label]) => {
    const next = HEADER_LABELS[HEADER_LABELS.indexOf(label) + 1];
    return { field, start: starts[label], end: next ? starts[next] : Infinity };
  });

  const insert = db.prepare(`
    INSERT INTO fide_players (fide_id, name, federation, sex, title,
      standard_rating, rapid_rating, blitz_rating, birth_year, flag)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(fide_id) DO UPDATE SET
      name = excluded.name, federation = excluded.federation, sex = excluded.sex,
      title = excluded.title, standard_rating = excluded.standard_rating,
      rapid_rating = excluded.rapid_rating, blitz_rating = excluded.blitz_rating,
      birth_year = excluded.birth_year, flag = excluded.flag
  `);

  const numeric = new Set(['fide_id', 'standard_rating', 'rapid_rating', 'blitz_rating', 'birth_year']);
  const total = lines.length - 1;
  syncState.totalRows = total;
  let done = 0;

  db.exec('BEGIN');
  try {
    // Full replace: the monthly list is authoritative (players do get removed).
    db.prepare('DELETE FROM fide_players').run();
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      if (!line.trim()) continue;
      const rec = {};
      for (const { field, start, end } of offsets) {
        const raw = line.slice(start, end).trim();
        rec[field] = numeric.has(field) ? (parseInt(raw, 10) || null) : raw;
      }
      if (!rec.fide_id || !rec.name) continue;
      insert.run(rec.fide_id, rec.name, rec.federation ?? '', rec.sex ?? '', rec.title ?? '',
        rec.standard_rating, rec.rapid_rating, rec.blitz_rating, rec.birth_year, rec.flag ?? '');
      done++;
      if (done % 25000 === 0) {
        syncState.importedRows = done;
        syncState.progress = `Importing players… ${done.toLocaleString()} of ~${total.toLocaleString()}`;
        db.exec('COMMIT');
        // Yield so status requests are answered while the import runs.
        await new Promise((resolve) => setImmediate(resolve));
        db.exec('BEGIN');
      }
    }
    db.exec('COMMIT');
    syncState.importedRows = done;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}
