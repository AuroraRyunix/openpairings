import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { api, TOURNAMENT_TYPES } from '../api.js';

export default function TournamentsPage() {
  const [tournaments, setTournaments] = useState(null);
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState({ name: '', type: 'swiss', rounds_count: 9 });
  const [error, setError] = useState('');
  const navigate = useNavigate();

  useEffect(() => {
    api.get('/api/tournaments').then(setTournaments).catch((e) => setError(e.message));
  }, []);

  async function create(e) {
    e.preventDefault();
    setError('');
    try {
      const t = await api.post('/api/tournaments', form);
      navigate(`/t/${t.id}/players`);
    } catch (e) {
      setError(e.message);
    }
  }

  return (
    <main className="page">
      <div className="page-header">
        <div>
          <h1>Tournaments</h1>
          <p className="subtitle">Everything you are organising, most recent first.</p>
        </div>
        {!creating && (
          <button className="primary" onClick={() => setCreating(true)}>New tournament</button>
        )}
      </div>

      {creating && (
        <form className="card" onSubmit={create}>
          <h2>New tournament</h2>
          <div className="form-grid">
            <label className="field">
              <span>Name</span>
              <input
                autoFocus
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                placeholder="e.g. Summer Open 2026"
              />
            </label>
            <label className="field">
              <span>Pairing system</span>
              <select value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value })}>
                {Object.entries(TOURNAMENT_TYPES).map(([value, label]) => (
                  <option key={value} value={value}>{label}</option>
                ))}
              </select>
            </label>
            <label className="field">
              <span>Rounds</span>
              <input
                type="number" min="1" max="30"
                value={form.rounds_count}
                onChange={(e) => setForm({ ...form, rounds_count: e.target.value })}
              />
            </label>
          </div>
          {error && <p className="error-note">{error}</p>}
          <div className="actions">
            <button type="submit" className="primary">Create tournament</button>
            <button type="button" onClick={() => { setCreating(false); setError(''); }}>Cancel</button>
          </div>
        </form>
      )}

      {tournaments === null ? (
        <p className="hint">Loading…</p>
      ) : tournaments.length === 0 && !creating ? (
        <div className="card empty">
          <p><strong>No tournaments yet.</strong></p>
          <p>Create your first tournament to start registering players.</p>
        </div>
      ) : tournaments.length > 0 && (
        <div className="card table-card">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>System</th>
                <th className="num">Rounds</th>
                <th className="num">Players</th>
                <th>Dates</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {tournaments.map((t) => (
                <tr key={t.id}>
                  <td><Link to={`/t/${t.id}/players`}><strong>{t.name}</strong></Link></td>
                  <td>{TOURNAMENT_TYPES[t.type] ?? t.type}</td>
                  <td className="num">{t.rounds_count}</td>
                  <td className="num">{t.player_count}</td>
                  <td>{t.start_date || '—'}{t.end_date ? ` → ${t.end_date}` : ''}</td>
                  <td><span className={`badge ${t.status === 'setup' ? 'muted' : ''}`}>{t.status}</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </main>
  );
}
