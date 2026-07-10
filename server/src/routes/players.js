import { Router } from 'express';
import { db } from '../db.js';

export const players = Router();

const EDITABLE = [
  'name', 'sex', 'title', 'fide_id', 'fide_rating', 'national_id',
  'national_rating', 'federation', 'birth_year', 'club', 'status',
  'start_round', 'team_id', 'board_order',
];

players.get('/tournaments/:id/players', (req, res) => {
  const rows = db.prepare(`
    SELECT * FROM players WHERE tournament_id = ?
    ORDER BY CASE WHEN fide_rating > 0 THEN fide_rating ELSE national_rating END DESC, name
  `).all(req.params.id);
  res.json(rows);
});

players.post('/tournaments/:id/players', (req, res) => {
  const t = db.prepare('SELECT id FROM tournaments WHERE id = ?').get(req.params.id);
  if (!t) return res.status(404).json({ error: 'Tournament not found' });
  const body = req.body ?? {};
  if (!body.name || !body.name.trim()) return res.status(400).json({ error: 'Name is required' });

  if (body.fide_id) {
    const dupe = db.prepare(
      'SELECT id FROM players WHERE tournament_id = ? AND fide_id = ?'
    ).get(req.params.id, body.fide_id);
    if (dupe) return res.status(409).json({ error: 'A player with this FIDE ID is already registered' });
  }

  const info = db.prepare(`
    INSERT INTO players (tournament_id, name, sex, title, fide_id, fide_rating,
      national_id, national_rating, federation, birth_year, club)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    req.params.id,
    body.name.trim(),
    body.sex ?? '',
    body.title ?? '',
    body.fide_id ?? null,
    Number(body.fide_rating) || 0,
    body.national_id ?? '',
    Number(body.national_rating) || 0,
    body.federation ?? '',
    Number(body.birth_year) || null,
    body.club ?? '',
  );
  res.status(201).json(db.prepare('SELECT * FROM players WHERE id = ?').get(info.lastInsertRowid));
});

players.put('/players/:id', (req, res) => {
  const row = db.prepare('SELECT * FROM players WHERE id = ?').get(req.params.id);
  if (!row) return res.status(404).json({ error: 'Player not found' });
  const body = req.body ?? {};
  const updates = [];
  const values = [];
  for (const field of EDITABLE) {
    if (body[field] === undefined) continue;
    updates.push(`${field} = ?`);
    values.push(body[field]);
  }
  if (updates.length) {
    db.prepare(`UPDATE players SET ${updates.join(', ')} WHERE id = ?`)
      .run(...values, req.params.id);
  }
  res.json(db.prepare('SELECT * FROM players WHERE id = ?').get(req.params.id));
});

players.delete('/players/:id', (req, res) => {
  const info = db.prepare('DELETE FROM players WHERE id = ?').run(req.params.id);
  if (info.changes === 0) return res.status(404).json({ error: 'Player not found' });
  res.status(204).end();
});
