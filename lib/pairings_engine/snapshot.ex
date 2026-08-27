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
    * `standings` is computed `through_round: published_through/1`, the
      longest *contiguous* published prefix. The highest published round is
      the wrong bound: with round 3 published and round 2 held back, standings
      through 3 would silently carry round 2's results. This is exactly the
      contract's note that `after_round` need not be the highest published
      round.
    * A `Pairing` with `hidden` set never reaches `boards`.

  One consequence of the last point, stated rather than left to be discovered:
  a hidden board's result still counts in `standings`, because it counts in the
  arbiter's own crosstable - `hidden` is a display flag, and standings that
  disagreed with the hall would be a worse failure than an unexplained half
  point. Today the flag is only settable on a fully-vacated row (no players, no
  result), so nothing is actually withheld; the note is for the day that
  widens.

  ## Only the fields the contract lists may travel

  `player_row/1` is a hand-written allowlist, never `Map.from_struct/1` or a
  `Map.drop/2` of known-bad keys - a new personal-data column added to
  `players` must default to not being published, rather than defaulting to
  being published until somebody remembers to exclude it. Email, phone,
  birth date, birth year, national id and the free-form `norm_data` map stay
  in the arbiter's database.
  """

  alias PairingsEngine.{Keizer, Standings, Tiebreaks, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

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
    players = publishable_players(tournament)
    # Every cross-reference in the document resolves through this map, so
    # there is exactly one place `no` is decided.
    nos = Map.new(players, &{&1.id, &1.pairing_number})

    rounds = published_rounds(tournament)
    after_round = published_through(Enum.map(rounds, & &1.number))

    %{
      "schema" => @schema,
      "version" => @version,
      "published_at" => now_iso8601(),
      "source" => %{"app" => "openpairings", "version" => app_version()},
      "tournament" => tournament_row(tournament),
      "players" => Enum.map(players, &player_row/1),
      "rounds" => Enum.map(rounds, &round_row(&1, tournament, nos)),
      "standings" => standings(tournament, nos, after_round)
    }
  end

  ## ---------- tournament ----------

  defp tournament_row(%Tournament{} = t) do
    %{
      # The tournament's existing public identity (`/p/:slug/...`), not a
      # second naming scheme invented for this payload - the registration
      # payload travelling the other way keys off the same string.
      "slug" => t.public_slug,
      "name" => t.name,
      "city" => blank_to_nil(t.city),
      "federation" => blank_to_nil(t.federation),
      "start_date" => blank_to_nil(t.start_date),
      "end_date" => blank_to_nil(t.end_date),
      "rounds_count" => t.rounds_count,
      "system" => system(t),
      "arbiter" => blank_to_nil(t.chief_arbiter),
      "fide_rated" => t.fide_homologated
    }
  end

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
  defp publishable_players(%Tournament{} = t) do
    t.id
    |> Tournaments.list_players()
    |> Enum.filter(&is_integer(&1.pairing_number))
    |> Enum.sort_by(& &1.pairing_number)
  end

  # An allowlist by construction - see the moduledoc. Anything not named here
  # stays in the arbiter's database, whether or not it existed when this was
  # written.
  defp player_row(%Player{} = p) do
    %{
      "no" => p.pairing_number,
      "name" => p.name,
      "title" => blank_to_nil(p.title),
      "rating" => zero_to_nil(Player.rating(p)),
      "federation" => blank_to_nil(p.federation),
      "fide_id" => p.fide_id,
      "club" => blank_to_nil(p.club),
      "category" => blank_to_nil(p.category)
    }
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

  # The longest contiguous run 1..n of published rounds - see the moduledoc for
  # why the highest published number is the wrong bound for standings.
  defp published_through(numbers), do: published_through(MapSet.new(numbers), 0)

  defp published_through(set, n) do
    if MapSet.member?(set, n + 1), do: published_through(set, n + 1), else: n
  end

  defp round_row(%Round{} = round, %Tournament{} = t, nos) do
    visible = Enum.reject(round.pairings, & &1.hidden)

    %{
      "number" => round.number,
      "date" => round_date(round, t),
      "boards" => boards(visible, nos),
      "byes" => byes(round, visible, t, nos)
    }
  end

  defp round_date(%Round{} = round, %Tournament{} = t) do
    blank_to_nil(round.date) || blank_to_nil(Enum.at(t.round_dates || [], round.number - 1))
  end

  # A board is a row with both seats filled. One seat filled is a
  # pairing-allocated bye (see `byes/4`); neither seat filled is a row an
  # arbiter has vacated entirely and there is nothing to report about it.
  #
  # `board` is the real integer column, not the frozen `display_board` label -
  # the contract types this as a number, and a fixed-table label like "1001" or
  # a slash-joined "5/6" is a rendering decision that belongs to whoever draws
  # the page.
  defp boards(pairings, nos) do
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
    |> Enum.sort_by(& &1.board)
    |> Enum.map(fn p ->
      %{
        "board" => p.board,
        "white" => Map.fetch!(nos, p.white_player_id),
        "black" => Map.fetch!(nos, p.black_player_id),
        "result" => result_token(p.result)
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
  defp byes(%Round{} = round, visible_pairings, %Tournament{} = t, nos) do
    allocated =
      for p <- visible_pairings,
          is_nil(p.white_player_id) or is_nil(p.black_player_id),
          seated = p.white_player_id || p.black_player_id,
          not is_nil(seated),
          # Same rule as `boards/2`: an unnumbered player cannot be referenced,
          # so their bye is withheld rather than emitted against a null.
          Map.has_key?(nos, seated) do
        %{
          "player" => Map.fetch!(nos, seated),
          "kind" => "pairing-allocated",
          "points" => Standings.bye_points("pairing-allocated", t)
        }
      end

    recorded =
      for row <- Tournaments.list_byes_for_round(t.id, round.number),
          Map.has_key?(nos, row.player_id) do
        %{
          "player" => Map.get(nos, row.player_id),
          "kind" => Map.get(@bye_kinds, row.type, row.type),
          # `bye_points_for_row/2` rather than `bye_points/4`: it works out the
          # round and the cumulative-absence count SWAR's two "Pt ABSENT" caps
          # need, so a capped absence is published at the value the crosstable
          # actually used.
          "points" => Standings.bye_points_for_row(row, t)
        }
      end

    Enum.sort_by(allocated ++ recorded, & &1["player"])
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
          "category" => blank_to_nil(e.player.category)
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
    codes = t.tiebreaks || []

    rows =
      t
      |> Standings.standings(through_round: after_round)
      # The arbiter's hand-set order, when they have taken it over, is the
      # authority - same call and same restriction (never Keizer) as
      # `PublicStandingsLive`.
      |> Standings.apply_manual_ranking(t)
      |> Enum.filter(&Map.has_key?(nos, &1.player.id))
      |> Enum.sort_by(& &1.rank)
      |> Enum.map(fn e ->
        %{
          "rank" => e.rank,
          "player" => Map.get(nos, e.player.id),
          # Game points, matching the "Pts" column of the public standings
          # page. `total` would silently fold in administrative extra points
          # for tournaments that do not rank on them.
          "points" => e.points,
          "tiebreaks" => Enum.map(codes, &Map.get(e.tiebreaks, &1, 0.0)),
          "category" => blank_to_nil(e.player.category)
        }
      end)

    %{
      "after_round" => after_round,
      "tiebreaks" => Enum.map(codes, &%{"code" => &1, "label" => tiebreak_label(&1)}),
      "rows" => rows
    }
  end

  defp tiebreak_label(code) do
    case Tiebreaks.get(code) do
      %{name: name} -> name
      nil -> code
    end
  end

  ## ---------- helpers ----------

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp app_version do
    case Application.spec(:pairings_engine, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

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
