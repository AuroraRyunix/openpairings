import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';

const EMPTY = {
  name: '', title: '', fide_id: '', fide_rating: '', national_id: '',
  national_rating: '', federation: '', birth_year: '', club: '', sex: '',
};

// Columns of the player grid; which ones are shown is up to the user (Display panel).
const ALL_COLUMNS = [
  { key: 'title',           label: 'Title' },
  { key: 'sex',             label: 'Sex' },
  { key: 'birth_year',      label: 'Birth',    num: true },
  { key: 'federation',      label: 'Country' },
  { key: 'national_id',     label: 'Id Nat',   num: true },
  { key: 'fide_id',         label: 'Id FIDE',  num: true },
  { key: 'fide_rating',     label: 'Elo FIDE', num: true },
  { key: 'national_rating', label: 'Elo Nat',  num: true },
  { key: 'club',            label: 'Club' },
  { key: 'status',          label: 'Status' },
];
const DEFAULT_VISIBLE = ['title', 'birth_year', 'federation', 'fide_id', 'fide_rating', 'national_rating', 'club'];
const STORAGE_KEY = 'pairingsengine.playerColumns';

function loadVisible() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (Array.isArray(saved)) return saved;
  } catch { /* fall through */ }
  return DEFAULT_VISIBLE;
}

export default function PlayersTab({ tournament }) {
  const [players, setPlayers] = useState(null);
  const [adding, setAdding] = useState(false);
  const [form, setForm] = useState(EMPTY);
  const [error, setError] = useState('');
  const [visible, setVisible] = useState(loadVisible);

  // FIDE search state
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const searchTimer = useRef(null);

  function reload() {
    api.get(`/api/tournaments/${tournament.id}/players`).then(setPlayers).catch((e) => setError(e.message));
  }
  useEffect(reload, [tournament.id]);

  function toggleColumn(key) {
    setVisible((v) => {
      const next = v.includes(key) ? v.filter((k) => k !== key) : [...v, key];
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }

  function onQueryChange(value) {
    setQuery(value);
    clearTimeout(searchTimer.current);
    if (value.trim().length < 2) { setResults([]); return; }
    searchTimer.current = setTimeout(async () => {
      try {
        setResults(await api.get(`/api/fide/search?q=${encodeURIComponent(value)}`));
      } catch { /* search is best-effort */ }
    }, 250);
  }

  function pickFidePlayer(fp) {
    setForm({
      ...form,
      name: fp.name,
      title: fp.title ?? '',
      fide_id: fp.fide_id,
      fide_rating: fp.standard_rating ?? '',
      federation: fp.federation ?? '',
      birth_year: fp.birth_year ?? '',
      sex: fp.sex ?? '',
    });
    setQuery('');
    setResults([]);
  }

  async function save(e) {
    e.preventDefault();
    setError('');
    try {
      await api.post(`/api/tournaments/${tournament.id}/players`, {
        ...form,
        fide_id: form.fide_id ? Number(form.fide_id) : null,
      });
      setForm(EMPTY);
      reload();
    } catch (err) {
      setError(err.message);
    }
  }

  async function remove(p) {
    if (!confirm(`Remove ${p.name} from the tournament?`)) return;
    await api.del(`/api/players/${p.id}`);
    reload();
  }

  const shown = ALL_COLUMNS.filter((c) => visible.includes(c.key));

  return (
    <>
      <div className="page-header">
        <p className="subtitle" style={{ margin: 0 }}>
          {players ? `${players.length} player${players.length === 1 ? '' : 's'} registered` : ''}
        </p>
        {!adding && <button className="primary" onClick={() => setAdding(true)}>Add player</button>}
      </div>

      {adding && (
        <form className="card" onSubmit={save}>
          <h2>Add player</h2>

          <label className="field search-wrap">
            <span>Search the FIDE database (name or FIDE ID)</span>
            <input
              autoFocus
              value={query}
              onChange={(e) => onQueryChange(e.target.value)}
              placeholder="Start typing a last name… e.g. Carlsen"
            />
            {results.length > 0 && (
              <div className="search-results">
                {results.map((fp) => (
                  <button type="button" key={fp.fide_id} onClick={() => pickFidePlayer(fp)}>
                    <span>{fp.title ? `${fp.title} ` : ''}{fp.name}</span>
                    <span className="meta">
                      {fp.federation} · {fp.standard_rating ?? 'unrated'} · {fp.birth_year ?? '—'}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </label>
          <p className="hint">…or fill the details in by hand below.</p>

          <div className="form-grid">
            <label className="field">
              <span>Full name *</span>
              <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Lastname, Firstname" />
            </label>
            <label className="field">
              <span>Title</span>
              <select value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })}>
                <option value="">—</option>
                {['GM', 'IM', 'FM', 'CM', 'WGM', 'WIM', 'WFM', 'WCM'].map((t) => <option key={t}>{t}</option>)}
              </select>
            </label>
            <label className="field">
              <span>FIDE ID</span>
              <input value={form.fide_id} onChange={(e) => setForm({ ...form, fide_id: e.target.value })} />
            </label>
            <label className="field">
              <span>FIDE rating</span>
              <input type="number" value={form.fide_rating} onChange={(e) => setForm({ ...form, fide_rating: e.target.value })} />
            </label>
            <label className="field">
              <span>National ID</span>
              <input value={form.national_id} onChange={(e) => setForm({ ...form, national_id: e.target.value })} />
            </label>
            <label className="field">
              <span>National rating</span>
              <input type="number" value={form.national_rating} onChange={(e) => setForm({ ...form, national_rating: e.target.value })} />
            </label>
            <label className="field">
              <span>Federation</span>
              <input value={form.federation} onChange={(e) => setForm({ ...form, federation: e.target.value })} placeholder="BEL" />
            </label>
            <label className="field">
              <span>Birth year</span>
              <input type="number" value={form.birth_year} onChange={(e) => setForm({ ...form, birth_year: e.target.value })} />
            </label>
            <label className="field">
              <span>Club</span>
              <input value={form.club} onChange={(e) => setForm({ ...form, club: e.target.value })} />
            </label>
          </div>
          {error && <p className="error-note">{error}</p>}
          <div className="actions">
            <button type="submit" className="primary">Add player</button>
            <button type="button" onClick={() => { setAdding(false); setForm(EMPTY); setError(''); }}>Done</button>
          </div>
        </form>
      )}

      {players === null ? (
        <p className="hint">Loading…</p>
      ) : players.length === 0 ? (
        <div className="card empty">
          <p><strong>No players registered yet.</strong></p>
          <p>Add players by searching the FIDE database, or enter them by hand.</p>
        </div>
      ) : (
        <div className="split">
          <div className="card table-card split-main">
            <table>
              <thead>
                <tr>
                  <th className="num">#</th>
                  <th>Name</th>
                  {shown.map((c) => <th key={c.key} className={c.num ? 'num' : ''}>{c.label}</th>)}
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {players.map((p, i) => (
                  <tr key={p.id}>
                    <td className="num">{i + 1}</td>
                    <td><strong>{p.name}</strong></td>
                    {shown.map((c) => (
                      <td key={c.key} className={c.num ? 'num' : ''}>
                        {p[c.key] || (c.key === 'status' ? p.status : '—')}
                      </td>
                    ))}
                    <td style={{ textAlign: 'right' }}>
                      <button className="danger-link" onClick={() => remove(p)}>Remove</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <aside className="card display-panel">
            <h2>Display</h2>
            {ALL_COLUMNS.map((c) => (
              <label key={c.key} className="check">
                <input
                  type="checkbox"
                  checked={visible.includes(c.key)}
                  onChange={() => toggleColumn(c.key)}
                />
                {c.label}
              </label>
            ))}
          </aside>
        </div>
      )}
    </>
  );
}
