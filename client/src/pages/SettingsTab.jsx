import { useEffect, useState } from 'react';
import { api, TOURNAMENT_TYPES } from '../api.js';

const GENERAL_FIELDS = [
  ['name', 'Tournament name'],
  ['venue', 'Venue'],
  ['city', 'City'],
  ['federation', 'Federation'],
  ['start_date', 'Start date', 'date'],
  ['end_date', 'End date', 'date'],
  ['organizer', 'Organizer'],
  ['chief_arbiter', 'Chief arbiter'],
  ['deputy_arbiter', 'Deputy arbiter(s)'],
  ['time_control', 'Time control'],
];

export default function SettingsTab({ tournament, onSaved }) {
  const [form, setForm] = useState({ ...tournament });
  const [catalogue, setCatalogue] = useState(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');

  useEffect(() => { api.get('/api/tiebreaks').then(setCatalogue); }, []);
  useEffect(() => { setForm({ ...tournament }); }, [tournament]);

  const set = (field, value) => setForm((f) => ({ ...f, [field]: value }));

  async function save(e) {
    e.preventDefault();
    setNote(''); setError('');
    try {
      await api.put(`/api/tournaments/${tournament.id}`, {
        ...form,
        rounds_count: Number(form.rounds_count),
        points_win: Number(form.points_win),
        points_draw: Number(form.points_draw),
        points_loss: Number(form.points_loss),
        bye_value: Number(form.bye_value),
      });
      setNote('Saved.');
      onSaved();
      setTimeout(() => setNote(''), 2500);
    } catch (err) {
      setError(err.message);
    }
  }

  // ---- tiebreak list helpers ----
  const tbInfo = (code) => catalogue?.tiebreaks.find((t) => t.code === code);
  const selected = form.tiebreaks ?? [];
  const available = catalogue
    ? catalogue.tiebreaks.filter((t) => !selected.includes(t.code))
    : [];

  function moveTb(index, delta) {
    const next = [...selected];
    const target = index + delta;
    if (target < 0 || target >= next.length) return;
    [next[index], next[target]] = [next[target], next[index]];
    set('tiebreaks', next);
  }

  return (
    <form onSubmit={save}>
      <div className="card">
        <h2>General</h2>
        <div className="form-grid">
          {GENERAL_FIELDS.map(([field, label, type]) => (
            <label className="field" key={field}>
              <span>{label}</span>
              <input
                type={type ?? 'text'}
                value={form[field] ?? ''}
                onChange={(e) => set(field, e.target.value)}
              />
            </label>
          ))}
        </div>
      </div>

      <div className="card">
        <h2>Format</h2>
        <div className="form-grid">
          <label className="field">
            <span>Pairing system</span>
            <select value={form.type} onChange={(e) => set('type', e.target.value)}>
              {Object.entries(TOURNAMENT_TYPES).map(([value, label]) => (
                <option key={value} value={value}>{label}</option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Number of rounds</span>
            <input type="number" min="1" max="30" value={form.rounds_count} onChange={(e) => set('rounds_count', e.target.value)} />
          </label>
          <label className="field">
            <span>Pair by</span>
            <select value={form.rating_type} onChange={(e) => set('rating_type', e.target.value)}>
              <option value="fide">FIDE rating</option>
              <option value="national">National rating</option>
              <option value="none">No rating (random order)</option>
            </select>
          </label>
          <label className="field">
            <span>Acceleration</span>
            <select value={form.acceleration} onChange={(e) => set('acceleration', e.target.value)}>
              <option value="none">None</option>
              <option value="baku">Baku acceleration (FIDE C.04.5)</option>
            </select>
          </label>
        </div>
      </div>

      <div className="card">
        <h2>Scoring</h2>
        <div className="form-grid">
          <label className="field">
            <span>Points for a win</span>
            <input type="number" step="0.5" value={form.points_win} onChange={(e) => set('points_win', e.target.value)} />
          </label>
          <label className="field">
            <span>Points for a draw</span>
            <input type="number" step="0.5" value={form.points_draw} onChange={(e) => set('points_draw', e.target.value)} />
          </label>
          <label className="field">
            <span>Points for a loss</span>
            <input type="number" step="0.5" value={form.points_loss} onChange={(e) => set('points_loss', e.target.value)} />
          </label>
          <label className="field">
            <span>Pairing-allocated bye worth</span>
            <input type="number" step="0.5" value={form.bye_value} onChange={(e) => set('bye_value', e.target.value)} />
          </label>
        </div>
      </div>

      <div className="card">
        <h2>Tiebreaks</h2>
        <p className="hint" style={{ marginTop: 0 }}>
          Applied in order, following the FIDE Tie-Break Regulations. Higher in the list = decided first.
        </p>
        {!catalogue ? <p className="hint">Loading…</p> : (
          <>
            <ol className="tb-list">
              {selected.map((code, i) => {
                const info = tbInfo(code);
                return (
                  <li key={code}>
                    <span className="tb-order">{i + 1}.</span>
                    <div>
                      <div className="tb-name">{info?.name ?? code}</div>
                      <div className="tb-desc">{info?.description}</div>
                    </div>
                    <div className="tb-buttons">
                      <button type="button" title="Move up" disabled={i === 0} onClick={() => moveTb(i, -1)}>↑</button>
                      <button type="button" title="Move down" disabled={i === selected.length - 1} onClick={() => moveTb(i, 1)}>↓</button>
                      <button type="button" title="Remove" onClick={() => set('tiebreaks', selected.filter((c) => c !== code))}>✕</button>
                    </div>
                  </li>
                );
              })}
            </ol>
            {selected.length === 0 && <p className="hint">No tiebreaks selected — tied players will share a rank.</p>}

            <div className="actions" style={{ flexWrap: 'wrap' }}>
              <select
                value=""
                style={{ width: 'auto' }}
                onChange={(e) => { if (e.target.value) set('tiebreaks', [...selected, e.target.value]); }}
              >
                <option value="">Add a tiebreak…</option>
                {available.map((t) => <option key={t.code} value={t.code}>{t.name}</option>)}
              </select>
              <button type="button" onClick={() => set('tiebreaks', catalogue.defaults[form.type] ?? [])}>
                Reset to FIDE default
              </button>
            </div>
          </>
        )}
      </div>

      <div className="actions">
        <button type="submit" className="primary">Save settings</button>
        {note && <span className="ok-note" style={{ alignSelf: 'center' }}>{note}</span>}
        {error && <span className="error-note" style={{ alignSelf: 'center' }}>{error}</span>}
      </div>
    </form>
  );
}
