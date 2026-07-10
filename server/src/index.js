import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { tournaments } from './routes/tournaments.js';
import { players } from './routes/players.js';
import { fide } from './routes/fide.js';
import { TIEBREAKS, FIDE_DEFAULTS } from './tiebreaks.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json());

app.use('/api/tournaments', tournaments);
app.use('/api', players);
app.use('/api/fide', fide);
app.get('/api/tiebreaks', (req, res) => res.json({ tiebreaks: TIEBREAKS, defaults: FIDE_DEFAULTS }));

// In production the built frontend is served from here.
const dist = path.join(__dirname, '..', '..', 'client', 'dist');
app.use(express.static(dist));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'Internal server error' });
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => console.log(`PairingsEngine server listening on http://localhost:${PORT}`));
