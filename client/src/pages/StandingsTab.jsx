import { useEffect, useState } from 'react';
import { api } from '../api.js';

export default function StandingsTab({ tournament }) {
  const [players, setPlayers] = useState(null);
  const [catalogue, setCatalogue] = useState(null);

  useEffect(() => {
    api.get(`/api/tournaments/${tournament.id}/players`).then(setPlayers);
    api.get('/api/tiebreaks').then(setCatalogue);
  }, [tournament.id]);

  const tbName = (code) => catalogue?.tiebreaks.find((t) => t.code === code)?.name ?? code;

  return (
    <>
      <div className="card">
        <p style={{ margin: 0 }}>
          <span className="hint">
            Standings update live once results are entered. Tiebreaks are applied in the
            order set under Settings, following the FIDE Tie-Break Regulations.
          </span>
        </p>
      </div>
      {players === null ? <p className="hint">Loading…</p> : players.length === 0 ? (
        <div className="card empty"><p><strong>No players registered yet.</strong></p></div>
      ) : (
        <div className="card table-card">
          <table>
            <thead>
              <tr>
                <th className="num">Rank</th>
                <th>Name</th>
                <th className="num">Elo</th>
                <th className="num">Pts</th>
                {tournament.tiebreaks.map((code) => (
                  <th className="num" key={code} title={tbName(code)}>{code}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {players.map((p, i) => (
                <tr key={p.id}>
                  <td className="num">{i + 1}</td>
                  <td><strong>{p.title ? `${p.title} ` : ''}{p.name}</strong></td>
                  <td className="num">{p.fide_rating || p.national_rating || '—'}</td>
                  <td className="num">0.0</td>
                  {tournament.tiebreaks.map((code) => <td className="num" key={code}>—</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
