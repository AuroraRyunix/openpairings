# Screenshots for the manual

Every screenshot slot in the chapters, in reading order. Until a file exists
the manual shows a checkered placeholder naming the file and what it should
show; once the file is in place the placeholder becomes the picture (after a
rebuild, or a recompile in development).

**Where the files go:** `priv/static/images/manual/<file>` (served as
`/images/manual/<file>`). The chapters refer to them as
`![alt text](screenshots/<file> "caption")`; see `PairingsEngine.Manual.Markup`
for the convention.

**How to take them**

- Light theme (the default), accent unchanged, English interface, browser zoom 100%.
- Window size as listed: the inner size of the browser window (the page, not
  the window frame). 1280x800 unless the slot says otherwise.
- PNG. Crop to the window's page area: no browser chrome, no desktop.
- Use an invented tournament and invented player names, never a real event.
- A test file in `test/pairings_engine/manual_test.exs` checks that this list
  and the chapters name the same files.

| File | Chapter | Page and state to capture | Window |
| --- | --- | --- | --- |
| `01-tournaments-list.png` | 1 Getting started | Tournaments page (`/`) with three or four tournaments listed, *New tournament* and the import buttons visible | 1280x800 |
| `01-tournament-tabs.png` | 1 Getting started | Any page inside a tournament, cropped to the top bar with the tabs Players, Pairings, Standings, Print, Advanced, Settings | 1280x800, crop to the bar |
| `02-leave-fide-mode-dialog.png` | 2 FIDE mode | The *Leave FIDE mode?* dialog at its first step, opened from Settings, FIDE (`/t/:id/settings/fide`), *Leave FIDE mode…* | 1280x800 |
| `02-settings-fide-page.png` | 2 FIDE mode | Settings, FIDE (`/t/:id/settings/fide`) with the tournament ID, event code and the homologated tick box filled in | 1280x800 |
| `03-new-tournament-form.png` | 3 Tournament set-up | The *New tournament* form on the Tournaments page, name and system filled in | 1280x800 |
| `03-settings-options.png` | 3 Tournament set-up | Settings, Options (`/t/:id/settings/options`) showing pairing system, Swiss engine and tournament rating | 1280x900 |
| `04-players-grid.png` | 4 Players | Players page (`/t/:id/players`) with about twelve players, the button row and the Display panel visible | 1280x800 |
| `04-add-player-form.png` | 4 Players | The *Add player* form with a FIDE search typed and its results listed | 1280x800 |
| `05-presence-cell-menu.png` | 5 Byes and absences | Players page with the presence cell's menu open on one player (Absent / Present) | 1280x800 |
| `05-hand-edits-menu.png` | 5 Byes and absences | Pairings page (`/t/:id/pairings`), a round paired, the *Hand edits* menu opened on a player's name | 1280x800 |
| `06-pairings-round-paired.png` | 6 Pairing | Pairings page (`/t/:id/pairings`) of a Swiss with round 3 paired and a few results in; round buttons, board table, Print and More visible | 1280x800 |
| `06-hand-edit-confirmation.png` | 6 Pairing | Pairings page: the confirmation of a *Swap with…* hand edit, boards before and after, with the banner that hand edits to the round are open | 1280x800 |
| `07-result-entry.png` | 7 Results | Pairings page mid-round, focus in a result field and the result list open on one board | 1280x800 |
| `08-standings-swiss.png` | 8 Standings | Standings page (`/t/:id/standings`) of a Swiss after round 5, tie-break columns visible | 1280x800 |
| `09-print-tab.png` | 9 Printing | The Print tab (`/t/:id/print`), a round paired, the list of documents with their *Print…* buttons | 1280x800 |
| `10-trf-import-review.png` | 10 Import and export | Tournaments page, TRF import review step for a file whose rounds break the FIDE pairing rules, with *Import anyway* | 1280x800 |
| `11-export-trf-rounds.png` | 11 FIDE report | Settings, Export (`/t/:id/settings/export`), TRF section with three rounds: one being played, one ready to send, one sent (receipt code shown) | 1280x800 |
| `12-teams-page.png` | 12 Teams | Teams page (`/t/:id/teams`) of a team tournament: four or more team cards with rosters in board order, and the *Boards per match* setting | 1280x800 |
| `12-team-standings.png` | 12 Teams | Standings of a team tournament after a few rounds, one team's tie-break working opened | 1280x800 |
| `13-categories-settings.png` | 13 Categories and norms | Categories (`/t/:id/categories`) with a few rule-based categories (rating band, age, women), prizes and the two switches | 1280x800 |
| `13-norms-forms.png` | 13 Categories and norms | Advanced, Norms (`/t/:id/norms`) with the IT3 / FA1 / IA1 / IT4 forms and the *Not ready to submit to FIDE* banner | 1280x800 |
| `14-openresults-settings.png` | 14 Publishing | Settings, OpenResults of a published tournament: the Off / Link only / Listed choice, *Automatically*, and a round's *Spectators see* level | 1280x900 |
| `15-handoff-list.png` | 15 Accounts and hand-off | Tournaments page with the *Hand off* action, and a handed-off tournament showing its read-only state and *Bring it back* | 1280x800 |
