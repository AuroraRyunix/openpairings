import { useEffect, useState, useCallback } from 'react';
import { useParams, Routes, Route, Navigate } from 'react-router-dom';
import { api, TOURNAMENT_TYPES } from '../api.js';
import PlayersTab from './PlayersTab.jsx';
import PairingsTab from './PairingsTab.jsx';
import StandingsTab from './StandingsTab.jsx';
import PrintTab from './PrintTab.jsx';
import SettingsTab from './SettingsTab.jsx';

export default function TournamentPage() {
  const { id } = useParams();
  const [tournament, setTournament] = useState(null);
  const [error, setError] = useState('');

  const reload = useCallback(() => {
    api.get(`/api/tournaments/${id}`).then(setTournament).catch((e) => setError(e.message));
  }, [id]);

  useEffect(reload, [reload]);

  if (error) return <main className="page"><p className="error-note">{error}</p></main>;
  if (!tournament) return <main className="page"><p className="hint">Loading…</p></main>;

  return (
    <main className="page">
      <div className="page-header">
        <div>
          <h1>{tournament.name}</h1>
          <p className="subtitle">
            {TOURNAMENT_TYPES[tournament.type]} · {tournament.rounds_count} rounds
            {tournament.venue ? ` · ${tournament.venue}` : ''}
          </p>
        </div>
        <span className={`badge ${tournament.status === 'setup' ? 'muted' : ''}`}>{tournament.status}</span>
      </div>

      <Routes>
        <Route index element={<Navigate to="players" replace />} />
        <Route path="players" element={<PlayersTab tournament={tournament} />} />
        <Route path="pairings" element={<PairingsTab tournament={tournament} />} />
        <Route path="rounds" element={<Navigate to="../pairings" replace />} />
        <Route path="standings" element={<StandingsTab tournament={tournament} />} />
        <Route path="print" element={<PrintTab tournament={tournament} />} />
        <Route path="settings" element={<SettingsTab tournament={tournament} onSaved={reload} />} />
      </Routes>
    </main>
  );
}
