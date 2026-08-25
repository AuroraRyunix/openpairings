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

## [0.17.0] - 2026-08-25

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

- [Feature] **Local mode: the standalone binary now runs on your own machine
  with one setting and nothing else.**

  ```bash
  OPENPAIRINGS_LOCAL=1 ./pairings_engine_linux_x86_64 start
  ```

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

- [Change] **Settings &rarr; Options saves per subject instead of all at once.**
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
- [Feature] **"Copy" (duplicate) a tournament**, named "Copy of &lt;original&gt;" -
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
