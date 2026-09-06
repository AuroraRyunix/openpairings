# Changelog

All notable changes to OpenPairings are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Each entry is tagged so a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a vulnerability closed, or judged not to apply |
| [Verified] | checked against a reference, no code change |

## [0.40.0] - 2026-09-06

- [Feature] **The pairing rationale now shows what each bracket was paired
  FROM, not only what came out of it.** For a round Ainalrami paired, every
  bracket in "What the engine reported" opens with the S1/S2 the engine
  actually paired off (seeds and names, S1 marked when it is the players
  moved down), a colour table for every player in it - the run they have had
  so far, Whites minus Blacks with its sign, what they are due, and FIDE's own
  classification of that preference: absolute, strong, mild or none - and
  the pairs inside the bracket that the absolute criteria ruled out, each
  with its reason: met in round N, both absolutely due the same colour, or
  forbidden by the arbiter. That list is the answer to "why am I not playing
  him"; until now the record described only the optimisation and could not
  say. A bracket where nothing was ruled out says so, because "the criteria
  chose freely" and "the rules left no choice" are different defences.
  Rounds paired before this release have a version-1 record and render as
  before, without these blocks.

- [Change] **Engine updated to Ainalrami 0.18.0**, which is what reports the
  above. Pairing behaviour is unchanged: the engine's comparison against
  bbpPairings stayed at 100%.

## [0.39.0] - 2026-09-05

- [Feature] **The player list exports as CSV, shaped the way you need it.**
  Settings - Export now has a picker: choose which fields go in the file, put
  them in the order you want them (they come out in that order, not in some
  fixed internal one), sort the rows by seed or by name, and leave out anyone
  flagged permanently absent - a player who is just missing one round still
  appears. You can also choose what separates the columns, which matters more
  than it sounds: Excel splits on the list separator of the machine's locale,
  so on a Belgian or Dutch Windows a comma-separated file opens as a single
  column of text and a semicolon-separated one just opens. The whole choice
  lives in the download link, so it can be bookmarked or passed to somebody
  else. Names that begin with `=`, `+`, `-` or `@` are neutralised on the way
  out - a spreadsheet would otherwise run them as formulas.

- [Fix] **Export was unreachable from the Settings menu.** The top-bar
  "Settings" menu listed seven of the ten settings pages: OpenResults, About
  and Export were missing, so the only way to reach Export was to open some
  other settings page first and find it in the row of tabs there. Anyone who
  did not already know it existed could not get to it. Both menus now list the
  same pages in the same order.

## [0.38.0] - 2026-09-05

- [Fix] **Deleting a player turned their opponents' losses into points.** The
  Remove button on the Players grid nils the seat and leaves the result
  standing, so every game the deleted player had survived as an opponentless
  row. Keizer scored that as an unpaired bye worth half a ladder rung - paid to
  whoever had LOST the game, with the loss dropped from the W/D/L line as well.
  The result now stands, and the vanished opponent is worth nothing, which is
  what a Keizer win means: what a win pays IS the opponent's value, and there
  is no longer an opponent to value. Standings already read the row this way;
  Keizer no longer diverges from it.

- [Fix] **An odd round robin lent half a point to everyone else's tiebreaks.**
  The structural bye - the player the Berger schedule sits out against the
  phantom - was recorded as a "requested-zero" row, a type chosen purely for
  its point value. That type also carries "the player asked for this", so
  C.07 Art. 16.3 re-counted the trailing bye as a draw: the byed player's
  adjusted score rose half a point in every opponent's Buchholz and
  Sonneborn-Berger. Because SB weights that score by the points scored against
  them, the error was not even uniform - whoever beat them gained 0.5 and
  whoever drew gained 0.25 - so it reordered players tied on score. A bye
  nobody requested is now involuntary, matching the rule already applied to a
  Swiss pairing-allocated bye. A genuine requested bye in the same tournament
  is unaffected.

- [Change] **Engine updated to Ainalrami 0.17.0.** Two TRF defects that could
  change a published round: a round already paired but not yet played was
  dropped when the file was read back, so the round was paired a second time;
  and an XXP "these two must never meet" line written with a comma instead of
  a space was discarded in silence rather than refused.

## [0.37.1] - 2026-09-05

- [Fix] **A hall screen opened by URL never cycled.** `?display=1` exists so a
  machine can be pointed at an address and left alone, and that was the one
  path that never started the timer - it was reached only from the button, the
  pause toggle and its own tick. The screen showed the first page of boards
  for the rest of the tournament.
- [Fix] **A vacated seat was published as a full-point bye whatever the result
  said.** A board with one seat emptied printed the tournament's bye value
  unconditionally, so one carrying a recorded forfeit went to the federation's
  public site as a bye. It now shows what the arbiter entered, and falls back
  to the bye value only when there is genuinely no result.

## [0.37.0] - 2026-09-04

- [Fix] **A player who was away now appears on the published page.** Declared
  absences are not pairings - they live in their own table - so nothing about
  them reached the results, and those players were simply missing from the
  round they had told the arbiter about. They now appear the way the
  federation's own software writes them: the same row as a bye, carrying the
  absence's point value and the word "Afwezig". The value is read from the
  standings code rather than decided again, so the page cannot disagree with
  the table printed above it.
- [Feature] **A strip of round links above the results**, so a long page can be
  jumped rather than scrolled. Only the rounds: the federation's own strip also
  links to sections this file does not contain, and a link to an anchor that is
  not there is worse than no link.

## [0.36.3] - 2026-09-04

- [Fix] **A bye now sits after the boards, not among them.** It was sorted on
  its board number like any other pairing, so it landed between board three
  and board four while its own board cell was blank - reading as a gap in the
  numbering. A published round puts its bye after the last numbered board,
  and so does this now.
- [Fix] **The points a bye awards print the way the federation prints them** -
  `1` rather than `1.0`, beside the `0.0` in the points column, and a
  half-point bye shows the same half symbol the results use.
- [Change] **The version reads as a version in the federation's list, and as
  itself in the file.** That list's "Vers." column takes whatever follows the
  last hyphen, so a plain `v7.00` arrived as `7.00`. The default is now
  `OpenPairings <release> -v7.00`: the column shows `v7.00`, and anyone
  opening the file sees which program wrote it and which release. Still
  settable.
- [Feature] **The page carries a footer saying what made it** - the same
  three-cell strip a SWAR file ends with, in the same place, reading
  the OpenPairings release, the pairing engine's version, and a build stamp.
  The engine is there because it is the one fact about a published round that
  is otherwise nowhere in the file, and it is what somebody asks about when a
  pairing looks wrong. The federation's software signs that strip with its own
  name and its author's initials; neither is copied onto a page they had no
  hand in.

## [0.36.2] - 2026-09-04

- [Fix] **Publishing to the federation failed at the indexing step.** The
  guid's curly braces were sent raw, and `{` and `}` are not legal in an HTTP
  request target - the client refused before anything left the machine.
  SWAR's own notes say to keep the braces and its tool needs a flag to manage
  it, which reads as though the server demands them; really that flag just
  makes a tool willing to send an illegal request. The federation's own
  published addresses percent-encode them, and the server decodes them back
  before its script runs. Upload was never affected; a tournament already
  staged can be finished with "Finish indexing".
- [Fix] **A bye now reads like a bye.** It put the word in the result column
  and left the opponent blank, so the label floated in the wrong place. A
  published file with byes in it settled the shape: the points awarded go in
  the result column and the word goes where the opponent's name would be. The
  tournament's own bye value is shown, rather than assuming one point.

## [0.36.1] - 2026-09-04

- [Fix] **A board with an empty seat took the SWAR page down.** Asking for a
  tournament's federation results page returned a server error whenever any
  round held a pairing with no white player - a seat an arbiter had vacated
  rather than a board they had deleted. Every shape now renders: a bye, a
  board seated on one side only, and a fully vacated board, which renders
  nothing at all rather than an empty row.

## [0.36.0] - 2026-09-04

- [Feature] **A tournament can be published to the Belgian federation's
  results site.** The sixth Belgian feature: generate the SWAR results page
  and send it, in the two steps the federation's server expects - upload, then
  index. Admin only, gated on the pack, and never automatic: no queue, no
  retry, no publish-on-save. It happens when somebody presses the button, on a
  confirmation that names the tournament and says where it is going. When the
  server refuses, its own message is shown - "bad Guid date" tells an arbiter
  which part is wrong, where "upload failed" would not.
- [Change] **An upload that stages but does not index can be finished.** The
  two steps are recorded separately, so a tournament whose file reached the
  server but never got indexed offers to run the second step again instead of
  making somebody upload the whole thing blindly.
- [Fix] **A tournament exported to SWAR now keeps its identity.** The `.swar`
  file fell back to a bare UUID when the tournament had no SWAR id yet - not
  the shape the results site accepts, so an upload from SWAR would have come
  back "bad Guid date", and never stored, so exporting twice produced two
  identities for one event. Exporting now mints the id in the documented shape
  and keeps it, which is what lets an arbiter carry on in SWAR and upload from
  there without publishing the same tournament twice.
- [Fix] **A flaky account test no longer depends on the whole database.** It
  set a password on every user row and asserted exactly one existed, which
  held only while no other test had left one behind - so it failed on some
  orderings and passed on others.

## [0.35.0] - 2026-09-04

- [Fix] **An odd-sized round robin locked its cycle count a round too early.**
  The rule that keeps single/double switchable while the rounds paired so far
  stay inside cycle 1 measured a cycle as "players minus one" - true only for
  an even count. An odd count plays a full round per player, because the bye
  is a phantom opponent, so a five-player event locked at round 4 of its own
  five-round schedule, and a five-player double locked at round 8 of ten. The
  length now comes from the schedule builder itself rather than a second copy
  of the arithmetic.
- [Fix] **A late registration could unlock a cycle count that was correctly
  locked.** The same rule counted every player row, including someone who
  registered after round 1. A round robin never reschedules around a
  latecomer - they never receive a pairing number - so counting them implied
  a longer schedule than exists, and a fully-paired four-player event read as
  editable again the moment an unrelated fifth player signed up. It now
  counts the frozen roster the schedule was actually built from.
- [Verified] **The rest of the round-robin flow was audited and is correct.**
  Schedules, colours across both cycles, the odd-count bye, standings and
  tie-breaks with unplayed games, withdrawals, the crosstable, and a TRF
  round trip were all swept for three to ten players and both cycle counts:
  every pair meets exactly once, the second cycle reverses the first's
  colours exactly, and nobody receives two byes. The round trip and the
  property sweep are now permanent tests.

## [0.34.0] - 2026-09-04

- [Feature] **A locked setting is a guard rail now, not a wall.** Settings
  that freeze once a round is paired - the pairing system, the engine, the
  match formats, category pairing, the absence-point rules - can be unlocked
  one at a time and changed. The lock still stops the accident; it no longer
  stops the decision.
- [Change] **The warning says what it costs, per setting.** Clicking a locked
  control already explained why it was locked; it now offers to unlock, above
  a sentence naming what that particular change would do to rounds already
  played. Swapping the pairing engine hands the new one a history it did not
  produce; changing the absence rules rescores every paired round on the
  spot. "Are you sure?" would have told an arbiter nothing.
- [Change] **An unlock lasts one save.** It lives in the page, never in the
  database, and closes again when the save succeeds - so it cannot quietly
  stay open for the rest of the tournament. A failed save keeps it, rather
  than making the arbiter click twice for one change.
- [Change] **Changing an unlocked setting is written to the audit trail** as
  its own entry, with the field and both values, rather than disappearing
  into the diff of an ordinary settings save. It is the record that makes the
  decision defensible weeks later.

## [0.33.0] - 2026-09-04

- [Change] **"Live view" is now "Local view".** "Live" reads as live to the
  public, and that page is the opposite of public: it is the screen in your
  venue and your own tab, and since it began showing only published rounds
  the old name invited exactly the confusion that gating exists to remove.
  What is public is OpenResults. The address and the module keep their names;
  only the label changed.
- [Fix] **The pairing list reads as a pairing sheet again.** White was
  left-aligned, the result centred in a fixed column, and black
  left-aligned after it - so a short name drifted away from the result and a
  long one crowded it, and the result never looked centred between the two
  players. White is now right-aligned, black left-aligned, and the two names
  share the width equally, the way a printed pairing sheet reads. The
  projector view follows, with a narrower result column since it is read from
  across a room.
- [Change] **Standings printing lives with the standings.** The pairings page
  no longer carries a Print standings button. Printing standings as they
  stood after an earlier round is no longer offered in the interface, only by
  its address - the standings page has no round to pin it to, and pinning one
  to that page's own Print would have silently dropped the manual-ranking
  banner, which only appears when no round is requested.

## [0.32.0] - 2026-09-04

- [Change] **A TRF will not leave without its round dates.** FIDE requires
  one per round, and a file that reaches them without it comes back after
  the event, when fixing it means re-exporting and re-submitting rather than
  filling in a field. The refusal names which rounds are missing and points
  at Settings, Dates.
- [Change] **A registration list still exports, dates or not.** It has no
  rounds to date, and it is the file an arbiter checks a registration list
  against - refusing it would have made the commonest pre-tournament export
  impossible. A partial export (`?rounds=1-3` of a nine-round event)
  likewise needs dates only for the rounds it actually contains.

## [0.31.0] - 2026-09-04

- [Fix] **The column ruler now appears on a roster too.** The ruler and the
  field legend were written only when the tournament had at least one round
  - but a registration list is exactly the file somebody holds against the
  column positions, checking whether a name has overrun its 33 characters.
  The legend now appears either way, stopping at the rank column rather than
  inventing game blocks for rounds that do not exist. Engine pin moved to
  Ainalrami v0.16.0, which carries the fix.

## [0.30.0] - 2026-09-04

- [Fix] **A sync during a live round is a warning, not a wall.** The refusal
  was wrong the moment it met a real installation: "in progress" means
  paired and not yet fully scored, which for a club championship is true
  from September to June, so the rating lists could never have been synced
  at all. The warning also names three and counts the rest, rather than
  listing a season's worth in one sentence.
- [Change] **And the risk it guarded is far smaller than it was.** the write
  lock is free between chunks, and what remains long is two single
  statements - the bulk delete and the full-text index rebuild - measured in
  seconds. A result entered during one of those waits rather than fails, and
  if it ever does fail it says so.

## [0.29.0] - 2026-09-04

- [Change] **A round is live, or it is not.** Putting a round on a screen in
  the hall is publishing it - the people it would be withheld from are the
  ones standing in front of it - so there is no longer a state where a round
  is on the wall while it is held back from the results site. A round is
  live, or it is not. When a paired round has not been published, the page
  says so and links to where you publish it, rather than quietly looking a
  round behind.
- [Change] **The standings follow the same round.** showing round 4's boards
  above a table that already counts round 5's results would give the
  withheld round away just as surely.

## [0.28.0] - 2026-09-04

- [Feature] **A projector view that cycles when the boards do not fit.**
  When there are more boards than the screen can hold it pages through them,
  about twelve seconds each, and comes back round. A page counter and a
  progress bar say which page is up and how long is left - somebody looking
  for board 47 needs to know it is coming and roughly when, or a rotating
  screen is worse than a still one. Tap to pause and read; tap again to
  carry on. If every board fits on one screen, none of that appears.
- [Change] **It fits itself to whatever screen it is plugged into.** The
  browser measures how many rows the glass can hold and tells the server,
  and re-measures when the window is resized or the screen rotated, so
  nothing has to be configured for a particular television.
- [Change] **High contrast by default, because it is aimed at a hall.** "Use
  my theme" switches back for a dark hall or a good screen.
- [Change] **A URL that opens straight into it, for an unattended screen.**

## [0.27.0] - 2026-09-04

- [Change] **One code, one phone.** The first device to scan the QR or type
  the 6-digit code claims it; a second is told the code has already been
  used and to ask for a new one. Before this, one code enrolled any number
  of phones until it expired, which meant a printed sheet left on a table
  was a working credential for a day, and the audit trail - which records
  the code, not the device - could not tell three helpers sharing one code
  apart.
- [Change] **A code can carry a name, so the right one reaches the right
  person.** The list also says whether a code has been scanned yet, which is
  how you tell that the one you just handed over actually arrived.
- [Change] **Codes already handed out become single-device too.** Unlike the
  access levels, which were backfilled to keep existing phones exactly as
  they were, this refusal is visible and recoverable: the second phone is
  told why, and the arbiter mints another.

## [0.26.0] - 2026-09-04

- [Change] **The phone shows what is left to do, not what is done.** A board
  drops out once its result is in, the header counts boards remaining rather
  than boards paired, and **Show all** brings the finished ones back for
  checking or correcting. At helper level a finished board could not be
  changed anyway, so leaving it in the list only asked someone to scroll
  past work they were not allowed to touch.
- [Change] **A board you just entered waits a moment before it goes.**
  Clearing a result returns the board to the list immediately, with no
  confirmation of its own, because that is already what clearing looks like.

## [0.25.0] - 2026-09-04

- [Feature] **An enrolled phone gets only the access it needs.** A code is
  minted as a **helper** by default: it may fill in a result on a board that
  is still blank, may not change one already entered, and sees only the
  latest paired round. A **deputy** keeps the old run of the place - any
  paired round, corrections included. Either can be limited to a range of
  boards. The level and range show in the device list and in the audit
  trail, which matters because one code can be used by any number of phones:
  the trail records the code, so "Boards 1-10, helper" says far more than a
  token id when two people disagree about a board.
- [Change] **Codes already in circulation keep the access they had.** The
  migration backfills every existing enrolment to **deputy**; only newly
  minted ones default to helper. A migration should not quietly narrow a
  credential somebody is already carrying.
- [Change] **Phone enrolment is refused outright on a local run.** A local
  run has no accounts at all, so an enrolment token would be the one
  credential that worked from another machine the day such a run could
  answer one.
- [Fix] **Messages on the phone's result page were invisible.** That page
  had no flash outlet, so every `put_flash` on it went nowhere - including
  the existing "this tournament is archived" refusal, which meant a helper
  tapping a result on an archived tournament saw nothing happen at all.

## [0.24.0] - 2026-09-04

- [Change] **No results site, no publishing controls.** There was a
  "Published / Not published" state and a dead "Turn on" button on a page
  that could not publish anything. A tournament that is already publishing
  keeps its controls even if the connection later goes away - otherwise
  there would be no way to turn it off.
- [Feature] **Publish and unpublish a round where the boards are.** Both
  already existed as buttons in the round header, which is easy to miss;
  they now sit where the boards are. In "publish immediately" mode neither
  appears, because that mode means every round is public the moment it is
  paired - a line says so and points at the setting.
- [Change] **A rating list sync no longer holds the database for the whole
  import.** They used to run the whole replace inside one transaction, and
  SQLite allows a single writer for the whole database, so every other write
  queued behind them - which is how entering a result could fail. Each chunk
  now commits on its own and the lock is free in between. The checks that
  refuse a corrupt or truncated download moved to before anything is
  deleted, since there is no longer a transaction to roll back: an import
  that parses no rows, or fewer than half the current list, still leaves the
  existing list untouched.
- [Fix] **An interrupted FIDE sync could break player search for good.** The
  import drops the search index's triggers and recreates them afterwards;
  with no transaction to undo that, a cancelled run left them gone, and the
  next run - which recreated only what it had found at its own start - found
  none and so restored none. From then on every change to a player would
  have left the index stale, silently. The triggers now have built-in
  definitions to fall back on, and a sync that finds them missing says so
  and puts them back.

## [0.23.0] - 2026-09-04

- [Fix] **Entering a result could fail while a rating list was syncing.** A
  sync holds SQLite's single database-wide write lock for its whole run, so
  a result entered at that moment waited 15 seconds and was then refused -
  and because a lock arrives as a raised error rather than a returned one,
  it bypassed the handling every write has and took the page down with a
  generic "something went wrong". Nothing was ever silently lost: a refused
  write is never written, and the page re-reads the database on the way
  back. But the arbiter had no way to know that. It now says, in as many
  words, that the change was **NOT SAVED** and nothing was written.
- [Change] **A sync yields to a round in progress.** A rating list can be
  refreshed at any time; a result cannot wait for one, so the sync is what
  yields. Both the FIDE and the Belgian sync are covered, and the guard is
  on the handler rather than the button - a control missing from the page is
  still an event anyone can send.

## [0.22.0] - 2026-09-03

- [Change] **Every version bump now publishes a release with binaries.**
  Releases used to be gated on a tag alone, and tags were easy to forget:
  the version moved from 0.18.0 to 0.22.0 with none behind it, so the newest
  build anyone could download was four releases old. A push to main whose
  `mix.exs` version has no release yet now cuts one, which means bumping the
  version and cutting a release are the same act. The commits after a bump
  publish nothing until the version moves again.
- [Fix] **The Belgian rating list sync stopped at “0 of 35849”.** Clearing
  the old roster fired one full-text-index scan per deleted player, so the
  cost grew with the square of the roster: measured at 141 ms for 1,000
  players, 538 ms for 2,000, and 2,136 ms for 4,000. At the current ~36,000
  members that came to roughly 171 seconds, just past the 180-second
  watchdog that gives up on a stalled import - so a sync that had been
  quietly slowing for weeks began failing outright. The index is now emptied
  in a single statement first: the same clear-out takes **145 ms**. A test
  guards the cost.
- [Fix] **Settings cards had no styling at all.** `.set-card` was used in
  six places across the optional-features and admin pages but never had a
  CSS rule, so each one rendered as bare text on the page background - no
  surface, no border, no padding.
- [Change] **Each federation now reads as a pack you can switch on.** Each
  switch is a full-width row you can click anywhere on, and an enabled one
  is tinted. The reassurance about tournaments is styled as an aside rather
  than competing with the cards that carry the switches.
- [Change] **A deploy no longer slows the running site to a standstill.**
  The build ran unconstrained on a two-core server while the previous
  version was still serving, taking both cores; it now runs on one, at low
  priority.

## [0.21.0] - 2026-09-02

### Added

- [Feature] **The Belgian features are now yours to switch on or off, one at a time.** A new page under your account lists them: the national rating-list sync, the player lookup that reads it, the bulk club update, and SWAR import and export. Off, the buttons are simply not there rather than there and refusing.

  **Turning one off never changes your tournaments.** It hides an entrance. Everything already imported - players, clubs, scores, categories - stays exactly as it is and scores exactly as it did; there is a test that imports a Belgian club tournament, turns all five off, and checks the standings and every scoring setting are identical afterwards.

  The lookup and the club update read the list the sync fetches, so with the sync off they search whatever was last downloaded. That is a real choice ("last month's list is fine"), so the page explains it rather than the switches enforcing it.

  Nobody loses anything on upgrade: if this machine is set up for the KBSB, or you have ever imported a SWAR tournament, or a member list is already downloaded, all five arrive switched on.

### Fixed

- [Fix] **Buttons could disappear off the edge of the page.** The top bar and the tournaments header packed their controls into a row that could not wrap, and the page clips what overflows rather than scrolling it - so a control that did not fit was not merely off-screen, it was gone and unclickable. In Dutch it bit hardest, because the words are longer: "Log out" is "Afmelden", "Tools" is "Hulpmiddelen", and at a 1000-pixel window the log-out link was rendering 25 pixels past the edge. It was already happening in English too, on a part-width laptop window with a tournament open. The rows wrap now, and a test keeps them wrapping.

### Changed

- [Change] **Seven themes, not eleven.** Solarized, Solarized Light, Nord and Nocturne are retired; Catppuccin is now called **Mocha**. If Catppuccin was your choice you keep it under its new name - the browser rewrites the stored value rather than resetting you, which is the difference between a rename and a removal. A retired theme falls back to the system default instead of leaving you on a palette that no longer exists.

### Added

- [Feature] **Three new looks, and two retired.** **Slate** (cool grey-blue, for a screen rather than a page), **Paper** (warm off-white with a brick accent) and **Board** (cream and board-green, the colours of the equipment) - the same three rooms the results site and the KBSB database manager already offer, so the suite looks like one thing. Dracula and Tokyo Night are gone.

  If either of those was your choice, your browser will quietly move you to the system theme rather than leaving you on a palette that no longer exists. Board's warning and error colours had never been chosen anywhere, so they are new: a leaf green kept deliberately lighter than the board-green accent so success does not read as "accent", boxwood ochre, and the brick red of a fallen flag.

### Changed

- [Change] Every theme and accent combination is still checked for readable text on every build - 616 measurements across eleven themes, none below the threshold.

## [0.20.0] - 2026-09-02

### Added

- [Feature] **Bringing a tournament back now brings the results with it.** Returning the file replaces this copy with what came back and then unlocks, in one go - if any part of it fails, nothing changes and the tournament stays locked. A restore point of the frozen state is kept first, so a wrong file can be undone; if that restore point cannot be written, the return is refused rather than risked.

  Three things must agree before anything is replaced, and one of them binds the contents rather than just the wrapper: the returning file's own history has to contain the moment this copy was handed over. A file that never left here cannot carry it.

  A tournament whose lock was forced open refuses a returning file, because after a forced unlock both copies can have real work in them - it says so, and names the safe route instead of guessing which one wins. What still does not come home is the record of who typed the results over there; the results themselves do.

- [Feature] **Move a tournament between this server and a copy on your own machine.** Hand it off and it locks here - read-only, with a banner on every page saying where it went - and downloads a file. Import that file elsewhere and the tournament is live there. Bring it back with the returning file and this copy unlocks. It is a checked-out library book, not a sync: exactly one copy is live at a time, and nothing is ever merged.

  Handing off carries the audit trail with the tournament, and the collaborator list as invitations to re-accept. It deliberately does not carry helper phones - a code that lets a phone enter results here must not start working somewhere else because a file moved - so those need re-enrolling on the other side. The panel says all of this before you commit to it.

  If the other machine is lost, stolen or wiped, an owner can force the lock open. It is folded away, asks you to type UNLOCK, records itself separately in the audit log, and says the true thing rather than a vague warning: the other copy still exists, this does not close it, and whoever has it must never open it again.

### Fixed

- [Fix] **A checked-out tournament can no longer be binned, purged or archived here.** Purging one destroyed the row the returning file needs, stranding the other copy permanently.
- [Fix] **Taking a tournament off the results site checked whether it was allowed to - after doing it.** On a frozen tournament the published copy, its history and its collected entries were destroyed and the key cleared, and only then was the change refused. Rotating a public address hit the same path, so a refusal left the tournament unpublished with its key gone.
- [Fix] Two pairing entry points read the archived flag directly instead of asking whether the tournament was writable at all, so they would have paired a checked-out tournament and then failed mid-write. A results import into one crashed outright, and generating a phone QR for one produced a code whose results the server then refused.
- [Fix] Nine refusals said "this tournament is archived" whatever the real reason was - sending an arbiter to unarchive a tournament that was not archived.
- [Change] **The FIDE/KBSB sync line is gone from the top bar.** The Connections page still shows both in full; the top bar had too much in it.

## [0.19.0] - 2026-09-02

### Fixed

- [Fix] **Buttons you can actually read, on every theme.** The main action button filled itself with your accent colour and wrote white on top - hardcoded. Across the ten themes and nine accent choices, **64 of 90 combinations failed** the accessibility threshold for readable text, the worst at 1.81:1 against a required 4.5. On Nord the button you are most meant to find scored 2.00. Each theme and accent now names the ink that belongs on it - Nord's is 6.24 - and the delete button, which had the same fault in six themes, is fixed the same way. Eight other places writing white on a coloured fill went with them; no hardcoded white is left in the stylesheet.
- [Change] **One action per screen actually looks like one.** The report downloads on the norms pages and the arbiter tools - IT3, IT4, FA1, IA1 and the combined forms - were each styled as the page's main action, so a page offering six of them shouted six times. They are the quieter tonal style now; saving still stands out, because saving is the thing you cannot get back by clicking again. Same for the "Add" button that builds a forbidden-pairing list, which is a step rather than the commit.
- [Feature] **A quieter middle button** (`tonal`) for the second action on a busy page: tinted with the accent and lettered in it, rather than shouting or disappearing. Readable by construction on every theme - the worst combination measures 4.65.
- [Fix] Two hover states were darker than the thing they hovered over, and one theme's accent hover walked its own contrast down; both now move away from their ink rather than into it.
- [Fix] The Save button on the publishing card carried a class that does not exist (`pe-btn-primary`), so it has been rendering as an ordinary button since it was written.

- [Fix] **The last yellow boxes, on Nord and every other theme.** The earlier fix moved the app's own components onto the theme's colours, but six places were reading daisyUI's `--color-warning`/`--color-success` instead - tokens no theme overrides, so they stayed a fixed amber and green while everything around them changed. The changelog's own [Fix] tags were one of them. Two more surfaced while widening the net: a warning panel tinted with a hardcoded red, and three connection-status rules reading a colour token that does not exist, so their grey never applied in any theme.
- [Fix] The theme test now reads the templates as well as the stylesheet, understands `oklch()`/`hsl()`/`rgb()`, and fails on any colour token the themes do not actually override - the three gaps that let the above through.

- [Fix] **Standings ties are ordered by an explicit rule** - rating, then name, then pairing id - instead of whatever order the rows happened to arrive in. On a fresh tournament with no games the previous order could differ between runs; no computed placing changes.

- [Security] **In production the server now listens on loopback only.** The only thing that ever connects to it directly is the tunnel on the same machine; binding every interface left the whole app one firewall rule away from the internet. `OPENPAIRINGS_LISTEN_IP` widens it deliberately for any deployment that needs that. Local mode was already loopback-only.
- [Security] **The build pipeline pins every GitHub Action to a commit** instead of a movable tag, grants write access only to the tag-gated release step rather than every build, checks the lock file on every run, and lets Dependabot propose action updates.
- [Security] **The deploy script no longer prints the server's secrets.** It read the systemd unit - `SECRET_KEY_BASE`, the mail password, the tokens - through the helper that echoes output, on every redeploy after the first; that read is silent now, the deploy-notice token travels to `curl` over a pipe instead of a command line, and anything that still gets printed passes through a redactor. The same script now refuses an unknown SSH host key, prefers key authentication (`DEPLOY_SSH_KEY`, password only with `DEPLOY_ALLOW_PASSWORD=1`), runs the service as its own system account with systemd's sandboxing, makes the database directory private, and sets `TRUSTED_PROXY_HOPS=1` so rate limits count real visitors. All of it takes effect on the next deploy. The secrets already printed to terminals should still be rotated.
- [Fix] The local-mode documentation now says, in one sentence, why the binary must never sit behind a tunnel or reverse proxy.

- [Change] **Pairing engine Ainalrami v0.15.0.** The TRF reader and writer now count columns in bytes like every other implementation, so a file from Swiss-Manager or bbpPairings with an accented name imports with that player's games intact; a byte-order mark no longer swallows the first line; a truncated line no longer yields a wrong opponent number; and the matcher breaks ties on a fixed rule rather than map order (checked byte-identical over 72,140 pairings). Nothing in the pairings this app produces changes.

- [Fix] **Ten forms can now recover what you typed after a dropped connection.** They had no `id`, so LiveView could not restore them after a reconnect - on venue wifi that meant retyping. The test suite now refuses a form without one, so it cannot come back.

- [Security] **Two phone-entry codes can no longer be active at once.** A unique index now enforces it; generation draws again on a collision instead of giving up after twenty tries and inserting the duplicate; and the public code page answers "wrong code" rather than a 500 if the database ever drifts.
- [Security] **Password-login lockout counts the real client address**, not the tunnel's, once `TRUSTED_PROXY_HOPS` is set - so thirty wrong passwords from one place lock out that place, not everybody.
- [Security] **The rate limiter counts atomically.** Under a burst of two hundred simultaneous hits it counted 109 to 127; it now counts two hundred.
- [Security] **A newline in the language switcher's return address no longer causes a 500.** The filter is an allowlist now, and anchored so a trailing newline cannot slip past it.
- [Fix] **Revoking a helper's phone access reaches their open page immediately** - it is sent back to the code screen - instead of only when they next try to enter a result.
- [Fix] A crafted settings event with an unknown field, or a context-menu position that is not a number, no longer crashes the arbiter's own page.
- [Change] The four pages that show bye chips now fetch the absence-cap counts once per render instead of once per chip; the unused second rate-limiter module is removed.

- [Security] **The public norms tool caps the number of extra arbiters at twenty.** The count reached the server unchecked through a hidden form field and drove the spreadsheet expansion; a single request asking for a hundred million meant ten gigabytes of XML. It is clamped at every parse, and the expansion itself refuses anything above the cap as a last line of defence.
- [Fix] **An out-of-range "master file" choice on the public tools page no longer crashes the session**; the index is parsed and clamped, and the combiner reports an invalid choice instead of raising.
- [Fix] **A search for a number longer than any FIDE id no longer crashes** - on the players page, the arbiter picker, or the results site's lookup. Anything outside the real id range is simply "no such player".
- [Change] The public tools page computes its player-count explainer once per file change instead of on every render, and the norms page debounces its officials form.

- [Fix] **A SWAR file with one unusable player no longer crashes the import.** A blank name or an out-of-range FIDE id made the whole import screen fall over instead of saying which player was wrong; it now reports the player and the field and writes nothing, as the TRF importer already did.
- [Fix] **A corrupt SWAR file can no longer pair a player against themselves, or against someone whose own record disagrees.** Each side's opponent is now checked to name the other back, the same two guards the TRF importer has had since July.
- [Fix] **Two SWAR players sharing an internal number are refused up front** instead of one of them silently losing every game to the other.
- [Fix] **Absence caps above 255 no longer wrap when exported to SWAR** (300 used to become 44); the export clamps and logs, and the settings form refuses the value in the first place.
- [Security] **A backup file cannot ask for an absurd key-stretching count.** The restore command used whatever iteration count the file's own header claimed; it is now bounded to a sane range.
- [Security] **The FIDE rating-list download checks the archive's declared size before inflating it**, with a generous ceiling, so a hostile zip cannot exhaust memory on its way in.
- [Fix] A tournament whose name has no Latin letters exports as `tournament-<id>.trf` instead of `.trf`.

- [Fix] **A substitution dialog left open could seat one player on two boards.** "Swap with…" checked the bench player once, when the dialog opened, and the dialog deliberately stays open while another arbiter edits the round. If that player was paired onto another board in the meantime, confirming still went through. The write now re-checks, inside its own transaction, that the player belongs to this tournament and is not already seated in the round, and refuses otherwise. This was the third of three seating writes the August sweep named; the other two were fixed then.
- [Fix] **Un-pairing a round is one transaction again.** It deleted the round, then the byes, as two separate steps; a crash between them left bye rows that a later re-pairing silently kept, and a player seated for real that round was scored for a game *and* a bye. Both deletes now commit together, and the standings ignore - with a warning in the log - any bye row for a round in which the player has a game.
- [Fix] **A restore that fails no longer moves the history pointer.** The "before restoring to…" snapshot and the pointer move were committed before the restore itself ran; when the restore was rejected, the tree pointed at a state the data was never in. All three now succeed or fail together.
- [Fix] **Accepting the same registration twice at once created two players.** The pending-to-accepted transition is now the guard: whoever claims it first creates the player, the other gets "already decided".
- [Fix] **A player's team must belong to the same tournament.** The edit form could carry a team id from anywhere; nothing displays teams yet, so this closes a door rather than a hole.
- [Fix] **The external pairing engine now has a deadline.** JaVaFo ran with no timeout; a pathological position could hang the arbiter's pairing indefinitely. It is now given sixty seconds and reports an error afterwards.
- [Change] **Absence-cap counts are fetched in one query per tournament** rather than one per rendered row, on the pages that adopt the new call; the four current callers still use the old one and will follow.

- [Fix] **Amber warning boxes ignored the theme.** Archived banners, the "careful, this is hard to undo" notes on the settings pages, the pairing-confirmation warnings, the history rail's tags and both status pills in the top bar were painted with a fixed amber, so on Nord, Dracula, Tokyo, Nocturne and Catppuccin they sat in the middle of the palette looking like something had failed to load.

  Every theme has always defined its own `--warn` — Nord's is its aurora yellow, Dracula's its pale citrus — these components just never used it. They do now, along with the reds and greens beside them, so a warning looks like a warning in the theme you actually chose.

  Two of them were worse than off-key: the OpenResults visibility toggles and the on/off state pills referenced a colour that does not exist, so *every* theme, including the two the app ships with, fell through to one hardcoded green.

  A test now reads the stylesheet and fails on a colour written into a component instead of taken from the palette, on a theme that forgets to redefine one, and on a fallback to a colour no theme defines. That last check is what would have caught the missing green.

## [0.18.0] - 2026-08-29

### Added

- [Feature] **Where you publish and where spectators go are two settings.**
  They were one field doing both jobs, and it cost something: on a server
  hosting both applications, every publish left the box, went out to the CDN
  and came back in through the tunnel to reach a process one hop away —
  because the single address had to be the public one. Pointing it at
  `localhost` would have broken every share link, QR code and printed URL.

  Leave the new "Public address" blank and nothing changes. Set it, and the
  server can send over loopback while spectators still get the public name.
  The win is not speed — publishing is queued and nobody waits on it
  — it is that two applications on one machine no longer need DNS and a
  CDN to be up to talk to each other.

  On a hosted install the deploy configures all three (send address, public
  address, token) from values it already has, and **reconciles them on every
  run** — so change them in the deploy configuration, not on the
  Connections page, where the next deploy would undo the edit. The `mix
  pairings.publishing` task still defaults to filling blanks and refusing to
  overwrite; it is the deploy, which owns one known host, that asks for the
  stronger behaviour.

- [Feature] **A record of machine-wide actions.** Role changes, backup
  downloads, publishing changes and rating-list syncs are now audit entries
  rather than log lines, and an administrator can read them on the Admin
  page. Log files rotate; a record should not. The audit trail holds them
  alongside per-tournament rows, and a tournament's own trail is unchanged.

- [Feature] **The standalone build opens your browser.** It used to start a
  server and sit there, leaving you to know that `http://localhost:4000` was
  the thing to type. It now opens your default browser at the right address
  once the server is actually listening, so double-clicking the binary opens
  OpenPairings.

  Only on a local run — a hosted server never tries this — and
  `OPENPAIRINGS_NO_BROWSER=1` turns it off for anyone running the binary
  headless or over SSH. It cannot stop the app starting: if the launch fails
  the failure is logged and the tournament goes on.

- [Feature] **An Admin page, next to Connections and only for
  administrators.** It shows who may administer this installation and lets an
  administrator change a role — grant `support` to a colleague, or take
  it back — plus the version, whether this is a local or hosted run,
  and the database size.

  Three things it refuses, each a way somebody would otherwise be locked out:
  you cannot change your own role; the last administrator cannot be demoted;
  and an address declared in the server's configuration is shown but not
  editable, because a button that appeared to revoke one and was undone by
  the next restart would be a lie.

  Granting roles from a screen is a change of mind from `mix pairings.role`,
  which shipped saying there should be no screen. That argument was about the
  *first* administrator and still holds — nothing here can bootstrap
  one. It does not reach the second: an administrator granting `support`
  gains nothing they did not have, since the same session can already
  repoint publishing and download the whole database.

- [Feature] **The publishing state is in the top bar, on every page.** A dot,
  a word and the round trip: *Live*, *Sending* while the queue is not empty,
  *Refused* for a rejected token, *Offline* when the results site cannot be
  reached, *Not publishing* when nothing is set up. It links to Connections,
  because a pill that says "Offline" and cannot be acted on is a worry rather
  than information.

  Publishing is deliberately invisible — queued, retried, never in the
  way of pairing a round — and the cost of that is an arbiter having no
  way to tell "results are going out" from "nothing has left this laptop
  since Tuesday". Both look like nothing happening. An arbiter does not visit
  the settings page mid-round; they pair, enter results, and trust it is
  going out. That trust is the thing worth instrumenting.

  The word carries the state, not just the colour: colour alone is unreadable
  to a colourblind arbiter and ambiguous to everyone at a glance. Amber
  pulses only while sending, which is the one state that is temporary, and
  the animation stops under `prefers-reduced-motion`.

  One poller serves the whole installation and everything else reads a cached
  value, so this costs no network request per page — which matters most
  when the results site is down, since that is exactly when every page would
  otherwise be waiting fifteen seconds to say so.

- [Feature] **Administrator and support roles.** Who may change how an
  installation is wired up is now an explicit role rather than a side effect
  of how somebody signed in.

  `admin` may change the publishing connection, take and download backups,
  and start a rating-list sync. `support` may *look* — the connection
  status, the backup list, the sync state, and the read-only connection check
  — because "why did publishing stop" is a question worth answering
  without handing over the ability to cause it. `owner` is everyone else, and
  is what every existing account becomes.

  Granted from the command line and nowhere else:

      mix pairings.role                          # who holds one
      mix pairings.role you@example.com admin
      mix pairings.role you@example.com owner    # revoke

  There is no screen for it on purpose. Shell access on the server is
  already the highest authority there is, so making it the way roles are
  granted keeps the authority to grant admin from being something admin
  itself confers.

  A deployment names its administrators once, in `DEPLOY_ADMIN_EMAILS`, and
  that drives **two independent routes to the same authority**. The address
  reaches the systemd unit as `ADMIN_EMAILS` and may administer with no
  database row at all; and the deploy also runs
  `mix pairings.role --ensure` after migrating, so it holds the role in the
  database too. Either alone is enough. The redundancy is the point: an
  installation nobody can administer is recoverable only over SSH.

  This grants nothing new — the unit is root-only, and root could run
  the mix task anyway. `mix pairings.role` with no arguments lists both
  kinds and marks which is which.

  **`--ensure` re-grants on every deploy**, so the deploy configuration is
  the source of truth: demoting somebody still listed there lasts until the
  next deploy. Revoking for good means removing the address *and* running
  `mix pairings.role <email> owner`. An address with no account yet is
  reported and skipped rather than failing, so a first deploy is never
  aborted by it.

  Your own machine needs none of this and is not affected.

- [Feature] **Backups can be downloaded.** A Backups card on Connections
  lists what is on the machine, takes one on demand before a risky change, and
  hands any of them over.

  They are written beside the database, which survives a bad migration, an
  accidental delete and a botched restore — most of what goes wrong
  — and does not survive the disk. Copying one off-site needs a
  destination this app has no business holding credentials for, so instead it
  gives you the file and says plainly that a backup kept only on the thing it
  protects is half a backup.

  Administrators only, and the card says why: a backup is every tournament,
  every player, the email addresses people gave the entry form, and every
  publishing key. On your own machine there is no gate — the file is
  sitting beside a database you can already open.

- [Feature] **A connection indicator for publishing.** Green when the results
  site answers, amber while something is being sent, amber again if the token
  is refused, red when it cannot be reached, grey when nothing is set up
  — with the round trip in milliseconds and the reason in words beside
  it. On Connections in full, and compact on a tournament's OpenResults page.

  Publishing is deliberately invisible: queued, retried, never in the way of
  pairing a round. That is right and it had a cost — "my results are
  going out" and "nothing has left this laptop since Tuesday" looked exactly
  the same, which is to say like nothing happening.

  A refused token and an unreachable server are shown differently on purpose:
  one is a working network and a wrong secret, the other is a network problem,
  and they want opposite fixes. And because an empty queue means either
  "everything has been sent" or "nothing was ever queued", it also says when
  something last actually went.

  The check runs off the page's own process. Doing it inline would have frozen
  the settings page for up to fifteen seconds on exactly the machine whose
  connection somebody had come to check.

- [Feature] **Far more control over what the public page shows, in far less
  space.** Seventeen switches instead of seven, grouped by what they decide:
  which pages exist at all (standings, round pairings, player cards, byes),
  what is shown beside each name, which tournament details ride in the header
  (city, dates, arbiter, deputy, tempo, FIDE badge), and which extra columns
  a shown page carries.

  Whole pages can now be withheld — some arbiters hold the standings back
  until the last round is in, and now they can. What still cannot be hidden is
  the truth on a page that IS shown: there is no way to publish a standings
  table with the names removed or a pairing list without results. A page is
  published honestly or not published.

  A withheld page says so and links back to the tournament, rather than
  claiming not to exist — the event is right there, and a 404 would send
  somebody hunting for a link that was never broken.

  The old layout took most of a screen for seven boxes and would have taken
  three for seventeen. It is a grid of compact toggles now, green when on.

- [Feature] **There are backups now.** There were none. Every tournament,
  result, registration and publishing key lived on one database file on one
  machine — and the keys are the only thing that can withdraw a published
  tournament, so losing the file meant losing the ability to take your own
  event off the public web.

  One is written a day, and `mix pairings.backup` takes one on demand before a
  risky change. `--list`, `--verify` and `--restore` are the other half: a
  backup is worth exactly what its restore is worth, so the file is a real
  database that gets opened and checked before anything is recovered.

  **The rating lists are left out.** They are 207 MB of the 219, they are a
  downloaded copy of somebody else's data, and a sync rebuilds them — so a
  backup is about 17 kB and it is worth keeping a month of them. The tables are
  emptied rather than dropped, because a database missing them would not match
  its own migration history and would refuse to start.

  Restoring writes the recovered database *beside* the live one and prints the
  three commands to swap it in. A SQLite file cannot be replaced underneath an
  open connection pool without risking the thing being recovered.

  Set `PAIRINGS_BACKUP_PASSPHRASE` to encrypt them — worth doing, because
  an unencrypted backup carries the email addresses people gave the entry form.

- [Feature] **Settings → Results site.** One page for everything about a
  tournament's public existence: publish it, list it or not, choose what the
  public page shows, open the entry form, get the share link, move it to a new
  address, take it down.

  These were spread over two pages and read as unrelated — the publish
  switch under Tournament next to the logo uploader, the entry form under
  Options next to pairing preferences. They are not unrelated. Every one of
  them answers part of "what does the public see", and an arbiter putting an
  event online should answer that on one screen rather than assemble it from
  two. Reviewing entries stays with the players it creates; there is a link.

- [Feature] **Choose what the public page shows.** Ratings, titles,
  federations, clubs, categories, tiebreak columns and player cards can each be
  turned off per tournament. A club evening and an international open have
  genuinely different answers about whose Elo belongs on the open web, and the
  arbiter is the one who knows which this is.

  Names, board numbers, results and placings are not on the list: they are the
  tournament, and an arbiter who does not want them public should not publish.
  Hiding the tiebreak columns hides the arithmetic, not the result — the
  order is still exactly the one the arbiter computed.

- [Feature] **Publishing a tournament no longer advertises it.** Publishing
  gives a tournament a public address; putting it on the results site's front
  page is a separate, deliberate choice, and it is **off by default**.

  It shipped defaulting to on, reasoning that this was what publishing had
  always meant. The reasoning was about not changing behaviour and it produced
  behaviour nobody chose: sixteen tournaments appeared on the front page at
  once because a migration had switched publishing on, not because sixteen
  arbiters had decided to advertise their events. Every existing tournament is
  reset to unlisted — nothing is taken down, and every link still works.

  The settings page says plainly that this is not privacy: an unlisted
  tournament is still readable by anyone who has the address, and addresses get
  forwarded.

- [Feature] **Entries arrive on their own.** The Registrations list now fills
  itself once a minute instead of waiting for someone to press Pull. That was
  fine while this app served the entry form — the arbiter was in the app
  and the entries were on the same machine — and stopped being fine when
  the form moved to the results site, because the queue then lived somewhere
  the arbiter had no view of at all. A queue nobody is told about is one
  discovered on the morning of the tournament.

  Nothing is accepted automatically. Entries land in the review list marked
  "not yet arrived" and wait for a person, which is the whole model. The Pull
  button stays: somebody standing at the door with a queue in front of them
  should not have to wait out a timer.

- [Fix] **The public page showed the wrong board numbers.** A fixed-table
  player takes board 1001 and the boards after them renumber to close the gap
  — that is what the arbiter's screen and the printed sheet show. The
  published page showed the raw column instead, so a game printed as board 12
  in the hall appeared online as board 1001, with every board after it off by
  one. The order was wrong too.

  The snapshot carried only the real board number, on the reasoning that a
  label is a rendering decision belonging to whoever draws the page. Right in
  principle, wrong in practice: nobody drew it. Both now travel, in the order
  the arbiter sees.

- [Fix] **A hand-set standings order no longer hides that it has gone stale.**
  The arbiter's own page warns when a result has changed since the order was
  set, or when a player joined afterwards and has not been placed. Neither
  warning travelled, so the public page said "the arbiter chose this order"
  while their screen said "…and it may no longer match the real
  standings". Both are published now, read from the same two functions the
  arbiter's page calls so the two cannot drift apart.

- [Feature] **Players can find themselves on the FIDE list again.** The entry
  form offers a search that fills in name, FIDE ID, rating, title, federation
  and birth year. The old local form did this and the results site could not,
  because the FIDE list lives on the arbiter's machine and did not move with
  the form — so players had been typing FIDE IDs from memory, and
  arbiters correcting them by hand.

  The list still lives here. The results site borrows a search of it over the
  publishing token, rate-limited, and proxies it server-side so the arbiter's
  address and the token never reach the page. The rating that comes back is
  the one for this tournament's tempo: a player entered at their standard
  rating in a blitz event is seeded wrong.

  Off unless both machines are deployed together. Where they are not, the form
  asks people to type their own details exactly as it did yesterday — a
  search box that cannot search is worse than none.

- [Feature] **Title and birth year on the entry form.** Both were collected by
  the old local form and neither survived the move, so arbiters were typing
  them. The title is a list of the eight FIDE awards rather than a text box,
  because free text collects "gm", "Grandmaster" and "GM (inactive)" and
  somebody normalises all of it by hand. Neither is required.

- [Feature] **Remove a tournament from the results site.** In Settings, under
  Publish to the results site, once something has actually been published.
  It deletes the public page, every earlier snapshot in that tournament's
  history, and any entries collected for it, and it says so before you
  confirm. Nothing on your machine is touched — the tournament, its
  players and its results stay exactly as they are.

  A takedown that does not reach the server changes nothing and tells you
  why. In particular a "not found" reply is reported rather than treated as
  "already gone": it can equally mean the results site is too old to have a
  takedown at all, and being told your event was withdrawn while it is still
  up is worse than being told nothing happened.

- [Feature] **Entries from the results site.** The public form on OpenResults
  collects sign-ups; a published tournament now has an **Entries** page
  (linked from its Settings) where you fetch them and decide on each one.
  Accept adds the player, Discard adds nothing.

  The results site cannot put anyone in your tournament. It holds requests
  and this machine comes and asks — which is why there is a Fetch button
  rather than a list that fills itself in. An accepted entrant lands **not
  yet arrived**, exactly like the form on this machine: filling in a web
  page announces an intention to play, and pairing someone who never turned
  up hands their opponent a forfeit win.

  Rounds an entrant asked to sit out become their absent rounds, clamped to
  the rounds your tournament actually has — a request for round 9 of a
  five-round event is shown to you rather than quietly trimmed.

  A turned-down entry is kept rather than deleted, so fetching again cannot
  bring it back and you can still reach the person. Their email address is
  the one personal detail an entry carries; it stays on that page and goes
  into no snapshot, no TRF and no public page.

- [Feature] **Publishing has a UI.** The Rating lists page is now
  **Connections** — everything this machine talks to, the two rating
  lists it reads and the results site it writes to. The address and token
  are set once for the machine; each tournament then has its own switch in
  its Settings, off until you turn it on.

  The token is never rendered back once saved, and an empty token box means
  "keep the one you have" rather than "clear it" — otherwise editing the
  address beside it would wipe a working token every time.

  **Test connection** is a GET against a route that cannot match anything,
  never a publish. A test button that published would be a trap: you press
  it to find out whether the settings work and a tournament goes live as a
  side effect.

- [Feature] **The results site has themes.** Six, chosen from the picker
  beside its name and remembered per browser: the original (Paper), Night,
  Board (cream and board-green), Slate, and a High contrast black-on-white for
  a projector at the back of a hall. "Match device" is there too.

  It opens on **light** rather than following the device. A spectator opens
  this page once, often inside a club's own site, and club sites are
  overwhelmingly light — a dark slab dropped into the middle of one reads
  as broken rather than as a theme.

- [Feature] **Right-click a player on the results site for their card.** The
  full opponent table — every round, who they played, their number,
  federation, title, rating and own total — shown in place, the way
  right-clicking a row does on the Players page here. Left-click still opens
  the page, which is what happens with no JavaScript and on a phone.

- [Feature] **The results site keeps itself current.** Standings and pairings
  refresh themselves every 20 seconds instead of waiting for somebody to pull
  down on their phone. The pages this replaced were live, and being static was
  the most visible thing lost in the move.

  It swaps one region rather than reloading, so scroll position, theme and an
  open card all survive; it stands down on the entry form, where replacing the
  page under somebody typing would clear it; and it says so in the footer when
  the connection has gone, rather than showing a page that has quietly stopped
  being current.

- [Feature] **Elo and running scores on the published pairings.** Each board
  shows both players' ratings and the points they carried into the round
  — which is what a pairing list means by score, and what explains why
  those two are on that board.

### Changed

- [Change] **Settings is arranged around what you are actually doing.**
  "Publish each round" was under Options and is now on OpenResults, with the
  rest of what reaches the results site. "Export / backup" has its own tab
  instead of sitting at the bottom of the Tournament page. The Tournament
  page no longer carries a signpost card pointing at OpenResults, since the
  tab beside it does that. And the settings tabs no longer offer Changelog,
  which is not tournament-specific and is already in the top bar.

- [Fix] **The Explain page described a colour rule the engine no longer
  follows.** Where Article 5.2.5 decides a board, the page told arbiters this
  engine reads the parity on the tournament pairing number and other programs
  read it differently. FIDE settled that question on 28 August 2026 —
  against us — and the engine was updated the same day, but the
  explanation was not. It now describes what actually happens, and says the
  ruling settled it rather than presenting a live disagreement. Three other
  places carrying the old claim were corrected with it.

- [Change] **New tournaments publish rounds MANUALLY by default.** They
  defaulted to publishing the instant a round was paired — on the
  public page before the arbiter had looked at it. The first person to see a
  pairing should be the person responsible for it: a mistake caught in ten
  seconds is a re-pair, and the same mistake seen by four hundred players is
  a correction, an announcement and an argument.

  Choosing "Immediately" now says so plainly, where you choose it. Existing
  tournaments that have never published are moved to manual too; one that is
  already publishing is left exactly as it is, because silently ceasing to
  publish mid-event is its own disaster.

- [Change] **The version number opens the changelog, and the changelog no
  longer asks you to log in.** The version sits in the top right of every
  page, including the sign-in page, and was not clickable. Making it a link
  exposed the second half: `/changelog` had been behind the login only
  because it was added beside the tournament pages and inherited their
  pipeline — so a signed-out visitor clicking it was sent to a log-in
  screen for a document that describes the application and reads nothing but
  `CHANGELOG.md`.

- [Feature] **The panel says how slow the connection has been, in one line.**
  "Slowest in 10 min: 4 ms" — and only that, when there is nothing
  else to say. A drop earns a second clause, because a drop is worth
  knowing: "Slowest in 10 min: 4 ms · last drop 2 h ago". If it is
  dropping now it says so in the same shape: "Drops in 10 min: 2", in bold.

  Deliberately not an uptime percentage. This app cannot see the checks it
  failed to make while it was down, so any figure it computed would describe
  how reachable the results site was during the moments the app was alive
  — flattering by construction. And a percentage averages away the
  shape that matters: 99.9% over a week is one ten-minute outage, which is
  nothing on a Tuesday and ruinous in round four. Real uptime needs something
  outside the machine watching it.

- [Fix] **The publishing panel said things twice.** It read "Connected" and
  then "Connected. The address and token are both accepted."; and "last sent
  just now" beside "82.0 KB last sent" — the same words twice on one
  line, from bolting the new size on as a separate item rather than folding
  it into the sentence. It now reads "82.0 KB sent just now", the message
  stops repeating the heading above it, and the three facts on that line are
  separated instead of running together.

- [Feature] **The publishing indicator says whether it has been steady, not
  just whether it works now.** A status light answers "right now", and the
  failure it hides best is the intermittent one: a hall's wifi that drops for
  fifteen seconds every few minutes reads green almost every time anyone
  looks, while results arrive late for no visible reason. The panel now keeps
  the last ten minutes of connection checks and says either "steady for the
  last 10 minutes, slowest check 180 ms" or "3 checks failed in the last 10
  minutes — it is answering now, but worth a look at the network".

  It says nothing at all until there is enough history to mean it. A claim
  about ten minutes from an app that started ninety seconds ago would be a
  lie told confidently.

- [Fix] **The publishing indicator opens instead of sending you to the
  rating lists.** Clicking "Live" in the top bar navigated to the FIDE
  rating-list page, which has nothing to do with publishing. It now opens the
  full status in place — the reason in words, the address, the queue,
  when something last went out and how big it was — and closes when you
  click away or press Escape. The Advanced and Settings menus gained the same
  click-away behaviour, which they never had either.

- [Feature] **How much a round costs to publish.** A published snapshot is
  the whole tournament rather than a change to it, so its size is the one
  figure that says what publishing actually sends — and it moves: the
  new tie-break breakdown multiplied it by about 3.4 on a large event. The
  size of the last document sent is now recorded and shown beside when it
  went.

- [Feature] **Every build now says exactly which build it is.** The top bar
  showed `v0.18.0`, which is a release, not a build — a week of commits
  and a dozen deploys all report the same string. It now reads
  `v0.18.0+3f2a1c9`, with the commit and the build time in the tooltip, and
  the same identifier travels on every published document so the results site
  records which build produced it. A build that does not know its own commit
  says `+unknown` rather than guessing.

  This came from losing half an hour to it: a deploy went out, the public
  site still looked wrong, and both sides reported the same version. Only one
  of the two applications had been deployed.

- [Fix] **The OpenResults settings page stopped looking like you had left the
  tournament.** It was the one settings page that did not tell the layout
  which tournament it belonged to, so the top bar dropped every tab —
  Players, Pairings, Standings, Print — and its Home link turned into
  "Tournaments".

- [Fix] **Importing a SWAR file with categories now says what it could not
  read.** SWAR's category block carries two lists of values; a player's
  category is read from the first, while both end up in the tournament's
  category list. A file using the second one therefore imported categories
  with nobody in them, silently. The import warns instead, naming both sets
  and pointing at Settings.

  What the second list means is genuinely not documented, and the candidates
  imply different imports — so this warns rather than guesses. One real
  club file with categories configured would settle it; `docs/swar-import.md`
  now says exactly what to look for.

- [Change] **A local install stops offering a server's controls.** Running
  the standalone binary signs its single owner in automatically, so the
  account Settings link, the "Share / Team" invitation card and the
  sign-in/sign-up pages had nothing to do there — the invitation would
  have been emailed to a terminal window, and a second account created on the
  sign-up page could never have been signed into. All four are gone on a
  local install, and a bookmarked sign-in URL goes to the tournament list
  instead of a page that cannot help. Log out still works, because it is
  merely inert rather than misleading.

- [Change] **The version header can no longer drift.** It is written in four
  places and only one of them is read by anything, so the other three went
  stale repeatedly — twice in the three days a code review spent
  documenting the first occurrence. `mix precommit` now refuses when the
  roadmap, the feature list or the changelog names a version `mix.exs` does
  not.

- [Change] **Seven documentation claims that were not true any more.** The
  roadmap said standalone binaries had no CI smoke test (there are four),
  that a "paired by someone else" notice had shipped (it was removed), and
  that the absence-handling setting was off by default while describing its
  behaviour backwards. The backup document promised "every Tournament field"
  when fifteen are held back. The endorsement checklist called FIDE Mode and
  adjourned games "not applicable" without mentioning that both are hard
  failures under the 2026 draft. A moduledoc argued at length that local mode
  deliberately does not log you in, next to the code that logs you in. None
  of it changed what the app does; all of it would have misled the next
  person to read it.

- [Feature] **Choose which tie-breaks the public page shows.** It was one
  switch for every column at once. Settings → Results now has a checkbox
  per tie-break the tournament ranks on, so you can publish Buchholz Cut-1
  and keep the rest off the page. A hidden one is not sent at all — no
  column, no value, no breakdown — rather than sent and hidden at the
  other end.

  **Hiding a column does not stop it deciding the order**, so two players can
  appear one above the other with every published number identical. Both the
  settings page and the public standings say so rather than leaving it
  unexplained.

  Publishing the numbers and publishing where they came from are also
  separate now: "How the tie-breaks were reached" is its own toggle.

- [Feature] **Published results now carry the working behind each
  tie-break.** The public site could show that your Buchholz was 14.5 and
  nothing about where it came from, which leaves the one question a player
  actually has — "why am I fourth?" — unanswerable. Each
  published standings row now carries, per tie-break, one contribution per
  round: which opponent it came from, what it was worth, and whether it was
  discarded by a cut or is one of Article 16's virtual opponents.

  It is sent rather than worked out at the other end, because it cannot
  honestly be worked out there: Buchholz sums opponents' **adjusted** scores,
  not the scores in their standings rows, so a public page adding up the
  visible numbers would disagree with the arbiter's. Only the tie-breaks that
  genuinely cannot be re-derived are sent — the Buchholz family,
  Sonneborn-Berger, Koya and average rating. Wins, games with Black and the
  running score are already visible in the results.

  **Turning off the tie-break columns now withholds this too**, rather than
  sending it and relying on the public site to hide it.

- [Fix] **A Keizer bye marks a hand-set standings order out of date.** Byes
  award points without going through result entry, so every other pairing
  path already flagged a manually-ordered standings table as stale when it
  wrote one. Keizer did not. Nobody could hit it — the manual-ordering
  card is hidden for Keizer tournaments — but that is a reason it could
  not be reached, not a reason it was right. Keizer's absentee byes are also
  written inside the round's own transaction now, as the Swiss ones always
  were, instead of just after it committed.

- [Change] **Searching the Belgian rating list works the way the FIDE one
  does.** Both sit side by side in the same dialog, but only the FIDE list
  had been given a full-text index; the national list was scanning every row
  on every keystroke, behind an index on last name that could never serve
  the query it was created for. It is indexed now, matches first names and
  name tokens in any order, and folds accents, so "muller" finds
  "Müller". The dead index is dropped.

- [Change] **A collaborator lookup runs on an index.** Sharing a tournament
  creates an invite against an email address, which only gains an account id
  once that person signs in, so the lookup matches either — and the
  email half had no index, making a query that runs on every page load a
  full table scan of the invite table. Nobody would have noticed at present
  sizes; it is one line.

- [Change] **Pairing a round stops rebuilding what it already worked out.**
  The per-category path had always computed the tournament's history once
  and passed it around; the ordinary single-pool path had not, so it built
  the same thing twice within one click. Pairing by category also asked for
  the forbidden-pairing list twice per category, for a list that is the same
  for all of them, and walked the whole roster's game history once per
  category on top of that. Measured on a 16-player round: 43 database
  queries before, 35 after; a four-category round, 96 before and 87, with
  the per-category cost now flat. The engine call still dominates a pairing
  click — this is housekeeping, not a speed-up you will feel.

- [Change] **The pairing-explanation page stopped recomputing the standings
  once per round.** It needs each round's incoming scores, and asked for them
  one round at a time — a nine-round tournament ran eleven full
  standings computations, then a twelfth with arguments identical to one it
  had just made. It reads the rounds once and folds each round's prefix in
  memory now.

- [Change] **The pairing sheet asks only for what it prints.** Each player's
  incoming score came from the full standings — every tie-break, the
  ranking sort, all of it — and then everything but the points was
  thrown away. That runs on mount, on every round switch and after every
  result entered. There is a points-only path now.

- [Change] **Tie-break scoring stopped redoing one calculation thousands of
  times.** The adjusted score FIDE Article 16.3 uses is a property of a
  player, but was recomputed at every game-encounter, separately inside each
  of Buchholz, its two cut variants, Median Buchholz and Sonneborn-Berger. A
  300-player 11-round grid did it around 9,900 times for 300 distinct
  answers. Computed once per player now, and carried.

- [Change] **"Pair the whole tournament" stopped rewriting the same setting
  once per round.** A round robin works out its own round count from the
  size of the field, and the button that pairs every round at once was
  re-deriving and re-saving that number on every single round — a
  14-player double round robin did it 26 times, each one telling every open
  page twice that the settings had changed. It happens once now. Nothing
  visible changes; there is just far less going on behind a button pressed
  during a live event.

- [Fix] **The tie-break list stopped offering three that score zero.** Match
  points, Game points and Berlin board points need team standings, which are
  not built. Adding one to a tournament produced a column of noughts that
  separated nobody, permanently, with nothing on screen to say why. They are
  out of the picker now, and a tournament that already stores one —
  FIDE's own default set for a team event names all three — drops it
  from the ranking and says on the Standings page which and why. The FIDE
  defaults themselves are left as FIDE wrote them; hiding our own gap by
  editing their list would misreport the regulation.

- [Verified] **Koya is right as it stands.** A code review flagged that the
  Koya tie-break reads an opponent's raw score where Buchholz and
  Sonneborn-Berger first apply the unplayed-rounds adjustment. Checked
  against C.07: Article 16 names its own scope in its opening sentence
  — Buchholz, Sonneborn-Berger and their variants — and Koya
  (Article 9.2) is not among them. No change; the citation is now in the
  code so the next reader does not re-open it.

- [Fix] **A draw stopped being called a win.** Under a 3-2-1 club scheme
  (win 2, draw 1, plus a point for turning up) a draw is worth exactly what
  a win is worth. Four screens — the player card, the printed
  crosstable, the pairing-explanation trail and the players grid —
  worked out whether you had won by comparing your points against the value
  of a win, so all four showed a "1" where the standings beside them showed
  a draw. The FIDE tie-break "games won over the board" counted it too.

  The result code always knew: `½-½` is a draw whatever a draw pays. Every
  screen reads that now, from one table. Its neighbour "rounds worth as many
  points as a win" is deliberately left comparing points, because that is
  the tie-break's definition in FIDE's own words.

- [Fix] **A phone can record a played-but-unrated result.** The three codes
  for a game that happened but does not reach the rating report have been
  enterable from the Pairings page since they shipped; the mobile screen
  carried its own copy of the list, made before they existed, so a helper at
  the board could not record one. The two screens read the same list now,
  and a build where they disagree fails rather than shipping.

- [Fix] **A CSV import can express every result a click can.** Bulk import
  rejected those same three codes outright, and separately accepted two
  spellings it documented nowhere. Both halves are gone: the accepted
  spellings and the codes they store are one table, and the documentation
  lists it.

- [Change] **The new-tournament form is grouped by what it asks.** It was one
  grid holding everything, so the explanations took layout cells of their own:
  name and system on a row, a paragraph across the next, the team checkbox
  alone beside two empty cells, another paragraph, and only then the fields
  that decide the tournament&#39;s shape. It is three small groups now - what it
  is, how big, where and when - with the notes between them rather than inside
  them, so choosing an option grows its own section instead of reshuffling
  everything after it.

- [Change] **The original attempt at that, kept for the record:** Its
  explanations — the engine note, the "Reporting only" note on team
  tournaments — were laid out as if they were form fields, so each one
  took a column beside an unrelated input, and choosing a pairing system
  reshuffled the rest. They span the full width now and sit under the field
  they explain, so picking an option adds a row instead of moving three
  columns. Three hand-tuned margins went with it.

- [Change] **The downloads are named after the product, and the release page
  now carries both shapes.** The single-file build was published as
  `pairings_engine_<target>` — the internal application name, which
  predates the app being called OpenPairings and means nothing to anybody
  downloading it. It is `openpairings_<target>` now.

  More usefully: a tagged release attached *only* that single file, which is
  the one `docs/binaries.md` tells a Windows arbiter **not** to start with,
  because antivirus deletes it on sight. The portable release — the
  recommended one — existed only as a CI artifact you had to dig out of
  a build page. It is attached to releases now, as one zip rather than 1,800
  loose files.

- [Change] **"Generate a new link" is now a real revocation.** It used to
  change this machine's idea of the address and nothing else. That was
  genuine revocation while the pages were served from here — they
  404'd the instant the slug changed — and it silently stopped being
  one when the page moved to another server.

  A bare rotation would have done the opposite of what the button promised:
  the leaked link keeps working, because the copy behind it is still there
  and this machine has merely stopped pointing at it, and the next publish
  creates a *second* copy at the new address. The tournament ends up public
  twice, and the key that could have withdrawn the first now names an address
  holding nothing.

  It now takes the old copy down, moves, and publishes again. The takedown
  goes first, because it is the part actually being asked for: if it fails,
  nothing else happens, since a failed revocation must never look like a
  successful one. The button says what it costs — printed QR codes and
  anything a club has embedded will need the new address.

- [Change] **A tournament switched on but never actually sent now heals
  itself.** On start-up the app queues a publish for anything marked to
  publish that has no key — a promise nothing kept, where Settings says
  "published" and hands out a share link the results site has never heard of.

  Three ways to land there, and none of the ordinary machinery recovered from
  any of them: today's migration, which is raw SQL and cannot queue anything;
  a queue write that failed, which is swallowed on purpose so a publish can
  never take down the write that triggered it; and a database restored from a
  backup taken between the switch and the send.

- [Change] **A tournament switched off after publishing still collects its
  entries.** Pulling used to require the publish switch to be on. That switch
  says whether more will be *sent*; it has nothing to do with whether there is
  a queue to collect. A tournament switched off still has its copy on the
  results site, and that copy's form is whatever the last snapshot said —
  so entries could arrive at a tournament this machine had stopped publishing
  to, sit unread, and be deleted unseen by a later takedown.

- [Change] **Closing the entry form now pushes immediately.** The form is on
  the results site, so the arbiter's switch only reaches it by riding along
  in the next published snapshot. Closing is the urgent direction — an
  arbiter shutting entries at the door needs the site to stop taking them
  — so both opening and closing enqueue a publish rather than waiting
  for the next result to come in.

  Before this the switch had no effect on the results site at all: it
  accepted entries for every published tournament regardless.

- [Change] **A hand-set standings order now says so on the public page.** The
  arbiter's chosen order was already published; the disclosure that a person
  chose it rather than a tiebreak was not, because it only ever lived on this
  app's own public standings page. Publishing the order while dropping that
  fact is the exact failure the feature's own documentation is written to
  prevent, and removing the page would have caused it silently.

- [Change] **Saving the publishing settings now tests them.** "Saved" on its
  own answers the wrong question — nobody types an address to find out
  whether it was stored, and a typo saves perfectly well. It now says whether
  the results site actually answered, and shows the reason when it did not.
  The settings are kept either way: a typo you cannot correct because the
  form discarded it is worse than one that is stored and reported.

- [Change] **A JSON backup of a published tournament now carries its
  publishing key, and is therefore as sensitive as a password.** That is
  deliberate: rebuilding a laptop from a backup has to recover the ability to
  manage what that laptop published, and a key left on the dead disk would
  strand a tournament in public with nobody able to take it down. Every place
  the app offers such an export now says what the file can do.

  **Importing one does not take the tournament over.** The key arrives
  dormant and the imported copy behaves as a separate tournament: switch
  publishing on and it gets a new address of its own. Settings then offers
  the choice in words — take over publishing the tournament already at
  that address, or start fresh — and doing nothing is starting fresh. If
  an import adopted the key by itself, two people opening the same file would
  both believe they owned that tournament, both publish to the same address,
  and either could delete the other's work.

  Duplicating a tournament never carries the key, even though it uses the
  same export-and-import machinery: the original is still right there, still
  publishing.

- [Change] **All three private copies of the played-code vocabulary are now
  checked at build time.** `Ainalrami.Trf.playing_codes/0` and `bye_codes/0`
  are public precisely so nobody writes a fourth, but neither expresses the
  question these call sites ask - *what point value does this code stand
  for* - which is a three-way split running across both engine lists rather
  than along them. What the engine can police is the domain, and that is the
  half that broke: `W`/`D`/`L` went missing from one copy and an opponentless
  unrated result escaped as an exception. A missing code now fails the build
  naming itself, instead of surfacing mid-import on an arbiter's file.

  Neither remaining copy was mis-scoring anything today; each was complete as
  of v0.14.0. The exposure was drift, which is now not possible silently.

- [Change] **The public standings page now respects the round publish gate.**
  It showed results for rounds the public *pairings* page one link away
  deliberately hides, so withholding a round hid who played whom and
  published the results anyway.

  Both public surfaces now compute standings through the same bound: the
  longest run of rounds 1..n that are *all* published. The contiguous prefix
  rather than the highest published number, because with round 3 published
  and round 2 held back, standings through 3 carry round 2's results anyway.

  That bound lived privately inside the OpenResults snapshot first, which
  meant the published site enforced the gate and the page served from this
  app did not — two publics disagreeing about what "not published yet"
  means. One definition now, in `Tournaments.published_through_round/1`.

- [Change] **Colour allocation follows a FIDE ruling that went against the
  engine.** The pairing engine is pinned forward to Ainalrami v0.14.0, which
  changes how Article 5.2.5 decides who gets White.

  5.2.5 is the last resort: when neither player of a pair has any colour
  preference, the higher ranked of them takes the initial colour if their
  number is odd. The question was which number. Ainalrami used the
  tournament pairing number as the handbook defines it; both reference
  engines used a numbering that skips players who have never been paired.
  On 2026-08-27 the FIDE Systems of Pairings and Programs Commission ruled
  that the references were right.

  **What an arbiter sees.** On a board where 5.2.5 decides and somebody in
  the tournament has been registered without ever being paired - a
  no-show, a late entry who has not arrived, anyone who has only taken
  byes - White and Black may now be allocated the other way round from
  before. Nothing else moves: who plays whom is decided before colours are
  allocated, so pairings, byes, floats and standings are untouched. A
  tournament already in progress is unaffected for rounds already paired.

  This brings us into agreement with bbpPairings and Gacrux on a class of
  boards where we previously and deliberately differed. See the engine's
  `docs/dispute-initial-colour.md` for the full record, including two
  mistakes of our own that the ruling exposed.

- [Change] **One TRF16 implementation, not two.** The app carried its own
  FIDE TRF16 reader/writer alongside the pairing engine's, which was
  photocopied from it and then kept growing - so a pairing input was written
  by one implementation and read by the other, and the app's copy knew
  nothing of `XXR`, `XXP`, `XXA`, `250`, `260`, `BB*` or `162`. Every caller
  now uses the engine's, and the app's is gone. Both were measured against
  each other on 249 serialize cases and 137 parse cases first: every
  remaining difference was the engine's reading or writing something the
  app's copy could not.

- [Change] **The extension lines are written, not glued on.** The `XXR`,
  `XXA` and `XXP` lines a pairing input carries - the round count, the Baku
  virtual points, and the arbiter's forbidden pairings and club/federation
  exclusions - used to be built as text and concatenated onto the finished
  TRF, which put exactly the lines carrying the rules outside the writer and
  outside every check it makes. They are fields of the tournament now and
  the writer emits them. This is the class of defect that gap hid: an `XXA`
  line one column too wide, which JaVaFo tolerated and bbpPairings rejected
  outright, so every accelerated tournament this app exported was unreadable
  by anything but JaVaFo.

- [Fix] **A pairing file for a round still being played is readable again.**
  A player row whose last round has no result yet lost the two columns that
  round's blank result occupies, because trailing whitespace was trimmed off
  the row. bbpPairings rejects the whole FILE for that, not just the round -
  it stops reading round blocks two columns early and then finds characters
  left over. This was already fixed in the engine's writer and arrives with
  the consolidation above; the app's own writer, which every export went
  through, still trimmed. Files where every round has a result are unchanged
  byte for byte.

- [Change] **The unsupported-extension guard now looks at every extension.**
  Before pairing with Ainalrami, the app scans the file it generated and
  refuses to pair - writing nothing - if it finds an extension line the
  engine will not act on, because an ignored rule yields a complete,
  legal-looking round that quietly breaks it. That scan only looked at lines
  beginning `XX`, which was the whole vocabulary while the app hand-built
  its own extension lines. The writer emits the numeric and `BB*` spellings
  too, so the scan now covers every code that is not TRF16's own.

### Removed

- [Removed] **This app no longer serves public pages.** `/p/:slug/pairings`,
  `/p/:slug/standings` and `/p/:slug/register` are gone. A tournament becomes
  readable by the public in exactly one way now: it is published to the
  results site.

  There were two public surfaces for one thing, and the default was the wrong
  one. A link to the machine running the round, printed on a wall chart and
  handed to a hall full of spectators, is precisely what the results site
  exists to prevent — and the fix earlier today only stopped the app
  *advertising* those links, it did not stop them working. A second
  correct-looking answer is worse than none, so they were removed rather than
  de-emphasised.

  **The two switches are now one.** "Public pages" and "Publish to the results
  site" asked different questions — may anyone read this here, versus
  does a copy leave at all — and the first has no meaning without a
  "here". Publishing is the whole of it. Every tournament whose public pages
  were switched on is now marked to publish, because its arbiter had already
  said "this is public" and the only thing that changed is where the public
  reads it.

  **Club embeds move too.** A club site that put the pairing list on its own
  front page embeds it from the results site now. The framing exception this
  app carried for those three pages is gone, along with the cookie-free
  websocket and the iframe height-reporting script that served them, and
  `PUBLIC_FRAME_ANCESTORS` with it. Nothing this app serves can be framed any
  more, which is one fewer argument to get right every time a route is added.

### Fixed

- [Fix] **The phone-enrolment QR could not work on your own computer, and did not say so.** Running OpenPairings locally, the QR encoded `http://localhost:4000/...` — which a phone resolves to *itself* — and the app only accepts connections from the machine it runs on, so even the right address would have been refused.

  That second part is deliberate and is what makes a build with no login safe to ship: it prints sign-in links to a terminal and signs in whoever reaches it. Opening it up so phones could connect would hand that to everyone on the venue wifi, so this is a property of running locally rather than a missing feature.

  The panel now says that, instead of offering a code that leads nowhere. Helpers can still enter results from a phone when a tournament runs on a shared server.

- [Fix] **A shared tournament went stale on the other person's screen.**
  Deleting, archiving or restoring a tournament told only its owner, so a
  collaborator kept seeing a row that was gone — or missed one that was
  back — until they happened to reload. Sharing worked in both
  directions already; it was the tournament's own lifecycle that forgot the
  other party existed.

- [Fix] **A player's card showed their opponent's score wrong.** It counted
  the opponent's administrative extra points, which a tournament only ranks
  on if you asked it to — and it does not by default. Right-clicking a
  player showed a total the standings table would deny.

- [Fix] **A crafted language-switch link returned a server error.** A
  `redirect_to` containing a backslash or a tab reached Phoenix's redirect,
  which refuses those by raising, so anyone could produce a 500 from the
  public log-in page. It sends you home instead. Never an open redirect
  — Phoenix stopped that part — but a language switch is not a
  place to find a stack trace.

- [Fix] **ARO and AROC1 counted an unrated opponent as rating zero, and it
  moved prizes.** A player who faced 2200-rated opponents and one unrated
  scored around 1956 instead of 2200, and dropped below anyone who happened
  to draw a full rated field — in a tie-break that decides who takes a
  trophy. One unrated entrant in the whole event was enough.

  The cause is honest enough on its own: an unrated player's rating is
  stored as `0`, which is right everywhere else and is a 2000-point vote
  inside an average.

  **C.07 Article 10 does not offer a number to use instead.** It says these
  tie-breaks "must be dropped from the tournament tie-break list when unrated
  players are present, unless detailed rules on the handling of unrated
  players are included in the tournament regulations or established and
  published by the Chief Arbiter before the start of the tournament." So
  excluding unrated opponents from the average, or substituting a floor
  rating, would both be inventing a rule FIDE declined to write.

  Rating-based tie-breaks are therefore dropped — not computed, not
  ranked on, and the column is gone — in any tournament with an unrated
  player, and the standings page says which and why, including the escape
  hatch: publish a rule in your regulations and use a different tie-break
  here. It re-checks as players are added, so a late unrated entrant drops it
  without anyone reloading.

- [Fix] **A change took up to half a minute to reach the results site.** The
  publish queue was swept on a 30-second timer and nothing else, so unlisting
  a tournament sat there until the next sweep — invisible until the new
  top-bar indicator gave it something to sit amber on. An enqueue now nudges
  the queue, debounced so that pairing a round does not fire one HTTP round
  trip per tournament, with the timer kept as the backstop that retries
  anything still in backoff.

- [Fix] **"Publish each round" described a page that no longer exists.** Its
  help text pointed at `/p/<slug>/pairings` — a route removed with the
  local public pages — and told you the switch was gated on a setting
  under Settings → Tournament, which had also moved. It now names the real
  address on the results site and the switch that actually gates it, which
  is on the same page.

- [Fix] **Twelve Dutch strings were wrong, including two buttons that meant
  the opposite of what they did.** The engine-switch confirmation offered
  "JaVaFo behouden" (keep JaVaFo) on the button that switches *to* JaVaFo,
  and "Ainalrami gebruiken" (use Ainalrami) on the one that keeps it —
  so a Dutch arbiter choosing a pairing engine was reading each button
  backwards. "Backups" read as "Terug" (Back), the publish indicator's
  "Sending" read as "Stand" (Standings), and a note about a round a
  tournament does not have read as "this tournament is archived".

  All of them were fuzzy entries: gettext's own guesses, produced by
  matching a new or reworded string against the most similar existing one.
  Dutch was reported complete at 918 of 918 and the count was true —
  what it did not say was that eleven of those were machine guesses nobody
  had read, and Elixir's Gettext (unlike GNU `msgfmt`, which drops them)
  puts fuzzy translations on the screen. A twelfth string, the publish
  queue's "1 tournament waiting to send", had no Dutch at all.

  The catalogue is now checked by tests rather than by counting: nothing
  untranslated, nothing fuzzy, and no translation interpolating a
  placeholder that will not be bound — that last one raises at runtime,
  so it would take the page down in Dutch and in no other language.

- [Fix] **On your own machine, the whole Connections page refused to do
  anything.** Setting where the results site is, taking a backup, and
  updating the FIDE and KBSB rating lists were all gated on having signed in
  through 02cloud SSO. A local install has no accounts at all — it
  signs itself in as an owner named after the machine — so it failed
  that check, and there was no way to pass it.

  Which meant the one build that most needs the rating list could not
  download it, and an arbiter could not point their own laptop at the results
  site.

  The gate is a role now, and a local run needs none: the listener is on
  loopback, sign-in re-checks that the request came from this machine, and
  whoever is at the keyboard already holds the database and the binary.
  Being able to run it is the credential — the same reasoning that
  already skipped email confirmation there.

- [Fix] **Every public link pointed back at this machine, even for a
  tournament being published.** The share links, the projector's QR code, the
  registration link — all of them handed out a `/p/:slug` address served
  by the very computer running the round.

  That is not a broken link, which is what makes it bad: it works perfectly
  and quietly undoes the split. Moving spectators off the arbiter's machine is
  the entire reason the results site exists, and the app was sending them
  straight back.

  There is now one function that answers where the public reads a tournament,
  and every link goes through it. (The local pages it fell back to were
  removed later the same day — see below — so that function now
  has one answer rather than two.)

  A tournament marked to publish on a machine that has not been told an
  address has no public link at all, rather than a link built from a blank
  address. The share card names the host a spectator will land on, so nobody
  has to read a URL to work out which site they just copied.

  The links are absolute now rather than relative — half of them end up
  on a QR code, in a printed footer or pasted into an email.

- [Fix] **The navigation still said "Rating lists".** The page became
  Connections when the OpenResults settings landed on it; the nav label was
  missed, so the button and the heading it led to disagreed.

- [Fix] **A backup no longer loses an accessible table, relabels a played
  round, or un-hides a hidden board.** Three separate ways a restore came
  back wrong.

  SWAR's `HandyTable` is a table *number*, not a flag — its own 1001+
  handicap numbering lives in that field — and the exporter was writing
  1 or 0 into it. So a wheelchair-accessible board survived a backup and
  restore as nothing at all, and nobody was told. It now carries the real
  number. The two cases that genuinely cannot (a legacy row that only ever
  held the flag, and a number past 32767 that would silently wrap negative)
  are explicit, and the second logs a warning naming the player.

  Restoring re-froze every round's board labels from each player's fixed
  table **as it stands at restore time**, so a backup taken after a
  mid-tournament pin renumbered rounds people had already sat down at. The
  labels are now carried in the payload. The excluded-field comment argued
  that recomputing was "more correct than carrying a stale label across" - a
  frozen label is not stale, it is the record of what the sheets on the
  tables said.

  And `hidden` was passed to `Pairing.changeset/2`, which does not cast it,
  so a restore put every hidden board back into public view. Version 0.14.x
  fixed the export half of that and not this one.

- [Fix] **Vacating a seat paid the player left on the board.** Keizer scored
  any pairing with no opponent as a pairing-allocated bye worth half the
  player's own ladder value, and vacating a seat writes exactly that shape.
  The remaining player was paid the moment an arbiter marked someone absent.
  A vacancy and a bye differ only by their result code, which is now what
  tells them apart. `award_bye_for_vacancy/2` still pays, because that is an
  arbiter deliberately choosing to.

- [Fix] **Byes and absences now sort below the special boards.** A fixed
  table is a seat somebody is playing at, so it belongs with the games; the
  two groups where nobody is playing belong together at the bottom.

  Worth recording: 0.14.7's entry claimed to have made exactly this change.
  The intent was right and the concatenation was backwards, so two comments
  elsewhere describing the intended order only become true now.

- [Fix] **A place card and the pairing sheet named different tables.** The
  sheet prints the displayed label; place cards, result cards and score
  sheets printed the engine's own board number. With any fixed table in the
  tournament those differ, so the card in a player's hand contradicted the
  sheet on the wall - and the number it showed appears on no document
  anybody in the hall can read. The cards now follow the sheet.

- [Fix] **A round's PGN could contain two games tagged `[Board "1"]`.** The
  tag now carries the engine's board number, and this is the one
  board-numbered surface that deliberately disagrees with the pairing sheet.
  A PGN tag is never read by somebody standing at a board; it is how a
  database tells one game of a round from another, keyed on (Event, Round,
  Board), which needs a uniqueness the label loses as soon as a fixed table
  collides with an ordinary one. Same number, two documents, two different
  right answers.

- [Fix] **A pairing created from the pool printed outside the round's
  numbering.** It was the one pairing-creating path that never froze its
  label, so it fell back to the engine's board number and left a visible gap
  in the printed sequence. Frozen narrowly rather than by re-freezing the
  round: a full re-freeze recomputes from current fixed tables and would
  renumber boards under players already seated.

- [Fix] **`fixed_board` accepted 0 and negative numbers**, which reached the
  label, the PGN and every printed document. A value that collides with an
  ordinary board is still allowed - that one is deliberate.

- [Fix] **Every rendered bye row fired its own COUNT query**, an N+1 inside
  four render loops. The query now runs only where its answer can change the
  result, which for any tournament that is not a SWAR import configured with
  a cap is never. No number it returns has moved, and there is a test
  counting queries alongside the ones pinning values.

- [Fix] **Queuing a publish can no longer break a write.** It hangs off the
  funnel every write in the app goes through, which is what stops any call
  site forgetting to publish — and equally meant one bad query there
  broke all of them. A publishing queue is a courtesy and must never stop an
  arbiter entering a result.

- [Feature] **A plain announcement banner, for telling people something
  without restarting anything.** `scripts/notice.py "Big server maintenance
  in 12 hours." --hours 12` puts one sentence on every open page until it is
  withdrawn or its time passes.

  Deliberately not the deploy warning, which could not have done this. That
  one is a restart countdown: capped at two hours, escalating through three
  tiers to red, saying things about unsaved work, and held in memory so it
  dies with the release it was warning about. All of which is right for a
  restart minutes away and wrong for "we are pushing the new system
  tomorrow".

  So the differences are the feature. It says whatever it is given, for up to
  two weeks, it never escalates, and it is **persisted** — a notice
  about maintenance twelve hours out has to outlive every restart in those
  twelve hours, and one that vanished at the first hiccup would look exactly
  like one that was never set.

  It restarts nothing and schedules nothing; the banner is the entire effect.
  Same `DEPLOY_NOTICE_TOKEN`, because it is the same privilege — both
  can put a banner on every screen — and the endpoint fails closed when
  that variable is unset.

- [Feature] **Tournaments can be published to OpenResults.** The public half
  of this app is a separate service, and until now nothing sent it anything:
  the snapshot builder existed and had no caller. It does now.

  Opt-in per tournament, off by default, and toggled by its own action rather
  than by the ordinary settings form — the same guarantee
  `public_pages_enabled` and `registration_open` already have, for a sharper
  reason. Those two decide whether somebody holding a link may read an event
  *here*; this one decides whether a copy of it leaves the machine at all,
  and a stray form field must not be able to start that. It is also excluded
  from the tournament export, so importing a file cannot make this machine
  start sending a copy of it to whatever server this machine is pointed at.

  **A publish never blocks and never fails loudly.** That is the entire point
  of the split: a chess venue's wifi — school gyms, hotel basements
  — is exactly where an arbiter is standing when they pair round 5. A
  write records an intent and returns; a background drain sends what is due
  every thirty seconds; a send that does not land keeps its place in the
  queue with a longer backoff and an error written in words rather than in a
  struct ("the connection was refused — is the server running?").

  **The queue holds intents, not payloads.** One row per tournament, enforced
  by a unique index. A snapshot is a whole document rather than a delta, so
  five publishes stacked up behind a dead connection are not five things to
  send — they are one send of the current state, rebuilt when it
  actually goes out. Eight results entered in a minute are one publish, and a
  publish delayed twenty minutes carries what is true when it leaves rather
  than what was true when it was queued. That is what an arbiter wants: the
  page catches up to the hall, not to a moment in the past.

  Publishing hangs off `broadcast_tournament_change/2`, the one funnel every
  write in the app already goes through, so no call site has to remember to
  publish and none can forget. It costs one primary-key lookup for a
  tournament that has not opted in.

- [Fix] **A single reported board moved everybody else's tiebreaks.** While a
  round was being played, the moment the first result was typed in, every
  player who had not yet reported gained a phantom draw on their opponents'
  Buchholz, BHC1, BHC2, MBH and Sonneborn-Berger — and Koya's 50%
  threshold jumped a full win at the same instant.

  Two quantities were being subtracted from each other that are not the same
  kind of thing. `rounds_played_count/1` returned the largest number of game
  *records* any player held, and it was compared against a round *number*. An
  unreported pairing produces no record at all, so the count rose as soon as
  one game finished, while every other player's last record still pointed at
  the previous round. The difference read as "this player missed a round",
  which Article 16.3 scores as a draw.

  Both readers now ask the rounds how many of them are *complete* — the
  highest round in which no pairing is still unreported — rather than
  asking the players how many records they hold. A round holding only byes
  counts as played; a round with no pairings and no byes does not, so
  creating a round in advance no longer awards anyone anything.

  This was the most ordinary situation there is: a round in progress, results
  coming in one board at a time, standings on a projector.

- [Fix] **Importing a round's results from CSV wrote them to the wrong
  games.** The importer matched each line against the board number the
  pairing engine assigned. Every document an arbiter can read - the printed
  pairing sheet, the Pairings page, the public page, the projector - prints
  the *displayed* board number instead.

  Those two are the same for almost every tournament, and come apart as soon
  as one player has a fixed table (Players -> Fixed table). That pairing is
  labelled with its table number and printed last, and the ordinary boards
  close the gap it leaves - so a fixed table on real board 3 of 5 makes the
  sheet read 1, 2, 3, 4 against real boards 1, 2, 4, 5.

  An arbiter transcribing that sheet typed four boards, got "4 results
  imported", and three of them landed on the wrong games. The standings were
  then wrong, and nothing anywhere said so.

  The importer now matches the number the sheet prints. Nothing changes for
  a tournament with no fixed table in it.

  Two things worth knowing about the edge:

  - A fixed table outside the ordinary range - SWAR's own starts at 1001 -
    now imports like any other line. It could not be entered from a CSV at
    all before, because 1001 is never a real board number and the importer
    rejected it as unknown.
  - A fixed table deliberately set to a number an ordinary board already
    uses prints two rows with the same label. That number is taken to mean
    the ordinary board, and the fixed table is entered from the Pairings
    page. The alternative - refusing the whole file as ambiguous - would
    block the four boards that are not ambiguous at all.

  Found while verifying something else, and it was not caused by it: the
  damage reproduces identically with a fixed table at 1001, so it has been
  live for as long as the feature has.

- [Fix] **Club sites could not embed the results pages at all.** They were
  reported as embeddable when the local public pages were removed; they never
  were. Phoenix sets `frame-ancestors 'self'` by default, and the claim came
  from searching the results site's own code for a policy, finding none, and
  never looking at an actual response.

  Every page there permits framing now, and that is safe for the whole site
  rather than for a list of routes: there is no session and no login, so a
  framing page gains nothing it could not get by fetching the URL itself.
  `PUBLIC_FRAME_ANCESTORS` restricts or disables it.

- [Fix] **A Keizer standings row could count a board nobody had scored yet
  as a played loss.** The instant a round was paired, `classify_result/2`'s
  catch-all sent the still-blank result into the same bucket as a genuinely
  played "0-0" - one more game Played, one more Loss - instead of treating
  it as not yet played. Played/W/D/L are not shown on any Keizer screen
  today, and the ladder itself was never wrong either way (a blank result
  scored 0 ladder points regardless of the bucket), so this stayed
  invisible with the app's own defaults. What it did inflate is
  `raw_points`, the ordinary-scoring column printed beside the ladder, by
  one `points_loss` per unscored board - real for any tournament with a
  non-zero loss value, zero everywhere else since `points_loss` defaults to
  0.0. A blank result now scores nothing, the rule `Standings.pairing_records/4`
  has always applied to the same state on the FIDE path.

### Security

- [Security] **Password sign-in had no rate limit.** Every other
  unauthenticated route in the app was given one deliberately — mobile
  enrolment, magic link, registration, the FIDE lookup — and this one
  was missed, leaving nothing between an attacker and a password list but
  bcrypt's own cost.

  It now shares the magic-link form's two buckets: per address, so a list
  cannot be walked against one account, and per client, so one client cannot
  walk a list of addresses. Refused before the password is checked, so a
  throttled attempt costs no bcrypt round and cannot be timed to tell a real
  account from a missing one. Only failures count — signing in and out
  during your own tournament must not lock you out of it.



- [Security] **The KBSB rating import was the one control on Connections
  with no role check.** Every sibling handler on that page checks; this one
  did not, and the page became readable by `support` the same day. It pulls
  the whole Belgian roster over somebody else's API and rewrites the local
  rating table — an act, not a look — so it is an administrator's
  now, on the handler as well as the button.

- [Security] **Connections is no longer readable by an ordinary account.**
  Its buttons were role-gated, and that was half the job: any signed-in user
  could still open the page and read the address this installation publishes
  to, the backup filenames and their sizes, when each rating list last
  synced, and whether the results site was answering.

  None of that is a password and all of it is the operator's business rather
  than every arbiter's. The route refuses now, not only the buttons, and the
  nav link is not offered — a link is a courtesy, but a bookmark or a
  typed URL is not, so the markup gate alone would have left the page serving
  to anyone who guessed it.

  `support` may still open it, which is the point of that role: the person
  answering "why did publishing stop" can see the diagnostics without the
  authority to change them.

- [Security] **Only an administrator can change where this machine
  publishes.** The OpenResults address and token were editable by any
  signed-in user, including a self-registered one. Repointing them at another
  server would quietly send every published tournament's player names,
  ratings and clubs there.

  It is now behind the same gate as the FIDE rating-list download and the
  backup download — an explicit `admin` role — and on the event
  handlers rather than only the markup, since a hidden button still accepts a
  crafted event.

  Signing in through 02cloud is deliberately **not** enough. How somebody
  authenticated and what they may do are different questions, and answering
  the second with the first would make every account in a federated
  directory an administrator of this installation's wiring.

  Deliberately not extended to a tournament's own publish switch. An operator
  decides *where* this machine publishes; the arbiter running an event decides
  *whether* theirs goes. Gating the second would stop an arbiter publishing
  their own tournament on a machine somebody else set up, which is the
  ordinary case rather than the dangerous one.

- [Security] **A published tournament belongs to the machine that published
  it, and can now be taken down.** Until now there was one ingest token for a
  whole results site, and it answered only "may this machine talk to this
  server". Anything holding it could overwrite any tournament there, and
  nothing could withdraw one at all: turning a tournament's publish switch
  off stopped further updates and left the page — player names, ratings,
  clubs and federations — public forever. The only remedy was SSH and
  SQLite.

  Each tournament now gets its own key, generated on your machine the first
  time it publishes and never regenerated. The results site requires it for
  every later update and for deletion, so a second machine holding the shared
  token can no longer touch your event.

## [0.17.1] - 2026-08-26

There is no 0.17.0 release. The version existed for a day and binaries
were built from it, none of which worked - migrations were skipped, so
every one served a 500 on its first page. A Burrito binary caches its
unpacked runtime under its own version number, so a machine that ran one
of those would be handed the broken extraction back for any later build
calling itself 0.17.0. Skipping the number is cheaper than explaining
that.

### Added

- [Feature] **Dutch.** The arbiter interface now speaks Nederlands - 548
  interface strings plus the 24 validation messages, picked from the
  language menu or taken from the browser's own `accept-language`. `nl-BE`
  and `nl-NL` both resolve to it; there is one catalogue, because chess
  vocabulary does not differ enough between Flanders and the Netherlands to
  justify two.

  Terminology follows Belgian (KBSB/FRBE) usage rather than literal
  translation: *paring* rather than the Dutch *indeling*, *scoregroep* for a
  score bracket, *doorschuiver* for a floater, and *stamnummer* for a
  national ID. **bye**, **tiebreak** and **Elo** stay untranslated because
  that is what arbiters actually say. Product and format names - JaVaFo,
  Ainalrami, SWAR, TRF16, IT3/FA1/IA1 - are never translated.

  **The public pages stay English**, deliberately and unchanged: an open
  draws players from many federations, and the language an arbiter picked
  for their own screens is not one to impose on a visiting player reading
  the standings.

- [Feature] **The Dutch is finished: the sentences with links in them, and
  everything that prints.** 840 interface strings now, up from 548.

  Two gaps closed. First, the sentences a previous pass deliberately left in
  English because they wrap around a link or a value: those needed the whole
  sentence to stay one translatable unit with the markup movable inside it,
  which is what `<.rich_text>` now does - the msgid carries a `%[name]`
  placeholder and the translator puts it wherever Dutch wants it. 54
  sentences that read half in each language, or not at all, now read as one.

  Second, **everything you print**. Pairing sheets, standings, cross tables,
  score sheets, place cards, result cards and player lists came out in
  English whatever language the arbiter had picked, because
  `PrintController` assembles its HTML as strings instead of through a
  template and so was invisible to every pass that walked templates. Printed
  documents now also carry the right `lang`, as does the app itself.

  Along the way, a wrapping script's "this is a code, not prose" filter
  turned out to be matching case-insensitively, which had silently skipped
  every one-word label in the app: eighteen Cancel buttons, and most column
  headers. Those are translated now too.

  Column headers that are codes (Pr., Nr, Fed, Elo, Pts, W/B, 1-0) stay
  English on purpose - they match the FIDE forms and the on-screen grid.

- [Feature] **Another 80 interface strings translated, and the half-Dutch
  sentences fixed.** The first pass wrapped 468 strings but only matched
  text sitting against a tag boundary on a single line, so longer sentences
  were left bare - and where it did fire mid-sentence it produced
  FRAGMENTS. The Players page read "Double-click a row to edit the player
  ... or right-click the Kolomtitel Pr. om het voor iedereen tegelijk in te
  stellen": half English, half Dutch, in one sentence.

  Sentences are now the unit. A fragment cannot be translated properly
  anyway - Dutch puts the verb where English does not, so a translator
  handed "to set it for everyone at once." on its own has nowhere to put
  it. Where a sentence wraps around an inline value it is left in English
  rather than split, which is untranslated but at least coherent; those are
  listed in `docs/i18n.md` as the remaining work.

- [Feature] **Players can request byes when they register.** The public
  form now shows one tickbox per round, so somebody who already knows they
  will miss round 1 says so while signing up instead of e-mailing the
  arbiter about it. They still land **not yet arrived**, exactly as before -
  requesting a bye is an announcement, not an arrival.

  Marking them present later does not cancel the byes. The two are separate
  fields and always have been; this is the first time anything filled the
  second one in from the player's side.

  The form states what a requested bye is actually worth in that tournament,
  read from its settings rather than assumed - a player deciding whether to
  ask for one is exactly who a hardcoded answer misleads.

- [Feature] **One value and one allowance for every round a player sits
  out.** Settings -> Scoring's "Genuine absences" card is now "Byes and
  absences": what a sat-out round pays, for the first N of them, up to
  round Y. It already existed - it just had almost nothing feeding it.

  A player asking for a specific round off and a player marked absent
  outright are now the same thing, because they are: the only way you know
  before the round is paired is that the player told you. Somebody who was
  paired and then didn't turn up is a forfeit on their board, which is a
  different event entirely and always was.

  FIDE's default is zero, so nothing changes until an arbiter sets a value.

- [Feature] **Played-but-unrated results (TRF `W` / `D` / `L`).** A game
  that was contested over the board but does not reach the rating report -
  typically one that ended before the minimum number of moves. Three new
  results on the Pairings page: "1-0 (played, not rated)" and its draw and
  loss counterparts.

  They score exactly what their rated twins score and count as PLAYED for
  every FIDE Art. 16 purpose, because the game happened. The only thing
  that differs is the letter in the TRF, which is how FIDE is told not to
  rate it. Required by the draft VCL4THP (Q185).

  Wired through the result table, standings, Keizer, TRF import and export,
  PGN and SWAR export. The last two mattered more than they look: PGN would
  have written `*` (its unknown-result marker) for a game that plainly had
  a winner, and SWAR export's catch-all returned bitmask 0 and 0.0 points,
  dropping the result and the score together.

- [Feature] **The pairing rationale explains Article 5.2.5, and says where
  we differ.** When neither player held a colour preference, 5.2.5 decided
  the board - the higher ranked player takes the initial colour if their
  tournament pairing number is odd. The board now says so.

  On a tournament paired by Ainalrami it adds the part an arbiter actually
  needs: other programs may seat that board the other way round. They take
  5.2.5's parity on the player's position within the bracket; we take it on
  the tournament pairing number, which is what Article 1.1 points to. **The
  pairing is identical either way - only who holds White differs.**

  This is the one rule where the engine knowingly differs from both
  reference implementations, and until now the only way to find that out
  was to ask us. Someone cross-checking a board against SWAR should be able
  to read the answer off the screen.

- [Fix] **Every standalone binary ever built skipped its own migrations and
  served a 500 on the first page.** `no such table: users`. Downloading a
  release, running it and opening the page did not work, and never had.

  Migrations run at boot when the app detects it is a release, and the check
  for that was `RELEASE_NAME != nil` - the line `mix phx.gen.release`
  generates. It is true of a release started through its own `bin/<name>`
  script and **false in a Burrito binary**, which is every executable this
  project ships: Burrito's launcher execs `erl` directly rather than going
  through that script, and sets `RELEASE_ROOT` but not `RELEASE_NAME`. So the
  guard said "not a release", migrations were skipped, and the app started
  against an empty database.

  It went unnoticed because nothing ever ran one. The binaries workflow built
  five executables and tested none of them, and the guide told you to run a
  migration step by hand first - through a `PairingsEngine.Release.migrate`
  that has never existed in this codebase. Two pieces of documentation and a
  CI job all agreeing about a step that could not be performed is what a gap
  in coverage looks like from the outside.

  Now keyed on `RELEASE_ROOT`, which both kinds of release set. Found by the
  new smoke test below, on its first run.

- [Change] **The binaries are built on every push to main, and each one is
  started before the build is called a success.** They were built on tags and
  manual dispatch only; the last build before this was a month old, on a
  branch, from before the engine switch. A shipped artifact built only at
  release time is tested only at release time.

  Each target now boots in local mode and is asked for a page, and the run
  fails unless the page comes back carrying the auto-signed-in owner's
  address. That is a thing no unit test can cover: the release evaluates
  `config/runtime.exs` for real, inside a self-extracting wrapper, and the
  migration bug above lived precisely in that gap. Concurrent runs on a
  branch cancel each other so a burst of commits does not queue five runners
  deep; tag builds never cancel.

  Deliberately no `paths-ignore` for documentation: `CHANGELOG.md` is
  compiled into the binary, so a docs-only change is not docs-only here.

- [Fix] **A first local run could hit "database is locked" while creating its
  own database.** Five pool connections racing to create the same new file
  and set WAL on it. Locally the pool is two now - one person cannot use five
  - which is both faster to start and a smaller race. It recovered either
  way, since Ecto retries, but a fresh install should not have to.

- [Feature] **A second download shape, because antivirus deletes the first
  one.** `openpairings_portable_<target>` is the same application as an
  ordinary Erlang release: a folder you unzip, runtime inside, with a
  launcher beside it - `OpenPairings.bat` on Windows, `openpairings.sh`
  elsewhere. Unzip, run the launcher, same localhost, same no-login, same
  everything.

  The single-file binary is nicer to hand somebody and it is not always
  possible to hand it to them. Symantec removed one from disk before it ran
  once - not a warning, not a quarantine prompt, deleted. Nothing is wrong
  with the binary: an unsigned executable carrying a compressed payload,
  which unpacks a runtime into AppData and spawns processes, is byte-for-byte
  what a dropper looks like, and a heuristic engine cannot tell them apart.

  Code signing is the real answer on Windows and needs a certificate on a
  hardware token or a cloud HSM. This needs neither, and a directory of DLLs
  with a `.bat` beside it is not a shape anything hunts for. Both shapes are
  built by the same CI run, both bundle the Erlang runtime, and both are now
  **started and asked for a page** before the build is called a success - the
  portable one through its launcher rather than around it, since the launcher
  is the part that is new.

- [Feature] **Local mode: the standalone binary runs on your own machine with
  no setup at all.**

  ```bash
  ./pairings_engine_linux_x86_64 start
  ```

  It is the default in a binary, and it took two goes to get there. The first
  version made you pass `OPENPAIRINGS_LOCAL=1`, so running the file the way
  anyone actually runs a file - by running it - produced `environment
  variable DATABASE_PATH is missing` and a 2.8 MB `erl_crash_dump`. That is a
  server's error message shown to somebody who is not running a server.

  Nobody deploys a self-extracting single-file executable to production; a
  server gets a real release and a service unit. So a binary IS the local
  case, and it now knows it without being told (Burrito's launcher exports
  `__BURRITO`). `OPENPAIRINGS_LOCAL` still overrides both ways: `=1` for a
  plain `mix release` or a dev run, `=0` to make a binary behave like a
  server anyway.

  The CI smoke test was complicit and has been fixed too: it passed
  `OPENPAIRINGS_LOCAL=1`, which proved the flag worked and said nothing about
  the case that broke. It now starts each binary with no configuration
  whatsoever.

  A release is built for a server, and refused to start without SMTP
  credentials, a `DATABASE_PATH` and a `SECRET_KEY_BASE` - all correct for a
  server, all nonsense for one person who downloaded one file. Local mode
  generates the secret once and keeps it, puts the database in the OS's own
  per-user data directory, and serves `http://localhost:4000`.

  **There is no login.** A local install has one user by definition - the
  person at the keyboard - so it does not ask who you are. The first request
  signs you in as an account named after your OS user and hostname
  (`ann@her-laptop.local`), created on first start and reused after that, so
  your tournaments are still there next time. The account exists at all only
  because tournament ownership, the audit trail and invitations are keyed on
  a user; it is cheaper to give local mode a real account than to teach all
  of that about a user who is not there. The log-out button is hidden, since
  there is nothing to log out of.

  This is a session, not a bypass: a genuine token is issued the same way a
  magic link would issue one, so scopes, sudo mode, expiry and LiveView all
  behave exactly as they always did. Nothing else in the app knows local mode
  exists.

  **Two independent conditions gate it, and both must hold.** The setting has
  to be on, *and* the request has to have physically come from this machine -
  checked per request against the peer address, ignoring `X-Forwarded-For`,
  which the client controls. The listener is also pinned to loopback and will
  not be talked out of it, not by `PHX_HOST` or anything else. The per-request
  check is not redundant with the pin: a reverse proxy in front of the app, or
  a later change to how the endpoint is built, breaks the pin's guarantee and
  leaves the other one standing.

  What made this worth doing now is the engine switch: pairing no longer
  needs a JVM. Ainalrami is Elixir and is *inside* the binary, so a local
  install has no external dependency at all. Migrations already ran at boot
  in any release, so first start creates and migrates the database itself -
  the binaries guide said to run an `eval` step first, and that step
  referenced a module that has never existed.

### Security

- [Security] **The retired markdown renderer is gone.** The changelog page
  was rendered by earmark, which carries CVE-2026-48591 - a stored XSS
  through unescaped HTML attribute values - and is retired in *every*
  release, so there was no version to upgrade to and never will be.

  The old reasoning for keeping it was sound as far as it went: the only
  markdown it ever saw was this repo's own `CHANGELOG.md`, read at compile
  time, so the hole was unreachable. That is a property of today's call
  sites, not of the code, and an abandoned package with a permanent
  advisory reopens the same argument at every audit.

  The suggested replacement, MDEx, is a Rust NIF, and this app cross-builds
  standalone binaries for five OS/arch targets - each would then need a Rust
  toolchain. So the parse now uses `earmark_parser` (maintained, pure
  Elixir, and the half that never had the flaw, since the flaw is in HTML
  generation) and the generation is ours, in `PairingsEngine.Markdown`,
  where escaping is not optional, the tag set is an allowlist, and a
  `javascript:` link is not something the renderer can emit.

  Verified as a swap rather than a rewrite: rendering the whole changelog
  through both produces identical counts for all 20 tags it uses and
  identical text, but for the apostrophe - earmark applied smartypants,
  which `earmark_parser` has deprecated. `mix hex.audit` now reports
  nothing.

- [Security] **A player could be seated on a board of a tournament they were
  not in.** Two of the ways an empty seat is resolved on the Pairings page -
  seating somebody from the pool, and pairing two players out of it - took
  the player id straight from the browser's message and checked only that the
  arbiter owned the *tournament*, which proves nothing about the row. The
  board's foreign key points at the players table and cannot say "and in this
  event", so any player id in the database could be put on any board of any
  tournament, under any account. Both now ask the ownership question the rest
  of the module already asks before accepting an id from the page.

### Verified

- [Verified] **An unrated game counts toward a title norm; a forfeit on the
  same board does not.** B.01 1.4.2 excludes a game "decided by forfeit,
  adjudication or any means other than over the board play" - it says
  nothing about rating, so a game recorded unrated still counts, at full
  value.

  That was already the behaviour, but by accident: the norms module reads a
  `played` flag and has never heard of unrated result codes, so the right
  answer fell out of another module's bookkeeping. No code changed; the
  rule is now stated where it applies and asserted both ways, because only
  the contrast shows the rule is being applied rather than everything being
  counted.

### Fixed

These first four came out of a deliberate sweep of the codebase for
inconsistencies rather than from a bug report, prompted by the engine
switch: if Ainalrami is what pairs every tournament now, the input it is
handed had better be right. The sweep looked for one shape in particular -
the same rule written down in two places, where the two can drift apart
without anything failing. It found five, four of them live.

- [Fix] **A game that was played but not rated was handed to the pairing
  engine as a loss.** The crosstable scored it correctly - an unrated win
  pays what a rated win pays - but the score written into the pairing file
  came from a second, hand-written mapping that listed six result codes and
  sent everything else to `points_loss`. `W` and `D` were not on the list.

  So a player who won an unrated game was given to the engine a full point
  light. That is not a display problem: score is what decides which bracket
  you are paired in, so they were bracketed too low and played the wrong
  opponents, while the standings on the next screen showed the point they
  had actually earned.

- [Fix] **An absence worth half a point was worth nothing to the pairing
  engine.** Same cause, bigger blast radius. A bye was scored from its
  letter in the file, and the letter for an absence is `Z`, read as a loss.
  But `Z` is also written for a requested zero-point bye, and an absence may
  be worth `abs_value` - half a point, in most clubs that set it, capped by
  round and by count.

  Exactly the tournaments that configure a paid absence are the ones it went
  wrong for: the arbiter sets "half a point for a round sat out", the
  standings honour it, and the file says zero. Byes are now scored by the
  same function the crosstable calls, so there is one answer to the question
  instead of two.

- [Fix] **A pairing-allocated bye in a SWAR 3-2-1 event dropped its presence
  points on the way to the engine.** The crosstable pays `bye_value` plus
  presence points; the engine was told `bye_value` alone.

- [Fix] **The explanation on the pairing-rationale page could have described
  a different pairing than the one on the board.** The options handed to the
  engine and the options handed to its explain pass were two separately
  written lists that happened to contain the same three keys. They now are
  the same list. Nothing was wrong yet - the next key added to one of them
  would have been.

- [Change] **The "absent counts as a voluntary unplayed round" setting is on
  by default, and now says so.** The field's own comment read "never on by
  default" directly above `default: true`. The default is correct - an
  absence and a requested bye are one event under two names, and splitting
  them for tie-break purposes split one thing in half - so the comment was
  the thing that was wrong, along with two test names describing the old
  default and no test asserting the real one. There is one now.

  Behaviour is unchanged; this entry exists because the documentation said
  the opposite of the code, which is worse than saying nothing.

- [Fix] **A backup restored every hidden board back into public view.** An
  arbiter can hide an individual pairing from the public page; that flag was
  not written into the backup file, so restoring an event un-hid all of
  them. That is a disclosure rather than a lost preference - the board the
  arbiter deliberately withheld comes back visible, with nothing to say it
  happened.

  Restoring a backup written before this fix leaves nothing hidden, which is
  the same state as before and the safe direction.

  The stored pairing rationale (the "why did the engine pair it this way"
  panel) is still dropped by a backup, and now says so in the code rather
  than going quietly. It holds internal player references that a restore
  cannot reconnect, so carrying it across would attribute every bracket to
  the wrong players while looking entirely convincing. Losing an explanation
  is better than showing a false one; carrying it properly needs work the
  file format already has a version field for.

- [Fix] **A 3-2-1 event was scored one way on screen and another in the file
  the engine brackets from.** SWAR's 3-2-1 system pays a point for turning
  up on top of the result, and the standings pay it - but the score column
  written into the pairing file carried no such point, for any game. So a
  Belgian club event bracketed its players by a number that was not the one
  on their own crosstable row. SWAR sends the sum of both to its engine, so
  this was also handing over a different column than the program the format
  was read off.

- [Fix] **A player marked absent in a Swiss tournament now scores their
  absence award.** They used to score nothing at all, whatever the
  tournament paid. Players absent for the whole event were filtered out of
  the round before the point where absences get recorded, so no record was
  written - no board, no forfeit, no row - and the award had nothing to
  attach to. Keizer had always recorded them; Swiss never did. Invisible
  while the award was zero, which is the default, and silently wrong for
  anyone who had set it.

  Round robin is unaffected and was never wrong: its schedule is fixed, so
  an absent player still has an opponent and the round is scored as a
  forfeit on that board rather than as an absence.

- [Fix] **A round robin too long for the app's own round limit crashed
  instead of refusing.** 32 players over two cycles is a 62-round schedule,
  and this app supports 30 rounds - the length a Berger table needs and the
  ceiling the tournament validation enforces were two numbers written
  independently, so asking for the next round threw an exception rather than
  saying anything. It now refuses in words, naming how many rounds that
  field would need and the maximum, and the maximum in the message comes
  from the same place the validation reads it. It is not quietly capped:
  capping would pair a schedule the arbiter did not ask for and drop the end
  of it.

- [Fix] **A half-point absence is no longer labelled "0 bye"** on player
  cards and printed lists. It reads from what the round actually paid,
  which could not vary until now.

- [Change] **Absences count as voluntary unplayed rounds by default.**
  FIDE's C.07 treats a voluntarily unplayed round differently in
  Buchholz/Sonneborn-Berger, and every absence the pairing knows about was
  announced in advance - so that is what it is. Existing tournaments keep
  whatever they have; only new ones start with it on.

  The warning attached to this setting now fires when you CHANGE it rather
  than whenever it is on. Tied to the state, it would have greeted every
  arbiter opening a fresh tournament with a red box about a setting they
  never touched.

- [Fix] **Every title norm in a 3-2-1 event was judged one band out.** The norm
  calculation bands each game's stored points against the tournament's own
  win/draw values to get FIDE's 1/½/0 - and on a SWAR 3-2-1 event those
  stored points already carry the point for turning up. So every played
  game shifted one band UP: a win read as a loss, a draw read as a win, a
  loss read as a draw. Not an occasional misread but a uniform inversion,
  so a player's norm score and every check derived from it were wrong for
  everyone in the event. The same nine games score 7.5/9 normally and
  scored 1.5/9 under 3-2-1.

- [Fix] **A club that pays for absences no longer exports as one that pays
  for none.** Leaving the absence limits blank means "no cap", which is
  what the settings screen tells you to do; the `.swar` exporter wrote a
  blank as `0`, and `0` in that format means "cap at zero - pay nothing".
  Re-importing the file made it true. Blank now exports as the round count,
  which is the largest honest number for a tournament that long.

- [Fix] **A player whose games were all unrated exported as "0 games
  played".** The `.swar` game counter used its own four-code list of what
  counts as played, against the nine the standings use - so the unrated
  W/D/L results and the asymmetric ones were invisible to it, and the file
  said zero games beside nonzero points and three round records. A file
  that contradicts itself, and one that re-imports as fact.

- [Fix] **Two forfeits exported to PGN as "unknown result".** `+/-` and
  `-/+`, the legacy spelling of a single-sided forfeit, fell through to
  `*` where their `FF` twins export as a decisive result. A double forfeit
  still exports as `*`, deliberately: PGN has no way to say it.

- [Fix] **Entering "1/2-0" in a Keizer tournament took the standings page
  down.** The asymmetric VCL.13 results have been storable, and scored, since
  they were added; Keizer's per-round statistics were the one reader of the
  same vocabulary never extended to them, and had no fallback, so the page
  raised the moment such a result was entered. They now count what the
  crosstable counts - the side on the half as a draw, the side on zero as a
  loss, both as games played. An unknown class is now a loud failure naming
  itself rather than a silently ignored one, because the alternative to a
  crash here is wrong standings.

- [Fix] **A withdrawn player's progressive-score tie-break stopped when
  they left.** Progressive score sums the running total round by round, and
  it was folding over the rounds a player had a record for rather than over
  the rounds of the event. FIDE's C.07 Art. 16.1.1 settles it - "any round
  after a participant withdraws is a zero-point-bye" - so those rounds
  exist and add nothing, which means carrying the total forward. A player
  who left after round 1 on 1.0 scored 1.0 where 3.0 is correct, and was
  placed below players they should have tied with.

- [Fix] **Importing a TRF with a blank round in the middle of it shifted
  every later round up one.** A round with no results is legal input - a
  late entrant's earlier rounds look exactly like that - but the import
  skipped it, so rounds came out numbered 1 and 3 with no 2 and the games
  from round 3 landed in round 2's columns, dates and all. Trailing blank
  rounds are still skipped: inventing rows for rounds that have not
  happened would claim the event is further along than it is.

- [Fix] **A TRF this app exported could not be read back into it: every
  played-but-unrated game returned as two byes.** The importer decided
  whether a round entry was a game at all from its own private list of
  result codes, written before `W`, `D` and `L` existed and never extended
  to them, so an unrated game failed to resolve to a board and each side
  came back as a bye with the opponent gone. The proof it was drift and not
  a decision sat thirty lines below the list, in code that could never run.
  There is one canonical list of playing codes now and the last two private
  copies of it are deleted - a private copy cannot be fixed by correcting
  the real one, which is how this kept happening.

- [Fix] **A played-but-unrated result recorded against a bye crashed both
  pairing and the FIDE download.** The guard that exists to stop a bye ever
  carrying a playing code had the same gap, so `W`, `D` and `L` stayed
  playing codes on a row with no opponent - the exact combination it is
  there to prevent. Building the FIDE file then raised, and raised early
  enough that nothing caught it: pairing the next round threw an exception
  where every other refusal returns a message, and the download went with
  it.

- [Fix] **A player marked as needing an accessible table lost that marking
  when the tournament was restored.** SWAR records the marking on its own,
  with no table number attached, and a `.swar` import stores it that way.
  Restoring a JSON backup or a snapshot re-derived it from whether a table
  number was present, so a player who had the marking and no number came
  back without it - and exporting that tournament to `.swar` again then told
  the next program the player did not need one. It is carried across as
  stored now.

- [Fix] **The categories "Turn off" button could not turn categories off
  once a round was paired.** Pairing by category locks after round 1, and
  the off-switch sent that locked setting along with the one it meant to
  change, so the whole write was refused - with a message naming a setting
  the arbiter had not touched. The button now sends only what it needs to,
  and is disabled with a sentence saying which setting is in the way.

- [Fix] **A late entrant marked absent was paid for rounds before they
  joined.** A player who is both absent and joining in a later round was
  written an absence row for every round of the event, including the ones
  the tournament did not have them for. Those rows score: on an event that
  pays for absences they collect real points and burn the per-player
  allowance doing it, and they go into the `.swar` export as well.

- [Fix] **Two players could be handed the same pairing number.** Mark the
  top-numbered player absent, then register a walk-in, and the walk-in was
  issued a number that was already on somebody's row: the next number was
  taken as the highest among players currently *eligible*, and an absent
  player keeps the number they were given. Nothing downstream objected. The
  exported FIDE file then carried two rows with the same starting rank and
  opponent references that could mean either of them, and the tie-break that
  exists so the pairing order is reproducible had nothing left to break the
  tie with. Which numbers have been issued is a question about the whole
  roster, and is now asked of the whole roster.

- [Fix] **An archived tournament still accepted three edits to a vacant
  board.** An archive is read-only, and seating somebody from the pool,
  awarding a bye for the vacancy and pairing two players out of the pool
  were the three members of that family that never asked whether the
  tournament was writable. Their five siblings all did, which is why the
  Pairings page carried a comment saying these writes were refused
  server-side regardless - and why the suite that proves it names the five
  and not the three.

- [Fix] **A FIDE ID with a letter in it crashed the add-player form.**
  Anything that is not a clean number - letters, a dash, a pasted value
  with a stray space - raised out of the duplicate check before the form
  could say "is invalid". A 40-digit number got further and raised from the
  database driver instead; IDs are now bounded to nine digits, which is
  more than FIDE issues.

- [Fix] **Picking a language on the log-in page and then signing in put you
  back in English.** Signing in clears the session, which is where the
  chosen language is kept, and nothing put the language back afterwards. The
  picker sits in the log-in page's own bar, so "choose Nederlands, then sign
  in" is the obvious order to do it in and it was the one order that lost
  the setting. The end-to-end language tests all signed in first and
  switched afterwards, so none of them was ever in a position to see it.

- [Fix] **Switching language sent you to the home page instead of back to
  what you were reading.** The picker is meant to return you to the page you
  were on and nothing in the app ever told it which page that was, so it
  always took its fallback. On the public pages that is worse than an
  inconvenience: a visitor reading the standings who switched language was
  bounced to the log-in screen, because the home page needs an account. The
  page is now passed through, query string included, so a switch on a
  filtered page comes back filtered.

- [Fix] **A browser asking for Dutch with a broken quality value now gets
  Dutch.** `accept-language: nl;q=banana` resolved to English, as did a
  dangling `nl-`. The resolver was already right - a malformed weighting
  sorts last rather than raising - but its test asserted the result was
  English, which was only ever true because Dutch did not exist yet. Worth
  recording as a fix rather than a test change: the behaviour a user gets
  really did change.

### Changed

- [Fix] **A Swiss late entrant was paired before the round they joined in.**
  A player with a `start_round` of 3 played rounds 1 and 2. The check
  existed and was correct - it is what decides whether there are enough
  players to pair at all - but the roster handed to the engine was rebuilt
  from scratch a few lines later without it. Keizer read `start_round`
  properly all along; only the Swiss path did not.

  They are now left out of the round completely: no board, and no absentee
  bye either, because a round before you join is not a round you were
  absent from. Reachable in practice by restoring a tournament from a
  backup, or by importing one, since nothing in the Swiss interface sets
  `start_round` by hand.

- [Change] **The new-tournament form names the engine.** Picking "Swiss"
  now says, underneath, that Ainalrami will pair it and which edition of the
  rules that means. The engine was previously only visible in Settings,
  which is not where the choice is being made.

- [Change] **The interface no longer claims a FIDE endorsement.** Four
  places said it - the engine picker, the note beside it on a homologated
  tournament, and both halves of the switch dialog. FIDE has announced that
  existing endorsements are revoked in the coming Acceptance Cycle, so it
  was a claim with a shelf life, and an app should not be trading on one.

  What replaced it is the thing that is both true and actually decides the
  question: Ainalrami implements C.04.3 as it stands from 1 February 2026,
  JaVaFo implements the 2022 edition it was last built for, and on a
  homologated event that difference is what you would be defending. The
  reasons to prefer JaVaFo are stated without the badge - most tournament
  software ships it, so its boards are the ones that reconcile.

- [Fix] **The engine that pairs every tournament now was pinned to a build
  from before two of its own fixes.** The pin moves to Ainalrami v0.11.1.

  Both fixes came from reading bbpPairings 6.0.0's source rather than
  inferring behaviour from its output. The final-round topscorer threshold
  used `pointsForWin` where the reference uses
  `max(pointsForWin, pointsForDraw)` - which only matters in a point system
  where a draw outscores a win, something FIDE would never publish but a TRF
  can state outright, since the values are free-form numbers in the file.

  It was measured rather than argued: a new corpus axis with a draw worth
  more than a win, run in two arms over identical seeds. With the fix,
  3,775,174 rounds and 31,184,698 pairings at 100.00% agreement. With that
  one line reverted, 8,181 rounds paired differently from the reference -
  and zero illegal rounds in either arm, which is the point. The broken arm
  does not fail loudly. It quietly pairs a different tournament.

  The second fix: the engine recognised only `1`, `=` and `0` as "a game was
  played". Correct for anything that came through its own TRF parser, which
  normalises the letter spellings `W`, `D` and `L` on the way in - and wrong
  for a caller building player maps directly, which is exactly what a host
  application does. A played unrated game read as unplayed carries no colour
  and no float history.

- [Change] **Ainalrami is the default Swiss engine now.** A new Swiss
  tournament is paired by our own engine unless you go and pick JaVaFo; it
  used to be the other way round. The confirmation dialog flipped with it -
  it now asks before switching a running tournament *to* JaVaFo, since that
  is the change that swaps a maintained engine for a third-party one frozen
  on the 2022 rules.

  The reason for the flip is that Ainalrami is no longer the riskier
  choice. It implements the 2026 handbook text where JaVaFo 2.2 implements
  2022, it agrees with bbpPairings 6.0.0 across two independent corpora of
  roughly 488 million pairings each, and the second corpus - run after the
  optimisation work - found zero disagreements. Every claim the settings
  screen used to make about the engines has been rewritten to match: the
  old copy called JaVaFo "FIDE-endorsed" and Ainalrami "experimental", and
  neither is a fair description any more. Nothing on the FIDE side is
  endorsed for the 2026 rules at all, which is the whole point.

  Existing tournaments are untouched. Whichever engine paired round 1 keeps
  pairing the rest.

- [Change] **The tournament's point system now reaches the pairing engine.**
  An event scored 3/1/0, or one with a half-point loss, or a pairing-allocated
  bye worth something other than a full point, was pairing as though it were
  1/½/0. The engine was reading its own defaults because nothing ever handed
  it the tournament's values. It does now - win, draw, loss, the
  pairing-allocated bye, the forfeit loss and the zero-point bye all travel
  with the pairing request.

  This matters most for downfloat history. A player whose "loss" is worth
  half a point was being recorded as having *scored*, and therefore as
  having floated down, which then steered later rounds. Tournaments on a
  standard 1/½/0 scoring see no change.

- [Change] **The About screen names the engine that is actually pairing.**
  It showed the pairing *system* - "Swiss" - which stopped identifying
  anything once the system label and the engine name came apart. A Swiss
  tournament now reads "Swiss - FIDE Dutch (Ainalrami)", matching how round
  robin has always read "Round robin (Berger)". The printed pairing sheet
  credits the engine by name for the same reason.

## [0.16.1] - 2026-08-23

### Changed

- [Feature] **The arbiter UI is now translatable: 469 strings in one file
  per language.** `priv/gettext/nl/LC_MESSAGES/default.po` would be Dutch -
  one entry per string, each recording the file and line it came from so a
  translator has context. Fill in the right-hand sides and the app speaks
  Dutch; nothing else needs touching.

  **The player-facing pages stay English on purpose.** Public pairings,
  standings, registration and mobile result entry are pinned via
  `EnglishHook` regardless of the chosen language. An open draws players
  from a dozen federations, and the language a Belgian arbiter picked for
  their own admin screens is not one to impose on a visiting player reading
  the standings.

  Nothing changes visually today: gettext returns the original text when no
  translation exists, so a wrapped app is byte-identical until a catalogue
  arrives.

- [Feature] **Language scaffolding, English only for now.** Adding a
  language is now translation work rather than architecture work: add it to
  `PairingsEngineWeb.Locale`, run `mix gettext.extract --merge`, translate
  the `.po`, done. The picker appears by itself once there is a second
  language - it stays hidden while there is one, because a picker offering
  a single option is furniture.

  A locale comes from the session first, then the browser's
  `accept-language`, then English. The header matters more here than in most
  apps: the people reading the public pages are players with no account and
  no settings screen, so their browser is the only thing that can speak for
  them. `nl-BE`, `nl-NL` and `nl` all collapse to one catalogue.

  Two things this had to get right, both documented in `docs/i18n.md`. A
  LiveView does not run in the process that served the request, so a locale
  set only by a plug would be lost the moment the socket connects - the page
  would render translated and then silently revert. And the resolved locale
  is written back into the session, because a LiveView cannot read headers,
  and without it the dead render and the live render disagree.

  Almost nothing is translated yet; a few strings are wrapped to prove the
  pipeline end to end.

- [Feature] **Four new themes: Solarized Light, High Contrast, Tokyo Night
  and Nocturne.**

  The set was five dark themes and one light, which is backwards for the
  work: an arbiter enters results in a brightly lit hall at two in the
  afternoon, not in a dark room at midnight. Three of these four address
  that.

  - **Solarized Light** - the palette already here, read the other way up.
  - **High Contrast** - pure black on white, heavy borders, no tinted
    surfaces. Not a flavour but an accessibility option, for reading a
    laptop across a hall; every other theme here trades contrast for calm.
  - **Tokyo Night** - deep indigo, distinct from a set that skewed grey
    (Nord) or purple-on-charcoal (Dracula, Catppuccin).
  - **Nocturne** - muted rose and gold over deep plum-grey. The only one
    that is not somebody else's palette.

- [Fix] **A categories test asserted a bare word against the whole page.**
  It creates a player called "High" and then did `refute html =~ "High"`,
  which broke the moment unrelated chrome contained that substring - the
  "High Contrast" theme in the topbar picker. The claim is about the preview
  modal's contents, so it now asks the modal rather than the document.

- [Removed] **The orange accent and the Gruvbox theme are gone too.**
  Orange carried the same translucent-warm `--accent-soft` as amber, so
  removing only amber left the identical trap one click away in the picker.
  Gruvbox showed it regardless of accent, because its own signature colour
  is orange - that one was the theme working as intended rather than a
  defect, and it goes because it is not wanted.

- [Removed] **The amber accent is gone.** In every dark theme its
  `--accent-soft` was a translucent orange, and that value is painted behind
  the active topbar tab and as the focus ring on selects - so a
  semi-transparent orange box followed you onto every page and around every
  dropdown you touched. All seven themes were swept against the accents to
  confirm: amber was the only *choice* that produced it. Gruvbox still does,
  but its accent is orange by definition, which is the theme rather than a
  bug.

- [Fix] **The stranded-page watchdog never fired.** It tested
  `liveSocket.isConnected()`, which is transport-level - and the websocket
  can be perfectly connected while the LiveView on the page has failed to
  rejoin and is dead. That is exactly the state a restart produces, so the
  check reported "connected", cleared itself, and the reload it existed to
  perform never happened. It now requires the main view to carry
  `phx-connected`, which LiveView sets only while genuinely joined.

- [Change] **The restart banner tells you to reload if the page is stuck.**
  It said "this page comes back on its own, no need to touch anything",
  which was not reliably true. A promise that does not arrive leaves
  somebody staring at a bar; "reload this page if it has not come back in a
  minute" costs one click and always works.

- [Change] **The history tree reads as a tree now.** Three things it was
  missing:

  - **Branches had no rail.** The vertical line was drawn once for the trunk,
    so a branch appeared as offset diamonds with nothing joining them - and
    that a branch is a *path* is the one thing this view exists to say. Each
    lane now draws its own rail, fainter than the trunk, because the
    leftmost line is where the tournament is now and should stay the line
    the eye follows.
  - **Cards ignored the pointer** despite carrying buttons. Border and a
    whisper of shadow on hover, nothing more: a row is a record, and lifting
    each one off the page would turn a history into a deck of cards.
  - **"Where the tournament is" could only be found by reading captions.**
    That card now carries an accent left edge and a faint tint, so it is
    findable at a glance down a long list. The badge still says it in words.

- [Change] **A collapsed restore point now shows WHAT changed under it, not
  just how many.** The row said "4 changes after this point", which is the
  one thing you cannot act on - it reads identically whether they were four
  rating refreshes or four re-pairings. Each point now carries a pip per
  kind of change folded beneath it, in the same hue the audit timeline and
  the expanded rows already use for that kind, so the colour language is one
  language rather than two. The count is still there, and screen readers get
  the kinds as text.

### Fixed

- [Fix] **`-fast` on the deploy script did nothing.** The flag was matched
  against `--fast` and `-f` only, so the single-dash spelling - the one
  actually typed - fell through and the deploy waited the full countdown
  with no complaint. A mistyped flag that looks exactly like a working one
  is the worst kind. `--fast`, `-fast` and `-f` are all accepted now, and
  anything unrecognised is called out instead of ignored.

### Changed

- [Change] **The two-minute restart tier is quieter again.** It was briefly
  given a tinted amber bar to make the state change harder to miss. Red at
  thirty seconds is where the volume belongs.

## [0.16.0] - 2026-08-22

### Security

- [Security] **Bandit upgraded to 1.12.5, closing a HIGH and a MEDIUM.** Bandit is
  the HTTP server, so both were reachable from the internet:
  CVE-2026-74836 (HIGH) let HTTP/2 connection-window starvation pin Plug
  processes indefinitely - a denial of service - and CVE-2026-75484
  (MEDIUM) passed header values containing CR, LF or NUL through to the
  application unvalidated.

- [Security] **earmark's CVE-2026-48591 is reported but not reachable here, and it
  stays for now.** The advisory is a stored XSS through unescaped HTML
  attribute values, which needs attacker-controlled markdown. There is
  none: the only thing earmark ever renders is this repo's own
  `CHANGELOG.md`, at compile time, baked into a constant. Nothing
  user-supplied reaches it at runtime.

  The suggested replacement is a Rust NIF, and the release workflow
  cross-builds Burrito executables for five OS/arch targets - taking that
  on to close a hole that cannot be reached is the worse trade. The
  reasoning is written down beside the code, and a test now fails if
  earmark is ever called from anywhere else, because a second call site is
  exactly what would make the CVE live.

### Changed

- [Fix] **The app was shipping a four-day-old Ainalrami, and every claim made
  about the engine was measured on a different build.** The dependency is
  pinned to an exact commit on purpose - an engine that changes under you
  is the one thing a tournament manager can never allow - but the pin had
  not been moved since 17 August, leaving it 79 commits behind.

  What that build was missing is not cosmetic:

  - **Article 5.2.5 initial-colour handling**, added the day after the pin.
    This is the exact behaviour the settings screen cites when it says
    Ainalrami follows the current handbook text, so the app was making a
    claim its own bundled engine could not honour.
  - **The entire matching-performance rewrite.** Measured here on a round 6
    after five played rounds: 100 players 4.35 s → 0.11 s, 200 players
    82.7 s → 0.19 s, and 400 players did not finish in seven and a half
    minutes → 0.65 s. A 200-player event was effectively unusable and a
    400-player one would have looked like a hang.
  - **The validation the UI quotes.** The zero-disagreements-over-488-million
    figure was measured against the current engine, not the pinned one.

  Pin moved to `6d739bd`, and the full suite - including the
  JaVaFo-versus-Ainalrami differential tests - passes against it.

- [Fix] **The restart banner can no longer get stuck on screen forever.**
  It was cleared only by a server push - fine, until the very thing it warns
  about is what stops those pushes arriving. If the socket did not come
  back, the page never heard the expiry and sat on "back shortly"
  indefinitely; reported after half an hour of it. It now times out on the
  client too, three minutes past the deadline, with no server involved.

- [Fix] **A page left stranded by a restart now comes back on its own.**
  The banner promised "this page reconnects on its own" and it did not
  always: LiveView retries the rejoin every five seconds forever, so
  anything that makes the rejoin fail *permanently* leaves the page looking
  alive and doing nothing until somebody hits reload.

  The known cause was the `SECRET_KEY_BASE` rotation above - the signed
  session token baked into the page could no longer be verified, so every
  retry failed for the same reason as the last. That is fixed at the root,
  but a retry loop that can never succeed is a bad enough failure mode to
  guard against on its own terms. If a restart is well past due and the
  socket is still down, the page reloads itself, which always works.

  Only ever armed by an announced restart. Reloading on any long
  disconnection would catch people on flaky phone signal in a tournament
  hall, which is an easier way to lose someone's work than the problem it
  fixes.

- [Fix] **Updates no longer log everyone out.** The deploy script has always
  meant to reuse `SECRET_KEY_BASE` across deploys, so sessions survive a
  restart - the code and the docs both said so. It never worked. The systemd
  unit is written as `Environment="SECRET_KEY_BASE=..."` and was read back
  with a pattern expecting no quotes, so the regex could not match the file
  the same script had just written. The reuse branch never ran, every deploy
  minted a fresh key, and every signed session cookie was invalidated.

  The script lives outside this repo and has been fixed there; both quoted
  and unquoted units are accepted now. Sessions survive from the next deploy
  onwards.

- [Feature] **"Updated to v0.16.0" appears once after an update**, bottom
  right, dismissible, gone by itself after twelve seconds. Only when the
  version actually changed: a crash-restart or a config reload is not news,
  and a toast that fires for non-events is one people stop reading. The
  comparison happens in the browser, because only it remembers what was
  running before the restart - the server that knew has been replaced.

- [Feature] **`--fast` on the deploy script warns for 30 seconds instead of
  ten minutes**, for a hotfix where the thing being fixed is worse than the
  interruption. The banner opens straight on its red tier, since there is no
  gentle phase to escalate from in half a minute.

  A flag rather than a smaller default: ten minutes is the right answer
  during a live tournament, and the short one should have to be asked for
  each time rather than inherited from a config file edited months ago. The
  notice endpoint accepts `seconds` as well as `minutes` now, floored at ten
  - a countdown nobody can finish reading is a flicker, not a warning.

- [Feature] **A deploy now warns everyone with a page open, before the
  server restarts.** The deploy script announces the restart, waits, and
  only then restarts; every connected page shows a banner that counts down
  and escalates in three steps: "we will be away for about 30 seconds,
  results save as you enter them, and you stay logged in", then at two
  minutes "good moment to finish anything you are halfway through",
  then red at thirty seconds with "go and grab a coffee, we will be back in
  about 30 seconds".

  The countdown runs in the browser from a single timestamp, so this costs
  one message per page rather than one per second per socket. Someone who
  opens a page halfway through the countdown still sees it, because the
  deadline is held server-side and read on mount rather than only
  broadcast - that person is the whole point of the feature.

  The banner also says how long the outage lasts (about 30 seconds), that
  the page reconnects by itself, and that you stay logged in - the three
  things somebody actually wants to know when a bar appears telling them
  the server is going away.

  It deliberately says neither of the two obvious things, because both are
  false. **You are not logged out** - the deploy reuses `SECRET_KEY_BASE`,
  so sessions survive. And **results are not lost**: they write straight
  through as you enter them, so they are already saved. What a reconnect
  actually costs is server-side state rebuilt on mount - an open dialog, a
  half-filled registration form, a settings page with unsaved edits - and
  that is what it names. A banner that overstates its case is one people
  learn to ignore.

  Off unless `DEPLOY_NOTICE_TOKEN` is set: the endpoint fails closed, so an
  unset variable means no banner rather than an open route.

- [Fix] **Hovering a player at the bottom of the bracket map cut the
  popover off.** The chart clips vertically on purpose (letting it overflow
  makes the mouse wheel scroll the graph instead of the page), so the
  canvas grows while a popover is open to give it room. That reserve was
  measured against a typical popover - and the tallest one belongs to
  precisely the player most likely to be at the bottom of the chart.

  A pairing-allocated bye goes to the LOWEST score group, and that player's
  popover carries two rows an ordinary one does not: the repeat-bye warning
  and the bye-detail footer. Deepest dot, tallest box, reserve sized for
  neither - about 52px of it was cut off below the graph, which is why it
  only ever happened on players with the fewest points.

  The reserve now covers the tallest popover rather than the average one.
  It costs nothing to be generous: the canvas only grows while a popover is
  actually open, so an over-estimate is a slightly larger transient grow,
  while an under-estimate silently clips content. There is a test that
  fails at the old value.

- [Fix] **The registration form's name matches are a dropdown now.** They
  rendered as a list underneath the form, so every keystroke reflowed the
  page and pushed the birth-year and federation fields down, out from under
  the cursor of anyone halfway through filling them in. The matches now
  hang under the field as an overlay - the same panel the arbiter-side FIDE
  lookup already used. Clicking away closes it and keeps what you typed,
  which matters for anyone not on the FIDE list, who never picks from it.

  The matches are real buttons rather than an ARIA listbox, on purpose:
  those roles promise arrow-key navigation, and a screen reader announcing
  a listbox whose arrows do nothing is worse than plain controls. Tab
  reaches them, Enter picks, and a live region says how many appeared,
  since a panel opening is otherwise silent.

- [Feature] **The registration form can be embedded in a club's own site**,
  like the public pairings and standings pages already could. Same
  `<iframe>`, same cookie-free socket.

  It was excluded under a blanket "no forms in a third-party frame" rule.
  That is the right default and was the wrong call here: clickjacking
  steals authority a victim already holds, and this form holds none - it
  needs a name, birth year and federation typed in, runs under an anonymous
  scope, and posts to this server rather than to whoever framed it, so it
  hands an embedding page nothing that fetching the URL would not.

  Nothing about who may enter has changed: `registration_open` is still
  checked twice, and entries are still rate-limited per IP.

- [Change] **"What the engine reported" moved to the foot of the rationale
  page.** It was sitting above the bracket map and the board-by-board
  cards, which are what an arbiter actually opens the page for. It is
  reference detail for the moment somebody queries one board, not something
  to read past every time; the intro now links down to it.

- [Feature] **The rationale now shows, board by board, what the pairing
  gave up - and shows the colour record that explains it.** One row per
  board: both seats with their assigned colour, each player's last six
  colours as a strip you can read at a glance, and a flag for anything
  sacrificed to pair the bracket at all ("colour preference denied",
  "upfloated again, having upfloated last round"). A board that gave up
  nothing says so, dimmed - checked and fine is information too.

  This replaces a first attempt that was, frankly, unusable: it printed
  every criterion that scored on every board, around 200 tags for a
  40-player round, and - worse - it had the polarity backwards. These
  criteria are phrased so that HIGHER is better, because the engine
  maximises them. A board scoring 1 on "colour preference" is the board
  where the preference was *honoured*. The board an arbiter is asked about
  scores 0, and zeros were exactly what the old view filtered out, so the
  one fact worth having was rendered as nothing at all.

  Six criteria can be read as a verdict about a single board (the four
  colour ones, and the two repeat-upfloat ones). The rest deliberately are
  not shown per board: C7, C8 and C19-C21 are score-scale magnitudes used
  to rank candidates, and C14/C16 REWARD pairing a recent downfloater
  rather than penalising anything, so a zero there is not a compromise and
  must never be drawn as one. Float boards are exempt entirely - those
  criteria are gated on the pair being inside the bracket, so a float
  scores zero on all six by construction, and reading that as sacrifice
  would paint every floating board as a disaster.

  The full ladder is still there, one disclosure away, with the bracket
  totals. The boards still sum to those totals exactly, float boards
  included, and a test asserts it because the page says so.

- [Change] **The Ainalrami dependency is pinned to a version tag rather
  than a bare commit.** The pin had sat 79 commits and four days stale
  without anyone noticing, because one commit hash looks exactly as current
  as another - there is nothing in a SHA to look old. `v0.10.0` against a
  newer upstream is legible at a glance, in a diff and in review.
  `mix.lock` still records the exact resolved commit, so the pin is no less
  precise than before, only readable.

- [Feature] **The pairing rationale now quotes the engine instead of
  inferring it - for Ainalrami rounds.** That page has always
  RECONSTRUCTED its brackets from a round's inputs and outputs, because
  JaVaFo hands back nothing but pairs and its reasoning cannot be
  extracted. Ainalrami can report its own working, so a round it pairs now
  stores that account on the round itself, at the moment it is paired.

  A new **"What the engine reported"** panel shows, per score bracket: who
  was moved down into it, who floated onward, the pairs it kept, and the
  **FIDE C.04.3 criteria that actually scored**, by name and value -
  "C6 pairs in bracket", "C12 colour preference" and the rest. Criteria
  that scored zero are not listed, because they did not come into the
  decision. Nothing in the app could show any of this before.

  It is stored rather than recomputed on demand for a reason: a round can
  be edited by hand after the engine paired it, and re-deriving the
  reasoning afterwards would explain a pairing the engine never produced.
  If boards are swapped or substituted later, the panel says so plainly
  rather than quietly presenting a record that no longer matches the
  boards.

  JaVaFo rounds, and every round paired before this release, keep the
  reconstruction exactly as before, and the page still says so.

- [Fix] **The app still said "JaVaFo" in places where Ainalrami had done
  the pairing.** The rationale page titled every Swiss round "Swiss (FIDE
  Dutch / JaVaFo)" whichever engine ran, and - the one that actually
  matters - the **IT3 report's B22 "Program used" was hardcoded to
  "OpenPairings (With JaVaFo)"**. That is a statement to FIDE about which
  program produced the pairings, so it was filing something untrue for any
  tournament paired by Ainalrami, and for round robin and Keizer events,
  which consult no Swiss engine at all. B22 now names the engine that
  actually paired, and reads plain "OpenPairings" where no external engine
  was involved. It is still hand-overridable, as before.

  The engine name now comes from one function on the tournament rather than
  being spelled out on each page, because this is the second time these
  labels have drifted apart.

  Remaining mentions of JaVaFo are the accurate ones: it is still the
  default engine, still credited in the README and licence notes, and the
  hints that described "XXP" as a JaVaFo rule now call it a TRF rule, which
  is what it is - both engines read it.

- [Change] **Every em dash in the codebase is gone**, in comments, UI copy,
  docs and this changelog alike - 4,261 of them, plus 19 en dashes,
  replaced with the plain hyphen the code already used elsewhere. No
  wording changed, so nothing can have shifted meaning.

- [Change] **This changelog's tags are labels now, not emoji.** A sparkle
  and a bug read as decoration and rendered at a different size in every
  theme font. They are coloured pills outlined in their own colour, which
  stays legible in both themes. The markdown source writes them as plain
  `[Fix]` so the file still reads on GitHub.

- [Change] **Settings → Options saves per subject instead of all at once.**
  The page was one long form with a single "Save settings" button beneath
  everything, so changing the pairing system at the top meant scrolling
  past the engine notes, the rate of play and the public-pairings card to
  commit it - and the "Saved." that came back sat at the bottom, telling
  you nothing about which of those settings had just been written.

  It is now three: **Pairing**, **Tournament type & rate of play**, and
  **Public pairings**, each with its own Save and its own confirmation
  beside that button. Saving one leaves the others untouched, including
  any edits left unsaved in them. Forbidden pairings and club/federation
  exclusions already worked this way and are unchanged.

- [Fix] **Two lines on that screen still said Ainalrami was not allowed for a
  FIDE-rated event.** They survived the change that permitted it and
  directly contradicted the warning printed a few lines below them. Both
  now say JaVaFo is the default and the safe choice, which is what is
  actually true.

- [Change] **The landing page leads with Ainalrami now, and no longer names
  JaVaFo.** The hero read "Swiss pairings via JaVaFo" and the feature list
  offered "JaVaFo Dutch, or Ainalrami in beta" - advertising a third-party
  dependency as the headline capability, and the in-house engine as a
  hedge. Ainalrami gets its own line: our own Swiss engine, built in
  Elixir. JaVaFo is still the default engine and is still credited where
  the credit is owed - in the README, the licence notes and the
  cross-program-agreement documentation.

## [0.15.1] - 2026-08-21

### Changed

- [Change] **Choosing the Ainalrami engine now asks first, and the
  description finally tells the truth about it.** The old copy said a
  handful of known disagreements remained and that forbidden pairings,
  club/federation exclusions and acceleration were unimplemented. None of
  that had been true for some time - the most recent measurement against
  bbpPairings found **zero disagreements** across ~488 million pairings,
  and all three features are supported.

  Understating an engine misleads an arbiter exactly as badly as
  overselling one, so the wording now says what it is: experimental
  meaning **not FIDE-endorsed**, which is a paperwork status rather than a
  measured quality one. Switching to it opens a confirmation dialog
  explaining that; switching back to JaVaFo needs no ceremony.

- [Change] **Ainalrami may now be used on a FIDE-homologated tournament.** It
  was refused outright before. That refusal asserted a quality judgement
  the measurements do not support: the engine agrees with bbpPairings
  across ~488 million pairings, and the one article where it differs from
  JaVaFo is 5.2.5, where it follows the current handbook text and JaVaFo
  carries pre-2026 behaviour.

  What remains true is the paperwork: FIDE endorses **engines**, not
  pairings, so a rated round paired by Ainalrami was not produced by the
  engine the endorsement names. That is now stated rather than enforced -
  the setting carries the warning, and confirming the switch on a
  homologated tournament shows it a second time. The default is still
  JaVaFo, and nothing changes for a tournament that leaves it alone.

- [Fix] **The Pair button named the wrong engine.** A tournament using
  Ainalrami still read "Pair round 5 (JaVaFo)", and the pairing sheet
  described pairings JaVaFo had not produced - the one place the engine
  choice became invisible after making it.
- [Change] **SWAR 3-2-1 tournaments are refused on import for now**, with an
  explanation rather than a silent failure. Their scoring works
  differently - a presence point for turning up, on top of the result -
  and while that part is now understood and implemented, what a BYE is
  worth under the scheme is still unresolved. Importing anyway would
  produce a standings table that looks right and is wrong, which is worse
  than not importing. Every other SWAR tournament type is unaffected.

### Fixed

- [Fix] **FA1 and IA1 arbiter norm forms had two values in the wrong
  boxes.** FIDE revised those templates and the bottom block moved: the
  old "Recommendation: (please tick…)" section was replaced by a
  confirmation-and-signature block. Our field mapping already matched the
  NEW layout, but the templates shipped in the app were the OLD ones - so
  the tournament federation and the chief arbiter's date were written into
  the recommendation rows instead of beside "Federation" and "Date".

  Templates updated, and verified by filling a form and reading each value
  back beside its own label rather than by trusting the cell numbers.

  IT3 was unaffected - its layout is unchanged; the revision only adds a
  "Pairing System" label above a value that was already there.
- [Fix] **SWAR 3-2-1 tournaments were scored 2-1-0.** The Belgian club
  scheme is Win 2 / Draw 1 / Loss 0 plus a **presence point** for turning
  up - which is what makes it 3-2-1. That presence point was only ever
  applied to byes, never to a played game, so every played round came out
  one point short.

  It is not a uniform shift: presence is paid per round ATTENDED, so a
  player who misses rounds falls one point further behind for each one,
  and the ORDER of the standings changed too, not just the totals.

  Found by reading SWAR's own source rather than by a bug report:
  `GetPresentPtsUntilRound` keeps presence in a separate accumulator and
  the ranking adds `Points + ExtraPts + SpecialPts`. A forfeit pays the
  winner only - the player who did not turn up does not collect a point
  for turning up - and a double forfeit pays neither.

  Only affects tournaments imported from a SWAR 3-2-1 file. Every other
  tournament carries no presence value and is untouched.
- [Fix] **"Team tournament" no longer looks like it does something it
  doesn't.** Ticking it sets the FIDE classification on the report and
  nothing else - pairing has never branched on team type, so players are
  paired individually either way. Unlabelled, that was a silent trap: the
  round it produces looks like a perfectly good pairing, so there is
  nothing to notice until someone checks the boards against the teams. The
  box now says "Reporting only" and spells out that team pairing, team
  standings and team tie-breaks are not built yet.

## [0.15.0] - 2026-08-20

The version in `mix.exs` had run ahead of this file: 0.14.32, 0.14.33 and
0.14.34 were tagged in code but never cut a section here, so everything
since 0.14.31 had been accumulating under Unreleased. This release closes
that gap - it covers those three versions as well as the work below, which
is why it opens a new minor line rather than continuing 0.14.x.

### Fixed

- [Fix] **Searching the local KBSB database returned nothing, always.** The
  search box carried its `phx-change` on a bare `<input>` with no
  wrapping form, so LiveView sent `%{"value" => …}` where the handler
  expected `%{"q" => …}`; nothing matched, the LiveView crashed and
  silently reconnected, and the box looked inert. It had been broken from
  the start and nobody could see it, because the KBSB database was never
  populated until the data-platform sync arrived.

  The test that covered this synthesised the event directly, which proved
  the handler worked but not that the page could reach it. It now drives
  the real form element.

- [Fix] **Registering a player now fills in the club number, not just the club
  name.** Both autofill paths - picking from the FIDE list, and typing a
  National id - set the name only, and the add dialog had no field to
  submit the number with. A player registered that way then showed up
  immediately as a pending club change, because "Update clubs" treats
  name and number as a pair.

- [Fix] **An accented player name no longer corrupts the FIDE TRF export.**
  TRF16 addresses its fields by column, and every reader outside this
  codebase - FIDE's rating server, SWAR, Swiss-Manager - counts one
  column as one byte. Names were padded by character, so a single
  accented letter made the row one byte too long and shifted every field
  after the name. For a row like `Hendricks, Björn` that meant the FIDE
  id `1001` was read as `100` - a *different player* - the rating `2400`
  as `240`, and the entire round history as blank.

  Exported names are now folded to ASCII (`é` → `e`, `ß` → `ss`), which
  is what FIDE itself does, so characters and bytes are the same thing
  again. Non-Latin scripts with no one-to-one Latin form become `?`
  rather than being dropped silently, so an arbiter can see and fix them
  before submitting.

  Pairing was never affected: JaVaFo decodes UTF-8 and produced
  byte-identical pairings either way, verified against both JaVaFo and
  bbpPairings. The pairing input is deliberately left untouched.

### Changed

- [Change] **"Refresh ratings" no longer touches national ratings.** It refreshes
  the FIDE rating and title, and nothing else. A national rating is an
  import/manual-entry artifact - SWAR's own ELO lands there when you
  import a `.swar` file, the KBSB search fills it in when you register a
  player off the list, and you can type it - so a bulk button quietly
  rewriting it afterwards made OpenPairings look like it maintains a live
  national-rating system, which it does not. National ratings still work
  exactly as before as the pairing fallback when a player has no FIDE
  rating. The part of the KBSB list that *is* worth refreshing in bulk is
  the club, which has its own "Update clubs" button.

### Removed

- [Removed] **The manual KBSB rating-list file upload.** The Belgian roster now
  comes from the data platform, which has the club names the file never
  carried and needs nobody to remember to do it. The rating-lists page
  offers the sync and nothing else; with no API configured it names the
  settings to set rather than falling back to a file picker.

- [Removed] **The "Pair by: FIDE rating / National rating" setting**, which never
  did anything. It was stored, validated and exported, but no code ever
  read it - pairing order comes from `Player.rating/1`, which is
  unconditionally FIDE-rating-first with the national rating as a
  fallback and never consulted the setting. Choosing "National rating"
  changed no pairing, which is worse than not offering the choice.
  National ratings still work exactly as they did as that fallback.

### Added

- [Feature] **"Sync from data platform" on the rating-lists page.** The Belgian
  roster can now be pulled straight from the KBSB data platform's
  Odoo-synced database instead of hunting down a rating-list file and
  uploading it by hand - including each player's club name and number,
  which is what "Update clubs" needs and which no earlier source
  provided. Appears once `KBSB_API_URL` and `KBSB_API_KEY` are set on the
  server; without them the page is unchanged and the file upload remains
  the only option.

  It fills the same local copy the file upload always filled, so nothing
  downstream changes: club refresh, registration autofill and name
  matching all keep reading it locally and keep working with the internet
  down, which is the point - rounds get paired in playing halls.

  Deceased members are now stored and handled explicitly: an exact
  National-id or FIDE-id lookup still resolves one, but a *name* match
  never will, so a living player cannot inherit a dead namesake's club.


- [Feature] **The Paid column is editable straight from the players table** - click
  or right-click a player's Paid cell for "Paid" / "Not paid" / "Gratis",
  the same gesture the Pr. column already had for Present/Absent.
  Right-clicking the Paid column *header* applies one of the three to
  every player at once, matching Pr.'s "All Absent" / "All Present". The
  fee status was previously reachable only by opening a player for
  editing, which is several clicks each on a registration desk.

  Paid is not one of the columns shown by default - switch it on from the
  column picker first, as before.

- [Feature] **"Update clubs" also matches on name + birth year.** The two id
  lookups (National id, then FIDE id) are exact but only help players
  registered off one of the databases. A player typed in at the desk with
  neither id - the common case at a club event - now resolves by name,
  with accents folded so "Bjorn" finds "Björn".

  It refuses to guess: a name that matches two people is only resolved if
  the birth year singles out exactly one, and a lone namesake whose birth
  year disagrees is treated as a different person. The preview gained a
  "Matched by" column so you can see which proposals rest on a name
  rather than an id.

- **"Update clubs" on the Players page.** Beside "Refresh ratings", and
  the same gesture: it compares every registered player against the
  locally-synced KBSB list and shows a preview of the club changes before
  anything is written. Matches by National id, falling back to FIDE id
  when no matricule is on file, and never clears a club the list has no
  entry for - an arbiter who typed a club for an unaffiliated guest keeps
  it. Club name and club number always move together.

- [Feature] **Embedded pages default to the light theme.** A frame sits inside
  somebody else's page, which is overwhelmingly light, so following the
  visitor's OS dark-mode setting dropped a dark slab into the middle of a
  white club site. Embedded pages now default to light regardless of the
  OS, and stay light when it flips at sunset. Only the DEFAULT changes --
  picking a theme from the switch still works inside the frame, still
  wins, and still persists.

- [Feature] **Embedded public pages size themselves, and no longer reload-loop.**
  Two follow-ups to the embedding support below, both found by actually
  putting it on a club site.

  The embedded page now posts its height to the host page whenever the
  content changes, so the iframe can be sized to fit rather than guessing a
  pixel value - a guess leaves the table scrolling in a small box or a slab
  of empty space under a short tournament. `docs/public-pages.md` has the
  snippet to receive it.

  And the embeddable pages now use a websocket that does not require the
  session cookie. A `SameSite=Lax` cookie is deliberately not sent to a
  cross-site iframe, so the normal socket connected with no session,
  LiveView rejected it, and the client retried forever - the page appeared
  to reload constantly on scroll and hover. Fixed with a second,
  cookie-free socket for those two pages, rather than by loosening the
  cookie for the entire app.

- [Feature] **The public pairing and standings pages can be embedded in another
  site.** They previously sent `frame-ancestors 'none'` like every other
  page, so a club website putting one in an `<iframe>` got a blank frame
  and a console error. Those two now allow it:

  ```html
  <iframe src="https://your-host/p/SLUG/pairings"
          style="width:100%;height:600px;border:0"></iframe>
  ```

  Nothing else does - not the public registration form, the arbiter
  tools, the mobile result entry, or any logged-in page, where being
  frameable is a clickjacking risk rather than a feature. Set
  `PUBLIC_FRAME_ANCESTORS` to a space-separated origin list to allow only
  particular sites, or to `'none'` to switch embedding off entirely. See
  `docs/public-pages.md`.

- [Feature] **A second Swiss pairing engine: Ainalrami, opt-in and beta** - the
  "multi-engine" item the login page has been advertising as coming soon.
  Settings → Options gains a "Swiss engine" control alongside the pairing
  system: **JaVaFo** stays the default and is unchanged, and
  [Ainalrami](https://github.com/AuroraRyunix/Ainalrami) - a from-scratch
  Dutch-system engine in pure Elixir, pinned as a `github:` dependency at
  an exact commit - is available as an alternative for club and non-rated
  events. It runs inside this app's own BEAM: no JVM, no jar, nothing to
  install alongside a release or a Burrito binary, which also means its
  tests are the first Swiss pairing tests in this suite that run on a bare
  checkout instead of being `@tag :javafo`-excluded.

  Both engines are handed the **byte-identical TRF**
  `Pairing.javafo_input/4` already built - the engine choice only decides
  what turns those bytes into pairs, and everything downstream
  (`create_round/5`, board freezing, absentee byes, standings) is shared and
  cannot tell which one answered. That keeps the two directly comparable on
  real tournament data rather than only on synthetic input, which is the
  whole point of having a second implementation.

  Three guards, all in the data layer rather than the UI, because "the UI
  hides the control" has never been enforcement here:
  - **Never on a FIDE-homologated tournament.** OpenPairings' entire FIDE
    story is FE1's *"Internal engine: NO - thru JaVaFo"*, exactly as Vega,
    Swiss Manager and TournamentService answer it, and JaVaFo's own
    endorsement is what then covers pairing legality. The changeset refuses
    Ainalrami on a homologated tournament **and** refuses ticking
    "FIDE-homologated" on a tournament already running Ainalrami - the
    reverse direction matters just as much, and checking only the changed
    field would have let it through.
  - **Locked after round 1**, via `Tournaments.locked_fields/1` (so
    `update_tournament/2` refuses it, not just the disabled select), same
    rule and same reason as `pairing_system` one level up: two independent
    Dutch implementations won't always agree, and swapping mid-event hands
    the new engine a history it didn't produce.
  - **Refuses rather than silently ignores anything it can't do.** Ainalrami
    reads every TRF extension this app emits - `XXR` (rounds), `XXP`
    (forbidden pairings and club/federation exclusions) and `XXA` (Baku
    acceleration) - so forbidden pairings and accelerated events work on
    either engine. That's new: Ainalrami's parser used to discard everything
    but `XXR`, which for this input is the worst way to fail, because an
    engine that ignores an `XXP` line still returns a complete, perfectly
    legal-looking round that just happens to seat two players who must never
    meet, and nothing downstream can tell. Integrating it here is what
    surfaced that; both extensions were implemented upstream rather than
    worked around, and the round is still refused outright - nothing
    written, reason named - if the generated TRF ever carries an extension
    the engine doesn't know. The check reads the generated file rather than
    the tournament's settings, so a future extension is caught by default
    instead of being quietly ignored.

    A late catch on that last point, found by a source sweep before any of
    this shipped: the integration parsed the `XXP` lines and then dropped
    them. `Ainalrami.Pairing.pair_next_round/2` takes forbidden pairs as an
    OPTION rather than reading them off the parsed file, and the call passed
    only the round count - so every explicit forbidden pairing and every
    club/federation exclusion was silently ignored, which is precisely the
    failure the guard above exists to prevent. The test that was supposed to
    cover it could not fail: it asserted that ranks 1 and 2 were not paired
    in round 1 of a six-player field, where the Dutch system pairs top half
    against bottom half and those two could never have met anyway. Both are
    fixed, and the replacement is four players - where the forbidden pair IS
    the natural pairing - with a control test pinning that.

  Round robin and Keizer are completely unaffected - they compute their own
  pairings and never consult the setting. See `docs/pairing-systems.md`.

- [Feature] **"Save a restore point" on the History page** - restore points could only
  ever be created as a side effect of something else. `Snapshots.capture/4`
  was called from exactly four handlers, all of them in PairingsLive: pairing
  a round, unpairing one, pairing a whole round-robin schedule, and importing
  results from a CSV. Run a tournament the way small clubs actually do -
  register players by hand, tune the settings, type results in one board at a
  time, never touch an import - and the app took *no* snapshots at all. The
  History page then had nothing to offer a "Go back to here" button on, so
  the restore machinery that has been shipped for a while (branch tree,
  "Switch to this branch", the type-to-confirm modal) was invisible and the
  whole page read as a list you could only look at. That was the actual
  complaint behind "History is just a read-only thing".

  So: a button that takes one on demand, with an optional short label
  ("End of day 1", "before the appeal") that becomes the point's caption on
  the timeline. It goes through the same `Snapshots.capture/4` as the
  automatic ones - same payload, same retention, same branch tree, same
  restore path - under its own `snapshot.manual` action code so hand-saved
  points show a "saved by hand" badge and read apart from the ones the app
  took to protect an irreversible action. It's a write like any other:
  refused on an archived tournament, and logged to the audit trail.

  The empty state is honest now too. A tournament with no restore points
  yet says so, explains that hand-editing doesn't take one, and points at
  the button - instead of silently rendering a timeline with no actions on
  it, which is what made this look broken rather than merely unused.

  The automatic triggers are deliberately unchanged: these are full
  tournament copies, so adding more of them shifts storage behaviour for
  every existing tournament and deserves its own decision (candidates noted
  in `TODO.md`).

- [Feature] **"Assign categories" now shows a dry-run preview before it writes
  anything** - clicking the button used to reassign every player's category
  instantly, no warning. It now computes the same rule decisions
  (`Tournaments.preview_auto_assign_categories/1`, the single source of
  truth the real write path now reuses too, so preview and apply can never
  drift apart) and shows a Player/From/To diff in a confirm modal, filtered
  to only the players who'd actually move. Cancel discards it with zero
  side effects; confirming re-checks current DB state rather than trusting
  the staged preview verbatim, so a concurrent edit mid-modal can't write
  stale decisions. A no-op roster (nothing would change) says so plainly
  instead of opening an empty diff.
- [Feature] **"Substitute player" now shows both halves of the move, with real in/out
  arrows** - previously the confirm modal only showed the board seat
  changing, with no visual for where the outgoing player went or the
  incoming player came from. A new "Not playing list" row appears alongside
  the board row (the outgoing seated player arriving there, the incoming
  pool player leaving it), and the existing `.SwapArrows` journey-arrow
  mechanism - which matches identical names appearing once on the "before"
  side and once anywhere on the "after" side, across the whole modal, not
  just within one row - draws the two arrows automatically from that shape
  alone. No changes needed to the arrow-drawing code itself. This also
  fixes a real bug the old single-row layout had: the *unchanged* seat (say,
  White, when Black was the one substituted) still showed the same name on
  both its own before/after sides, so the old name-matcher drew a spurious
  arrow between White's two seats instead of showing anything for the
  actual substitution - misleading, since it looked like White had somehow
  moved. That seat still gets its own short "stayed put" arrow today (the
  same thing an unmoved partner in a two-board swap already got), but it's
  no longer the only, unexplained arrow on screen.

- [Feature] **Hide a fully-vacated board, or delete the round's actual last one** - two
  ways to clean up a pairing row that's left over from marking both players
  on it absent, without ever risking the 0.14.6 board-renumbering bug class
  again. "Hide" (right-click the empty board, or from the new "Hidden
  boards" panel) is a display-only, fully reversible toggle - it's skipped
  by PairingsLive, LiveRoundLive, PublicPairingsLive and print docs, but the
  row, its frozen `display_board`, audit history and TRF/export data are
  completely untouched, and never interacts with `PairingDisplay`'s freeze
  mechanism at all. "Delete" is a real, permanent removal, but is only ever
  offered - and only ever accepted server-side - on the round's own current
  highest real board number, since deleting the trailing row is the one
  deletion that can never require renumbering anything after it. It goes
  through the same confirm-modal pattern as every other hand-edit gesture on
  this page.

### Changed

- [Change] **The login/registration hero no longer lists "multi-engine" as coming
  soon** - it ships (above), so the Swiss line now names both engines and
  the coming-soon row is down to TRF26 alone.
- [Change] **Result cards redesigned** - each player's name, rating/starting-№, and
  signature line used to be crammed onto one small row alongside a "Sign
  ___" blank; the name is now on its own, larger row, with the signature on
  a separate row below it instead of competing for space on the same line.
  The result row (1-0 / ½-½ / 0-1) is now genuinely centred - the trailing
  "other: ...." option previously used `margin-left: auto` to push itself
  right, which dragged the three main results left of true centre as a side
  effect.
- [Change] **Removed the "Print player cards" button** from the Players page - kept
  causing confusion with "Print place cards" right next to it and wasn't
  something arbiters actually used; the print route itself is untouched.
- [Change] **The swap-confirm modal (swap/vacate/fill/substitute/pair) is wider**
  (720px instead of 560px, the same `.pe-modal-wide` variant the categories
  preview above already uses) so names have more room before truncating.
- [Change] **Removed the "⇄ Board N" chip** from a cross-board swap's changed seat -
  confusing, and redundant with the journey arrows the modal already draws
  to show where a moved player came from. Also removed its now-fully-dead
  plumbing (`related_board`, threaded through three functions purely to
  feed this one chip) and the `flex-wrap` machinery that existed only to
  give it its own line.

### Changed

- [Change] **The History page is the restore-point tree now, not a merged event feed**
  - it used to interleave audit rows and restore points as peers, which broke
  down in three ways once it was actually used. Saving a point by hand wrote
  both a snapshot and an audit row, so it showed up twice. Audit rows carry no
  branch information, so after switching to a branch a result change still
  rendered at the top of the trunk, which is not where the tournament was. And
  the page carried filters for "players", "settings" and so on - questions
  about changes, which is the Audit trail's subject, not this page's.

  So the points are the timeline, and everything that changed between two of
  them is folded under the earlier one, collapsed until you open it. A branch
  can be collapsed to a single line. The kind filters are gone; the Audit
  trail keeps the full searchable log, and this page links to it. Day headings
  went too - one collapsed branch can stand in for points spanning several
  days, which headings couldn't survive - so each point carries its own date.

  The save box got a real label and an example instead of the placeholder
  "What is this point?", which read as a search field. And having exactly one
  restore point no longer looks broken: it is the point the tournament is
  already on, so it offers no "go back", and the page now says why instead of
  showing a save button and nothing else.

### Fixed

- [Fix] **Settings now says where the chief arbiter lives** - the Officials
  fields sit on the Norms page, because that is what builds the IT3/FA1/IA1
  forms from them, but an arbiter looking for "chief arbiter" looks under
  **Settings**, and Settings said nothing at all. Reported by someone who
  could not find the field while holding a direct link to it. Settings →
  Tournament grew an "Officials" card that links to Norms and shows the
  current chief arbiter, or says it is not set and that this does not block
  pairing (it is a recommended field, not a required one). It edits
  nothing - moving the fields back is a separate question about what the
  Norms page is then for.

- [Fix] **The accelerated TRF this app exports was malformed, and only JaVaFo
  would read it** - `XXA` lines carry Baku acceleration's virtual points,
  and the writer padded each player's starting rank to five columns instead
  of four. That put a single-digit rank in column 9 and left columns 5-8
  blank, shifting every value on the line one place right of where the
  format puts it. JaVaFo accepts the malformed form, which is exactly why
  this survived: JaVaFo has been the only thing that ever read these files.
  Any stricter reader rejects the line outright, so an accelerated
  tournament exported for a rating officer, an archive, or a second engine
  was silently unusable. Confirmed against the real bbpPairings binary,
  which reads the rank from columns 5-8 and each value four wide on a
  five-column stride, and proven by generating one accelerated TRF that
  differs only in this layout: the old form is refused as an invalid line,
  the new one parses - and JaVaFo pairs both identically, so no existing
  pairing changes.

- [Fix] **The bracket map's variable dead space, under the graph** - on
  "Pre-round score brackets" there was sometimes a sizeable empty gap
  between the graph and the minimap strip below it, and sometimes none.
  Reported as intermittent; it was entirely deterministic. The canvas's
  inline `min-height` permanently reserved the room a *hover* popover needs
  below the lowest dot that opens downward, and because the above/below flip
  deliberately tests against the much taller *pinned* popover's room, on
  every round past the first essentially every dot opens downward - so the
  reservation cleared the graph's own floor by about 110px on most rounds
  and by nothing on the few whose bracket happened to be tall enough. Which
  round you looked at decided whether you saw a gap.

  Now both reservations are deferred, the same way the pinned one already
  was: the canvas rests at exactly the graph's height and grows via
  `:has()` only while a wrap is actually hovered, focused or pinned
  (`--pe-hover-min` / `--pe-pinned-min`). The popover can cover what sits
  under the chart while it's open, which is the deliberate trade - a
  tooltip overlapping its surroundings for as long as you hover is better
  than a permanent empty band under every chart. Nothing about the flip
  itself changed, so a pinned popover still always opens onto the side it
  reserved room on, and neither popover is clipped by the strip's
  `overflow-y: hidden`.

- [Fix] **Something covering the corner of the "Everything" button on the History
  page** - the timeline's day headings paint an opaque 10px-wide mask over
  the rail so the date sits in a clean gap, and that mask deliberately
  overhangs 6px above the label to cover the rail's own inset. Above the
  *first* heading there is no rail to cover - the rail lives inside the
  `<ul>` below it - so the overhang only reached up into the filter row,
  which sits directly above with no margin between them, and landed exactly
  on the bottom-left corner of the first filter button. The first day group
  is now marked server-side (`.tl-first-day`) and drops the upward overhang;
  later headings, which genuinely do have rail above them, are unchanged.
  The marker has to come from the server because each heading is the first
  child of its own day group, so `.tl-day:first-child` matches every one of
  them rather than the first.

- [Fix] **Three real "vacated seat" crashes in the "Explain this round" page and
  its underlying analysis, found and fixed over one afternoon as each one
  surfaced the next.** `Tournaments.vacate_seat/3` can empty EITHER colour's
  seat (not just the one a bye already leaves empty), which turned out to
  be a state nothing downstream actually expected:
  1. `PairingRationale.board_context/7`'s rematch check assumed White is
     always present whenever the board isn't a formal bye - crashed with
     `key :id not found in: nil` reading `white.id` when only Black
     remained seated.
  2. A bye's own recipient can be vacated too (a bye pairing already has
     Black's seat empty; vacating White leaves nobody at all, but `is_bye`
     - which only checks Black's seat - still reports the board as a bye).
     `annotate_bye/3` then crashed reading the vanished recipient's name.
     Fixed alongside a real, quieter second bug in the same function: an
     empty "ghost" bye board sorting before a real one would have silently
     reported the empty ghost as the round's allocated bye instead of the
     actual recipient.
  3. Once the analysis itself stopped crashing, `PairingExplainLive`'s own
     rendering turned out to make the identical assumption in three
     separate places - the score-bracket graph, the "Board by board" card
     list, and the "Pairing numbers" table - each reading a player's name
     unconditionally with no guard for a missing seat. Boards missing a
     side are now excluded from the score-bracket graph entirely (there's
     no player to plot), and the other two now show a plain "Seat vacant"
     note instead of crashing.
- [Fix] **The round-dates setup checklist could stay stuck on "missing" forever**
  even after every date was filled in - `round_dates` was only padded or
  truncated to match `rounds_count` on the Dates settings page's own save,
  not wherever else `rounds_count` can change (e.g. round-robin silently
  correcting it to match the real Berger schedule on freeze). Moved into
  the shared tournament changeset so it happens on every save, from any
  page.
- [Fix] **The "Delay (minutes)" field showed even when "Publish each round" was
  set to "Immediately"** - it now only appears for "After a delay", live,
  as the dropdown changes.
- [Fix] **A print doc could show a stale fixed-board note after a round was
  already paired and frozen** - `fixed_board_note/1` (score sheets, result
  cards) read `Player.fixed_board` live, bypassing the freeze mechanism
  that already exists for exactly this (see the 0.14.6-class fix below) and
  contradicting its own module doc's claim to be the *only* such reader. A
  mid-round edit to a player's fixed board could make a reprinted document
  disagree with the already-frozen main pairing sheet for the same board.
  Now reads the pairing's own frozen data instead.
- [Fix] **The swap-confirm modal's before/after cards could end up different
  heights**, making the connecting journey arrows look crooked - caused by
  a long name wrapping onto a second line in one card but not its partner.
  Names no longer wrap (truncate with an ellipsis instead, full name still
  available on hover); cards now size to their own content instead of a
  forced equal split, so a short name's card isn't stretched to match a
  long one.
  - A related, more specific wrap bug survived that first fix: the W/B
    colour badge could end up alone on its own line, above the name, on
    any "Swap colours" confirm with two ordinary-length names - not just a
    pathological long one. Root cause: with `flex-wrap: wrap` on the seat
    row, the browser decides which line an item lands on using its
    *un-shrunk* preferred size, not its post-ellipsis size - so a name
    "too wide" to fit next to the badge got bumped to a new line before
    the shrinking/ellipsis logic ever got a chance to run.
  - "Pair these two" (pool-pair) could show a large, visibly empty gap
    between its two cards - a CSS Grid trap: the arrow column's `auto`
    track sizing doesn't mean "size to content" the way it does for a
    `width` property, it means "absorb the grid's leftover space" when
    nothing else claims it, and two narrow cards left a lot of it. Changed
    to `max-content`, which never grows past the arrow glyph itself.

### Fixed

- [Fix] **An archived tournament's Pairings page let you enter/change results** -
  the underlying write was always correctly refused
  (`Tournaments.ensure_writable/1`, in place since archiving shipped), but
  the result `<select>` had no `disabled` state tied to `archived_at`, and a
  refused write showed no error at all. Worse: because a refused write
  leaves every assign byte-identical to before, LiveView sends no patch for
  that board's `<select>` - so the browser's own "user just picked this"
  native state was left uncorrected, visually looking like the change had
  taken even though nothing was written. Fixed by disabling the select
  outright while archived, surfacing a clear "This tournament is archived"
  error on any write that's still refused, and forcing a patch on refusal
  (a small nonce threaded into the element) so the existing
  data-result-resync hook actually runs and snaps the value back. The
  right-click board-editing menu (swap/mark absent/award bye/fill seat/pool
  pair) now also refuses to open at all on an archived round, and CSV
  results import is hidden.
- [Fix] **Two more instances of the "crashes instead of showing an error" bug
  class found while fixing the above**: the Players page had its own
  broken local `error_text/1` (same shape as an earlier-fixed crash in
  Settings) that raised trying to read `.errors` off the bare atom
  `:archived` instead of a real changeset - editing, deleting, or bulk
  actioning a player on an archived tournament crashed the LiveView. CSV
  results import had the identical bug one level down, in
  `ResultsImport.write_all/2`. Both fixed; audited and fixed the same
  "write refused but the LiveView shows nothing" gap (no crash, just
  silence) across the Pairings, Players, Categories, Standings, and
  Tournament/Options settings pages too, so every one of them now shows a
  clear error instead of quietly no-oping.
- [Fix] **A production migration wrote `display_special` (the fixed-board freeze
  from the fix below) as the literal text `"true"`/`"false"` instead of the
  integer `0`/`1`** - `Repo.update_all` against the raw `"pairings"` table
  name has no `:boolean` type info to encode through, so SQLite stored the
  Elixir atoms' literal text. Every page that loaded a pairing then crashed
  with `cannot load "false" as type :boolean`, a full outage confirmed and
  fixed live in production (data repaired, migration source corrected so a
  fresh deploy can't repeat it).
- [Fix] **Only a tournament's owner could archive it - a co-arbiter it was shared
  with could not**, even though sharing otherwise grants "exactly like you"
  access. `archive_tournament`/`unarchive_tournament` now go through the
  same owner-or-accepted-collaborator check every other shared action uses;
  an archived shared tournament also now shows up in a collaborator's own
  Archived panel (marked "shared"), not just the owner's - previously it
  would have simply vanished from their dashboard the moment anyone
  archived it. Delete stays owner-only, same as the main list.
- [Fix] **Giving a player a fixed (accessible) board after their round was already
  paired silently renumbered every board after theirs** - `PairingDisplay`
  read `Player.fixed_board` live on every render, so an arbiter editing a
  player's fixed board mid-round (e.g. on the Players page) retroactively
  moved that player's pairing to the special/end-of-list group and closed the
  gap in the ordinary sequence, shifting every board number after it, while
  people were already seated. The special/ordinary classification and board
  label are now computed exactly once, at the moment a round is (re-)paired -
  ordinary pairing, round-robin, Keizer, or an import/restore - and frozen
  onto the pairing (`display_board`/`display_special`). Editing a player's
  fixed board no longer has any effect on an already-paired round; it only
  takes effect the next time that round is paired (a fresh round, or an
  explicit unpair-and-re-pair). The narrower survivor of the 0.14.6
  board-renumbering bug class.
- [Fix] **The top bar overflowed the page horizontally at laptop widths** (roughly
  769-1280px, i.e. most laptops with the window not maximised) - the auth
  cluster (FIDE/KBSB sync status, email, Settings, Log out, version) never
  shrank, so it pushed the whole page wider than the viewport. There were no
  responsive rules at all between the 1280px desktop layout and the 768px
  tablet one. Two new breakpoints now drop the sync strip, then the email and
  version, before anything is forced to wrap.
- [Fix] **The "Advanced" and "Settings" top-bar dropdowns, and the accent/theme
  pickers, were always laid out and hit-testable, not just when opened** -
  `.topbar-menu-panel`/`.accent-picker-panel`/`.theme-picker-panel` each set
  `display: flex` (or `grid`) unconditionally, relying entirely on
  `<details>`'s own native collapse to hide the closed panel. In Chromium
  that collapse uses `content-visibility: hidden`, which still reports the
  panel's full-size box for layout purposes while correctly skipping
  paint/hit-testing - so a closed dropdown was invisible and non-interactive,
  but its ~180px-wide box still counted toward the page's scrollable width.
  This was most of what was actually causing the top-bar overflow above (a
  closed multi-item "Settings" panel poking out past the viewport with no
  visible cause). All three panels are now `display: none` unless their
  `<details>` is `[open]`, which is also simply correct regardless of any one
  engine's collapse behaviour.
- [Fix] **Norms was missing from the "Advanced" sub-nav strip** - the top-bar
  dropdown menu listed four pages (Norms, History, Audit trail, Pairing
  rationale) but the strip rendered on each of those pages only showed three
  boxes, because `NormsLive` never rendered the shared sub-nav at all. It
  does now, and the sub-nav component covers all four consistently.
- [Fix] **Settings that decide the shape of already-paired rounds were locked only
  in the Settings LiveViews, not in the data layer** - `pairing_system`,
  `rr_cycles`, `rr_match_format`, `swiss_match_format`, `pair_by_category`
  and the "Pt ABSENT" trio (`abs_value`/`abs_jusque`/`abs_nbfois`) were
  disabled inputs plus a strip of the submitted params in
  `SettingsOptionsLive`/`SettingsScoringLive` - enforced nowhere else.
  Confirmed exploitable: calling `Tournaments.update_tournament/2` directly
  with `pairing_system: "keizer"` on a tournament with a paired Swiss round
  silently succeeded, reinterpreting every round already on the board under
  different pairing/scoring rules. `Tournaments.locked_fields/1` is now the
  single source of truth - `update_tournament/2` itself refuses a change to
  any locked field once round 1 is paired, and both Settings pages render
  their disabled state from the same function, so the two cannot drift apart
  again. This is the same shape of bug the archive guard (`ensure_writable/1`)
  exists to prevent, just for a different property - "the UI hides the
  button" is not enforcement.

### Added

- [Feature] **Archive a tournament** - a new frozen read-only state, separate from the
  Recycle bin. An archived tournament stays *fully readable*: its own pages,
  public link, prints and exports all keep working exactly as before. It just
  refuses every change until you unarchive it. Unlike the bin, nothing
  archived is ever purged automatically - it's "done with this, keep it
  forever", not "on its way out".

  Archived tournaments leave the main list and get their own **Archived**
  panel on the Tournaments page, with an amber `archived` badge, and every
  page inside one carries a persistent read-only banner.

  The read-only part is enforced in the context layer
  (`Tournaments.ensure_writable/1`, called by all ~30 write paths plus the
  pairing engines), not by hiding buttons - a stale open tab, a queued
  LiveView event or a direct script call are all refused too. `archived_at`
  is a dedicated column rather than a `status` value (status is derived and
  would be recomputed away) and is deliberately not cast by the ordinary
  changeset, so no settings save can archive or silently unarchive anything.

### Fixed

- [Fix] **`SettingsSupport.error_text/1` crashed the LiveView on any non-changeset
  error.** It called `changeset.errors` unconditionally, so a bare reason atom
  parsed as a remote call (`:archived.errors/0`) and took the whole page down.
  Found by the archive tests - a settings save on an archived tournament hit
  it immediately. Now handles changesets, atoms and strings.

## [0.14.31] - 2026-08-13

### Changed

- [Change] **Public pages are now off by default** for a new tournament, instead of
  on - player names, ratings and clubs no longer become reachable by
  anyone who finds the link until an arbiter deliberately turns it on
  (Settings → Tournament → Public pages), same "opt-in per event"
  reasoning self-registration already used.
- [Change] **Scoring moved to its own Settings tab** - points per win/draw/loss,
  the pairing-allocated bye value, and SWAR's "Pt ABSENT" genuine-absence
  rule used to live at the bottom of the Options page; they're on
  Settings → Scoring now, since "how many points" is a different concern
  from "how the tournament is paired" (Options).
- [Change] **Categories on/off moved onto the Categories page itself** - it used
  to be a checkbox buried in the Options form (labeled "Enable the
  Categories tab", even though the tab was already always shown). It's
  now a plain Turn on/Turn off button right on the Categories page,
  taking effect immediately - no more Save-then-navigate-over round
  trip. "Pair each category independently" moved there too, next to the
  switch it depends on, marked **(beta)**, and turning categories off
  now also turns this off in the same write (previously conflicted with
  the changeset's own validation if attempted directly).
- [Change] **Clearer genuine-absence field labels**, on the new Scoring page:
  "Points for a genuine absence (SWAR's 'Pt ABSENT')" → "Points awarded
  for a genuine absence", with a fuller explanation of what "genuine
  absence" actually means (a plain no-show, distinct from a requested
  bye or a forfeit) above the fields. "...pays through round
  (inclusive)" → "Last round this still applies to"; "...for up to this
  many absences (cumulative)" → "Cap: only a player's first N genuine
  absences pay" - both with longer, more concrete hints.
- [Change] **A prominent warning now accompanies "Treat a genuine absence as a
  voluntary unplayed round for tiebreaks"** - this option changes FIDE
  tiebreak results (Buchholz/Sonneborn-Berger), not just scoring, and
  FIDE's own C.07 has no such concept at all. The warning appears the
  instant the checkbox is ticked, before the page is even saved.

### Fixed

- [Fix] **The Save-settings button on the Tournament and Options pages sat
  crammed against whatever card came right after it** (Tiebreaks → Save
  → Public pages / Share-Team, and Options → Save → Forbidden pairings)
  - a bare `.actions` row only ever had margin above it, none below, so
  it visually ran into the next section. Now has proper spacing on both.

## [0.14.30] - 2026-08-13

### Added

- [Feature] **Public pairings can now be published on a delay instead of the
  instant they're paired** - a new "Publish each round" setting
  (Settings → Options → Public pairings) picks between four modes:
  *Immediately* (the old, still-default behavior), *Manually* (a round
  stays hidden from `/p/:slug/pairings` until you publish it by hand),
  *After a delay* (a fixed number of minutes after pairing), and *On
  the round's own date* (midnight UTC of that round's date on the
  Dates page). Whichever mode is active, the Pairings page also gets a
  standalone **Publish now / Unpublish** button and a public/not-public
  badge for the round you're viewing - a manual override that works
  regardless of mode, so an arbiter can always release a round early or
  pull it back, even under a timed or scheduled setting. Rounds can be
  published out of order (round 3 public while round 2 still isn't);
  the public page always shows exactly the round it was asked for, or
  a placeholder if that one isn't out yet.

## [0.14.29] - 2026-08-13

### Changed

- [Change] **Start/end date are no longer entered separately from round dates** -
  they used to be their own fields on the Tournament settings page,
  independent of the per-round dates on the Dates page (two places that
  could say different things about what's really one piece of
  information). They're derived now: the earliest and latest non-blank
  entry in `round_dates`, recomputed on every save regardless of which
  settings page triggered it. The Dates page shows the derived result
  live as a read-only preview, updating as you type before you even
  save. The "New tournament" form keeps its one "Date from" field (it
  only ever seeded every round to the same date); "Date to" is gone -
  it would have been silently ignored under the new model.
- [Change] **A tournament's setup no longer independently requires a start
  date** - requiring `round_dates` already covers it now that start
  date is derived from that list, not a second, separate requirement to
  satisfy.

## [0.14.28] - 2026-08-13

### Fixed

- [Fix] **The swap confirm modal's card pairs still ended up visibly uneven
  with real (longer) names**, even after 0.14.27's top-alignment fix -
  the "⇄ Board N" chip sat on the same line as the name, so it ate into
  the name's own available width on only the "after" card (the one side
  that ever gets a chip), making the exact same name wrap harder there
  than its own "before" counterpart managed without a chip competing
  for room. The chip now forces onto its own line below the name, so
  both sides of a pair get identical width to wrap into. Verified
  against the exact case that surfaced it (`Burssens, Ruben (1502)`, a
  name long enough to wrap under a chip but not without one): the name
  itself no longer wraps at all now, on either side.

## [0.14.27] - 2026-08-13

### Fixed

- [Fix] **The swap confirm modal's two board-diff cards could end up visibly
  misaligned** when a long name wrapped to two lines in one card but not
  its mirror (e.g. on the White row of one card, the Black row of the
  other) - centering each card vertically meant the taller one grew
  upward as well as downward, so its own White row landed at a
  different height than the other card's White row despite White not
  having changed. Both cards now align to the same top edge instead.

### Changed

- [Change] **Every player shown in a swap now gets a journey arrow, not only the
  ones who moved** - a two-board player swap shows 4 people (the 2 who
  traded boards plus whoever they left behind on each board); all 4 now
  get one, in their own colour: the 2 travellers get a real crossing
  journey, the 2 who stayed put get a short arrow back to their own
  seat, so nobody shown reads as forgotten next to the two who visibly
  moved. A same-board colour swap still shows exactly 2 (there's nobody
  else on that one board to draw) - unchanged. Verified live: 4 paths,
  4 dots, one per player's own colour; the two stationary players' paths
  measure as flat, near-zero-length arrows back to themselves.

## [0.14.26] - 2026-08-13

### Security

- [Security] **`phoenix_live_view` 1.2.7 → 1.2.9**, clearing a LOW-severity open
  redirect (EEF-CVE-2026-64941 / GHSA-36m4-rm57-3prf) in LiveView's own
  internal `validate_local_url!/2` check - an ASCII tab/LF/CR in a URL
  could pass that check as "local" while a real browser strips those
  characters and follows the link elsewhere. Pulled `phoenix` along with
  it (1.8.9 → 1.8.11, phoenix_live_view's own dependency floor) - both
  already inside this project's existing `mix.exs` version constraints,
  so only `mix.lock` changed.

  Not obviously reachable from this app's own code today - the one
  place that stores a redirect target (`user_return_to`) uses the
  current request's own path, not an attacker-supplied parameter - but
  the vulnerable check sits inside every `redirect`/`push_navigate`/
  `push_patch` LiveView does internally, so worth clearing regardless.

## [0.14.25] - 2026-08-13

### Added

- [Feature] **Every player shown in the swap confirm modal gets their own colour**
  - not just the two who moved. A two-board swap shows up to four
  people (the two travellers plus whoever stayed put on each board);
  each now has a distinct colour (from a fixed 6-colour palette,
  independent of the tournament's own accent) applied to their name
  everywhere it appears, so identity is legible at a glance instead of
  only "changed vs. unchanged". Each traveller's journey arrow, dot,
  arrowhead and "⇄ Board N" chip now match their own colour too - read
  straight off the seat elements the arrows hook already found, so
  there's no separate colour list to keep in sync between Elixir and
  JS. A same-board colour swap gets two colours; a non-swap confirm
  (mark absent, award bye, fill a seat, pool-pair) gets none, same as
  before.

## [0.14.24] - 2026-08-13

### Fixed

- [Fix] **Swap journey arrows: the two curves crossed below the middle rather
  than at it**, which read as a mistake rather than a swap. Each curve
  was built with one shared control x ("a lane per arrow"), which is not
  symmetric; with `+k` out of the start and `−k` into the end, both
  curves pass through the exact centre of the channel at their own
  half-way point and meet there.
- [Fix] **The arrowhead was still turning as it landed.** Each curve now ends
  (and starts) with a short straight run, so the head sits on a level
  segment.

## [0.14.23] - 2026-08-13

### Added

- [Feature] **The swap confirm modal now draws each moving player's journey** - a
  curved arrow from where they sit now to where they land, with a dot at
  the start and an arrowhead at the finish. Two boards trading players
  gives two curves crossing in the middle, which is the swap itself; a
  same-board colour swap crosses inside the one row. The curves route
  through the centre column (the static "→" steps aside and widens into
  a channel) so they never cross the opaque board cards.

  Which seats get joined is worked out by matching a name that changed
  seats on *both* sides, so mark-absent, award-bye, fill-seat, pool-pair
  and substitute-from-pool draw nothing at all - nobody travels between
  two shown boards there - with no extra server-side state to keep in
  sync. Purely additive: with no JS, or if measurement fails, the plain
  "→" layout and the "⇄ Board N" chips stand exactly as before. Honours
  `prefers-reduced-motion` (no draw-in animation), and redraws on
  window resize and on re-render.

## [0.14.22] - 2026-08-13

### Fixed

- [Fix] **The new W/B swap-modal badges (0.14.21) were inverted on a dark
  theme** - White rendered as a dark box, Black as a light one. The fix
  used `var(--surface)`/`var(--text)` for an "inverted pair," not
  noticing those tokens themselves flip between light and dark themes.
  Now fixed literal colours (the same cream/charcoal pair the brand
  mark's own chess pieces use), so White is always the light box and
  Black always the dark one, independent of theme.

## [0.14.21] - 2026-08-13

### Changed

- [Change] **The swap confirm modal's board-seat colour indicator is no longer a
  fixed-red dot** - replaced with theme-aware W/B letter badges (White:
  bordered, page-surface background; Black: inverted, same pair either
  way), so it no longer reads as an alarm colour in the one place -
  mid-swap - nothing is actually wrong. A genuine two-board swap's
  changed seat also gets a small "⇄ Board N" chip pointing at the other
  board involved, so the two independent before/after cards no longer
  need to be mentally cross-referenced by hand.

## [0.14.20] - 2026-08-13

### Added

- [Feature] **PGN export can include board numbers** - right-click "Export PGN" on
  the Pairings page (same `.PrintMenu` pattern as "Print pairings"/"Print
  result cards") for three more variants: this round with board numbers,
  every round, and every round with board numbers. `?board=1` adds a
  `[Board "N"]` tag to every game, using the same DISPLAY board number
  every other view shows (fixed-table boards relabeled/moved), not the
  raw stored board.
- [Feature] **Editing a past (non-latest) round's pairings now asks you to confirm
  it's not a mistake** - swap, mark absent, pool-pair, fill a seat, award
  a bye: any pairing-altering action staged on a round that isn't the
  tournament's current latest paired round now shows a clear warning in
  the confirm modal ("You're changing round N, not the current round"),
  with the primary button disabled until an explicit "I understand, apply
  anyway" checkbox is ticked - both client-side and re-checked
  server-side. Entering/editing a result is unaffected; this only gates
  changes to who's paired with whom.

### Fixed

- [Fix] **Public pairings round-picker/table sat flush against each other with
  no gap.**

## [0.14.19] - 2026-08-13

### Fixed

- [Fix] **SWAR export produced a file real SWAR misreads for a player with
  many rounds absent and no per-round "byes" row** (globally
  `absent: true`, never explicitly marked absent round-by-round). A
  round with neither a `Pairing` nor a `byes` row used to be silently
  omitted from that player's `[RONDE]` array - internally consistent for
  our own reader, but not a shape real, hand-run SWAR tournaments ever
  produce, and real SWAR was confirmed (against an actual production
  export) to desync on it: "???" opponent names and phantom results on
  *later* rounds for exactly that player, once their block ran out. Every
  round from the player's `start_round` onward now gets an explicit
  zero-point "absent" record instead of being skipped - a round before
  `start_round` (not registered yet) is still correctly omitted. No
  change to OpenPairings' own scoring/standings; only what gets written
  into the exported `.swar` file.

## [0.14.18] - 2026-08-13

### Added

- [Feature] **Public pairings page now shows round history, not just the latest
  round** - `/p/:slug/pairings` gained the same round-picker the
  authenticated Pairings page has (`?round=N`, bookmarkable/shareable),
  so anyone with the public link can look back at earlier rounds instead
  of only ever seeing whatever round is currently being paired. The
  public standings and pairings pages now cross-link to each other.

## [0.14.17] - 2026-08-12

### Fixed

- [Fix] **"Pair with another player who isn't playing…" confirm dialog got
  silently closed by an unrelated remote broadcast** - an arbiter mid-way
  through that gesture, with someone ELSE entering a totally unrelated
  result elsewhere in the round, got bounced out of it as if they'd hit
  Escape themselves. A remote broadcast now leaves any in-progress
  menu/swap/confirm gesture alone (the round data underneath it still
  refreshes fully either way); only the arbiter's own completed action
  clears it. Hardened `Tournaments.pair_from_pool/4` to re-check the
  target board number is still free right before writing, since the
  confirm dialog can now sit open across a remote update.
- [Fix] **The Players page's own "Player data was just updated by another
  arbiter" popup, removed** - same call as the Pairings page's identical
  notice (0.14.12): it kept surprising people mid-click regardless of
  where it sat. Player data still refreshes live underneath; only the
  popup announcing it is gone.
- [Fix] **Assigning categories skipped unrated players for an `elo_below`
  threshold bracket** (e.g. "U1800") - an unrated player's rating is
  effectively 0, which genuinely is under any positive ceiling; the
  `rating > 0` guard had it backwards. `elo_above` keeps requiring a real
  rating, unchanged - an unrated player has no proven rating to be above
  anything.

### Added

- [Feature] **Tiebreak values on the Players Card** (right-click a player) - a
  compact strip of the tournament's own configured tiebreaks and this
  player's value for each, same as the Standings page shows per column.
  Also added to the card's print version.

## [0.14.16] - 2026-08-12

### Added

- [Feature] **Print button on the Players Card popup** (right-click a player on the
  Players page) - opens a new tab with that one player's round-by-round
  history (opponent, colour, result, running score) as a print-ready
  document, same data and table shape as the popup itself. New route:
  `GET /t/:id/print/card/:player_id`.

## [0.14.15] - 2026-08-12

### Added

- [Feature] **Public standings link (`/p/:slug/standings`) now also shows the
  Category column** whenever the tournament has 1+ categories - it was
  added to the authenticated Standings page and print in 0.14.14, but
  missed the public page, which has no column-preference system at
  all and just needed the column added outright. Same "-" for an
  unassigned player, on both the FIDE-tiebreak table and the Keizer
  ladder.

## [0.14.14] - 2026-08-12

### Added

- [Feature] **Standings page now shows a Category column whenever the tournament
  has 1+ categories defined** - printed standings already did this
  (Category column plus one sub-table per category); the live
  Standings page never had a Category column at all. Shows
  unconditionally once the tournament has any categories - not gated
  by the Players page's column-visibility tickbox, matching print's
  own always-on behavior. Covers both the FIDE-tiebreak table and the
  Keizer ladder.

## [0.14.13] - 2026-08-12

### Fixed

- [Fix] **Changing an already-set result didn't show up for another arbiter
  viewing the same round, if they had that board's result dropdown
  focused** - confirmed by hand: the write and the live broadcast both
  worked correctly (the database and every other part of the page
  updated), but that one `<select>`'s displayed value stayed stuck on
  the old result, even after clicking away from it. Root cause is a
  genuine Phoenix LiveView behavior (protecting a focused form control
  from a server-pushed value change, so it doesn't clobber in-progress
  typing) that doesn't fit a discrete-choice dropdown like this one. The
  real result is now also mirrored into a plain `data-result` attribute,
  which always patches through regardless of focus; the result select's
  hook resyncs its value from that on every update, closing the gap
  without disturbing whatever the arbiter is doing.

## [0.14.12] - 2026-08-12

### Removed

- [Removed] **The "Round N was just updated by another arbiter" notice, entirely**
  - repositioning it as a fixed toast (0.14.11) didn't fix the
  underlying complaint: it still popped up and grabbed attention
  mid-click regardless of where on screen it sat. The round data itself
  keeps refreshing live via the existing broadcast the moment anyone
  enters a result elsewhere - that always worked and still does; only
  the popup announcing it is gone.

## [0.14.11] - 2026-08-12

### Fixed

- [Fix] **"Round was just updated by another arbiter" notice pushed the whole
  board list down for everyone else viewing the round** - it sat inline
  above the pairings table with a plain margin, so it appearing the
  instant someone else entered a result visibly shifted every board
  underneath it, right as another arbiter might be reading or clicking
  one. It's now a fixed-position toast that overlays instead of pushing
  layout - same idea the existing flash-message toast already uses,
  just anchored top-center. Also gave each board row a stable DOM `id`
  so a remote update always patches rows in place rather than risking
  a full node swap that could drop focus from an open result dropdown.

## [0.14.10] - 2026-08-12

### Added

- [Feature] **Each player's score coming into the round now shows next to their
  name on the pairing list** - the authenticated Pairings page, the
  public pairings page, the projector/live view, and the printed
  pairing list all show it now, e.g. "Alice (2400, 2.5)" (rating and
  score together where a rating exists, just the score otherwise). This
  is the score BEFORE the round shown, not after - the same figure a
  real printed pairing sheet has always shown, computed fresh per round
  so it's correct even when browsing a past round.

## [0.14.9] - 2026-08-12

### Fixed

- [Fix] **The public pairings page (`/p/:slug/pairings`) and the projector/live
  view (`/t/:id/live`) never used the same board display logic as the
  authenticated Pairings page** - both just sorted by raw `pairing.board`
  with no relabeling at all, so the moment a tournament had a fixed-table
  ("special") board, a bye, or an absence, they'd silently disagree with
  the arbiter's own Pairings page and with print: a real board 10 showed
  "10" there, "1001" everywhere else, for the exact same game. Both now
  go through the same `PairingDisplay` module as the Pairings page and
  print, so every surface shows identical board numbers and row order.

## [0.14.8] - 2026-08-12

### Fixed

- [Fix] **Marking a player absent (or otherwise changing a bye) renumbered
  every other board in the round** - a real regression from 0.14.6's
  "byes/absences sort below the special boards" change: pulling a bye
  or vacant seat out of the ordinary numbering sequence to move it
  visually to the bottom also shrank that sequence, shifting every
  later board's displayed number. Board numbers are now computed once,
  together, from real board order regardless of bye/vacant/normal
  status - stable no matter what an arbiter does to any other board
  mid-round - while the ROW ORDER (byes/vacant sorted below the
  special boards, unchanged from 0.14.6) stays exactly as intended.

## [0.14.7] - 2026-08-12

### Fixed

- [Fix] **FIDE lookup silently rewrote an already-filled name when the only
  difference was formatting** (case, punctuation, word order - e.g. an
  arbiter's own "Tom van 't Hoff" against FIDE's "Van 't Hoff, Tom"),
  with no confirmation prompt, even though a genuinely different name
  correctly asked first. The "don't bother asking about a pure
  reformat" shortcut turned out to be the wrong default for identity
  data - real report: a player's hand-typed name got rewritten with no
  warning. Any real change to an already-filled Name/Sex/Birth year
  now always asks first; only a byte-for-byte-already-correct value
  (re-running the lookup for no reason) still applies without a
  prompt, since there's nothing to actually change.

### Changed

- [Change] **Pairings table (and matching print documents) now order byes and
  vacant/absent seats below the special (fixed-table) boards** -
  previously a bye or an absence-vacated seat just sat wherever its real
  board number happened to fall among the ordinary boards. Order is now:
  ordinary boards, then byes, then vacant seats, then special boards
  (unchanged). A fixed-table player's own bye still sorts and labels as
  a special board, not as a bye row - the fixed-table label always wins.

## [0.14.5] - 2026-08-12

### Changed

- [Change] **Players page Pr. cell menu: clearer wording, and works on a plain
  click too** - a single player's Present/Absent toggle used to say
  "All Absent"/"All Present", easily misread as touching every player;
  it now just says "Absent"/"Present" for one row (the column
  header's genuinely-bulk menu keeps the "All" wording - right-click
  it to set everyone at once). Right-click wasn't discoverable to
  begin with, so a plain left-click on the cell opens the same menu
  now too.

### Verified

- [Verified] **Fixed-board results and same-round byes don't cross-contaminate** -
  investigated a report that a fixed-board win looked mis-credited
  (it wasn't: a different player's matching score came from their own
  bye that round, entirely independent). Added a regression test
  (`PairingsEngine.StandingsTest`) that enters a result through the
  exact write path the UI/CSV import use and asserts every player's
  score end to end, confirming standings are keyed by player id start
  to finish - `PairingDisplay`'s board relabeling can't affect it.

## [0.14.4] - 2026-08-12

### Added

- [Feature] **Sex (M/F) column on the Standings page and printed standings** -
  follows the same "sex" tickbox preference as the Players page on the
  live Standings view (shown by default until you touch the Display
  panel); always shown on the printed standings document (main table,
  per-category tables, and the Keizer ladder alike). Shows FIDE's own
  letters, same as the recent Players table fix.

## [0.14.3] - 2026-08-12

### Changed

- [Change] **"Norms" moved into the "Advanced" top-bar dropdown**, alongside Audit
  trail and Pairing rationale, instead of sitting as its own tab.
- [Change] **Cleaned up the "Advanced"/"Settings" dropdown chevron** - it now sits
  inline with the label (proper vertical alignment instead of a stray
  floating triangle) and flips to point up while the menu is open.

## [0.14.2] - 2026-08-12

### Fixed

- [Fix] **Sex column showed the raw internal code ("M"/"W") instead of FIDE's
  own letters ("M"/"F")** - both on the Players table and on printed
  player lists. Storage is unchanged (still "m"/"w" internally, matching
  `Trf.trf_sex/1`'s export convention); only the display was wrong.

## [0.14.1] - 2026-08-12

### Changed

- [Change] **FIDE lookup now asks before overwriting a Name, Sex, or Birth year
  that's already on file and disagrees with FIDE's own record** -
  previously only a fuzzy name-search match staged its name behind a
  confirmation; an exact FIDE-ID match applied everything, including
  identity fields, immediately. Filling in a currently-blank value still
  applies right away either way (nothing to conflict with), and a name
  that's the same identity just reformatted (case, punctuation, word
  order - e.g. "tijl de moyer" vs FIDE's own "De Moyer, Tijl") still
  applies immediately too, not treated as a real change. Operational
  data (title, rating, federation) keeps applying directly on every
  refresh, since that's the expected, routine outcome of the button -
  FIDE publishes a new list monthly and this is how ratings actually
  get updated. Multiple conflicting fields on the same lookup are shown
  together in one prompt.

## [0.14.0] - 2026-08-12

### Changed

- [Change] **Round-robin tournaments now pair their whole Berger schedule in one
  action instead of one round at a time.** A round-robin round's pairings
  never depend on prior results - the whole schedule is fixed the moment
  the player list is frozen - so there was never a reason to require a
  click per round the way Swiss does. "Pair round 1" is now "Pair the
  whole tournament," confirm-gated (it locks in who's playing; anyone
  added afterward isn't in the schedule, and it can't be changed once it
  exists). This also closes "I don't see all rounds in advance" - the
  whole schedule exists and is browsable right after that one click.
- [Change] **Round-robin's declared round count now always matches what the Berger
  schedule for the actual roster needs.** It used to be a free-typed
  number on the tournament-creation form (defaulting to a generic "9",
  the same default Swiss uses) with nothing tying it to the real math -
  "I get too many rounds" was a direct symptom of that mismatch, showing
  round tabs the schedule would never actually reach. `rounds_count` is
  now corrected to the real total (a pure function of player count plus
  cycles/match-format) the moment the round-robin pairing pass first
  freezes the player list, not a value the arbiter needs to compute by
  hand.

## [0.13.1] - 2026-08-12

### Fixed

- [Fix] **The KBSB lookup button could find a player's FIDE ID but never used
  it** - if the player's FIDE ID was blank, "KBSB lookup" would fill it
  in from KBSB's own cross-reference, but the arbiter then had to click
  "FIDE lookup" a second time by hand to actually pull that player's real
  FIDE data (title, rating, federation, birth year). Now the FIDE data
  comes in automatically the moment KBSB supplies the ID that unlocks it.
  If the FIDE ID KBSB found isn't in the local FIDE copy (e.g. not synced
  recently), KBSB's own fields are still applied rather than discarded.

## [0.13.0] - 2026-08-12

A batch of smaller fixes and features from one round of feedback.

### Added

- [Feature] **"Leave" a shared tournament.** A collaborator could never remove
  themselves from a tournament someone else shared with them - only the
  owner could remove a collaborator. Leaving is now self-service, right
  next to the (still owner-only) Delete button on the tournament list.
- [Feature] **"Copy" (duplicate) a tournament**, named "Copy of <original>" -
  available to the owner and any collaborator, reusing the same export/
  import round trip Settings > Export/backup already relies on. The copy
  is owned by whoever clicked it; no collaborators carry over.
- [Feature] **Fixed-table ("special board") pairings are now really renumbered**,
  not just annotated. A player with a Fixed table set (Players page) used
  to just get a "(table N)" note next to their ordinary board number,
  leaving no visible gap. Now the ordinary boards close the gap a pulled-
  out fixed-table board leaves (board 10 -> fixed_board 1001 means
  whoever was board 11 becomes displayed board 10), and fixed-table
  pairings move to the end of the Pairings page and the printed
  board-order pairing list, sorted by their own table number. Two
  fixed-table players paired against each other show as one row. The
  player edit modal now warns (doesn't block - sharing a table is valid
  when paired together) when a Fixed table value is already used by
  someone else.
- [Feature] **Standings columns follow the Players page's Display panel.** We/W-We,
  tiebreak columns, and XtPts/Total used to always show on Standings;
  now unticking a column on Players hides it here too (shared
  localStorage preference, defaults to "show everything" for anyone
  who's never touched the Display panel).
- [Feature] A top-level **Changelog page** (`/changelog`), next to Tournaments and
  Tools - it used to be buried at Settings > Changelog, needing a
  specific tournament in context even though the content is entirely
  app-wide.

### Changed

- [Change] The top-left nav link reads **"Home"** instead of "Tournaments" once
  you're inside a tournament - same destination, clearer label for
  leaving the tournament context.
- [Change] Tournament list: a single-day tournament shows just the one date
  instead of "date -> date"; finished tournaments get their own badge
  colour instead of looking identical to running ones.
- [Change] FIDE rating-list downloads (~41 MB, network fetch) are now limited to
  SSO-signed-in accounts. Local self-registration is open to anyone, so
  without this, anyone could sign up and repeatedly trigger the full
  download.

### Fixed

- [Fix] **FIDE lookup didn't fill in Sex (M/F)** - added, normalized from
  FIDE's raw "M"/"F" to the app's own "m"/"w" convention.
- [Fix] **The topbar accent-picker/theme-picker (and the Advanced/Settings
  dropdowns) sometimes didn't open on the first click** - an open
  popover's panel could cover the next trigger over. All four now share
  an exclusive `<details>` group, the browser-native fix.
- [Fix] **The pairing-rationale "Pre-round score brackets" chart ignored the
  theme system** - every colour (band backgrounds, player dots, floater/
  rematch connector lines, the fairness sparkline) was fixed light-theme
  hex, unreadable under every other theme.
- [Fix] **A tournament's uploaded logo only ever showed on place cards** -
  every other print document (pairing list, standings, player list/
  cards, crosstable, result cards) never rendered it at all.

## [0.12.3] - 2026-08-12

### Fixed

- [Fix] **The player edit modal's fields weren't live-synced to the server at
  all** - typing a corrected name or FIDE ID only changed the browser's
  copy; the server-side form stayed exactly as it was when the modal
  opened until Save was clicked. Clicking "FIDE lookup" or "KBSB lookup"
  right after typing something new silently searched on the *old* value
  instead (or, if a FIDE ID was already on file from before, used that
  instead of a freshly-typed name - which is also why the name-correction
  confirmation could seem to not fire: it was really taking the exact-ID
  path on stale data, not skipping the check). The whole modal now syncs
  on every field change, matching what Save would actually submit.

## [0.12.2] - 2026-08-12

### Changed

- [Change] **FIDE lookup now corrects the player's name, not just the
  ID/rating/federation/birth year.** By FIDE ID (an exact, unambiguous
  match) the name is corrected immediately, same as every other field. By
  name only (a fuzzy best guess), everything else still fills in right
  away, but the name goes behind a "FIDE has this player's name as
  '…' - correct it? Yes/No" prompt instead of silently overwriting
  whatever was typed by hand.

## [0.12.1] - 2026-08-12

### Fixed

- [Fix] **A player unrated in a tournament's own tempo (Rapid/Blitz) showed as a
  literal 0 Elo instead of falling back to their Standard rating.** FIDE's
  list uses `0`, not a blank field, for "no rating in this list" - the
  fallback logic used `||`, which doesn't treat `0` as absent in Elixir, so
  it never fired. Affects the tempo-aware FIDE lookup added in 0.12.0; also
  fixed the raw Standard/Rapid/Blitz hint on the player dialog, which had
  the identical bug.

## [0.12.0] - 2026-08-11

The version number sat at 0.11.1 for five weeks while the app kept
shipping - this release is everything that landed in that gap, in one
batch rather than the many small ones it should have been. Going
forward this file gets an entry every time the version bumps.

### Added

- [Feature] **SWAR `.swar` v7 export** - a real, opinionated SWAR file OpenPairings
  can write from any tournament, not just import. Settings → Export /
  backup.
- [Feature] **Hand-editing a paired round** - right-click any player on the
  Pairings page to swap them with someone else, mark them absent, award
  a bye, or fill an empty seat from the round's "not playing" pool. Two
  people sitting the round out can be paired straight into a new board.
- [Feature] **Threshold prize categories** - a category can now be "below/above
  this Elo" or "below/above this age" instead of only a hand-picked
  name, with a one-click "Assign categories" button that fills in every
  player at once.
- [Feature] **Public self-registration** - players can register themselves for a
  tournament without an arbiter account (off by default, rate-limited).
- [Feature] **Mobile "enrol a phone"** - no-account result entry from a phone at
  the board, for arbiters or helpers without a login.
- [Feature] **Automatic FIDE title-norm judgment (B.01)** on the Norms page.
- [Feature] **TRF06 import support**, and VCL.13's asymmetric ½-0 / 0-½ result
  code across the whole pipeline.
- [Feature] **Standalone single-file binaries** - no separate Elixir/Erlang
  install needed to run OpenPairings.
- [Feature] **Alphabetical pairing list and printable score sheets.**
- [Feature] Settings → About page: which pairing engine a tournament is using, and
  a credits line.
- [Feature] 02cloud SSO (Keycloak) as an optional login method; configurable FIDE
  rating-list source URL.
- [Feature] Light/dark theming and an accent-colour picker - now with 4 more accent
  colours (Indigo, Cyan, Orange, Fuchsia, 11 total) and 5 more full themes
  (Solarized Dark, Nord, Dracula, Catppuccin Mocha, Gruvbox Dark) alongside
  System/Light/Dark, 8 total. The theme switch is now a popover instead of
  an inline button row, to fit them all.
- [Feature] **Tempo-aware FIDE ratings** - a player's FIDE lookup/refresh now pulls
  the Standard, Rapid, or Blitz rating matching the tournament's own
  cadence (Settings → Options → Type), falling back to Standard when the
  player has no rating in that specific list yet. The player registration
  dialog shows all three alongside "Elo used" (whichever one the pairing
  engine actually reads). Changing a tournament's Type after players are
  already registered doesn't retroactively re-fetch anyone's rating - a
  save note points arbiters to the Players page refresh instead.

### Changed

- [Change] The Players page's right-click "Absent" now has a real bulk mode (the
  Pr. column header) that touches every player at once without
  disturbing anyone's individually-set absent rounds.
- [Change] Printed player lists follow exactly the columns ticked in the Display
  panel, instead of a fixed five.
- [Change] FIDE report generation (IT3/FA1/IA1/IT4): arbiters are no longer
  capped at two, the organizer is a searchable FIDE person instead of
  free text, and arbiter/organizer e-mail became mandatory for a
  download.
- [Change] JaVaFo's pairing input for round 2 onward is built in current-
  standings order rather than fixed pairing_number order - this is what
  a real SWAR-vs-OpenPairings pairing mismatch on the same data turned
  out to be.
- [Change] The bracket-map pairing-rationale view: unpin no longer stray-scrolls
  the hover panel, plus a head-to-head duo view.
- [Change] The "updated by another arbiter" toast (already on Pairings) now also
  shows on the Players page.
- [Change] Mobile result entry: forfeit and asymmetric-disciplinary result codes
  (1-0 FF, 0-0 FF, ½-0, etc.) are now reachable from a phone, behind a
  "More…" toggle per board rather than crowding the three main buttons -
  chosen over a long-press gesture, which has no visible affordance and
  behaves inconsistently across mobile browsers.

### Fixed

- [Fix] **Results entered from a phone weren't being written to the audit
  trail at all** - every other way of entering a result was, mobile was
  simply never wired up. Now logs the same `pairing.result_entered`/
  `_changed`/`_cleared` actions the desktop flow does, attributed to
  "System" (no user account exists for an enrolled phone) with the
  enrollment's own label/id recorded so an arbiter can still tell which
  phone made the change.

- [Fix] **Round 2+ pairing input had no tie-break for players equal on both
  score and rating** - JaVaFo's Dutch-system engine falls back to input
  order when a bracket has more than one structurally-equal pairing, and
  that fallback order was effectively arbitrary (unordered map
  enumeration), not a real rule. Found via the same real SWAR-vs-
  OpenPairings comparison above; fixed by adding `pairing_number` (FIDE
  Art. 1.14's starting-rank fallback) as the third sort key.
- [Fix] **`SW321_PreBye` presence points** on pairing-allocated byes were not
  modeled at all - a real scoring gap for clubs running SWAR's 3-2-1
  point scale.
- [Fix] **FIDE C.07's Cut-1 Exception** (Art. 16.5.1) was missing, and a
  trailing pairing-allocated bye was scored as a draw instead of a bye.
- [Fix] **Article 16.4** unplayed-round tiebreak scoring (Buchholz / BHC1 /
  Sonneborn-Berger) was wrong for a specific unplayed-round shape.
- [Fix] **SWAR `AbsValue` mapping** was backwards - a checked "pay ½ point for
  absence" box imported as 0 points, not 0.5.
- [Fix] SWAR handicap-table boards were misplacing pairings in board order.
- [Fix] The registration form's FIDE-id dropdown could silently fail to
  appear at all.

### Security

- [Security] Content-Security-Policy with a per-response nonce.
- [Security] Rate-limiting keyed on the real client IP; throttled magic-link sends
  and registration-form submissions.
- [Security] Mobile enrollment codes moved to a CSPRNG, 8 digits over one global
  space instead of per-tournament.
- [Security] Closed an `/invites` link enumeration issue; tournament owners can now
  disable or rotate a public link.
- [Security] Bumped `bandit` for a HIGH-severity WebSocket DoS advisory.

---

Versions before 0.11.1 are not itemized here - see the git history.
