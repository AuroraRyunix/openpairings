// Fixed-width line builder/reader using the 1-indexed, inclusive column
// ranges from columns.js (e.g. [15, 47] for the name field).

export function newLine() {
  return [];
}

export function place(chars, [startCol, endCol], text, { align = 'left' } = {}) {
  const width = endCol - startCol + 1;
  text = (text ?? '').toString().slice(0, width);
  const padded = align === 'right' ? text.padStart(width, ' ') : text.padEnd(width, ' ');
  const start = startCol - 1;
  while (chars.length < start) chars.push(' ');
  for (let i = 0; i < width; i++) chars[start + i] = padded[i];
}

export function render(chars) {
  return chars.join('').replace(/\s+$/, '');
}

export function read(line, [startCol, endCol]) {
  return (line.slice(startCol - 1, endCol) || '').trim();
}
