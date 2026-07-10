import { Router } from 'express';
import { db } from '../db.js';
import { getStatus, runSync } from '../services/fideSync.js';

export const fide = Router();

fide.get('/status', (req, res) => {
  res.json(getStatus());
});

fide.post('/sync', (req, res) => {
  runSync(); // fire and forget; progress is polled via /status
  res.status(202).json(getStatus());
});

fide.get('/search', (req, res) => {
  const q = (req.query.q ?? '').toString().trim();
  if (q.length < 2) return res.json([]);

  if (/^\d+$/.test(q)) {
    const row = db.prepare('SELECT * FROM fide_players WHERE fide_id = ?').get(Number(q));
    return res.json(row ? [row] : []);
  }
  // FIDE names are "Lastname, Firstname"; prefix search uses the name index.
  const like = q.replace(/[%_]/g, '') + '%';
  const rows = db.prepare(`
    SELECT * FROM fide_players
    WHERE name LIKE ? COLLATE NOCASE
    ORDER BY standard_rating IS NULL, standard_rating DESC
    LIMIT 20
  `).all(like);
  res.json(rows);
});
