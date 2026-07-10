import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';

export default function FidePage() {
  const [status, setStatus] = useState(null);
  const pollRef = useRef(null);

  async function refresh() {
    const s = await api.get('/api/fide/status');
    setStatus(s);
    const busy = s.status === 'downloading' || s.status === 'importing';
    if (busy && !pollRef.current) {
      pollRef.current = setInterval(refresh, 1000);
    } else if (!busy && pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }
  }

  useEffect(() => {
    refresh();
    return () => clearInterval(pollRef.current);
  }, []);

  async function startSync() {
    await api.post('/api/fide/sync');
    refresh();
  }

  const busy = status && (status.status === 'downloading' || status.status === 'importing');
  let percent = null;
  if (status?.status === 'downloading' && status.totalBytes > 0) {
    percent = (status.loadedBytes / status.totalBytes) * 100;
  } else if (status?.status === 'importing' && status.totalRows > 0) {
    percent = (status.importedRows / status.totalRows) * 100;
  }

  return (
    <main className="page">
      <h1>FIDE database</h1>
      <p className="subtitle">
        A local copy of the FIDE rating list, used to look up players when registering them.
      </p>

      <div className="card">
        {!status ? <p className="hint">Loading…</p> : (
          <>
            <p>
              <strong>{status.playerCount.toLocaleString()}</strong> players in the local database.
              {status.lastSync
                ? <> Last updated: <strong>{status.lastSync}</strong> (UTC).</>
                : <> The database is empty — download the rating list to get started.</>}
            </p>

            {busy && (
              <div className="progress-block">
                <div className="progress-track">
                  <div
                    className={`progress-fill ${percent === null ? 'indeterminate' : ''}`}
                    style={percent !== null ? { width: `${percent.toFixed(1)}%` } : undefined}
                  />
                </div>
                <p className="ok-note">{status.progress || 'Working…'}</p>
              </div>
            )}
            {status.status === 'error' && (
              <p className="error-note">Update failed: {status.error}</p>
            )}

            <p className="hint">
              FIDE publishes a new list every month (~1.9 million players, download is around 10 MB).
              Updating takes a minute or two.
            </p>
            <div className="actions">
              <button className="primary" onClick={startSync} disabled={busy}>
                {busy ? 'Updating…' : status.playerCount > 0 ? 'Update from FIDE' : 'Download rating list'}
              </button>
            </div>
          </>
        )}
      </div>
    </main>
  );
}
