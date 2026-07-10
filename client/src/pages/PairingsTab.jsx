import { useState } from 'react';

// One tab for the whole round workflow: pick a round, pair it, enter results,
// go back to any earlier round to correct a result.
export default function PairingsTab({ tournament }) {
  const [round, setRound] = useState(1);
  const rounds = Array.from({ length: tournament.rounds_count }, (_, i) => i + 1);

  return (
    <>
      <div className="round-picker">
        {rounds.map((n) => (
          <button
            key={n}
            className={n === round ? 'active' : ''}
            onClick={() => setRound(n)}
          >
            {n}
          </button>
        ))}
      </div>

      <div className="page-header" style={{ marginTop: 16 }}>
        <div>
          <h2 style={{ margin: 0 }}>Round {round}</h2>
          <p className="subtitle" style={{ margin: 0 }}>
            <span className="badge muted">not paired</span>
          </p>
        </div>
        <div className="actions" style={{ margin: 0 }}>
          <button className="primary" disabled title="Automatic pairing (JaVaFo) is the next build step">
            Pair round {round}
          </button>
          <button disabled title="Available once the round is paired">Print pairings</button>
        </div>
      </div>

      <div className="card table-card">
        <table>
          <thead>
            <tr>
              <th className="num">Board</th>
              <th>White</th>
              <th style={{ textAlign: 'center' }}>Result</th>
              <th>Black</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td colSpan="4">
                <div className="empty">
                  <p><strong>This round has not been paired yet.</strong></p>
                  <p className="hint">
                    Pairing runs the FIDE Dutch system through JaVaFo and fills this table.
                    Results are entered right here (1-0, ½-½, 0-1, forfeits), and earlier
                    rounds stay editable by selecting them above.
                  </p>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </>
  );
}
