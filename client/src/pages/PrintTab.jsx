import { api } from '../api.js';

const PRINT_CSS = `
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; color: #111; margin: 24px; }
  h1 { font-size: 20px; margin: 0 0 2px; }
  .sub { color: #555; margin: 0 0 18px; font-size: 13px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; border-bottom: 2px solid #000; padding: 5px 8px; font-size: 11px;
       text-transform: uppercase; letter-spacing: 0.04em; }
  td { padding: 5px 8px; border-bottom: 1px solid #ccc; }
  .num { text-align: right; }
  .player-card { border: 1.5px solid #000; padding: 14px 16px; margin-bottom: 16px;
                 page-break-inside: avoid; }
  .player-card h2 { font-size: 16px; margin: 0; }
  .player-card .meta { color: #444; font-size: 12.5px; margin: 2px 0 10px; }
  .player-card table td, .player-card table th { padding: 4px 8px; }
  @media print { .player-card { break-inside: avoid; } }
`;

function openPrintWindow(title, subtitle, bodyHtml) {
  const w = window.open('', '_blank');
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${title}</title>
    <style>${PRINT_CSS}</style></head><body>
    <h1>${title}</h1><p class="sub">${subtitle}</p>${bodyHtml}
    <script>window.onload = () => window.print();<\/script></body></html>`);
  w.document.close();
}

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;');

export default function PrintTab({ tournament }) {
  async function printPlayerList() {
    const players = await api.get(`/api/tournaments/${tournament.id}/players`);
    const rows = players.map((p, i) => `<tr>
      <td class="num">${i + 1}</td><td>${esc(p.title)}</td><td><strong>${esc(p.name)}</strong></td>
      <td class="num">${p.fide_rating || ''}</td><td class="num">${p.national_rating || ''}</td>
      <td>${esc(p.federation)}</td><td>${esc(p.club)}</td>
    </tr>`).join('');
    openPrintWindow(
      esc(tournament.name),
      `Registered players (${players.length})`,
      `<table><thead><tr><th class="num">#</th><th>Title</th><th>Name</th><th class="num">FIDE</th>
       <th class="num">Nat.</th><th>Fed</th><th>Club</th></tr></thead><tbody>${rows}</tbody></table>`
    );
  }

  async function printPlayerCards() {
    const players = await api.get(`/api/tournaments/${tournament.id}/players`);
    const roundRows = Array.from({ length: tournament.rounds_count }, (_, i) => `<tr>
      <td class="num">${i + 1}</td><td></td><td></td><td></td><td></td>
    </tr>`).join('');
    const cards = players.map((p, i) => `<div class="player-card">
      <h2>${i + 1}. ${esc(p.title)} ${esc(p.name)}</h2>
      <p class="meta">${p.fide_rating ? `FIDE ${p.fide_rating}` : ''}${p.national_rating ? ` · Nat. ${p.national_rating}` : ''}${p.federation ? ` · ${esc(p.federation)}` : ''}${p.club ? ` · ${esc(p.club)}` : ''}</p>
      <table><thead><tr><th class="num">Rd</th><th>Opponent</th><th>Colour</th><th>Result</th><th>Score</th></tr></thead>
      <tbody>${roundRows}</tbody></table>
    </div>`).join('');
    openPrintWindow(esc(tournament.name), 'Player cards', cards);
  }

  const documents = [
    { name: 'Player list', desc: 'All registered players with ratings, federation and club.', action: printPlayerList },
    { name: 'Player cards', desc: 'One card per player with their round-by-round schedule to fill in.', action: printPlayerCards },
    { name: 'Pairing list (per round)', desc: 'Board-by-board pairings for posting at the venue.', needsRounds: true },
    { name: 'Alphabetical pairing list', desc: '"Where do I sit" list, sorted by player name.', needsRounds: true },
    { name: 'Score sheets', desc: 'Pre-filled per board: names, ratings, move columns, signatures.', needsRounds: true },
    { name: 'Standings', desc: 'Current ranking with points and tiebreaks.', needsRounds: true },
    { name: 'Cross table', desc: 'Full results grid of the tournament.', needsRounds: true },
  ];

  return (
    <div className="card table-card">
      <table>
        <thead>
          <tr><th>Document</th><th>Description</th><th></th></tr>
        </thead>
        <tbody>
          {documents.map((d) => (
            <tr key={d.name}>
              <td><strong>{d.name}</strong></td>
              <td className="hint">{d.desc}</td>
              <td style={{ textAlign: 'right' }}>
                {d.needsRounds ? (
                  <button disabled title="Available once rounds are paired">Print…</button>
                ) : (
                  <button className="primary" onClick={d.action}>Print…</button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
