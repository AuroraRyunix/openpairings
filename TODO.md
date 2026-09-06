# TODO / Roadmap

Version: **0.42.0** (not 1.0 yet - the maintainer will call that explicitly).
See [`docs/features.md`](docs/features.md) for what's already shipped.

> **A second whole-codebase sweep ran on 2026-09-01** - 33 items, in
> [docs/sweep-2026-09-01.md](docs/sweep-2026-09-01.md): 3 High, 14 Medium,
> 9 Low, 3 leads, 4 optimisations. **All fixed on 2026-09-02** except two
> leads left deliberately - a dead `matches` table, and whether a CI runner
> image ships a populated keyring. Every claim was checked against the
> source before it was filed, and the six whose mechanism was dynamic were
> reproduced with a test first. The runtime layer (OTP, Phoenix, LiveView,
> SQLite) was checked against 2026 advisories and is clean; the box runs
> OTP 27.3.4.16, past every advisory on that line.
>
> The deploy-script half of it - secrets printed on every redeploy, the
> service running as root, an SSH client that trusted any host key - is
> fixed in the script but **only takes effect on the next deploy**, and the
> secrets already printed still have to be rotated by hand.
>
> Ainalrami's half is in that repository, shipped as **v0.15.0**; this app
> pins it.
>
> **A whole-codebase sweep ran on 2026-08-26** - 78 items, in
> [docs/sweep-2026-08-26.md](docs/sweep-2026-08-26.md). All 12 confirmed
> bugs and all 15 leads are now closed; that document's Status section
> carries the finding-to-commit table, and its own "Still open" list is
> stale and says so.
>
> Its remaining 49 items - 27 drift, 7 optimizations, 15 additions - went
> unexamined until **2026-08-29**, when all of them were assessed in
> [docs/sweep-2026-08-26-followup.md](docs/sweep-2026-08-26-followup.md).
> **All of them are now closed** (2026-08-30). One turned out not to be a
> defect: Koya reads an opponent's raw score where Buchholz adjusts, and
> C.07 Article 16 names its own scope in its opening sentence without Koya
> in it. What remains from that document is its documentation-drift
> section and the tiers this file had already parked.
>
> Three documents, three jobs: this file is the roadmap, the sweep is the
> evidence, the followup is the triage.

## Everything that is open, in one place

### publish_mode has two different defaults - decided 2026-09-04

`priv/repo/migrations/20260813150000_add_pairing_publish_delay.exs` sets the
column default to `"immediate"`, and its own comment says that is to
"preserve today's behaviour". But `Tournaments.Tournament` declares
`field :publish_mode, :string, default: "manual"`, and Ecto sends struct
defaults on insert - so the column default never applies to a tournament
created through the app, and every new tournament is **manual**.

Verified by creating one: `publish_mode` comes back `"manual"`.

That means the per-round publish controls are visible by default (they are
hidden only in `"immediate"`), and, since 2026-09-04, that the live/projector
view starts out saying a round is paired but not published.

**Decided: manual is correct and stays.** Publishing a round should be an
act, not something that happens because a round got paired - and the
projector view now depends on that being true.

No migration. Changing a column default in SQLite means rebuilding the
table, and this one is unreachable: tournaments are created and restored
through changesets, and nothing writes that row in raw SQL. The schema
field carries the explanation so nobody closes the gap from the wrong end.


Last reconciled **2026-08-30**. This section is the index; the detail lives
where it always did and is linked from each line. Anything not listed here
is either done or deliberately dropped.

Three repositories feed this list, so it is the only place that sees all of
them at once: **OpenPairings** (this one), **Ainalrami** (the engine,
vendored), and **OpenResults** (the public site).

### Do next - all four done 2026-08-29

- ~~**Password sign-in had no rate limit.**~~ It shares the magic-link
  form's two buckets now - per address and per client - refused before
  the password is checked, so a throttled attempt costs no bcrypt round
  and cannot be timed. Only failures are counted.
- ~~**`PlayerCard` showed an opponent's score inflated.**~~ Reads
  `Standings.rank_score/2` instead of `.total`, so it stops counting
  administrative extra points in a tournament that does not rank on them.
- ~~**A shared tournament went stale for the collaborator.**~~ The four
  lifecycle writes use `broadcast_tournament_list/1`, which reaches every
  accepted collaborator as well as the owner.
- ~~**`safe_path/1` turned a crafted URL into a 500.**~~ It rejects the
  characters Phoenix refuses (backslash, tab, encoded forms) rather than
  handing them to `redirect/2` to raise on.

The next tier is whatever ranks highest in the followup below. Nothing
there is currently known to bite a user the way these four did.

### Correctness and quality - closed 2026-08-30

Every item [docs/sweep-2026-08-26-followup.md](docs/sweep-2026-08-26-followup.md)
ranked as still real is done. That document carries each closure with its
commit, and the regulation text where a finding turned out not to be one.

The recurring shape is worth keeping on the page, because naming it is what
made the fixes cheap: **one rule spelled in more than one place.** "Which
result was this?" had been re-derived in five modules and now lives in
`PairingsEngine.Results`; `RoundRobin` hand-copied two functions rather than
calling the ones exposed for it; the tie-break catalogue carried a `teams:`
flag nothing read and which had quietly gone wrong. The same "higher ranked"
misreading appeared in Gacrux, in this engine, and in this engine's own test
harness.

Its **documentation-drift section** is closed too, checked entry by entry
against the code on 2026-08-30. Five of the seven were still true, one had
already been fixed, and one blamed the wrong file. Two of the five were worse
than filed - this document had the `absent_counts_as_vur` setting inverted,
not merely defaulted wrong - and two more of the same class turned up while
fixing them.

The version-consistency check the sweep asked for is **built** (2026-08-30):
`mix pairings.version_check`, wired into `mix precommit` ahead of the tests.
It reads `mix.exs` and refuses when this file's header, `docs/features.md`'s
or the changelog's top section names a different version - the drift that
happened three times, the last inside the three days the followup covers.

### Doc hygiene - done 2026-08-29

- ~~`Layouts.public/1` was dead code~~, orphaned when the local public
  pages went. Deleted, along with the root layout comment that named it, and
  `EnglishHook`'s moduledoc now names the one player-facing page it
  actually still covers rather than the four it used to.
- ~~`docs/features.md` said 0.17.1~~ while `mix.exs` said 0.18.0. The
  sweep's own version-drift item, which had recurred three days after being
  filed - the standing argument for the pre-commit version check it
  suggested, which is still not built.
- ~~The sweep had two pairs of duplicate entries~~ (Drift #5/#6 and
  #10/#11). Left in place so the numbering every other document cites still
  resolves, with a note at the head of that section saying a count taken
  from it is two too high.

### Roadmap-scoped suggestions - three closed 2026-08-30

The follow-up's items 26-32. Closed: the team-pairing SPP cross-reference
(and its blocker turned out to be CLEARED, see below), and local-mode polish
- the Settings link, the Share/Team card and the register/log-in routes now
know they are on a single-user install, joining the log-out link that has
known since 0.17.1.

Still open, and each needs a decision rather than typing:

- **Norms-vs-Settings** - the pointer card shipped, the page move did not.
  A product call about where norms live.
- **ITDX `?` unknown-result code** - PARKED 2026-08-30, deliberately, and
  owed. `docs/tec-feedback-2026-09.md` section C.2 tells TEC "We will
  implement `?`", the letter has gone, and nothing implements it.

  **No effect on a real tournament, which is why it can wait.** Nothing can
  produce a `?` today: TRF-26 is not published (the letter's own C.1 asks
  whether it exists), so no file in the wild carries one. If one arrives
  anyway, `Ainalrami.Trf` raises a `ValidationError` on an unknown result
  symbol - the import is refused, loudly, rather than mangled. That is the
  safe failure and it is the behaviour the letter argues for; only the
  symbol itself is missing.

  Split, and worth doing in one sitting in this order - a `?` the engine
  accepts and this app does not understand is worse than neither:

    1. **Ainalrami** (small): add `?` to `@result_codes` and
       `@legal_result_pairs`, keep raising on everything else.
    2. **OpenPairings** (the real work, ~half a day): decide what a stored
       `?` MEANS. The design to build unless something argues otherwise -
       scores nothing for both players; not `played`, so it never reaches a
       tie-break as a real game; **parse-only**, never enterable, because a
       "don't know" button becomes a placeholder and stops meaning what it
       says; keeps the round incomplete so it blocks the next pairing and
       the rating report; labelled on screen as "unknown - from an imported
       file" so it reads as something to fix. It is a blank that says whose
       fault it is.

  Checked while scoping it: `TrfImport.result_string/2`'s catch-all turns an
  unrecognised code into `""`, which is exactly the "silently converts a
  corrupt file into a plausible one" failure C.2 names - but it is
  UNREACHABLE, because every one of the twelve pairs Ainalrami permits has
  an explicit clause above it. Belt to the engine's braces, not a hole.

- **Q140 consistency checks are page-scoped** - they live in
  `pairing_explain_live.ex` and nothing extracts them for a layout-level
  banner, so a check only fires where somebody went looking. **Parked
  2026-08-30 by the maintainer: fine as is.** Reviving it needs a decision
  first - recompute the checks per page load, or store them when the round
  is paired - because the checks come from the full `PairingRationale`
  build and a layout banner renders on every page.

### Blocked on something outside the code

- **SWAR `value1`/`value2`** and **`SW321_PreBye`** - both need one real club
  file with categories configured. All three `.swar` fixtures carry
  `type = 0`.

  The `value1`/`value2` half is now **warned about rather than silently
  mis-imported** (2026-08-30): a file carrying a second value list gets a
  named warning saying those categories have nobody in them.
  `docs/swar-import.md` tabulates the three candidate meanings and what a
  real file would have to show to pick between them. The interpretation is
  still blocked; the silence is not.
- **The i18n fragment count** - unmeasurable by grep, because a HEEx text
  node spans lines. The instrument that would settle it is a pseudo-locale;
  not built, and nobody has asked.

### Parked by decision

- **The 2026 Acceptance Cycle** - five hard failures, FIDE Mode being the
  spine. Detailed in the next section. Q208 came off this list on
  2026-08-29 when ARO was fixed, because it was never only an acceptance
  item.
- **Team tournaments** - deferred. Ainalrami has the C.04.6 reading written
  up before any code (`deps/ainalrami/docs/conformance-c0406-teams.md`);
  OpenPairings has partial scaffolding wired to nothing.

  **No longer blocked on the SPP.** C.04.6 Article 4.3.1 is the same
  TPN-parity rule as the individual 5.2.5, so team colour allocation was
  waiting on that question rather than merely being large. The SPP answered
  on 2026-08-28 (against us) and Ainalrami v0.14.0 conforms, which is what
  this app pins - so the reading the team work needs is settled. Size is now
  the only thing in the way.
- **American accelerated pairing** - dropped, maintainer's own call.
- **Auditing OpenPairings against SWAR's C++ source, file by file** - real,
  never costed.

### Ainalrami (the engine)

- **The Gacrux 5.2.5 candidate.** The corrected consistency checker fired 17
  times over ~1,065,000 rounds on the 2026-08-29 corpus - **all seventeen on
  Gacrux, all in round 2**, with bbpPairings and Ainalrami silent. Those are
  rounds where Gacrux contradicts *itself*: one board implying the initial
  colour was white, another implying black. Not adjudicated; one position
  read by hand turns it into a finding or dissolves it, as two earlier
  candidates dissolved. Logs on Photon at `/root/ain_val_run/`.
- **Two upstream reports written and unsent** - the bbpPairings C2 report,
  and `docs/finding-gacrux-5-2-4.md`. The maintainer sends those.
- **Team tournaments** - the reading is done, the code is not. C.04.6 is not
  the Dutch engine applied to teams: it has its own C1-C10 criteria, and
  Article 3.6 defines the answer as the head of a lexicographic order rather
  than an optimum, so weighted matching does not choose at all. No reference
  implementation pairs teams - not bbpPairings, JaVaFo, Gacrux or SWAR - so
  there is nothing to differential-test against.

### OpenResults

Nothing open. The entry form is unfinished and unlinked, parked by the
maintainer.

### Operational - the maintainer's, not the code's

- **Deploy.** Nothing since 2026-08-29 morning is on the box. The next
  deploy wires publishing and grants the admin role by itself, and will
  decline to move the endpoint to loopback until it is forced.
- **Rotate the secrets** that reached a session scrollback on 2026-08-29.
- **FIDE search does not work for a laptop arbiter behind NAT** - it needs
  both applications on one host. No design yet.

## The 2026 Acceptance Cycle (dominates everything below)

FIDE TEC circulated draft **VCL4THP v13** and a revised **TEC Manual** on
2026-08-25, for consultation until **2026-09-07**. When the final versions
publish, TEC announces a new Acceptance Cycle and **existing endorsements
are revoked** - every vendor re-qualifies. Our feedback draft is
[tec-feedback-2026-09.md](docs/tec-feedback-2026-09.md); it is not sent.

The VCL is 226 questions with **accumulating penalty percentages, where
over 100% is a failure**, plus hard stops that end verification on the
spot. What follows is our own read of where we stand. It is a read, not a
verdict - TEC verifies, we do not.

### Hard failures (verification stops)

- **FIDE Mode does not exist.** We have a fide_homologated flag; the VCL
  wants a MODE (Q40-46) with warning Levels 1-5, a Level-4 double warning
  on exit, no re-entry once exited, and a ### TRF comment recording the
  round it was left. Half the other requirements report THROUGH this, so it
  is the spine: build it first, or build everything else twice.
- **Adjourned games are not implemented at all** (Q157-169). The word does
  not appear in the codebase. Needs a result state, "counts as a draw for
  pairing purposes", a Level-3 warning when a non-draw result is entered
  later, and a block on final standings while any remain.
- **Prohibited pairings can be added mid-tournament** (Q196).
  Tournaments.add_forbidden_pairing/3 does not go through
  ensure_unlocked/2. Cheap to fix - but see the feedback draft, where we
  argue this should be a Level-4 warning rather than a prohibition, since
  C.05:5.2 binds the ORGANISER to communicate, not the software to refuse.
- **Past results are editable in any round** (Q189-191). C.04.2:4.3 allows
  only the round immediately preceding the last one played.
- **TRF import does not verify the imported rounds** against the pairing
  rules (Q54). Mostly plumbing, now that a checker exists.

### Accumulating penalties

Over 100% fails, so these add up rather than standing alone:

- Tournaments over 30 days, where a player may hold more than one rating
  (Q210, **40%**; Q212, 35%)
- ~~Unrated players in rating-based tie-breaks (Q208, **32%**)~~ **Fixed
  2026-08-29**, and it was never only an acceptance item: ARO/AROC1 averaged
  an unrated opponent in as a literal 0, so one unrated entrant moved prize
  placings in any tournament using them. C.07 Art. 10 gives no substitute
  rating - it drops the tie-break outright when unrated players are present -
  so `Standings.effective_tiebreaks/1` does that, and the standings page
  names the code and the escape hatch.
- Consistency checks only on explicit request (Q140, **25%**)
- Custom Rating Lists (Q117, 18%)
- Chess960 (Q222, 15%) - **deferred by decision, 2026-08-25.** Cheap for
  the penalty it carries (a start-position draw would satisfy the question)
  but deliberately not now. Keep it on the list.
- ~~W/D/L unrated results, games shorter than one move (Q185, 7%)~~ -
  **shipped 0.17.1.** The codes were already read and written; what
  0.17.1 fixed is that they reached the *pairing engine* correctly. The
  score in TRF columns 81-84 came from a hand-written mapping separate
  from the crosstable's, and `W`/`D` were not on it - so an unrated win
  was banked as a loss and the player was bracketed a full point low.

  Both remaining copies - `TrfImport`'s and `bye_safe_result/2`'s - were
  closed on 2026-08-28, so **Q185 is now genuinely finished**. Neither was
  mis-scoring anything: each was a complete partition as of v0.14.0, and the
  exposure was drift rather than a live defect, which this note previously
  implied. Both are now checked at build time against the engine's own
  vocabulary, so a code the engine accepts and the call site does not fails
  the build naming itself.

### Blocked on FIDE

- **TRF-26.** Required throughout (Q21 PTC input, Q217 report completeness
  at 30%), but the Manual documents Records 162/172/299 as clarifications
  OF a specification rather than as one. Whether it is published is the
  main question in our feedback. We implement TRF16 today.

### Where we are already strong

Written down so it is not accidentally rebuilt. Q19-23 wants a free CLI
Pairing/Tie-Break Checker AND a Random Tournament Generator, and Ainalrami
has both. Q33's mandatory 50,000-tournament cross-test we exceed by five
orders of magnitude. Q70-88's scoring and PAB configuration landed
2026-08-24. Q180-184's result codes are already exact: 1/2-0, 0-1/2 and 0-0
are supported, forfeits are restricted to the three legal codes, and the
illegal combinations cannot be entered.

## Known gaps / deferred features

- ~~**The deploy script reports success when the service is dead.**~~
  **Fixed 2026-08-28**, though UNPROVEN: the verification has never run a
  real deploy. Build failures abort before the restart, a dirty dep
  checkout is recovered with `deps.clean` without `--build`, ports are
  preflighted, and health is polled on systemd and HTTP together. Original
  note, found the
  hard way on 2026-08-28: it printed "Deployment Completed Successfully!"
  with `pairingsengine.service: Failed with result 'exit-code'` in the same
  output, and the site was down for six minutes past the announced window.

  It restarts the service and never asks whether the thing it restarted came
  back. A poll on `http://localhost:$APP_PORT/` until it answers, with a
  timeout and a non-zero exit, would have turned a silent break into a
  visible one. Worth doing when the script is taught to deploy two apps -
  it will have twice as much to get wrong by then.

  What actually broke, for the record, because the shape will recur every
  time the engine pin moves: `mix.lock` pointed at Ainalrami v0.14.0 while
  the dependency's checkout on the box had a stray local edit to
  `docs/engineering-log.md`. Git refused to switch commits over a dirty
  file, so `deps.get` aborted - and so did `ecto.migrate`, which is why the
  migration silently did not run either. Fixed with
  `mix deps.clean ainalrami` (WITHOUT `--build`, which only clears build
  artifacts and leaves the dirty source in place), then re-fetch, migrate,
  restart. A `deps.get` that fails should stop the deploy.

- ~~**`Publishing.enqueue_id/1` can take the whole app down.**~~ **Fixed
  2026-08-28**, with a caveat that matters: the rescue covers a missing
  TABLE, not a missing COLUMN. Ecto selects every field a schema declares,
  so a column added ahead of its migration breaks every query that loads a
  tournament, not the one function reading the new field. That one is
  mitigated by deploy ORDER, which the deploy script now enforces by
  aborting when a migration fails. Original note: it hangs off
  `broadcast_tournament_change/2`, which every write in the application goes
  through - the point being that no call site can forget to publish. The
  same property means one bad query there breaks every write.

  That is not hypothetical: between the restart and the migration on
  2026-08-28 the app ran new code against the old schema and every write
  raised `no such column: t0.publish_to_openresults`. The window was small
  because the migration was one command away, but the window exists on every
  deploy where code lands before schema.

  A publishing queue is a courtesy. It must never be able to stop an arbiter
  entering a result. Wrap the enqueue so a database error there is logged
  and swallowed, and the write proceeds - "publishing is not working yet" is
  a state the app should survive, not die of.

- ~~**Byes sort above special boards, and should sort below them.**~~ **Fixed
  2026-08-28.** Order is now normal, special, byes, absents. 0.14.7's entry
  had claimed this change and shipped the concatenation backwards. Original
  note, reported by
  the maintainer 2026-08-28. `PairingDisplay.with_display_boards/1` currently
  orders normal, then byes, then vacant seats, then special boards. The
  order an arbiter expects is **normal, special, byes, absents** - a special
  board is a board somebody is playing on, so it belongs with the games, and
  the two categories where nobody is playing belong at the bottom together.

  One line in `with_display_boards/1`'s `ordered` concatenation. It is
  display order only - the frozen `display_board` labels are computed by
  `compute_labels/1` and are not affected, so this cannot renumber anything.
  Check the printed pairing sheet and the projector view alongside the
  Pairings page, since all three read this function.

These are real, identified gaps - not yet built, and not accidentally missed:

- ~~**Admin/support role** (`users.role`)~~ **Shipped 2026-08-29**, and it
  closed a live bug rather than only adding a feature.

  `admin` changes the wiring (publishing connection, backups, rating syncs),
  `support` may only look at it, `owner` is everyone else. Granted by
  `mix pairings.role` and nowhere else - a hosted installation has no
  administrators until someone runs it, deliberately, because shell access
  is the one credential that cannot be circular.

  What it replaced was `User.sso?/1`, which had been standing in for
  authority across the whole Data & sync page. Two things were wrong with
  that, and the second was worse:

    * every account in a federated directory passed it, so "signed in
      through 02cloud" meant "may repoint where this installation
      publishes";
    * **a local build failed it.** `local_owner_changeset/2` sets no
      `keycloak_sub`, so the auto-signed-in local owner was not an SSO
      account - and the arbiter's own laptop could not set its publishing
      address, take a backup, or download the FIDE rating list. Local mode
      now needs no role at all (`PairingsEngine.Authz`), which is the rule
      the maintainer asked for and the reason the item was worth doing.
- ~~**FIDE/KBSB "last synced" banner**~~ - this claim was already stale:
  the topbar's `.sync-freshness` strip ("FIDE: 3 days ago · KBSB: never
  synced") has been showing this for a while (`Layouts.sync_label/1`,
  `Fide.last_sync/0`/`Kbsb.last_sync/0`). Nothing left to build here.
- **Live "round paired by someone else" notice** - **not built.** This entry
  used to claim the opposite, at length: that PairingsLive had carried a
  dismissible `remote_notice` toast "for a while" and that PlayersLive had
  just been given the same. Neither is true. `grep -rn "remote_notice" lib/`
  returns nothing, and both LiveViews carry an explicit comment saying the
  notice was REMOVED (`pairings_live.ex:106`, `players_live.ex:134`).
  [docs/features.md](docs/features.md)'s near-term list has had it right all
  along - it lists this as unbuilt - so this file was the one out of step.
  Corrected 2026-08-30.

  What both pages do have is the silent live refresh: a broadcast reloads
  the round, so nobody is looking at stale boards. The gap is only that
  nothing SAYS a colleague did it.
- **Team tournaments** - explicitly deferred by the maintainer as a "future
  thing." More scaffolding already exists than this note used to claim:
  `Tournaments.Team` schema, `Player.team_id`/`board_order`, TRF16 team-block
  read/write (`Trf.team_line/1`/`parse_team_line/3`), and "Swiss (teams)"/
  "Round robin (teams)" are already selectable as a tournament format. None
  of it is wired end-to-end though - no team CRUD UI, `Pairing.pair_next_round/1`
  doesn't branch on team type at all (teams pair as plain individuals today),
  no team standings/tiebreaks, and the team TRF block is never actually sent
  to JaVaFo. Still a real, substantial feature gap - just not a from-scratch
  one.
- **American (accelerated pairing) system** - explicitly dropped, not planned
  ("no one cares" - maintainer's own call).
- **SWAR categories: value1 / value2 are merged on import** - the
  [CATEGORIES] block holds a type integer plus two parallel 17-slot arrays.
  SwarImport.map_categories/1 flattens both into one name list and ignores
  the type, while SwarExport.reverse_categories/1 writes value2 blank and
  the type always 1. Per-player CatIndex only ever indexes value1, so
  either value2 holds boundaries (and import invents phantom categories) or
  it continues the name list (and assignment breaks past the 16th).
  **Unresolvable from what we have**: all three .swar fixtures in the repo
  carry type = 0. One real club file with categories configured settles it.
- ~~**Print output is not translated**~~ - **this claim was already stale
  when it was last quoted, 2026-08-29.** `print_controller.ex` carries 81
  `gettext/1` calls, and `locale_test.exs` has a dedicated
  "a printed document comes out in Dutch too" case that asserts the
  document's subtitle, its table header, the credit line and `lang="nl"`,
  *and refutes each English equivalent* - so it cannot pass against an
  empty catalogue, nor against one covering only the `~H` templates.

  `docs/i18n.md` §"The other trap: HTML built as strings" documents the two
  rules that apply there and nowhere else (entities are not double-escaped
  because the output is interpolated raw; values go through `esc/1` while
  the msgid does not). Nothing left to build.
- **Dutch is complete as of 2026-08-29** - `mix gettext.extract --merge` had
  not been run since before the OpenResults split, so 104 new strings (and 17
  removed with the local public pages) were sitting outside the catalogue
  entirely. Extracted, and all 103 untranslated entries filled: 918 of 918,
  with placeholder parity checked mechanically, since a translated `%{name}`
  is a crash rather than a typo.

- **i18n fragments left English on purpose** - sentences wrapping around an
  inline value cannot be one `gettext/1` call as written, and splitting them
  renders half in each language. Do not wrap a fragment to raise the count.

  **Two of this item's own claims were false and are removed (2026-08-29):**
  the number was **41**, and it said they were "listed with the placeholder
  shape each needs in docs/i18n.md". That document contains no such list -
  it gives the technique (`rich_text/1` with `%[name]` placeholders) and the
  rule, and nothing else. Neither the count nor the inventory has any
  provenance anybody can now find.

  What is measurable says most of this work already happened.
  `CoreComponents.rich_text/1` - the tool that exists for exactly this - is
  used **55 times across 19 files**, beside 1,236 `gettext/1` calls in the
  web layer, and the catalogue is at 933 msgids with Dutch complete and
  now test-enforced. Static scans for prose sitting next to an
  interpolation surface only column abbreviations, result codes and product
  names, every one of which `docs/i18n.md` puts off-limits by name.

  **What is actually blocked is the measurement, not the work.** Whether an
  unwrapped sentence remains cannot be answered by grep: a HEEx text node
  spans lines, and "an Elixir line with no tags on it" matches multi-line
  attributes, moduledocs and the arguments of `gettext/1` itself far more
  often than it matches prose.

  The instrument that would settle it is a **pseudo-locale**: generate a
  catalogue from `default.pot` whose every msgstr is its own msgid inside
  markers, render the pages under it, and anything that comes back unmarked
  was never wrapped. That is the standard technique, it is finite, and it
  would replace this item's guesswork with a number that stays true. Nobody
  has asked for it, so it is written down rather than built.
- **SWAR presence points on pairing-allocated byes (`SW321_PreBye`)** -
  modelled now (`tournaments.presence_on_allocated_bye`,
  `Standings.bye_points/2`); if a real club file ever surfaces where this
  models differently than expected, re-verify against it (only synthetic
  fixtures + the one real file with a coincidental match have exercised it).

## Tech debt

- ~~**`.form-grid` versus the Settings pages' `.set-*` primitives.**~~
  **Closed 2026-08-29 as a decision, not debt** - and the note was wrong
  about which pages, which is why it kept reading like something unfinished.

  It named `tournaments_live.ex` / `norms_live.ex`. It is three:
  `tournaments_live.ex` (1 use), `norms_live.ex` (7) and `players_live.ex`
  (2) - which is what `app.css`'s own comment says ("Players, Norms and
  Tournaments"). None of them uses `.set-*` at all.

  The condition the note set for revisiting is "only if Settings' layout
  system is ever extended app-wide". It has not been: `.set-*` is used by the
  Settings pages, Categories and Registrations, all of which are
  settings-shaped, and nothing else has reached for it.

  Converting the three would be a regression rather than a tidy-up.
  `.set-*` is one column because settings are read top-to-bottom and mix
  stacked fields with toggle rows; those three are data-entry forms where the
  auto-fill grid is the right layout and a single column would waste most of
  a wide screen. Two layout systems here is two answers to two questions.

  **The grid did have a real bug, found 2026-08-29** by the maintainer
  ("boxes all over the place" on the New tournament form), and it was not the
  one this note was about. `.form-grid` had no rule for children that are not
  fields, so a bare `<p class="hint">` took an auto-fill cell and landed
  beside an unrelated input - and because it occupied a COLUMN, a conditional
  hint appearing reshuffled everything after it. Three inline
  `margin-top` values were papering over it.

  Fixed as one shared rule (`.form-grid > .hint, > .error-note, > .ok-note`
  span `1 / -1`), so a hint sits under its own field and appearing inserts a
  row. The child combinator matters: a hint nested inside its own
  `label.field` is untouched. `players_live.ex` and `norms_live.ex` were
  checked and do not have the bug - they keep hints outside the grid or
  inside a field - so the rule is a no-op there today and a guard rail
  later. The decision above is unchanged: the grid stayed.
- ~~Round robin's `total_rounds/2` vs. a user-set `rounds_count`~~ -
  **shipped**: this used to disagree in the UI (an arbiter could set
  `rounds_count` to anything, mismatching what the Berger schedule for
  their actual roster needs - real complaint: "I get too many rounds").
  `RoundRobin.pair_next_round/1` now corrects `rounds_count` to the real
  schedule total the moment players are frozen, every call - round-robin's
  length was never a free-standing choice the way it is for Swiss, it's a
  pure function of player count + cycles/match-format. Round-robin also
  now pairs its whole schedule in one action (`RoundRobin.pair_all_rounds/1`,
  confirm-gated on the Pairings page's "Pair the whole tournament" button)
  instead of one round at a time, since a round-robin round's pairings
  never depend on prior results - closing the "I don't see all rounds in
  advance" complaint too, since the whole schedule now exists right after
  that one click.

## Still open from the 2026-08-26 sweep

The bug-severity findings from [docs/sweep-2026-08-26.md](docs/sweep-2026-08-26.md)
that no commit has closed. All were filed as leads, not as confirmed bugs.
Three of them were adjudicated on 2026-08-27 - two confirmed, one refuted -
and that pass turned up a fourth. Full evidence and line references are in
that document's "Three leads, adjudicated 2026-08-27"; this is the index.

- ~~**Keizer's `classify_result` catch-all scores an unscored pairing as a
  played loss**~~ **Fixed 2026-08-29.** `played`/`wins`/`draws`/`losses`
  stayed confirmed-dead (nothing renders them), but `raw_points` was not -
  proved with a non-zero `points_loss` in a test first (played 1, losses 1,
  `raw_points` inflated by exactly `points_loss` for a board with no result
  at all), then fixed, then reproved at 0. `classify_result/2` now has its
  own class for a blank result (`:not_played`), scored as nothing by both
  `class_points/4` and `round_stats/2` - the same rule
  `Standings.pairing_records/4` already applied to the equivalent FIDE-path
  state, now implemented once instead of twice. Original note: Keizer's
  `classify_result` catch-all scores an unscored pairing as a
  played loss** (`lib/pairings_engine/keizer.ex:605`). A paired-but-unscored
  pairing carries `result: ""`, falls to `_ -> :zero`, and `round_stats/2`'s
  `:zero` bucket increments both `played` and `losses`, where
  `Standings.pairing_records/4` returns `[]` for the same state.
  **CONFIRMED as a defect, harm refuted**: `played`/`wins`/`draws`/`losses`
  are dead fields - returned by `Keizer.standings/2` and read by nothing, and
  all four Keizer surfaces render Score only. The one live effect is
  `raw_points` inflated by `points_loss` per unreported game, which is 0.0
  by default. Low priority, but it is two implementations of one rule.
- ~~**`adjusted_score/3` mixes a record count with a round number**~~
  **Fixed 2026-08-28.** `rounds_played_count/1` is gone entirely and
  `completed_rounds/2` replaced it - the highest round in which every pairing
  has a result, counting bye-only rounds - carried on each standings entry and
  threaded into both `adjusted_score/3` and the Koya threshold. That is the
  third horizon this note prescribed, and it was the one open finding with a
  wrong number on an arbiter's screen.

  The original note:

- **(historic) `adjusted_score/3` mixes a record count with a round number**
  (`lib/pairings_engine/standings.ex:770`). `missing_tail` subtracts a round
  number from `rounds_played_count/1`, which counts records, so one board
  reporting first can hand every un-reported player's opponents a phantom
  draw on Buchholz/BHC1/BHC2/MBH/SB, and move Koya's 50% threshold a full
  win at the same instant. **CONFIRMED - and the cause and cure both need
  correcting.** `rounds_played_count <= round_horizon` always (one record
  per player per round, both global maxima), so swapping to `round_horizon`
  as this document first proposed pads MORE, not less. The fix is a third
  horizon: the highest round in which no pairing still has `result: ""`,
  threaded into both `adjusted_score/3` and `tiebreak("KS", ...)`. This is
  the one open finding with a wrong number on an arbiter's screen.
- ~~**The public standings page ignores the per-round publish gate**~~
  **Moot 2026-08-29** - that page was removed with the rest of the local
  public pages, so the code the finding pointed at is gone.

  The PRODUCT question it left open - should withholding a round withhold its
  results too? - is now answerable in a way it was not then: standings and
  round pairings are separate switches on the results site, so an arbiter who
  wants the rounds without a league table, or the table without the rounds,
  can have either. What is still not offered is "show the standings but
  compute them as if round 5 had not happened", and nobody has asked for it.

  The original note:

- **(historic) The public standings page ignores the per-round publish gate**
  (`lib/pairings_engine_web/live/public_standings_live.ex:72`). It calls
  `Standings.standings/2` with no `through_round` and counts every `rounds`
  row, so in manual or timed publish mode it shows a round the public
  pairings page one link away deliberately hides. **REFUTED as a bug** - the
  settings card is headed "Public pairings" and names `/p/<slug>/pairings`
  literally, and the unpublish confirm, `round_published?/2`'s `@doc` and the
  CHANGELOG entry all scope it the same way. Open only as a PRODUCT
  question: should withholding a round withhold its results too?
- ~~**`Ainalrami.Pairing.explain_round/3` drops `:point_system`**~~
  **Closed 2026-08-28.** It was fixed upstream by `4dd9980` and waiting on the
  pin, which was `v0.11.1`. The pin moved to `v0.14.0` for the Article 5.2.5
  ruling, and `4dd9980` is an ancestor of it - confirmed by
  `git tag --contains`, which lists v0.12.0, v0.13.0 and v0.14.0.
- ~~**A vacated seat pays the player left on the board a half-value Keizer
  bye.**~~ **Fixed 2026-08-28.** A vacancy and a bye differed only by their
  result code, and `score_game/3` collapsed both into one branch; that code
  is now what tells them apart, and a vacated seat scores 0.0.
  `award_bye_for_vacancy/2` still pays, because that is the arbiter
  choosing to. Original note: a vacated seat pays the player left on the board a half-value Keizer
  bye** (`lib/pairings_engine/keizer.ex:561`). `score_game/3` treats any
  pairing with `opponent_id == nil` as `:unpaired_bye` worth half the
  player's own ladder value, and `do_vacate_seat/3` writes exactly that
  shape - so vacating a seat pays the REMAINING player until the arbiter
  runs `award_bye_for_vacancy/2`. Found while adjudicating the three above;
  unlike the `classify_result` one, this is a real points effect. The Swiss
  path gives them nothing.
- ~~**`Standings.bye_points_for_row/2` fires one COUNT query per rendered
  bye row.**~~ **Fixed 2026-08-28.** The query now runs only where its
  answer can change the result - never, for a tournament that is not a SWAR
  import configured with a cap. A telemetry test counts queries beside the
  ones pinning values, so the numbers are provably unmoved. Original note:
  `Standings.bye_points_for_row/2` fires one COUNT query per rendered bye
  row** (`lib/pairings_engine/standings.ex:347`), an N+1 inside four render
  loops. `add_bye_records/3` already does the same count in one in-memory
  pass; the display path never learned it.

## FIDE endorsement readiness (pre-2026 cycle)

> Written against FIDE's earlier Annex 4 checklist. Superseded in scope by
> the 2026 Acceptance Cycle section at the top of this file - kept because
> the shipped items below are still shipped, and the reasoning is still the
> record of why they were done that way.

Full checklist, current status per item, and the testing-harness plan live
in [`docs/fide-endorsement.md`](docs/fide-endorsement.md) (built from FIDE's
own Annex 4 Verification Check List and Annex 1 endorsement form). Concrete
gaps identified there, extracted here as actionable items:

- ~~Lock `pairing_number` after round 4 is paired~~ (VCL.09) - **shipped**:
  `Tournaments.update_player/2` now rejects changing an already-assigned
  number once 4 rounds are paired; a first assignment (late entry) still
  always works.
- ~~Asymmetric ½-0 / 0-½ result support~~ (VCL.13) - **shipped**: the TRF16
  spec itself has no cross-validation rule between the two sides' codes
  (that was `Trf`'s own invention) - it's just `=` for the ½ side, `0` for
  the 0 side. Wired through the schema, result-entry UI, standings scoring,
  TRF export/import (both directions), Keizer's own scoring, and SWAR
  import (which already had bitfield codes for this, previously dropped as
  unmappable). See `docs/fide-endorsement.md`'s VCL.13 entry for the file
  list.
- ~~Fuzz-testing harness - but not a pairing checker~~ - **shipped**: (1)
  `test/pairings_engine/trf_property_test.exs` - `StreamData` property tests
  on `Trf.serialize/1` against random-but-legal rosters/histories, checked
  against ground truth via `parse/1` round-tripping rather than re-deriving
  `Trf`'s own column positions; (2)
  `test/pairings_engine/cross_program_test.exs` - runs OpenPairings' real
  `Pairing.pair_next_round/1` (JaVaFo) against `bbpPairings` (Bierema Boyz
  Programming, Apache-2.0, vendored in `priv/bbppairings/` - a genuinely
  independent second Dutch-system implementation, not JaVaFo again) on
  byte-identical TRF16 input, diffing the actual pairing every round across
  `PAIRING_FUZZ_COUNT` (default 8, set much higher for a deliberate
  "throw a pile of random tournaments at it" pass) synthetic tournaments.
  Both tagged `:javafo`/`:bbppairings`, gated in `test_helper.exs` exactly
  like the existing `:swar_fixture` pattern.
  **First real finding, not yet resolved**: a `PAIRING_FUZZ_COUNT=200` run
  found ~6 disagreements (~1.2% of rounds) on small rosters (5-13 players),
  always a same-score-group-splitting choice in an otherwise-legal
  situation (verified against JaVaFo run standalone, bypassing OpenPairings
  entirely, to rule out an OpenPairings-side bug) - needs FIDE Dutch-system
  rules research to tell whether this is a bbpPairings quirk, a JaVaFo
  quirk, or a genuinely underspecified tie-break FIDE's own rules leave
  open; the harness's exact job is surfacing this, not resolving it.
- ~~TRF06 import~~ (VCL.11, recommended not mandatory) - **shipped**: read
  FIDE's actual archived TRF06 specs (2006 and 2016 versions) rather than
  guessing - column positions are byte-identical to TRF16, so no separate
  importer was needed, just tolerating TRF06's older bye convention (a
  dangling playing code, no F/H/U/Z). Verifying this surfaced and fixed two
  real `Trf` bugs along the way - see `docs/fide-endorsement.md`'s VCL.11
  entry.
- ~~Two smaller "needs verification" items~~ (UTF-8 response headers on the
  TRF export, no accidental "FIDE"-branded claim about OpenPairings itself
  in the UI) - **both verified**: UTF-8 was already correct (confirmed via
  `Plug.Conn`'s own source, locked in with a test); the login page's hero
  copy had one real overclaim ("FIDE-compliant pairings..."), reworded.
- ~~Trailing pairing-allocated byes scored as draws instead of their
  awarded value~~ (VCL.19) - **shipped**: found while auditing
  `standings.ex` against FIDE's C.07 revision effective 1 March 2026
  (Art. 16.2.1/16.3). `Pairing.result == "bye"` (JaVaFo's own
  odd-player-count byes) was marked `voluntary: true` - inconsistent with
  the `byes`-table path, which already excluded `"pairing-allocated"` from
  its own `voluntary` set. A trailing occurrence (the common last-round
  case) made `adjusted_score/3` substitute a draw's worth of points for
  the bye's real value in every opponent's Buchholz/SB. See
  `docs/fide-endorsement.md`'s VCL.19 entry.
- ~~C.07's new Art. 16.5.1 "Cut-1 Exception"~~ (VCL.19) - **shipped**:
  BHC1/BHC2/MBH now cut a contribution from one of the participant's own
  voluntary unplayed rounds (a bye, via `dummy_score/3`) in preference to
  an ordinary game contribution, reusing the existing `voluntary` flag as
  the VUR tag. See `docs/fide-endorsement.md`'s VCL.19 entry.
- ~~SWAR's "absent" bye type unconditionally treated as voluntary~~ -
  **shipped**: new `Tournament.absent_counts_as_vur` setting, **on by
  default** since 0.17.1 (`tournament.ex:128`). On means an absence is
  treated as a voluntary unplayed round, the same as a requested bye, so a
  trailing one is downgraded for opponents' tie-break purposes; an arbiter
  can turn it OFF from Settings for the stricter reading, where an absence
  always counts at its award value like a forfeit loss.

  This entry had the polarity backwards - it said "off by default" and then
  described the off behaviour as the default one. `docs/fide-endorsement.md`,
  the document with compliance weight, has always had it right. Corrected
  2026-08-30.

## Backlog (no particular order, nothing blocking)

- ~~**History page (`/t/:id/history`) reported as "just a read-only thing"**~~
  - **answered 2026-08-16.** Nothing was broken: the restore buttons only
  render on entries that ARE restore points, and `Snapshots.capture/4` was
  reachable from exactly four handlers, all in `PairingsLive` (pair a round,
  unpair one, pair a whole round-robin schedule, import results by CSV). A
  tournament run by hand - players edited, settings tuned, results typed in
  - therefore had zero snapshots, hence zero buttons, hence a page that
  reads as a list you can only look at. Shipped: a "Save a restore point"
  action on the page itself (`"snapshot.manual"`), plus an honest empty
  state saying there are none yet and why. The moduledoc's stale
  "Read-only" claim is corrected too.

  Deliberately **not** done at the same time: broadening the automatic
  capture triggers. Adding one before, say, every settings save or every
  result entry would change snapshot volume and storage for every existing
  tournament (these are full tournament copies, `@keep_per_tournament 50`
  of them), so it wants its own decision rather than riding along. The
  candidates, if that decision is ever taken: bulk player import, "assign
  categories" / extra-points apply (both rewrite every player in one
  click), and manual-standings re-seed. Single-field edits are not
  candidates - they're already reconstructable from the audit trail's
  before/after diff.

  The second half of the same report - something colliding into the
  "Everything" filter button - was a layout bug, not a filter-state one,
  and is fixed too: the first day heading's opaque rail mask overhung 6px
  upward into the filter row directly above it. See the CHANGELOG entry.

- ~~"Substitute player" draws its journey arrow on the wrong seat~~ -
  **shipped 2026-08-15, the "bigger redesign" option**: `matchTravellers()`
  in the `.SwapArrows` hook matches purely by NAME across the whole modal,
  not per-row (see its own extensive comments) - `confirm_for/2`'s
  `:swap_pool` branch now adds a second "Not playing list" row (new
  `bench_card/1` component, single-seat, no colour disc) showing the pool
  player on "before" and the seated player on "after". Because those two
  names already appear once each on the real board row's opposite side,
  the UNCHANGED hook now finds a clean match for both and draws two real
  arrows - one in, one out - exactly as asked, with zero changes to
  `matchTravellers()`/`render()` themselves. The previously-misleading
  phantom arrow on the *unaffected* seat (e.g. white, when black was
  substituted) still fires - the hook's own stated philosophy is "everyone
  shown gets an arrow, the ones who stayed put get a short one back to
  their own seat" - but it's no longer the sole, unexplained arrow on
  screen; it now sits alongside two clearly-purposeful in/out arrows, so it
  reads as "white stayed" rather than as a wrong-looking swap. Not
  separately suppressed - consistent with how a real 2-board swap already
  shows a short "stayed" arrow for an unmoved board partner.

- ~~**Chief arbiter (and the other Officials fields) are unfindable without
  the link.**~~ **Cheap fix shipped**: Settings > Tournament grew an
  "Officials" card that names the Norms page, links to it, and shows the
  current chief arbiter (or says it is unset and that this does not block
  pairing -- it is a *recommended* field, not a required one). It edits
  nothing; the point is that Settings is no longer silent about a field it
  plainly looks like it should own. The fuller fix below -- moving Officials
  back to Settings -- is untouched and still open, deliberately: it needs a
  decision about what Norms is then for.

  Original report, kept for that decision: they live on `/t/:id/norms`,
  moved there from SettingsLive at some point (see `norms_live.ex`'s
  "relocated from SettingsLive" notes). Nothing is broken - the "ready to pair" hint on PairingsLive links
  straight to the right page via `setup_field_path/2`, and the field saves
  fine - but an arbiter looking for "chief arbiter" will look under
  **Settings**, not under a page called **Norms**, and there is nothing on
  Settings pointing them onward. Reported by the maintainer, who could not
  find it even while holding the link.

  The cheapest fix - a pointer in the Settings → Tournament card - is the
  one that shipped. What is still open is the fuller move.

- ~~"Players - title-norm judgment" table has no meaningful sort order~~ -
  **shipped**: `players_by_norm_relevance/2` now sorts achieved-norm
  players first, then closest-to-qualifying (fewest failing B.01 checks on
  their nearest-miss title), then no-games players last.
- ~~"Explain a round" score-bracket map misplaces handicap-table players~~ -
  **shipped, real confirmed bug**: SWAR assigns accessible/"handicap table"
  pairings a per-round Table number starting at 1001 (`TABLE_HANDICAP + N`,
  Swar.h) - not a real board number, just like the `TABLE_BYE` sentinel
  already handled. The importer was copying it verbatim into `board`, so a
  handicap-table pairing (confirmed via production tournament 18, round 5,
  Vandekerckhove Ava - `board: 1001` in the actual DB row) sorted to the
  far end of anything ordered by board number, including the rationale
  bracket map, regardless of real score. `SwarImport.finalize_boards/1` now
  renormalizes a handicap-range Table value the same way it already did for
  byes. Only fixes *future* imports - tournament 18's existing round-5 row
  still has the raw 1001 in the DB; a one-off data fix there is separate,
  deliberately not done without asking first (touches live tournament
  data).
- ~~Public standings page needs to be a clean spectator overview~~ -
  **shipped**: `/p/:slug/standings` and `/p/:slug/pairings` now render
  through a new minimal `Layouts.public/1` (brand + theme switch only, no
  tournament tabs/accent picker/sign-in) instead of the full authenticated
  `Layouts.app/1`, and both show a compact arbiter/deputy/tempo/round-dates
  line (`PairingsEngineWeb.Components.PublicTournamentMeta`) when set.
- ~~Printed standings/pairings pages don't carry the arbiter/tempo/
  round-dates line~~ - **shipped**: `PrintController`'s shared
  `tournament_info_html/1` (already used by every print doc - pairings,
  standings, player list/cards, crosstable, place cards, result cards) was
  missing deputy arbiter and the per-round dates list (`round_dates`,
  distinct from the free-text `start_date`/`end_date` it already showed).
  Both added as their own line items, labeled "Deputy arbiter" and "Round
  date(s)" to stay unambiguous next to the existing "Dates: start - end".
- **Audit OpenPairings' logic against SWAR's own C++ source, file by
  file.** Very low priority - this is a "nice to have more confidence,"
  not a response to anything currently broken. Scoping notes from
  discussing it: SWAR's source is ~74k lines/135 files total, but almost
  all of that is UI/vendored-library noise; the actually-comparable
  business logic is ~14 files / ~15,600 lines / ~490 functions
  (`Utils.cpp`, `Joueur.cpp`, `Classement.cpp`, `Categories.cpp`,
  `Tournoi.cpp`, the four `Pairing*.cpp` files, `Pairtwo.cpp`,
  `EnvoiJAVAFO.cpp`, `ImportTrfFile.cpp`, `ImportCsv.cpp`,
  `XtraPoints.cpp`). A full function-by-function pass is genuinely
  multiple days of work for uncertain payoff, since most of those
  functions are mundane and will never diverge. If this ever gets picked
  up, prioritize the highest-risk subset instead of going exhaustive:
  `Classement.cpp` (tiebreaks), `Utils.cpp` (shared edge-case logic - this
  is where the round-specific-absence bug lived), and `EnvoiJAVAFO.cpp`
  (SWAR's own TRF builder, directly comparable to
  `Pairing.javafo_input`/`TrfExport` - the class of bug already found
  twice). Both real bugs found so far came from symptom-driven
  investigation (a real tournament comparison surfacing something odd,
  then a targeted SWAR-source dive), not exhaustive pre-auditing - that's
  the higher-leverage pattern to keep leaning on rather than this.
- Remaining SWAR-parity items: hard pairing variants (accelerated pairing
  beyond Baku, more exotic tiebreak orderings) and printing extras beyond
  what's in `docs/printing.md`.
- Extend the automatic B.01 title-norm judgment
  (`PairingsEngine.Norms.TitleNorms`) to the documented-but-unmodelled
  exemptions. Currently conservative (never claims a norm the numbers don't
  strictly support), which is the safe default but under-counts in specific
  event types. What is actually left, after checking each against the
  handbook text rather than against this list:

  - **Federation-mix exemptions (1.4.3 a-d).** Still open, and the one that
    bites in practice: a national championship or zonal is exempt from the
    "two other federations" rule, so a Belgian national championship where
    most opponents are Belgian reports `foreign_federations` and
    `own_federation_share` as failing when the norm is valid. Needs a
    tournament-level event-type field, which is a schema change plus a
    Settings control plus arbiter discipline in filling it in. One clause -
    1.4.3's big-Swiss case (20+ FIDE-rated players from 3+ federations,
    10+ GM/IM/WGM/WIM title-holders per round) - is auto-detectable from
    data already held and needs no new input.
  - **7/8-game concessions (1.4.1.1-1.4.1.3).** Still open. World Team/Club
    and Continental Team/Club Championships, the World Cup, and the
    unplayed-last-round-win case. Same event-type dependency.
  - ~~**Double-round-robin titled-opponent halving.**~~ **Not a gap - this
    entry was wrong**, and acting on it would have introduced a real bug in
    the dangerous direction. The requirement is already satisfied, because
    the two sides count in different units: `counted_games/2` emits one
    entry per GAME, so a DRR opponent is counted twice, while the Annex
    counts distinct people ("Different MO"/"Different TH") and halves the
    requirement to compensate. Halving `high_needed` on top of the per-game
    count would have asked for ONE distinct titled opponent where FIDE asks
    for two. `title_norms_test.exs` now pins both sides of that boundary.
    (The article number in the old text was wrong too - it is 1.4.5's final
    clause, not 1.4.3d.) The companion "DRR needs 6+ players" rule is
    likewise redundant: a 5-player DRR is 8 games, which the 9-game minimum
    already refuses.
- ~~Standalone binaries (`docs/binaries.md`) have no automated smoke test in
  CI beyond "it builds"~~ - **they have had four since before this was
  written.** `.github/workflows/binaries.yml` boots a real target and curls
  `/` for each of the binary and the portable release, on Unix and Windows
  (`:125`, `:167`, `:209`, `:241`). Corrected 2026-08-30.
- ~~Re-uploading a `.swar` file for a tournament already in OpenPairings
  creates a second, duplicate tournament instead of updating the existing
  one~~ - **first step shipped**: `tournaments.swar_guid` is now stored on
  import, and re-uploading a file whose GUID matches a tournament the
  uploader can already reach shows a warning ("This looks like a
  tournament you already have") with the choice to open the existing one,
  import as a new tournament anyway, or cancel - instead of silently
  creating a duplicate. Still open: a full field-level *merge* (rebuild
  rounds/results without clobbering OpenPairings-only edits like
  norm_data, manual ranking, extra points, forbidden pairings) - that's
  real additional work beyond the detect-and-ask step and deliberately not
  scoped yet.

## Process notes for whoever picks this up next

- `mix precommit` (compile --warnings-as-errors, deps.unlock --unused,
  format, test) is the pre-flight check; CI runs the equivalent.
- `mix format --check-formatted` must stay green - the whole repo was
  normalized to pass it in 2026-07-25; don't let it silently regress by
  editing with a tool that reintroduces CRLF (`.gitattributes` pins source
  files to LF, but a misconfigured editor can still fight it locally).
- Never commit `Co-Authored-By`/`Generated with Claude Code` trailers to
  this repo - an explicit, standing maintainer preference.
- `docs/AGENTS.md` and this file were written in a single documentation
  pass (2026-07-25); nothing enforces they get updated when the code moves
  on. Treat any obviously stale claim in either as a bug, not gospel - see
  the note at the top of `docs/AGENTS.md`.
