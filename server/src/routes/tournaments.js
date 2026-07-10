import { Router } from 'express';
import { db } from '../db.js';
import { FIDE_DEFAULTS } from '../tiebreaks.js';

export const tournaments = Router();

const TYPES = ['swiss', 'roundrobin', 'team-swiss', 'team-roundrobin'];

// Fields the client may update via PUT, all plain columns.
const EDITABLE = [
  'name', 'type', 'venue', 'city', 'federation', 'start_date', 'end_date',
  'organizer', 'chief_arbiter', 'deputy_arbiter', 'time_control',
  'rounds_count', 'rating_type', 'points_win', 'points_draw', 'points_loss',
  'bye_value', 'tiebreaks', 'acceleration', 'status',
];

function rowToJson(row) {
  return { ...row, tiebreaks: JSON.parse(row.tiebreaks) };
}

tournaments.get('/', (req, res) => {
  const rows = db.prepare(`
    SELECT t.*, COUNT(p.id) AS player_count
    FROM tournaments t
    LEFT JOIN players p ON p.tournament_id = t.id
    GROUP BY t.id
    ORDER BY t.created_at DESC
  `).all();
  res.json(rows.map(rowToJson));
});

tournaments.post('/', (req, res) => {
  const { name, type = 'swiss', rounds_count = 9 } = req.body ?? {};
  if (!name || !name.trim()) return res.status(400).json({ error: 'Name is required' });
  if (!TYPES.includes(type)) return res.status(400).json({ error: 'Invalid tournament type' });
  const rounds = Math.max(1, Math.min(30, Number(rounds_count) || 9));
  const tiebreaks = JSON.stringify(FIDE_DEFAULTS[type]);
  const info = db.prepare(
    'INSERT INTO tournaments (name, type, rounds_count, tiebreaks) VALUES (?, ?, ?, ?)'
  ).run(name.trim(), type, rounds, tiebreaks);
  const row = db.prepare('SELECT * FROM tournaments WHERE id = ?').get(info.lastInsertRowid);
  res.status(201).json(rowToJson(row));
});

tournaments.get('/:id', (req, res) => {
  const row = db.prepare('SELECT * FROM tournaments WHERE id = ?').get(req.params.id);
  if (!row) return res.status(404).json({ error: 'Tournament not found' });
  res.json(rowToJson(row));
});

tournaments.put('/:id', (req, res) => {
  const row = db.prepare('SELECT * FROM tournaments WHERE id = ?').get(req.params.id);
  if (!row) return res.status(404).json({ error: 'Tournament not found' });

  const body = req.body ?? {};
  if (body.type !== undefined && !TYPES.includes(body.type)) {
    return res.status(400).json({ error: 'Invalid tournament type' });
  }
  if (body.tiebreaks !== undefined && !Array.isArray(body.tiebreaks)) {
    return res.status(400).json({ error: 'tiebreaks must be an array of codes' });
  }

  const updates = [];
  const values = [];
  for (const field of EDITABLE) {
    if (body[field] === undefined) continue;
    updates.push(`${field} = ?`);
    values.push(field === 'tiebreaks' ? JSON.stringify(body[field]) : body[field]);
  }
  if (updates.length) {
    db.prepare(`UPDATE tournaments SET ${updates.join(', ')} WHERE id = ?`)
      .run(...values, req.params.id);
  }
  const updated = db.prepare('SELECT * FROM tournaments WHERE id = ?').get(req.params.id);
  res.json(rowToJson(updated));
});

tournaments.delete('/:id', (req, res) => {
  const info = db.prepare('DELETE FROM tournaments WHERE id = ?').run(req.params.id);
  if (info.changes === 0) return res.status(404).json({ error: 'Tournament not found' });
  res.status(204).end();
});
