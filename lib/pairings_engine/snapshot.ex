defmodule PairingsEngine.Snapshot do
  @moduledoc """
  Builds the publish payload OpenResults consumes - the one contract between
  the arbiter's machine and the public results server. The specification is
  `docs/snapshot-schema.md` in the OpenResults repo; this module is its only
  producer.

  Not to be confused with `PairingsEngine.Snapshots` (plural), which is the
  restore-point/branching machinery for a tournament's own database. Nothing
  here touches that.

  Three properties are worth stating up front, because they are why the shape
  looks the way it does rather than like the Ecto schemas underneath.

  ## It describes a tournament, not a database

  No row ids cross. A player is referenced everywhere by `no`, their
  `pairing_number` - the TRF start number, stable inside the event and
  meaningless outside it. `Player.id`, `Round.id` and `Pairing.id` never
  appear, so a column can move here without OpenResults noticing.

  ## Withholding happens HERE, not on render

  An unpublished round and a hidden board are absent from the payload
  entirely. The server cannot leak what it was never sent, which is a
  stronger guarantee than a public page that has to remember to filter.
  Concretely:

    * `rounds` contains only rounds `Tournaments.round_published?/2` accepts -
      the same gate `PairingsEngineWeb.PublicPairingsLive` applies, per round,
      because publishing can be manual and therefore out of order.
    * `standings` is computed `through_round: Tournaments.effective_standings_through/1`,
      the round public standings actually go through - see that function's
      own doc for the exact formula. It is capped at the longest
      *contiguous* prefix of rounds that are BOTH published AND complete
      (`PairingsEngine.Pairing.round_complete?/2` - every pairing has a
      result; `Tournaments.standings_through_round/1` computes that cap on
      its own). The highest published round is the wrong bound, for two
      reasons: with round 3 published and round 2 held back, standings
      through 3 would silently carry round 2's results (the contract's note
      that `after_round` need not be the highest published round); and with
      round 1 published the moment it is paired, standings through 1 would
      say "after round 1" while every board still reads 0-0, because a
      published round used to count even with no results in it.
    * `players` is withheld entirely - `[]`, and with it every standings row -
      while `tournament.standings_through` is `nil` AND no round has been
      published yet. This is the one piece of withholding that depends on a
      tournament SETTING (what an arbiter has explicitly published via
      `Tournaments.publish_standings_through/2`, or the migration/import
      default - see `Tournament.standings_through`'s own field doc) rather
      than purely on publish/hide state per round or board: an arbiter who
      has never published so much as the before-round-1 entry list does not
      want it doubling as an early standings page with every score at zero.
      The moment any round publishes - even with results still coming in -
      the roster is exactly as load-bearing as every board that names these
      players, so it travels regardless of that setting from then on (see
      `withhold_starting_rank/3` below).
    * A `Pairing` with `hidden` set never reaches `boards`.
    * A published round whose results are not public
      (`Tournaments.results_public?/3` - the "Results round N" switch, forced
      on by public standings through that round and by "immediate" mode)
      travels with every board's `result` set to `null` and
      `"results_public": false`. Nothing else derived from a result can
      carry that round: `standings` (and with it `working`) stop at
      `after_round`, which is at most the highest round whose standings are
      public, and a round at or below that bound has its results forced
      public by definition. A `vacated-seat` row in `byes` is a result typed
      against an emptied seat, so it is withheld whole. Every other bye -
      requested, absent, pairing-allocated - is part of the pairing sheet,
      decided before a game starts and printed with its points in the hall,
      so it still travels with its points.

  One consequence of the last point, stated rather than left to be discovered:
  a hidden board's result still counts in `standings`, because it counts in the
  arbiter's own crosstable - `hidden` is a display flag, and standings that
  disagreed with the hall would be a worse failure than an unexplained half
  point. Today the flag is only settable on a fully-vacated row (no players, no
  result), so nothing is actually withheld; the note is for the day that
  widens.

  ## Only the fields the contract lists may travel

  `player_row/2` is a hand-written allowlist, never `Map.from_struct/1` or a
  `Map.drop/2` of known-bad keys - a new personal-data column added to
  `players` must default to not being published, rather than defaulting to
  being published until somebody remembers to exclude it. Email, phone,
  birth date, birth year, national id and the free-form `norm_data` map stay
  in the arbiter's database.
  """

  alias PairingsEngine.{
    Categories,
    Keizer,
    PairingDisplay,
    PublicDisplay,
    Standings,
    TeamStandings,
    Tiebreaks,
    Tournaments
  }

  alias PairingsEngine.TiebreakWorking
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}
  alias PairingsEngine.{Authz, Repo}
  alias PairingsEngine.Accounts.User

  @schema "openresults/snapshot"
  # The envelope is versioned, not the fields - this changes only for a break
  # that cannot be expressed additively. See the contract's "Why it looks like
  # this".
  @version 1

  # The two legacy spellings for a single-sided forfeit, from historical and
  # SWAR-imported data (see `Tournaments.Pairing`'s `@results`). Normalised on
  # the way out so OpenResults only ever sees one vocabulary; the arbiter's own
  # database keeps whatever it has.
  @legacy_results %{"+--" => "1-0FF", "--+" => "0-1FF"}

  # `byes` table types -> the contract's bye kinds. "full-point" is in the
  # contract's vocabulary but has no counterpart here; an unrecognised type
  # travels verbatim rather than being reported as something it is not - a bye
  # type added to this app later is better read as unknown by OpenResults than
  # read as the wrong thing.
  @bye_kinds %{
    "requested-half" => "half-point",
    "requested-zero" => "zero-point",
    "absent" => "absent",
    "pairing-allocated" => "pairing-allocated"
  }

  @doc """
  The complete snapshot for `tournament`, ready for `Jason.encode!/1`.

  String keys throughout, so the map reads as the JSON it becomes.
  """
  @spec build(Tournament.t()) :: map()
  def build(%Tournament{} = tournament) do
    rounds = published_rounds(tournament)

    players =
      tournament
      |> publishable_players()
      |> withhold_starting_rank(tournament, rounds)

    # Every cross-reference in the document resolves through this map, so
    # there is exactly one place `no` is decided.
    nos = Map.new(players, &{&1.id, &1.pairing_number})

    after_round = Tournaments.effective_standings_through(tournament)
    results_public = &Tournaments.results_public?(tournament, &1, after_round)

    team_nos = if paired_as_teams?(tournament), do: team_numbers(tournament), else: %{}

    matches_by_round =
      if paired_as_teams?(tournament) do
        tournament |> TeamStandings.matches() |> Enum.group_by(& &1.round)
      else
        %{}
      end

    base = %{
      "schema" => @schema,
      "version" => @version,
      "published_at" => now_iso8601(),
      "source" => %{"app" => "openpairings", "version" => app_version()},
      "tournament" => tournament_row(tournament),
      "players" => Enum.map(players, &player_row(tournament, &1)),
      "rounds" =>
        Enum.map(rounds, fn round ->
          round_row(
            round,
            tournament,
            nos,
            results_public.(round),
            Map.get(matches_by_round, round.number, []),
            team_nos
          )
        end),
      "standings" => standings(tournament, nos, after_round)
    }

    base = maybe_put_publisher(base, tournament)

    if paired_as_teams?(tournament) do
      base
      |> Map.put("teams", teams_row(tournament, nos, team_nos))
      |> Map.put("team_standings", team_standings_row(tournament, team_nos, after_round))
      |> Map.put("board_stats", board_stats_row(tournament, nos, team_nos, after_round))
    else
      base
    end
  end

  # Added 2026-09-14. Who published, for the hosted server's admin panel
  # only - see docs/snapshot-schema.md ("publisher") in the OpenResults repo
  # for the full contract. Present only on a HOSTED publish
  # (`not Authz.local_mode?/0`; a desktop install has no accounts to name and
  # already identifies itself with its installation key) and only when the
  # tournament's owner is still known. `email` is the account's only identity
  # today - there is no separate display name field on `Accounts.User` - so
  # `name` is omitted rather than invented; OpenResults falls back to the
  # email alone when `name` is absent, exactly like every other optional
  # field in this document. `host` is this instance's own public host, so
  # OpenResults can show which hosted deployment a tournament came from
  # without hard-coding one.
  defp maybe_put_publisher(base, %Tournament{} = tournament) do
    if Authz.local_mode?() do
      base
    else
      case owner_email(tournament) do
        nil -> base
        email -> Map.put(base, "publisher", %{"email" => email, "host" => public_host()})
      end
    end
  end

  defp owner_email(%Tournament{user_id: nil}), do: nil

  defp owner_email(%Tournament{user_id: user_id}) do
    case Repo.get(User, user_id) do
      %User{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp public_host do
    PairingsEngineWeb.Endpoint.host()
  end

  ## ---------- tournament ----------

  defp tournament_row(%Tournament{} = t) do
    %{
      # The tournament's existing public identity, not a second naming
      # scheme invented for this payload - the registration payload
      # travelling the other way keys off the same string.
      "slug" => t.public_slug,
      "name" => t.name,
      "city" => blank_to_nil(t.city),
      "federation" => blank_to_nil(t.federation),
      "start_date" => blank_to_nil(t.start_date),
      "end_date" => blank_to_nil(t.end_date),
      "rounds_count" => t.rounds_count,
      "system" => system(t),
      "arbiter" => blank_to_nil(t.chief_arbiter),

      # Added 2026-08-29. Facts a printed pairing sheet carries as a matter of
      # course, which the public page had no way to show - a spectator or a
      # player following the link could not see who was deputising or what the
      # time control was. The local page grew a line for exactly this and it
      # did not survive the move.
      "deputy" => blank_to_nil(t.deputy_arbiter),
      "time_control" => blank_to_nil(t.rate_of_play),

      # Which rating a player should be entered at - "rapid", "blitz", or
      # standard. Not the same field as `time_control`, which is prose an
      # arbiter types for humans; this is the tournament's own `standard`
      # classification, and it tells the results site which of a FIDE
      # player's three ratings to offer when somebody finds themselves on the
      # list. A player entered at their standard rating in a blitz event is
      # seeded wrong, and the arbiter has to notice and fix it.
      "tempo" => blank_to_nil(t.standard),

      # Whether rounds are halves of matches. A round-robin or swiss played in
      # two-game matches numbers its rounds 1..2n, and nobody in the hall calls
      # round 4 "round 4" - it is game 2 of match 2, which is what the
      # arbiter's own round picker says. Without this the public page and the
      # arbiter disagree about what to call every second round.
      "match_format" => t.rr_match_format == true or t.swiss_match_format == true,
      "fide_rated" => t.fide_homologated,

      # Added 2026-08-29, when this app stopped serving its own entry form.
      # Until then this flag was enforced here, against the local
      # `/p/:slug/register`; now the only form is on the results site, and
      # riding along in the snapshot is the only way the arbiter's decision
      # reaches it.
      #
      # A reader that predates this field must treat its ABSENCE as open,
      # not closed - that is what it did before the field existed, and a
      # reader that guessed "closed" would silently take an open form down
      # on every tournament that had not republished yet. Entries are a
      # queue an arbiter reviews, so an extra one costs a glance; a form
      # that is shut when it should be open loses a real person's entry and
      # tells nobody.
      "registration_open" => t.registration_open,

      # Added 2026-08-29. Whether the results site lists this tournament on
      # its front page, as opposed to serving it only to somebody who has the
      # address. Absent means listed - which is what publishing meant before
      # there was a choice.
      "listed" => t.public_listed != false,

      # Which columns the public page may show. Sent RESOLVED - every key,
      # every value a real boolean - rather than as the sparse map the
      # arbiter's edits are stored in. A reader should not have to know this
      # app's default list to interpret the answer, and sending
      # `%{"club" => false}` and expecting six `true`s to be inferred would
      # make the contract depend on a list only this side has.
      "display" => PublicDisplay.resolve(t.public_display)
    }
    |> put_tournament_categories(t)
    |> put_team_event(t)
  end

  # Added with team pages. Absent means an individual tournament, which is
  # exactly how every already-published snapshot read before this field
  # existed - so it is added only for a team event rather than sent as
  # `false` on every other one.
  # Team data travels only for a tournament whose teams are actually PAIRED
  # as teams: a team round robin, or a team Swiss paired by teams (or not yet
  # paired). A team Swiss already paired player by player publishes as an
  # individual event - flagged as a team event, it would show empty team
  # standings on the results site in place of its real ones.
  defp paired_as_teams?(t), do: Tournament.paired_as_teams?(t)

  defp put_team_event(row, %Tournament{} = t) do
    if paired_as_teams?(t), do: Map.put(row, "team_event", true), else: row
  end

  # Added 2026-09-13. The tournament's own category vocabulary, in its own
  # order - what `players[].categories` entries are drawn from and the order
  # a filter bar should offer them in, rather than each reader re-deriving
  # "the order categories appear across the roster" and disagreeing with the
  # arbiter's Categories page.
  #
  # Gated on the same "category" display key as `players[].categories` (see
  # `player_row/2`) and OMITTED rather than sent empty when hidden: an
  # arbiter who has switched categories off has said players should not be
  # sorted into "Women" or "U14" in public, and a bare `[]` here would still
  # let a reader show an (empty) category filter and invite the question of
  # why it never fills in. Absence reads the same as an arbiter's app that
  # predates this field, which is exactly the fallback OpenResults already
  # needs for `players[].categories`.
  defp put_tournament_categories(row, %Tournament{} = t) do
    if PublicDisplay.show?(t.public_display, "category") do
      Map.put(row, "categories", t.categories || [])
    else
      row
    end
  end

  # Manual ranking is never offered for Keizer - see docs/manual-standings.md
  # for why - so the flag is meaningless there and the warnings below it would
  # be nonsense. Matches the arbiter's own page, which gates the same way.
  defp manual?(%Tournament{manual_ranking: true, pairing_system: system}), do: system != "keizer"
  defp manual?(%Tournament{}), do: false

  # The contract's three systems are `pairing_system`'s three, not `type`'s
  # four: `type` is the FIDE report classification and has no Keizer at all.
  defp system(%Tournament{pairing_system: "round_robin"}), do: "roundrobin"
  defp system(%Tournament{pairing_system: "keizer"}), do: "keizer"
  defp system(%Tournament{}), do: "swiss"

  ## ---------- players ----------

  # A player with no `pairing_number` has never been in a paired round
  # (`Pairing.ensure_pairing_numbers/2` assigns them over the active roster at
  # the first pairing), so nothing in the document could reference them - `no`
  # is the only identifier that crosses. Publishing them with a null `no` would
  # put an unreferenceable row in `players`; they are left out instead.
  #
  # Except before round 1 is paired, when NOBODY has a number yet. Filtering
  # then left `players` empty, so the public standings page - which shows the
  # field in start order until round 1 has results - was blank for exactly
  # the stretch it exists for (reported 2026-09-11, on a live tournament).
  # So while no player has a number, the field is numbered provisionally:
  # the same players (`Pairing.active_players/1`) in the same order
  # (`Pairing.initial_order/1`) that pairing round 1 will number, so the
  # provisional numbers normally come out identical to the real ones. Nothing
  # is written back: the real numbers are still issued, and frozen, only by
  # pairing round 1.
  defp publishable_players(%Tournament{} = t) do
    players = Tournaments.list_players(t.id)

    if Enum.any?(players, &is_integer(&1.pairing_number)) do
      players
      |> Enum.filter(&is_integer(&1.pairing_number))
      |> Enum.sort_by(& &1.pairing_number)
    else
      t.id
      |> PairingsEngine.Pairing.active_players()
      |> PairingsEngine.Pairing.initial_order()
      |> Enum.with_index(1)
      |> Enum.map(fn {player, number} -> %{player | pairing_number: number} end)
    end
  end

  # The one withholding rule that reads a tournament SETTING
  # (`standings_through`, written only by `Tournaments.publish_standings_through/2`
  # and its migration/import defaults - nil means nothing has ever been
  # published) rather than publish/hide state on a round or a board - see
  # the moduledoc. `rounds` is `published_rounds/1`'s own result, already
  # computed by the caller, rather than asked again here: "no round has been
  # published" and "`rounds` is empty" are the same fact, and re-deriving it
  # a second way is how the two drift.
  #
  # Once any round is published, the players named on its boards are exactly
  # as load-bearing as the board itself - withholding them here would leave
  # `boards[].white`/`boards[].black` pointing at a `no` with no row in
  # `players` - so this only ever fires while `rounds` is still empty.
  defp withhold_starting_rank(_players, %Tournament{standings_through: nil}, []), do: []
  defp withhold_starting_rank(players, %Tournament{}, _rounds), do: players

  # An allowlist by construction - see the moduledoc. Anything not named here
  # stays in the arbiter's database, whether or not it existed when this was
  # written.
  defp player_row(%Tournament{} = t, %Player{} = p) do
    %{
      "no" => p.pairing_number,
      "name" => p.name,
      "title" => blank_to_nil(p.title),
      "rating" => zero_to_nil(Player.rating(p)),
      "federation" => blank_to_nil(p.federation),
      "fide_id" => p.fide_id,
      "club" => blank_to_nil(p.club),
      # `category` keeps meaning exactly what the schema doc says it means -
      # this player's SINGLE category - because the snapshot contract is
      # additive only and every already-published tournament reads it. Under
      # several categories per player the single one is the pairing category
      # (`PairingsEngine.Categories`), which for a tournament that never puts
      # a player in two is the same string it always was. Unlike `categories`
      # below, `category` is NOT gated on the "category" display key here -
      # it never has been, and narrowing an existing published field's
      # behaviour is not this change's job.
      "category" => blank_to_nil(Categories.pairing_category(t, p))
    }
    |> put_player_categories(t, p)
  end

  # Added 0.53.0, gated 2026-09-13. Every category, in the tournament's own
  # order. OMITTED - not sent as `[]` - while the arbiter has the "category"
  # display key off, for the same reason `tournament.categories` is omitted
  # (see `put_tournament_categories/2`): the field exists to let a public
  # page group and filter players by category, which is precisely what
  # switching the setting off says not to do. Optional by the schema's own
  # convention otherwise: an older publisher omits it and a reader that does
  # not know it ignores it, exactly as `fide_id` and `rating` already work.
  defp put_player_categories(row, %Tournament{} = t, %Player{} = p) do
    if PublicDisplay.show?(t.public_display, "category") do
      Map.put(row, "categories", Categories.listed_categories(t, p))
    else
      row
    end
  end

  ## ---------- rounds ----------

  # Gated per round with `round_published?/2`, never `number <= latest`:
  # `Tournaments.latest_published_round_number/1` only tracks the HIGHEST
  # published round, and manual publishing can leave a lower one held back.
  # Same reasoning, and the same call, as `PublicPairingsLive.reload/2`.
  #
  # Reloaded through `Tournaments.get_round/2` because that is the loader the
  # public pairings page uses, so the two can never drift on what a round
  # carries.
  defp published_rounds(%Tournament{} = t) do
    t.id
    |> Tournaments.list_rounds()
    |> Enum.filter(&Tournaments.round_published?(t, &1))
    |> Enum.map(&Tournaments.get_round(t.id, &1.number))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.number)
  end

  # The contiguous bound `standings/3` below needs (published AND complete)
  # lives in `Tournaments.standings_through_round/1`, not here - this
  # function only gates `rounds` itself, which stays published-only: a
  # round's pairings are withheld for being unpublished, never for being
  # incomplete.

  defp round_row(%Round{} = round, %Tournament{} = t, nos, results_public?, matches, team_nos) do
    visible = Enum.reject(round.pairings, & &1.hidden)

    row = %{
      "number" => round.number,
      "date" => round_date(round, t),
      # Added 2026-09-13 with the "Results round N" switch. `false` means the
      # boards below carry no results because the arbiter has not published
      # them, not because none were entered. Absent means true: an older
      # publisher sent every result it had.
      "results_public" => results_public?,
      "boards" => boards(visible, nos, results_public?),
      "byes" => byes(round, visible, t, nos, results_public?)
    }

    if paired_as_teams?(t) do
      Map.put(row, "matches", Enum.map(matches, &match_row(&1, team_nos, results_public?)))
    else
      row
    end
  end

  ## ---------- team events ----------

  # Frozen `pairing_number`s once round 1 exists (see `PairingsEngine.TeamRoundRobin`).
  # Before that every team is numbered provisionally, in the same seeding
  # order the Teams page shows and the first pairing will freeze - the same
  # reasoning `publishable_players/1` applies to players before round 1.
  defp team_numbers(%Tournament{} = t) do
    teams = Tournaments.list_teams(t.id)

    case Enum.reject(teams, &is_nil(&1.pairing_number)) do
      [] -> teams |> Enum.with_index(1) |> Map.new(fn {team, n} -> {team.id, n} end)
      frozen -> Map.new(frozen, &{&1.id, &1.pairing_number})
    end
  end

  defp teams_row(%Tournament{} = t, nos, team_nos) do
    t.id
    |> Tournaments.list_teams()
    |> Enum.filter(&Map.has_key?(team_nos, &1.id))
    |> Enum.map(fn team ->
      roster =
        t.id
        |> Tournaments.team_roster(team.id)
        |> Enum.filter(&Map.has_key?(nos, &1.id))
        |> Enum.map(&Map.fetch!(nos, &1.id))

      %{
        "no" => Map.fetch!(team_nos, team.id),
        "name" => team.name,
        "short_name" => blank_to_nil(team.short_name),
        # A captain's name is typed by the arbiter, like a tournament's own
        # `arbiter`/`deputy` fields above - not a player record, so the
        # player-data allowlist in `player_row/2` does not apply to it.
        "captain" => blank_to_nil(team.captain),
        "players" => roster
      }
    end)
    |> Enum.sort_by(& &1["no"])
  end

  # One match, board 1's colour, its board numbers and the points OpenPairings
  # computed - never recomputed by a reader. Withheld the same way a board's
  # own result is: `results_public?` nulls the points, never the teams
  # themselves, exactly as `boards/3` nulls a game's result but keeps the two
  # players. A hidden board is left out of the board-number list (display
  # only - see the moduledoc's note on `hidden`), which does not change the
  # points: those are the arithmetic the round's own standings already ran.
  #
  # `forfeit_decision` (added with match forfeits by decision): the team the
  # arbiter awarded the match to, `%{"to" => team no}`, or null. It says who
  # won the match, so it travels exactly when the match points do - one
  # condition, `points_public?`, gates both.
  defp match_row(m, team_nos, results_public?) do
    boards =
      m.boards
      |> Enum.reject(& &1.pairing.hidden)
      |> Enum.map(& &1.pairing.board)
      |> Enum.sort()

    points_public? = results_public? and m.complete?

    %{
      "number" => m.number,
      "team_a" => Map.get(team_nos, m.team_a_id),
      "team_b" => m.team_b_id && Map.get(team_nos, m.team_b_id),
      "bye" => m.bye?,
      # `team_a` has White on board 1 (`PairingsEngine.TeamRoundRobin`); named
      # explicitly rather than left implicit, so a reader never has to know
      # that convention to draw "Team A (White) 2-2 Team B".
      "board1_white_team" => not m.bye? && Map.get(team_nos, m.team_a_id),
      "boards" => boards,
      "game_points" => if(results_public?, do: %{"a" => m.gp_a, "b" => m.gp_b}),
      "match_points" => if(points_public?, do: %{"a" => m.mp_a, "b" => m.mp_b}),
      "forfeit_decision" => if(points_public?, do: forfeit_decision_row(m, team_nos))
    }
  end

  defp forfeit_decision_row(%{forfeited_to: team_id}, team_nos) when not is_nil(team_id),
    do: %{"to" => Map.get(team_nos, team_id)}

  defp forfeit_decision_row(_match, _team_nos), do: nil

  defp team_standings_row(%Tournament{} = t, team_nos, after_round) do
    codes = TeamStandings.effective_tiebreaks(t)
    hidden = t.public_hidden_tiebreaks || []

    shown =
      if PublicDisplay.show?(t.public_display, "tiebreaks"),
        do: Enum.reject(codes, &(&1 in hidden)),
        else: []

    entries =
      t
      |> TeamStandings.standings(through_round: after_round)
      |> Enum.filter(&Map.has_key?(team_nos, &1.team.id))

    rows =
      Enum.map(entries, fn e ->
        %{
          "rank" => e.rank,
          "team" => Map.fetch!(team_nos, e.team.id),
          "mp" => e.mp,
          "gp" => e.gp,
          "tiebreaks" => Enum.map(shown, &Map.get(e.tiebreaks, &1, 0.0)),
          "working" => team_working_json(e.working, shown, team_nos)
        }
      end)

    %{
      "after_round" => after_round,
      "tiebreaks" => Enum.map(shown, &%{"code" => &1, "label" => tiebreak_label(&1)}),
      "rows" => rows
    }
  end

  # Same shape and same withholding rule as `working_json/2` for individual
  # tie-breaks: an opponent that never publishes becomes `null` and a hidden
  # code simply is not a key.
  defp team_working_json(by_code, shown, team_nos) do
    by_code
    |> Map.take(shown)
    |> Map.new(fn {code, parts} ->
      {code,
       Enum.map(parts, fn part ->
         %{"round" => part.round, "value" => part.value}
         |> put_unless(
           :nil_opponent,
           "opponent",
           part.opponent_id && Map.get(team_nos, part.opponent_id)
         )
         |> put_unless(:played, "kind", part.kind)
       end)}
    end)
  end

  defp board_stats_row(%Tournament{} = t, nos, team_nos, after_round) do
    t
    |> TeamStandings.board_stats(through_round: after_round)
    |> Enum.filter(&Map.has_key?(nos, &1.player.id))
    |> Enum.map(fn r ->
      %{
        "player" => Map.fetch!(nos, r.player.id),
        "team" => Map.get(team_nos, r.team_id),
        "board" => r.main_board,
        "games" => r.games,
        "points" => r.points,
        "percentage" => r.percentage,
        "performance" => r.performance
      }
    end)
  end

  defp round_date(%Round{} = round, %Tournament{} = t) do
    blank_to_nil(round.date) || blank_to_nil(Enum.at(t.round_dates || [], round.number - 1))
  end

  # A board is a row with both seats filled. One seat filled is a
  # pairing-allocated bye (see `byes/4`); neither seat filled is a row an
  # arbiter has vacated entirely and there is nothing to report about it.
  #
  # Two numbers, because they answer different questions.
  #
  # `board` is the real integer column the engine assigned - stable, unique,
  # what a result is keyed on. `label` is the frozen `display_board` string
  # the arbiter's own screen and printed sheet show, which is not always the
  # same: a fixed-table player takes board 1001, and the boards after them
  # renumber to close the gap.
  #
  # Only `board` used to travel, on the reasoning that a label is a rendering
  # decision belonging to whoever draws the page. Right in principle, wrong in
  # practice - nobody drew it, so the public page showed 1001 for a game
  # printed as board 12 in the hall, and every board after it was off by one.
  # The old local public page ran the renumbering itself, and its comment
  # records this same bug being found and fixed once already.
  #
  # So the label travels too, and the rows travel in the order the arbiter
  # sees them, because the order is half of the disagreement.
  defp boards(pairings, nos, results_public?) do
    pairings
    |> Enum.filter(&(&1.white_player_id && &1.black_player_id))
    # Both seats must resolve to a published `no`. `publishable_players/1`
    # drops a player with no `pairing_number` so that `players` holds no
    # unreferenceable row - but dropping the player without dropping the
    # BOARD they sit on trades an orphan row for a dangling reference, which
    # is worse: the contract says every reference is a `no` and "nothing else
    # identifies a player", and `null` is not a `no`. A renderer looking that
    # up finds nothing and has no way to say why.
    #
    # A board with an unnumbered player is not publishable, so it is withheld
    # whole, exactly as a hidden board is.
    |> Enum.filter(
      &(Map.has_key?(nos, &1.white_player_id) and Map.has_key?(nos, &1.black_player_id))
    )
    |> PairingDisplay.with_display_boards()
    |> Enum.map(fn %{pairing: p, board: label} ->
      %{
        "board" => p.board,
        "label" => to_string(label),
        "white" => Map.fetch!(nos, p.white_player_id),
        "black" => Map.fetch!(nos, p.black_player_id),
        # Withheld here, at build time - see the moduledoc.
        "result" => if(results_public?, do: result_token(p.result))
      }
    end)
  end

  # The token OpenPairings already stores, verbatim, apart from the two legacy
  # forfeit spellings. A game with no result yet is `null`, not `""`.
  defp result_token(result) when result in [nil, "", "bye"], do: nil
  defp result_token(result), do: Map.get(@legacy_results, result, result)

  # Two sources, one list. A pairing-allocated bye is a real `Pairing` row with
  # one empty seat; every other kind is a `byes`-table row, which never appears
  # in `round.pairings` at all (see `Tournaments.list_byes_for_round/2`).
  defp byes(%Round{} = round, visible_pairings, %Tournament{} = t, nos, results_public?) do
    allocated =
      for p <- visible_pairings,
          is_nil(p.white_player_id) or is_nil(p.black_player_id),
          seated = p.white_player_id || p.black_player_id,
          not is_nil(seated),
          # Same rule as `boards/3`: an unnumbered player cannot be referenced,
          # so their bye is withheld rather than emitted against a null.
          Map.has_key?(nos, seated),
          # A result recorded against a vacated seat is a result, and goes
          # where the round's other results go - see the moduledoc.
          results_public? or not recorded_result?(p) do
        one_seat_row(p, seated, round.number, t, nos)
      end

    # Every cumulative absence count in one query, built before the loop -
    # `bye_points_for_row/2` would ask the database once per emitted row.
    absent_counts = Standings.absent_counts(t)

    recorded =
      for row <- Tournaments.list_byes_for_round(t.id, round.number),
          Map.has_key?(nos, row.player_id) do
        %{
          "player" => Map.get(nos, row.player_id),
          "kind" => Map.get(@bye_kinds, row.type, row.type),
          # `bye_points_for_row/3` rather than `bye_points/4`: it works out the
          # round and the cumulative-absence count SWAR's two "Pt ABSENT" caps
          # need, so a capped absence is published at the value the crosstable
          # actually used.
          "points" => Standings.bye_points_for_row(row, t, absent_counts)
        }
      end

    Enum.sort_by(allocated ++ recorded, & &1["player"])
  end

  defp recorded_result?(%{result: r}), do: r not in [nil, "", "bye"]

  # One seat empty, and nothing recorded on the board: a genuine
  # pairing-allocated bye, worth the tournament's bye value.
  defp one_seat_row(%{result: r}, seated, _round_number, %Tournament{} = t, nos)
       when r in [nil, "", "bye"] do
    %{
      "player" => Map.fetch!(nos, seated),
      "kind" => "pairing-allocated",
      "points" => Standings.bye_points("pairing-allocated", t)
    }
  end

  # One seat empty, and a result recorded against it anyway - the shape a SWAR
  # or TRF import can carry, and the one an arbiter reaches when someone
  # forfeits a board whose opponent has already been vacated.
  #
  # Every such row used to be published as a pairing-allocated bye at
  # `bye_value`, so a player who forfeited a round appeared on the public site
  # with a full point for it. Worse than merely wrong on this row: OpenResults
  # reconstructs each player's running total by adding these per-round figures
  # up (`OpenResultsWeb.Tournament.round_contributions/1`), so one invented
  # point moved every later total on that player's card, while the `standings`
  # block in the same document - computed from `Standings`, which scores the
  # result - said something else. The identical bug was fixed in the SWAR
  # publish path first; see `Bel.SwarPublish.single_seat_award/2`.
  #
  # The points therefore come from `Standings.pairing_award/3`, not from a
  # second opinion formed here, so this row and the crosstable travelling with
  # it are the same arithmetic.
  #
  # `kind` says "vacated-seat" rather than reusing one of the bye kinds. The
  # contract's kinds each name a bye an arbiter granted; this is a board that
  # lost its opponent, which is not one of them, and a renderer that has not
  # heard of the word prints it verbatim rather than mislabelling it (see the
  # `@bye_kinds` note above for the same reasoning applied to bye types). The
  # result token travels alongside so the page can say WHY the score is what
  # it is; an unknown key is ignored by an older server, which is why this is
  # additive rather than a change to `boards/3`'s shape - `boards[].white` and
  # `boards[].black` are contractually non-null, and a snapshot is sent to
  # whatever version of OpenResults is deployed, not to this checkout's.
  defp one_seat_row(p, seated, round_number, %Tournament{} = t, nos) do
    %{
      "player" => Map.fetch!(nos, seated),
      "kind" => "vacated-seat",
      "result" => result_token(p.result),
      "points" => p |> Standings.pairing_award(round_number, t) |> Map.get(seated, 0.0)
    }
  end

  ## ---------- standings ----------

  # Computed here, ordered here, tiebroken here. OpenResults never calculates a
  # placing - the arbiter's screen and the public page have to agree, and the
  # printed crosstable is the document of record.
  defp standings(%Tournament{pairing_system: "keizer"} = t, nos, after_round) do
    rows =
      t
      |> Keizer.standings(through_round: after_round)
      |> Enum.filter(&Map.has_key?(nos, &1.player.id))
      |> Enum.map(fn e ->
        %{
          "rank" => e.rank,
          "player" => Map.get(nos, e.player.id),
          # The three columns a Keizer ladder actually shows (see
          # `PublicStandingsLive`): Keizer points rank the field, `value` is
          # the player's current Keizer value and `score` the plain game score.
          "points" => e.points,
          "value" => e.value,
          "score" => e.raw_points,
          "category" => blank_to_nil(Categories.pairing_category(t, e.player))
        }
      end)

    %{
      "after_round" => after_round,
      # A Keizer ladder has no FIDE tiebreak columns - it ranks on Keizer
      # points alone. Declaring the tournament's configured codes here would
      # promise values `rows[].tiebreaks` cannot supply positionally.
      "tiebreaks" => [],
      "rows" => rows
    }
  end

  defp standings(%Tournament{} = t, nos, after_round) do
    # `codes` is what the tournament RANKS on; `shown` is what the public
    # page is allowed to see. Both are needed and they are different: a code
    # the arbiter has hidden still decided the order, and a page that showed
    # some of the working and none of the rest would read as broken rather
    # than as withheld.
    codes = t.tiebreaks || []
    hidden = t.public_hidden_tiebreaks || []

    entries =
      t
      |> Standings.standings(through_round: after_round)
      # The arbiter's hand-set order, when they have taken it over, is the
      # authority - same call and same restriction (never Keizer) as the
      # arbiter's own standings page.
      |> Standings.apply_manual_ranking(t)
      |> Enum.filter(&Map.has_key?(nos, &1.player.id))
      |> Enum.sort_by(& &1.rank)

    # How each tiebreak number was reached, per player - see
    # `PairingsEngine.TiebreakWorking`. Computed here and nowhere else in the
    # app: it is only ever wanted by a reader asking "why am I fourth", and
    # that reader is on the public site.
    #
    # WITHHELD, not merely hidden, when the arbiter has turned the tiebreak
    # columns off. They are hiding the arithmetic, and a per-opponent
    # decomposition is more of it than the columns ever showed - so it must
    # not travel at all, rather than travel and rely on the renderer to
    # remember. That is the contract's own rule for a round or a board the
    # arbiter withheld, and it applies here for the same reason.
    shown =
      if PublicDisplay.show?(t.public_display, "tiebreaks"),
        do: Enum.reject(codes, &(&1 in hidden)),
        else: []

    working =
      if PublicDisplay.show?(t.public_display, "tiebreak_working") and shown != [] do
        TiebreakWorking.working(
          entries,
          t,
          Enum.filter(shown, &(&1 in TiebreakWorking.publishable_codes()))
        )
      else
        %{}
      end

    rows =
      entries
      |> Enum.map(fn e ->
        %{
          "rank" => e.rank,
          "player" => Map.get(nos, e.player.id),
          # Game points, matching the "Pts" column of the public standings
          # page. `total` would silently fold in administrative extra points
          # for tournaments that do not rank on them.
          "points" => e.points,
          # Positional against `standings.tiebreaks` below, so both are built
          # from `shown` - a hidden code leaves no gap and no `null`, it is
          # simply not part of the document.
          "tiebreaks" => Enum.map(shown, &Map.get(e.tiebreaks, &1, 0.0)),
          "working" => working_json(Map.get(working, e.player.id, %{}), nos),
          "category" => blank_to_nil(Categories.pairing_category(t, e.player))
        }
      end)

    %{
      "after_round" => after_round,

      # Added 2026-08-29. The order above is already the arbiter's, but the
      # DISCLOSURE that it was set by hand rather than computed used to live
      # only on this app's own public standings page - the one surface a
      # non-logged-in viewer saw. That page is gone, so without this the
      # ordering travels and the fact that a person chose it does not, which
      # is the most misleading shape this feature has.
      #
      # See docs/manual-standings.md, which lists every surface that must
      # carry the banner.
      "manual_order" => manual?(t),

      # Two ways a hand-set order stops describing the tournament. Both are
      # warned about on the arbiter's own standings page and neither was
      # travelling, so the public page said "the arbiter chose this order"
      # while the arbiter's screen said "...and it is now wrong".
      #
      # Read from the same two functions that page calls, rather than
      # recomputed here, because two answers to "is this stale" is exactly
      # the failure this is fixing.
      "manual_stale" => manual?(t) and Standings.manual_ranking_stale?(t),
      "manual_incomplete" => manual?(t) and Standings.manual_ranking_incomplete?(entries),
      "tiebreaks" => Enum.map(shown, &%{"code" => &1, "label" => tiebreak_label(&1)}),

      # Whether the ORDER above used a tie-break that is not in the list.
      # Added 2026-08-30 with per-tie-break visibility.
      #
      # Hiding a column hides the arithmetic, not its effect: two players can
      # sit one above the other with every published number identical, and
      # nothing on the page to say why. That is worse than hiding all of them,
      # because a partial explanation reads as a broken one. So the page is
      # told, and says so.
      #
      # Compared against the RANKING codes, not the configured ones: a
      # tie-break C.07 Article 10 already dropped never affected the order, so
      # hiding it is not withholding anything.
      "tiebreaks_withheld" => Enum.any?(Standings.effective_tiebreaks(t), &(&1 not in shown)),
      "rows" => rows
    }
  end

  # Player ids never cross this boundary, so an opponent becomes their
  # pairing number. An opponent who is not in the published roster at all
  # becomes `null` - the same shape a virtual opponent has, which is correct:
  # in both cases there is nobody on this page to point at.
  defp working_json(by_code, nos) do
    Map.new(by_code, fn {code, %{total: total, parts: parts}} ->
      {code,
       %{
         "total" => total,
         "parts" => Enum.map(parts, &part_json(&1, nos))
       }}
    end)
  end

  # `opponent` and `kind` are omitted at their commonest values rather than
  # sent as `null` and `"played"` on every part. There are as many parts as
  # players x codes x rounds, so the two keys cost more than everything else
  # in the document put together on a large event; absent-means-default is
  # already how `listed` and `manual_order` read.
  defp part_json(part, nos) do
    %{"round" => part.round, "value" => part.value}
    |> put_unless(:nil_opponent, "opponent", part.opponent_id && Map.get(nos, part.opponent_id))
    |> put_unless(:played, "kind", part.kind)
  end

  defp put_unless(map, :nil_opponent, _key, nil), do: map
  defp put_unless(map, :nil_opponent, key, no), do: Map.put(map, key, no)
  defp put_unless(map, :played, _key, :played), do: map
  defp put_unless(map, :played, key, kind), do: Map.put(map, key, to_string(kind))

  defp tiebreak_label(code) do
    case Tiebreaks.get(code) do
      %{name: name} -> name
      nil -> code
    end
  end

  ## ---------- helpers ----------

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The BUILD, not the release. OpenResults stores this against every
  # snapshot it receives, so "which build produced this document" is
  # answerable months later from the receiving side alone - and a document
  # that arrived from a build nobody can identify says so.
  defp app_version, do: PairingsEngine.Build.id()

  # A missing key and a null mean the same thing to the reader: not known. A
  # blank string does not - it would render as an empty column rather than as
  # an absent one.
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # This app stores "no rating" as 0 (see `Player.rating/1`); the contract has
  # no such convention, and a published 0 would read as a real rating.
  defp zero_to_nil(0), do: nil
  defp zero_to_nil(rating), do: rating
end
