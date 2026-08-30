# Follow-up on the 2026-08-26 sweep's unaudited sections

The original sweep's own "Still open" section named three groups nobody had
looked at: the 7 optimizations, the 15 "worth adding" items, and the 27
"drift and inconsistency" items - 49 items, three days of heavy change since.
This reads all 49 against `HEAD` (not against TODO.md, not against the sweep
itself) and buckets each one.

**39 of the 49 are still real, in whole or in part. 10 are resolved** - 6 by
an actual code or doc fix, 2 because the feature they described was removed
entirely (the local public pages), and 2 because the file they point at
isn't part of this repository at all (it's vendored Ainalrami documentation
under `deps/`, gitignored). None turned out to be flatly wrong when written -
every one of the 49 was describing something real at the time, which says
the sweep's care extended past the sections that got adversarially checked.

The single most useful item in the list is **Q208** (`Worth adding #7`,
`standings.ex:802-816`): ARO/AROC1 average an unrated opponent's rating in as
a literal `0`, which is a 2000-point-wide vote in a tiebreak that decides
prize placement. Unlike most of what follows, this needs no unusual
configuration to trigger - any tournament with one unrated player in it is
enough - and the fix is one function once C.07 Art. 10 is read to pick
between "exclude" and "substitute a floor." It ranks below a couple of
items below only because those are marginally cheaper and more certain
fixes; as a return on a few hours of work, this is the best one on the page.

Two more are worth reading before the ranked list: `PlayerCard` shows an
opponent's score inflated by extra points they didn't earn on the standings
table (`Drift #17`), and a collaborator's Tournaments page can silently keep
listing a tournament its owner already deleted (`Drift #22`). Both are live,
both are one-paragraph fixes, and both are things an arbiter would actually
notice.

---

> **Verify before acting.** This assessment was written on 2026-08-29
> while other work was landing in the same tree, so an entry can be
> closed by a commit made after it was read - two already are (#4, #23).
> Check the code, not this document, exactly as this document was
> written by checking the code rather than the sweep it assesses.

## Still real, ranked by cost to a user

### 1. PlayerCard shows an opponent's score inflated by points they don't rank on

`lib/pairings_engine/player_card.ex:36` and `:173` — **[Drift #17]**

Unchanged. `row/4` builds `opponent_total: opponent && opponent.total` (line
36) while the same function's footer correctly uses `entry.points` for the
card owner's own side (line 173). `Standings.rank_score/2`'s own doc calls
reading `entry.total` directly "almost always a bug" for exactly this
reason - it counts a player's administrative extra points in a tournament
that doesn't rank on them, which is the default (`count_extra_points:
false`).

Consequence: right-click a player with a non-zero `extra_points` in an
ordinary tournament, and their opponent's card shows a total the standings
table would deny. The fix costs one line - `row/4` already receives
`tournament` (line 24), so `Standings.rank_score(opponent, tournament)`
drops straight in - which is exactly why this is the highest-value item on
the page next to Q208: real, currently reachable with the default settings,
and a five-minute fix.

### 2. A collaborator's Tournaments page goes stale on delete/archive/restore

`lib/pairings_engine/tournaments.ex` — `soft_delete_tournament/1`,
`restore_tournament/1`, `archive_tournament/1`, `unarchive_tournament/1`
(all still `broadcast_user_tournaments(updated.user_id)` only) —
**[Drift #22]**

Unchanged, confirmed at all four call sites plus `create_tournament/2` and
`update_tournament/2`. `TournamentsLive` still subscribes only to
`Tournaments.user_tournaments_topic(current_scope.user.id)`
(`tournaments_live.ex:34-36`) - the current user's own topic. The
collaborator-specific functions (`add_collaborator/3`, `remove_collaborator/3`,
`leave_tournament/2`, `accept_invitation/2`, `link_pending_collaborators/1`)
all correctly fan out to the non-owner's topic; the seven tournament
lifecycle writes never do.

Consequence: an owner deletes, archives, or restores a shared tournament,
and every collaborator's open Tournaments page keeps showing the old state
until they manually reload - a deleted one 404s on click, an archived one
still looks live and writable in their table. This is the one item on the
page that is a straightforward correctness bug in a real, shipped,
multi-user feature (collaboration), not a performance or compliance gap.

### 3. Password log-in has no rate limit; every sibling public endpoint has two

`lib/pairings_engine_web/controllers/user_session_controller.ex:33-64` —
**[Worth adding #13]**

Unchanged. `RateLimit.` is called from `fide_lookup_controller.ex`,
`mobile_enroll_controller.ex`, `user_live/login.ex` (magic link) and
`user_live/registration.ex` - not from `user_session_controller.ex`. The
email+password branch (`create/3`, line 33) calls
`Accounts.get_user_by_email_and_password/2` (line 52) directly, with no
`RateLimit.allow?`/`record` anywhere in the module.

Consequence: an attacker can walk a password list against any account with
no ceiling but bcrypt's own cost, on a route reachable with only a CSRF
token from the public log-in page. Passwords are the secondary path here
(SSO and magic links are primary), which is the sweep's own reason for
filing this as a suggestion rather than a bug - but "secondary" isn't "unused,"
and every other unauthenticated endpoint in this app got a bucket
deliberately. `RateLimit`'s own moduledoc describes itself as covering
exactly this class of route.

### 4. ~~ARO/AROC1 score an unrated opponent as a literal zero~~ FIXED 2026-08-29

> **Closed the same day this was written, and the fix below is NOT the
> one that shipped.** This entry proposes excluding `rating == 0`
> opponents from the average or substituting a floor. C.07 Article 10,
> read directly, offers neither: it says the tie-break "must be dropped
> from the tournament tie-break list when unrated players are present"
> unless the regulations or the Chief Arbiter published a rule
> beforehand. FIDE gives no substitute rating, so both proposals here
> would have invented the rule it declined to write.
>
> `Standings.effective_tiebreaks/1` drops the code instead. The
> analysis below is kept because the diagnosis was right even though
> the prescription was not.

`lib/pairings_engine/standings.ex:797-816` — **[Worth adding #7 / Q208]**

Unchanged.

```elixir
defp aro(entry, by_id, cut_lowest) do
  ratings =
    entry.games
    |> Enum.filter(& &1.played)
    |> Enum.map(fn g -> opponent(g, by_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PairingsEngine.Tournaments.Player.rating(&1.player))
    ...
```

`Player.rating/1` (`player.ex:333-341`) returns `0` for a player with
neither a FIDE nor a national rating - correct for its other callers (sort
keys), wrong here: in an average, `0` isn't a missing value, it's a
2000-point-wide vote. TODO.md lists "Unrated players in rating-based
tie-breaks (Q208, 32%)" as an open VCL penalty without saying where it
bites; this is where. See the summary above for why this ranks where it
does - see it here for the fix: read C.07 Art. 10, then either exclude
`rating == 0` opponents from both numerator and denominator of `aro/3`, or
substitute the regulation's floor. One function, and it's the one place on
this whole page where getting it wrong changes who wins a prize.

### 5. `safe_path/1` turns a crafted URL into a 500 instead of a redirect

`lib/pairings_engine_web/controllers/locale_controller.ex:34-38` —
**[Drift #24]**

Byte-for-byte unchanged from the sweep's citation. Phoenix 1.8.11 (still the
pinned version, `mix.lock`) rejects any local URL containing `\`, `/%09` or
`/\t` (`@invalid_local_url_chars`, `deps/phoenix/lib/phoenix/controller.ex:507`),
and `safe_path/1`'s own guard only checks for a leading `//`. `GET
/locale/en?redirect_to=/%5Cevil.com` still reaches `redirect(conn, to:
"\\evil.com")`, which still raises.

Not an open redirect - Phoenix's own check stops the send - but an
unauthenticated visitor gets a 500 page where the code intends a redirect.
Low blast radius (one route, one ugly error page, no data exposure), which
is why it ranks here rather than higher; still a one-line fix:
`String.contains?(path, ["\\", "/%09", "/\t"])` added to the existing guard.

### 6. ~~Pairing a large or categorized tournament redoes work it already has~~ FIXED 2026-08-30

> All four parts. `do_pair_single/4` builds the run's shared history up
> front and threads it through `order_for_pairing/3` and
> `javafo_input/5` - `order_for_pairing/3`'s nil default is gone, since
> that default WAS the bug. `build_shared_history/1` now also carries the
> forbidden-pairing list (read twice per TRF build before, so ten times in
> a five-category run) and, via `precompute_games/2`, each player's TRF
> game list - the O(N x R) walk that ran once per category. `active_players/1`
> is read once per run and threaded, with `eligible_from/2` split out of
> `eligible_players/2` for the filtering half.
>
> Measured on identical probes against the previous commit: a 16-player
> single-pool round 2 went 43 -> 35 queries, a 16-player four-category
> round 1 went 96 -> 87, and the marginal cost per category is now flat at
> 17 (its own engine call and board inserts). The sweep's own framing holds:
> the engine call dominates, so this is housekeeping.
>
> The unused `preload: [:player_a, :player_b]` on
> `Tournaments.list_forbidden_pairings/1` is deliberately LEFT: the Settings
> page (`settings_options_live.ex:96`) reads the preloaded structs to print
> player names, and it is now read once per pairing run rather than twice
> per category, so the preload costs that run one extra join instead of ten.

`lib/pairings_engine/pairing.ex` — see line list below — **[Optimizations #1
and #2]**

Both confirmed unchanged, and worth reading together since they're the same
shape at two different scopes.

**Single-pool path** (`do_pair_single/4`, `pairing.ex:408-437`): calls
`order_for_pairing(tournament)` at line 409 with no `shared_history`, then
`javafo_input(...)` at line 420, which calls `trf_player_rows(tournament,
players)` at line 1532 - also with no `shared_history`. Each nil default
re-triggers `build_shared_history/1` (3 queries, `pairing.ex:2152+`) and the
O(N x R) `Enum.find` walk inside `games_per_player/3` (`pairing.ex:2094-2136`).
The category path (`do_pair_by_category/4`, `pairing.ex:461-501`) does this
correctly - `shared_history` computed once at line 470, threaded at line
482 - which is exactly the reference implementation the single-pool path
should be calling. Separately, `active_players/1` is still queried three
times per run: `pair_next_round/1:111`, inside `eligible_players/2:2044`,
and again inside `do_pair/2:334`.

**Per-category path** (`build_category_trf/5`, `pairing.ex:719-742`): even
with `shared_history` threaded correctly, `trf_player_rows(full_roster,
shared_history)` at line 728 still re-runs the O(N x R) walk once per
category, since `shared_history` only saves the three DB queries, not the
in-memory computation. And `engine_trf/5` (`pairing.ex:757-784`) calls both
`forbidden_pairs/3` (line 776) and `exclusion_pairs/3` (line 777)
independently, each of which calls `Tournaments.list_forbidden_pairings/1`
on its own (`pairing.ex:1602`, `:1625`) - which still carries an unused
`preload: [:player_a, :player_b]` (`tournaments.ex:1825-1832`). Neither
caller reads the preloaded structs, only `.player_a_id`/`.player_b_id`. That's
6 queries per category for data that's identical across all of them.

Real, but reason about the actual cost rather than the sweep's raw
comparison count: the dominant latency in a pairing click is very likely the
external engine call itself (a JVM spawn for JaVaFo, or the Ainalrami NIF/
port), not this. The category multiplier is the part that scales badly - 5
categories means 5x the redundant CPU walk and 30 queries where 5 would do -
so this is worth fixing on any install that actually uses pair-by-category
with more than 2-3 categories, and safe to leave alone otherwise.

### 7. ~~"Pair the whole tournament" rewrites `rounds_count` once per round~~ FIXED 2026-08-30

> `pair_all_rounds/1` freezes, reads the roster and corrects `rounds_count`
> ONCE, then loops on `do_pair_next_round/2` with the corrected struct -
> which is what `pair_next_round/1` was already doing per call, only now the
> correction survives the recursion. Also removes a `Repo.exists?` and a
> roster read per round. A test subscribes to the tournament topic and
> asserts exactly one `:settings` broadcast against five `:rounds` ones.

`lib/pairings_engine/round_robin.ex:97-154`, `:318-354` —
**[Optimization #4]**

Unchanged, and now higher-stakes than when the sweep wrote it: TODO.md
confirms `RoundRobin.pair_all_rounds/1` is wired to a real, shipped button
("Pair the whole tournament" on the Pairings page), not a theoretical API.
`pair_all_rounds/1` (line 143-154) recurses at line 146 with the *original*
`tournament` argument - `ensure_correct_rounds_count/2`'s correction (line
318-354) is local to `pair_next_round/1`'s own call and never makes it back
to the caller. So every round of a double round-robin re-detects the same
mismatch and calls `Tournaments.update_tournament/2` again, which still
fires `broadcast_tournament_change(:settings)` + `broadcast_user_tournaments/1`
every time (`tournaments.ex:583-594`). A 14-player double round-robin still
issues on the order of 26 redundant writes and 52 redundant broadcasts
inside one click. Nothing breaks - the loop still terminates correctly -
it's wasted writes and PubSub churn on a real, present-tense button.

### 8. ~~No index on `tournament_collaborators.email`~~ FIXED 2026-08-30

> `20260830100000_index_collaborator_email`. The item's own caveat stands -
> this table is small and nothing measurable was being lost - but the plan
> did change: `EXPLAIN QUERY PLAN` on the `user_id OR email` match went from
> a full `SCAN tournament_collaborators` to a `MULTI-INDEX OR` over both
> indexes, and a test asserts the scan does not come back.

`priv/repo/migrations/20260711100000_create_tournament_collaborators.exs:25-26`
— **[Optimization #7]**

Confirmed: still only `unique_index([:tournament_id, :email])` and
`index([:user_id])`; no migration since adds one on `email` alone.
`collaborator_tournament_ids/1` (`tournaments.ex:264-266`) still does
`c.user_id == ^user.id or c.email == ^user.email` with no index serving the
email half, and it's now used at four call sites (`tournaments.ex:134, 177,
256, 1113`), including inside `list_tournaments/1` - a subquery run on every
authorized page mount.

Ranked below the pairing-performance items because the sweep never
estimated this table's actual size the way it did for `kbsb_players`
("tens of thousands of rows"), and there's good reason to expect it's much
smaller: it holds one row per accepted-or-pending collaborator invite, a
feature most tournaments never use. SQLite scans a few hundred or even a
few thousand rows in well under a millisecond; the fix is one line
(`create index(:tournament_collaborators, [:email])`) and cheap enough to
do anyway, but there's no evidence this is currently costing anyone
anything measurable.

### 9. ~~The pairing-explanation page recomputes standings once per round, twice at the end~~ FIXED 2026-08-30

> `Standings.standings_by_round/2` reads the rounds and byes ONCE and folds
> every horizon out of them in memory; `player_trails/2` calls it once and
> reuses the `through_round` entries it already holds instead of asking for
> them again. Keizer keeps its per-horizon calls on purpose - its ladder is
> a running recurrence, so there is no single extraction to fold prefixes
> out of. A test asserts each horizon is byte-identical to a standalone
> `standings/2` call, and counts queries via Ecto telemetry.

`lib/pairings_engine/pairing_rationale.ex:195-226`, `:623-642` —
**[Optimization #3]**

Unchanged. `player_trails/2` still builds `scores_by_round` as
`Map.new(0..through_round, fn r -> {r, pre_round_scores(tournament, r)}
end)` (line 198-199) - `through_round + 1` calls to `Standings.standings/2`
(via `pre_round_scores/2`, line 637-642) - and then calls
`Standings.standings(tournament, through_round: through_round)` a second
time, with identical arguments, at line 201. Each call independently
re-queries `games_by_player/3` (`standings.ex:210-245`, a fresh `Round`+
preload query and a fresh byes query every time) and runs the full tiebreak
pass. For a 9-round tournament that's still 11 full standings computations
where one game-extraction pass and 10 in-memory prefix folds would do.

Real, and the fix the sweep proposed (drop the duplicate call at minimum;
extract games once and derive each round's prefix in memory) is unchanged
and still correct. Ranked here rather than higher because this page is
opened on demand (Advanced menu), not on every result entry the way
`PlayersLive`/`PairingsLive` are.

### 10. ~~`player_scores_before_round/2` still throws away everything but points~~ FIXED 2026-08-30

> `Standings.points_by_player/2` - extraction and a sum, no tiebreak pass,
> no adjusted scores, no ranking sort. The three live call sites
> (`PrintController`, `LiveRoundLive`, `PairingsLive.refresh/2`) get it
> through the unchanged `player_scores_before_round/2`.

`lib/pairings_engine/standings.ex:128-137` — **[Optimization #6]**

Still true in shape - `standings(tournament, through_round: round_number -
1)` runs the full `compute_tiebreaks/3` pass and then
`Map.new(entries, &{&1.player.id, &1.points})` discards all of it - but
cheaper than when the sweep wrote it, for two reasons. First, the tiebreak
pass itself got much cheaper (see #11 below). Second, one of the sweep's
four cited call sites is gone: `PublicPairingsLive` no longer exists (the
local public pages were removed 2026-08-29). The other three -
`PrintController:667`, `LiveRoundLive:113`, and `PairingsLive:145` - are all
still live, and `PairingsLive.refresh/2` still runs on mount, on every round
switch, after every arbiter action, and on every `{:tournament_changed,
...}` broadcast. Worth a dedicated points-only path eventually; not urgent
given #11.

### 11. ~~Standings tiebreaks were O(N²R²) - now mostly fixed, by accident~~ FIXED 2026-08-30

> Part two is closed too. `adjusted_score/2` depends on nothing but the
> entry it is given and `points_draw`, so it is computed once per player in
> `build_standings/5` and carried on the entry as `:adjusted_score` - the
> same treatment `completed_rounds` already had, and for the reason stated
> there (twenty-odd `tiebreak/4` clauses to thread a parameter through).
> BH/BHC1/BHC2/MBH and SB read the carried value.

`lib/pairings_engine/standings.ex:686-905` — **[Optimization #5]**

This is the one item on the page where the news is mostly good, and it's
worth stating precisely because the sweep's own math no longer applies.

The sweep's complaint had two parts. Part one: `adjusted_score/3` recomputed
`rounds_played_count(by_id)` - an O(N x R) scan - on every call, and
`tiebreak("KS", ...)` did the same once per entry. **This part is gone.**
Commit `99e1448` (2026-08-28, fixing the unrelated "Still open" lead about
`adjusted_score/3` mixing a record count with a round number) deleted
`rounds_played_count/1` entirely and replaced it with `completed_rounds`,
computed once per `build_standings/3` call (`standings.ex:76`) and carried
on every entry (`standings.ex:93`). `adjusted_score/2` (now arity 2 - the
unused `by_id` parameter is gone) reads `opp_entry.completed_rounds`
directly (`standings.ex:861`); `tiebreak("KS", ...)` reads `entry.completed_rounds`
(`standings.ex:784`). Both are O(1) where they were O(N x R).

Part two is still there: `adjusted_score/2` is still called once per
game-encounter with no memoization - once per opponent inside
`buchholz_contributions/3` (`standings.ex:827-834`, itself called separately
for BH/BHC1/BHC2/MBH with no caching between them), and again inside
`tiebreak("SB", ...)` (`standings.ex:722-732`). Each call still does an
`Enum.sort_by` over the opponent's games (O(R log R)).

Reasoned through rather than assumed: before the fix, a 300-player/11-round
`PlayersLive` grid render did roughly 9,900 `adjusted_score` calls at ~3,300
element-steps each (the O(N) factor) plus a sort - on the order of 33M
element-steps. With the O(N) factor gone, the same 9,900 calls now cost
roughly 60 element-steps each (just the sort and two O(R) passes) - on the
order of 600K element-steps, a two-orders-of-magnitude drop, achieved by a
commit that was never filed against this optimization item at all. What
remains (precomputing `%{player_id => adjusted_score}` once and sharing it
across BH/BHC1/BHC2/MBH/SB) is a real, legitimate further win, but it's now
a constant-factor cleanup, not the asymptotic fix the sweep described -
worth doing opportunistically, not worth reprioritizing anything for.

### 12-16. The five VCL hard failures - confirmed still unbuilt, already the maintainer's own top priority

**[Worth adding #10, #11, #8, #9, #12]**

Grouped because re-flagging these individually adds little: TODO.md's own
"Hard failures (verification stops)" section already lists all five as the
top item in the file, above every other priority. This confirms each is
still exactly as absent as TODO.md already says, with the current file:line
evidence:

- **FIDE Mode does not exist.** `grep -rn "fide_mode" lib/` returns nothing.
  The only FIDE-mode-adjacent state is still `field :fide_homologated,
  :boolean, default: false` (`tournament.ex:186`). `locked_fields/1` /
  `ensure_unlocked/2` (`tournaments.ex:623`, `:659`) - the machinery the
  sweep's write-up said this should be built on top of - are unchanged and
  still available for it.
- **Adjourned games don't exist.** `grep -rn "adjourn" lib/` returns
  nothing.
- **Prohibited pairings can still be added mid-tournament (Q196).**
  `add_forbidden_pairing/3` (`tournaments.ex:1848-1873`) still checks only
  `ensure_writable`/`same_player`/`invalid_player`/`already_forbidden` - no
  round-count guard, `ensure_unlocked/2` never called on this path.
- **Past results are still editable in any round (Q189-191).**
  `update_pairing_result/2` (`tournaments.ex:2137-2141`) still checks only
  `ensure_writable`.
- **TRF import still doesn't verify against the pairing rules (Q54).**
  `import_text/2`'s points cross-check (`trf_import.ex`, the
  `## ---------- points cross-check ----------` section) still only checks
  declared points against recomputed points, not pairing legality.
  `Ainalrami.Trf.parse/1` is called (`pairing.ex:977`-equivalent,
  `trf_import.ex:38`), but nothing in `lib/` calls a checker/replay
  function - `deps/ainalrami/lib/ainalrami/cli.ex` shows the capability
  exists in the dependency, unreached from this app.

### 17. ~~"Which result was this?" is still re-derived in five modules~~ FIXED 2026-08-30

> Closed by `PairingsEngine.Results`, which now owns the code vocabulary and
> the win/draw/loss classification. `Standings` stamps an `outcome` on every
> game record; the four display consumers read it. **One of the five cited
> sites was not a bug:** C.07 Art. 7.1 defines WIN as "the number of rounds
> where a participant obtains, with or without playing, as many points as
> awarded for a win" - a point comparison in the regulation's own words, so
> `standings.ex`'s WIN clause is the rule, not a re-derivation. Its
> neighbour 7.2 ("games won over the board") was a real one and now reads
> the outcome. The 3-2-1 gate the item describes as unreachable was left
> unreached: nothing about `allow_swiss321` changed.

`lib/pairings_engine/standings.ex:609-616`, `player_card.ex:90-122`,
`pairing_rationale.ex:372-378`, `players_live.ex:315`,
`print_controller.ex:1387-1391` — **[Drift #19]**

All five still independently compare `points >= tournament.points_win`
rather than reading a stored classification, and would still misclassify a
draw as a win under the Belgian 3-2-1 scheme the sweep worked out
(points_win 2.0, presence_value 1.0 -> a draw stores 2.0, so `2.0 >=
2.0` reads as a win everywhere).

What's changed: `Pairing.player_points/2` - the sweep's "seventh opinion,"
cited as also omitting the presence point - **no longer does.**
`game_points/3`'s played-game branch now adds
`Standings.presence_points_for_code(t, g.result)` (`pairing.ex:1902`),
landed in commit `5f21ef0` under the comment "the third drift this
function's own docstring did not know about." That closes the TRF-vs-crosstable
disagreement half of the original finding; the five-module win/draw/loss
misclassification is untouched.

Ranked below where its "five call sites" framing might suggest, because
it's confirmed unreachable in production: `presence_value` only takes a
non-default value via a SWAR 3-2-1 import, and `SwarImport.parse/2` refuses
a 3-2-1 file unless called with `allow_swiss321: true`
(`swar_import.ex:151-156`) - an option the actual UI call sites
(`tournaments_live.ex:632-706`, via `prepare_import/1`/`commit_import/3`)
never pass. Real latent risk if that gate is ever lifted for arbiters, zero
current cost.

### 18. ~~Koya (KS) still doesn't apply the Article 16 score adjustment~~ NOT A DEFECT, settled 2026-08-30

> The reading this item asked for was done. **Article 16 names its own
> scope in its opening sentence:** "the tie-breaks Buchholz (see Article
> 8.1), Sonneborn-Berger (see Articles 9.1 and 13.2) and their variants
> (Fore Buchholz, see Article 8.3; and "Cut" Modifiers, see Articles 14.1 to
> 14.4), which are directly or indirectly based on opponents' results, are
> affected by the presence of unplayed rounds." Koya is Article 9.2 and is
> in no part of that list, so the adjustment does not reach it and reading
> `opp.points` directly is correct. The quotation is now in the code above
> the `KS` clause. No change made; the secondary claim about the threshold
> was already fixed in `99e1448`.

`lib/pairings_engine/standings.ex:783-794` — **[Drift #20]**

The primary claim is unchanged: `tiebreak("KS", ...)` reads `opp.points`
directly (line 789) where BH/BHC1/BHC2/MBH/SB all route through
`adjusted_score/2` first. The secondary claim - that the threshold moved
mid-round because it was derived from a record count rather than a round
number - is **fixed**: `max_score` now reads `entry.completed_rounds *
t.points_win` (line 784), the same corrected horizon Optimization #5's
write-up covers, landed in the same `99e1448` commit. What's left is
narrower than the sweep framed it: a real inconsistency between KS and its
neighbors, gated behind the same low-frequency condition (a tied group
where an opponent has trailing voluntary unplayed rounds) the sweep itself
flagged as needing a direct reading of C.07 Art. 16's actual scope before
deciding whether this is a bug or working as intended.

### 19. ~~Mobile result entry still can't write three result codes the Pairings page can~~ FIXED 2026-08-30

> Both screens read `PairingsEngine.Results.entry_codes/0`, and each raises
> at COMPILE time if its own offered list drifts from it - so this class of
> defect cannot come back silently. The phone also gained the three unrated
> codes as buttons behind "More…", not just as writable values.

`lib/pairings_engine_web/live/mobile_results_live.ex:108-126` —
**[Drift #26]**

Unchanged - still a 10-item hand-copied guard
(`when result in ["1-0", "1/2-1/2", ...]`), still missing `"1-0U"`,
`"0-1U"`, `"1/2-1/2U"` (present in the canonical `Pairing.@results`,
`pairing.ex:23-44`, since VCL4THP Q185 shipped) and the `"+--"`/`"--+"`
legacy codes. The comment claiming this mirrors "PairingsLive's own full
`@results` set" is still false. A round entered by a helper's phone can't
record a played-but-unrated result the same round can record from the
Pairings page.

### 20. ~~`docs/results-import.md` and the CSV parser still disagree on the token set~~ FIXED 2026-08-30

> The accepted spellings moved into `PairingsEngine.Results` alongside the
> codes they store; `normalize_result/1` delegates, the three unrated codes
> parse, and both the moduledoc and `docs/results-import.md` list what the
> parser actually accepts. A test walks every token in the table and asserts
> it stores a code the schema will take.

`lib/pairings_engine/results_import.ex:32-40`, `:120-122` —
**[Worth adding #6]**

Unchanged both directions: `1/2-0`/`½-0`/`0.5-0` and `0-1/2`/`0-½`/`0-0.5`
are still accepted (lines 121-122) but appear in neither the moduledoc's
token list nor `docs/results-import.md`. The three unrated codes
(`1-0U`/`0-1U`/`1/2-1/2U`) that the Pairings page and every other
import/export path accept are still absent from `normalize_result/1`
entirely - a bulk CSV import still can't express a result the same round
can express by click.

### 21. ~~Tiebreak picker still offers three codes that silently score zero~~ FIXED 2026-08-30

> All three parts. `available_tiebreaks/1` reads `Tiebreaks.selectable/0`,
> which excludes MP/GP/BB; `Standings.dropped_tiebreaks_with_reasons/2`
> drops a stored one and the Standings page prints why, through the same
> path C.07 Art. 10 already used for rating-based breaks; and the unread,
> internally-inconsistent `teams:` boolean is now `scope:`
> (`:individual | :team | :both`) plus `available:`, both read. DE and WIN
> are `:both` rather than the old `teams: true`, BH and SB likewise (Art.
> 13.2 defines them for teams). A new `tiebreaks_test.exs` walks every
> selectable code through real standings and fails if one is offered but
> dropped - and it caught the FIDE team-event defaults naming all three,
> which are deliberately left alone.

`lib/pairings_engine_web/live/settings_tournament_live.ex:353-355`;
`lib/pairings_engine/standings.ex:800` — **[Drift #27]**

Unchanged. `available_tiebreaks/1` still offers the full
`Tiebreaks.catalogue()` with no filtering; `Standings`'s catch-all clause
(`defp tiebreak(_unknown, _entry, _by_id, _t), do: 0.0`) still exists;
`teams:` is still read nowhere (`grep -rn "\.teams\b" lib/` outside
`tiebreaks.ex` itself returns nothing) and is still internally
inconsistent (DE/WIN are `teams: true` but implemented for individuals;
BH/SB are `teams: false`). An arbiter who adds "Match points" to an
individual Swiss still gets a silent, permanent tie at zero with no error.

### 22. Keizer still never invalidates a stale manual ranking on its own bye writes

`lib/pairings_engine/keizer.ex` (no `invalidate_manual_ranking` call
anywhere in the module) vs. `round_robin.ex:453` (which has one) —
**[Drift #15]**

Unchanged; `RoundRobin.create_round/4`, `Pairing.insert_round_absentee_byes/3`,
`Pairing.create_round/6`, and `Pairing.insert_category_round/4` all call
`Tournaments.invalidate_manual_ranking/1` after a point-awarding bye write;
Keizer's `create_round/4`/`insert_absentee_byes/4` (both writing
point-awarding rows: a `result: "bye"` Pairing and `byes` rows of type
`"absent"`) still don't. Confirmed still inert: `StandingsLive` still gates
the entire manual-ranking card and banner on `!keizer?`
(`standings_live.ex:196`, `:198`, `:322`), and `manual_ranking` can only be
switched on for a tournament that's still Swiss at zero rounds paired - so
the flag can technically be `true` on a Keizer tournament, just unreachable
from the one page that would show it. Separately, `insert_absentee_byes/4`
is still called after `create_round/4`'s own transaction commits
(`keizer.ex:156-158`), not inside it.

### 23. ~~`parse_absent_rounds/1` is still two byte-identical private copies~~ FIXED 2026-08-29

> Closed hours after this was written. It lives at
> `Player.parse_absent_rounds/1` now, beside the input grammar it
> mirrors, and the reader tolerates malformed input rather than
> raising - a hand-edited row would previously have taken down pairing
> for a whole tournament.

`lib/pairings_engine/pairing.ex:2060-2069`, `lib/pairings_engine/keizer.ex:718-727`
— **[Drift #16]**

Confirmed character-for-character identical, still private to each module.
Worth noting: TODO.md's own "Still open" entry cites `pairing.ex:2031` and
`keizer.ex:633` for this - both already off by ~30 lines from the code as
of this read, which is itself a small demonstration of the sweep's central
point (line-number citations go stale fast; nobody re-verifies them until
someone has to).

### 24. ~~`RoundRobin.ensure_frozen/1` still hand-copies two functions instead of calling them~~ FIXED 2026-08-30

> `ensure_frozen/1` calls `Pairing.active_players/1` and
> `Pairing.ensure_pairing_numbers/2`; `frozen_players/1` calls
> `Pairing.full_roster_players/1`, which is public now for the same reason
> the other two were. The `already_frozen?` guard deliberately stays in
> `RoundRobin` rather than moving into the shared function: numbering a late
> entrant is correct for Swiss and wrong for a Berger schedule, which is
> fixed at freeze time. Nothing about the copies had drifted yet, which is
> the only reason this was risk rather than a defect.

`lib/pairings_engine/round_robin.ex:289-311`, `:365-370` — **[Drift #18]**

Unchanged. `ensure_frozen/1` still writes its own `active_players`-shaped
query (line 297-302) and its own `Enum.sort_by(&{-Player.rating(&1),
&1.name})` (line 303) instead of calling `Pairing.active_players/1` and
`Pairing.ensure_pairing_numbers/2`, both explicitly exposed ("so
`PairingsEngine.Keizer` can freeze pairing numbers... rather than
duplicating this logic") for exactly this reuse - which `Keizer` does
(`keizer.ex:126`) and `RoundRobin` still doesn't. `frozen_players/1` still
duplicates `full_roster_players/1`'s query shape too. The two copies still
agree today; this is drift risk, not present drift.

### 25. ~~KBSB search: stale docstring, dead index, infix LIKE with no index path~~ FIXED 2026-08-30

> All three. `20260830110000_create_kbsb_players_fts` gives the national
> list the same FTS5 table, triggers and backfill `fide_players` got in
> `20260726090000`, and drops the `[:last_name]` index in the same
> migration - a prefix index against an infix pattern, never used by
> anything. `Kbsb.search/1` mirrors `Fide.search/1` exactly, FTS with a LIKE
> fallback. The docstring no longer claims a last-name prefix match, which
> it had not been for a long time. A test deletes one row from the FTS table
> only and asserts the search stops finding it, which is what proves the
> index is the thing answering.

`lib/pairings_engine/kbsb.ex:8-42` — **[Drift #14]**

Unchanged on all three counts. Docstring still claims "last-name prefix";
the query is still `pattern = "%" <> tok <> "%"` against both `last_name`
and `first_name`. `create index(:kbsb_players, [:last_name])`
(migration `20260713150000`) is still the only DB touch of that column and
still can't serve an infix LIKE. `Fide.search/1` got the FTS5 fix for
exactly this problem (`20260726090000_create_fide_players_fts.exs`); KBSB's
sibling function didn't. Bounded cost, per the sweep's own honest framing:
admin-only page, per-keystroke, tens of milliseconds on a few tens of
thousands of rows, not seconds.

### 26-32. Roadmap-scoped suggestions, still unbuilt, no new evidence to add

**[Worth adding #1, #2, #3, #4, #14, #15]**

- **SWAR categories import-time warning** (`Worth adding #1`): still not
  built. `map_categories/1` (`swar_import.ex:1448-1456`) still silently
  flattens `value1`+`value2` for any non-zero `type`; no warning fires, and
  `docs/swar-import.md` still doesn't name what file characteristics would
  settle the ambiguity.
- **Norms-vs-Settings decision** (`Worth adding #2`): still open by
  TODO.md's own admission - the pointer card shipped, the actual page move
  didn't, and the entry still says so.
- **Team-pairing SPP cross-reference** (`Worth adding #3`): still not
  cross-referenced. Neither `TODO.md:199` nor `docs/features.md:166-168`
  mentions "SPP" or "5.2.5" anywhere near the Team tournaments entry.
- **ITDX `?` code** (`Worth adding #4`): `Pairing.@results`
  (`pairing.ex:23-44`, the half of this that lives in this repo) still has
  no `"?"` entry. `docs/tec-feedback-2026-09.md:194` still says "We will
  implement `?`."
- **Q140 consistency checks stay page-scoped** (`Worth adding #14`): the
  checks are still only in `pairing_explain_live.ex`
  (`:1159`, `:1173`); `Tournaments.refresh_status!/1`
  (`tournaments.ex:2759-2780`) still only derives tournament status, no
  check extraction, no layout-level banner.
- **Local-mode polish** (`Worth adding #15`): **partially done.** The
  duplicate-code half the sweep flagged as "the exact shape this codebase
  names as its highest-value bug class" is fixed - `local_mode?/0` in both
  `layouts.ex:347` and `user_auth.ex:114` now delegate to
  `PairingsEngine.Authz.local_mode?/0` (landed in `b376788`, alongside that
  commit's actual subject, the admin/support role). What's still open: the
  Settings link (`layouts.ex:203`), `invite_live.ex`, and the
  `/users/register`/`/users/log-in` routes (`router.ex:211-216`) are all
  still unconditional - `grep -rln "local_mode?" lib/pairings_engine_web/live/
  lib/pairings_engine_web/controllers/` returns only `admin_live.ex`.

## Purely documentation drift - real, but costs a future reader, not a user

Each of these is confirmed still wrong in the doc named; none affects
anything the app does. Grouped and kept short because the fix in every case
is "edit the paragraph."

- **`TODO.md`'s binaries-smoke-test claim** (`TODO.md`, Backlog section)
  still says CI has no smoke test beyond "it builds." `.github/workflows/binaries.yml`
  still has four (`:125`, `:167`, `:209`, `:241`), each booting a real
  target and curling `/`. This item's other half - the W/D/L VCL-gap line
  the sweep cited from the same paragraph - is already fixed: TODO.md now
  carries it struck through as "shipped 0.17.1," with a further correction
  dated 2026-08-28. **[Drift #1, half; other half already fixed]**
- **The concurrent-arbiter notice** is still described as shipped
  (`TODO.md`, "Now shipped: the identical mechanism on PlayersLive too")
  and still listed in `docs/features.md:158` as unbuilt near-term work -
  while the code still deliberately removed it from both LiveViews
  (`pairings_live.ex:94-98`, `players_live.ex:134`, both with an explicit
  "removed" comment) and `grep -rn "remote_notice" lib/` still returns
  nothing. **[Drift #2]**
- **`TODO.md`'s `absent_counts_as_vur` claim** (`TODO.md:502`) still says
  "off by default"; the schema still says `default: true`
  (`tournament.ex:128`). Notably, `docs/fide-endorsement.md` - the document
  with actual compliance weight - already got this fixed (see below); the
  roadmap file didn't. **[Drift #3]**
- **`docs/features.md`'s version header** still says "0.17.1"; `mix.exs`
  is at `0.18.0`. Worth flagging on its own: `TODO.md`'s own header *was*
  fixed (now correctly reads `0.18.0`), so this drift has already recurred
  once inside the three-day window this follow-up covers - live proof that
  the sweep's suggested fix (a version-consistency check in `mix
  precommit`) still doesn't exist and would already have paid for itself.
  **[Drift #4, half]**
- **`docs/fide-endorsement.md`'s superseded-scope banner** is still only in
  `TODO.md`; Section A (`fide-endorsement.md:192-195`) still frames FIDE
  Mode as "not applicable to audit," and VCL.15 (`:300-303`) still says "N/A
  - nothing to verify since the feature doesn't exist," neither
  cross-referenced to the 2026 VCL's Q40-46/Q157-169 hard failures a few
  hundred lines away. **[Drift #7]**
- **`docs/import-export.md`** still claims the JSON backup carries "every
  Tournament field" / "Everything the app models" (lines 11, 142); the code
  excludes eleven fields now, including three new OpenResults-related ones
  (`tournament_export.ex:122-127`). The logo caveat still points at a
  section of this same doc that still doesn't mention logos. **[Drift #8]**
- **`ConsoleMailer`'s moduledoc** still argues at length that local mode
  deliberately does not auto-log-in (`console_mailer.ex:9-24`); `UserAuth.local_owner_session/2`
  still does exactly that (`user_auth.ex:106-108`). **[Drift #13]**

---

## Already fixed

- **`pairings.hidden` is now exported and restored correctly**
  (`tournament_export.ex:293`, `"hidden" => p.hidden`, with a comment
  naming the exact bug: "a restore silently un-hid every hidden board - a
  disclosure, not just a lost setting"). **[Drift #21]**
- **`categories_live.ex` now asks `locked_fields/1`** instead of
  re-deriving the lock rule (`categories_live.ex:45`,
  `:pair_by_category in Tournaments.locked_fields(tournament)`), matching
  `SettingsOptionsLive`/`SettingsScoringLive`. **[Drift #25]**
- **`docs/fide-endorsement.md`'s `absent_counts_as_vur` default** now
  correctly reads "on by default since 0.17.1" (`:373-386`), with the
  rationale, the historical off-by-default migration backfill, and the old
  wrong comment all explained. Both sweep entries pointing at this file and
  line resolve together. **[Drift #5 and #6, same fix]**
- **`docs/swar-import.md`'s "not modeled" claim** is gone, replaced with
  "Modelled since 0.16.x, and the engine was told about it in 0.17.1"
  (`:470-479`), naming `presence_value`, `presence_on_allocated_bye`,
  `Standings.bye_points/4`, and the 0.17.1 engine-parity fix specifically.
  Both sweep entries pointing at this paragraph resolve together.
  **[Drift #10 and #11, same fix]**
- **`Pairing.player_points/2` no longer omits the presence point.** Fixed
  in commit `5f21ef0`, which added
  `Standings.presence_points_for_code(t, g.result)` to the played-game
  branch (`pairing.ex:1902`) - this closes the narrower of the two claims
  bundled into Drift #19 (see above for what's still open).

## No longer applies

- **The `/p/:slug/register` framing doc** (`docs/public-pages.md`) is moot:
  the entire local public-pages subsystem it describes was removed
  2026-08-29. The doc has already been rewritten to say so in its own first
  paragraph ("This app serves no public pages at all... The local pages
  were removed rather than de-emphasised"). **[Drift #9]**
- **The public-layout language-picker contradiction** no longer has a
  route to live on. `Layouts.public/1` (`layouts.ex:316-335`) is now dead
  code - `grep -rn ":public\b" lib/pairings_engine_web/` (excluding the
  definition and unrelated `publish*`/`public_slug` matches) returns
  nothing, meaning no route or controller sets it as a layout anymore.
  `EnglishHook` is still mounted, but now only on `/m/results`
  (`router.ex:267-274`, `MobileResultsLive`), which never renders a
  language picker. See "found while reading" below for what's stale about
  this one. **[Drift #23]**

## Out of scope: the file isn't in this repository

Two items, plus part of a third, point at documentation that lives in
`deps/ainalrami/docs/` - the vendored Ainalrami dependency, gitignored
(`.gitignore:14`, `/deps/`), pulled from a separate GitHub repository
(`AuroraRyunix/Ainalrami`, pinned at `v0.14.0` in `mix.lock`). Nothing in
this repository can fix these; the action, if any, belongs to that project.

- **`docs/validation.md`'s "Not covered" contradictions**
  (`deps/ainalrami/docs/validation.md`). Checked anyway, for what it's
  worth: the specific claim the sweep flagged (non-default point
  configuration listed as uncovered when a `draw_heavy` axis already
  covers it) is fixed in the pinned version - that bullet is struck through
  and marked "covered, and it was worth it." The late-entrants/`rounds_count`
  bullet is still present but has been substantially rewritten with more
  care than the sweep's citation implies (it now explains precisely what
  the harness does and doesn't generate, and dates a 2026-08-27 priority
  shift). This document is being actively maintained independently of
  OpenPairings' own three days of work. **[Drift #12]**
- **"Fields above 500 / rounds above 20" corpus axis**
  (`deps/ainalrami/docs/validation.md:833-837`). Still listed as not
  covered, exactly as the sweep found - but again, this is Ainalrami's own
  harness gap to close, not OpenPairings'. Their doc already calls it "the
  most reachable gap on the list" in its own words. **[Worth adding #5]**
- **`docs/conformance-c0406-teams.md`**, cited by `Worth adding #3`
  (team-pairing/SPP cross-reference), is also under `deps/ainalrami/docs/`.
  The suggestion itself - add a cross-reference in *OpenPairings'* `TODO.md`
  - is in scope and still unfulfilled (see above); only the target
  document on the other side of that cross-reference lives elsewhere.

## Nothing in the 49 was simply wrong

Every item checked out as describing something real at the time it was
written - the "worse than this document had it" and "refuted" categories
the sweep already ran near the top of the same document apparently caught
what would have failed here too. That's worth telling whoever runs the next
sweep: the adversarial pass on the 15 "likely bugs" was necessary and
caught real overclaims: nothing here suggests the *unaudited* sections
needed the same skepticism, only the same three days of patience.

---

## Found while reading, not in the sweep

- **The `Trf` module has moved entirely out of this repository.**
  `lib/pairings_engine/trf.ex` - cited by name in several sweep items - no
  longer exists. `Trf` is now aliased everywhere (`pairing.ex:38`,
  `trf_import.ex:38`, `trf_export.ex:27`) to `Ainalrami.Trf`, i.e. the
  vendored dependency. `Trf.@result_codes`, `Trf.serialize/1`, and
  everything else the sweep attributed to this repo's own TRF writer now
  lives in `deps/ainalrami/lib/ainalrami/trf.ex`, outside this repository.
  This doesn't change any of the verdicts above, but it means several
  `trf.ex:NN` citations in the original sweep document no longer resolve
  to anything in `lib/` at all, and won't for as long as the current
  architecture holds.
- **`EnglishHook`'s moduledoc is now stale in the same way `docs/public-pages.md`
  used to be.** It still says it's "Used on the player-facing pages - the
  public pairings and standings, the registration form, and mobile result
  entry" (`english_hook.ex:5-6`). Three of those four routes don't exist
  in this app anymore; only mobile result entry does. Small, but it's the
  exact "left one branch of a removed feature's documentation behind"
  shape the sweep spent a whole section on, in a file the sweep itself
  never looked at.
- **Two pairs of near-duplicate entries inside the sweep document itself:**
  `Drift #5` and `#6` are both `docs/fide-endorsement.md:370`, same claim,
  worded twice; `Drift #10` and `#11` are both about the same paragraph in
  `docs/swar-import.md`. Neither pair is wrong, they're just the same
  finding filed twice - worth deduping before the next sweep publishes,
  so a reader doesn't count 49 when 47 unique items were actually found.
- **Optimization #5 was mostly fixed by a commit that never mentions
  performance.** `99e1448` exists to fix a *correctness* bug (a record
  count standing in for a round number, filed as a "Still open" lead, not
  as one of these 49 items) - and, as a side effect of the one change that
  bug needed, removed the single largest cost term this document's
  Optimization #5 was filed against. It's a clean example of the
  codebase's own recurring lesson working in its favor for once: one
  canonical value (`completed_rounds`), computed once and threaded
  through, fixed a wrong number *and* an algorithmic complexity class in
  the same eleven lines.
