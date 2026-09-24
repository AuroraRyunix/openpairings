defmodule PairingsEngine.TrfExport do
  @moduledoc """
  User-facing FIDE TRF16 export of a tournament's full roster, as opposed to
  `PairingsEngine.Pairing.javafo_input/2` (a JaVaFo-only input file, built
  from active players and fed straight into the pairing engine - never
  downloaded by a user).

  The distinguishing feature here is **round selection**: `export/2` can
  produce a TRF containing only a chosen subset of rounds - the header's
  round-dates line and every player's per-round result columns are trimmed
  to match, and points are recomputed from the filtered games only. See
  `parse_rounds/2` for the accepted `rounds` query-param syntax and
  `docs/import-export.md` for the user-facing reference.

  Only players who have actually been included in a paired round (i.e. have
  a `pairing_number`) are exported - see
  `PairingsEngine.Pairing.trf_player_rows/2`.
  """

  alias PairingsEngine.{Federation, Pairing, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # The app's one TRF16 implementation, and the one TRF error type that goes
  # with it. There used to be a local `PairingsEngine.Trf` as well - a
  # photocopy Ainalrami's was taken from, which then kept growing while the
  # copy stood still. What is left in this app is the adapter above: turning
  # Ecto structs into the plain maps the writer takes.
  alias Ainalrami.Trf
  alias Ainalrami.Trf.ValidationError

  @doc """
  Builds the TRF26 text for `tournament`, limited to `rounds_spec` (either a
  raw query-param string per `parse_rounds/2`, or an already-parsed list of
  round numbers). Defaults to every paired round when `rounds_spec` is
  `nil`/blank. `dialect: :engine` asks for the older `XX*`/`BB*` spelling the
  pairing programs read; the default is FIDE's TRF26 (see `Ainalrami.Trf`,
  "Two dialects").

  Returns `{:ok, text}`, or `{:error, %Ainalrami.Trf.ValidationError{}}`
  if the filtered result set fails `Trf`'s own legality validation (an
  unrecognized or mutually-inconsistent result code) - never raises.
  """
  def export(tournament, rounds_spec \\ nil, opts \\ []) do
    with :ok <- ensure_round_dates(tournament, rounds_spec) do
      {:ok, build(tournament, rounds_spec, opts)}
    end
  rescue
    e in ValidationError -> {:error, e}
  end

  # SWAR parity #23 (manual standings override) is deliberately NOT
  # surfaced in this file - see docs/manual-standings.md for the full
  # reasoning. In short: the FIDE "086-089 Rank" column and the "005-008
  # Starting rank" column both carry `pairing_number` in this codebase (see
  # `Pairing.trf_player_rows/2`), and every game's opponent cross-reference
  # is baked against that same value - rewriting it per player to the
  # standings rank would desync those references and fail
  # `Trf.serialize/1`'s own cross-check, so this doesn't touch it. There is
  # therefore no hidden override to disclose in this file at all: the TRF's
  # rank column was never affected by manual ranking in the first place.
  # The UI (the page offering this download) carries the caveat instead -
  # see `PairingsEngineWeb.PairingsLive`.

  @doc """
  Parses a `rounds` query-param string into a sorted, deduped list of round
  numbers clamped to `1..max_round`.

  Accepts a comma-separated mix of single round numbers and dash ranges,
  e.g. `"1-5"`, `"1,2,4"`, or `"1-3,6,8-9"`. Out-of-range or unparsable
  tokens are silently dropped rather than raising. `nil`, `""`, or a spec
  that yields no valid rounds at all defaults to every round in
  `1..max_round`.
  """
  def parse_rounds(spec, max_round)

  def parse_rounds(nil, max_round), do: all_rounds(max_round)
  def parse_rounds("", max_round), do: all_rounds(max_round)

  def parse_rounds(spec, max_round) when is_binary(spec) do
    rounds =
      spec
      |> String.split(",", trim: true)
      |> Enum.flat_map(&parse_token(&1, max_round))
      |> Enum.uniq()
      |> Enum.sort()

    if rounds == [], do: all_rounds(max_round), else: rounds
  end

  defp all_rounds(max_round) when is_integer(max_round) and max_round > 0,
    do: Enum.to_list(1..max_round)

  defp all_rounds(_), do: []

  defp parse_token(token, max_round) do
    case token |> String.trim() |> String.split("-", trim: true) do
      [a, b] ->
        with {lo, ""} <- Integer.parse(String.trim(a)),
             {hi, ""} <- Integer.parse(String.trim(b)),
             true <- lo <= hi do
          Enum.to_list(max(lo, 1)..min(hi, max_round)//1)
        else
          _ -> []
        end

      [a] ->
        case Integer.parse(a) do
          {n, ""} when n >= 1 and n <= max_round -> [n]
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Resolves the export metadata needed to build the download filename (see
  `PairingsEngineWeb.ExportController`): the concrete list of rounds that
  `export/2` will produce for the same `rounds_spec` (after clamping/
  defaulting per `parse_rounds/2`), and the FIDE tournament ID that applies
  to that round range per `applicable_fide_id/2`. Kept separate from
  `export/2` itself so the controller can compute the filename without
  parsing the TRF text back out just to find out which rounds/ID it used.
  """
  def export_meta(tournament, rounds_spec \\ nil) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)

    %{rounds: rounds, fide_id: applicable_fide_id(tournament, rounds)}
  end

  @doc """
  The FIDE tournament ID that applies to `rounds` (a list of round numbers,
  e.g. from `parse_rounds/2`) - SWAR's "this FIDE ID applies to rounds X-Y"
  model (`tournament.fide_id_ranges`, see
  `PairingsEngine.Tournaments.Tournament`'s schema doc).

  Resolution:

    * If exactly one configured range fully covers `rounds` (its
      `from_round..to_round` spans at least `min(rounds)..max(rounds)`),
      that range's ID is used - this is the common case (a report cleanly
      split by round).
    * Otherwise - no ranges configured, the round span crosses more than
      one range's boundary, only partially overlaps one, or matches none -
      falls back to the tournament-wide `tournament.fide_tournament_id`.
      This never raises: an unresolvable/blank case simply yields `nil`,
      which the filename builder renders as an omitted segment (e.g. a
      tournament that isn't FIDE-homologated at all).

  Returns `nil` rather than `""` for "no ID applies", regardless of which
  field it came from.
  """
  def applicable_fide_id(tournament, rounds) do
    with [_ | _] <- rounds,
         min_r = Enum.min(rounds),
         max_r = Enum.max(rounds),
         [range] <-
           Enum.filter(tournament.fide_id_ranges || [], fn r ->
             r["from_round"] <= min_r and r["to_round"] >= max_r
           end) do
      blank_to_nil(range["fide_tournament_id"])
    else
      _ -> blank_to_nil(tournament.fide_tournament_id)
    end
  end

  defp build(tournament, rounds_spec, opts) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)
    dialect = Keyword.get(opts, :dialect, :trf26)

    players = Tournaments.list_players(tournament.id)

    trf_players =
      tournament
      |> Pairing.trf_player_rows(players)
      |> Enum.map(&report_unknown(&1, dialect))
      |> Enum.map(&filter_player_games(&1, rounds, tournament))
      # Baku virtual points for the rounds in the file. The report had
      # left them out altogether; TRF26 wants them (`250`) for pairing.
      |> then(&Pairing.accelerated_rows(tournament, &1, players, length(rounds)))
      |> append_future_byes(tournament, rounds, paired)

    last_round = Enum.reduce(trf_players, length(rounds), &max(length(&1.games), &2))

    # Postponed games, as `{starting rank, column}` - see `mark_unknown/2`.
    unknown = if dialect == :trf26, do: postponed_columns(trf_players), else: []
    point_system = unknown_point_value(Tournament.engine_point_system(tournament), unknown)

    tournament
    |> serialize(trf_players, players, rounds, last_round, point_system, dialect)
    |> mark_unknown(unknown)
  end

  defp serialize(tournament, trf_players, players, rounds, last_round, point_system, dialect) do
    Trf.serialize(
      %{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          # Defensive normalization: the SWAR importer already normalizes a
          # Belgian regional marker (VSF/FEFB/FRBE/"FIDE"/...) to "BEL" on
          # import, but a tournament imported before that normalization
          # existed may still carry the raw marker in the database - reusing
          # the same helper here means it exports "032 BEL" either way, with
          # no re-import required. A no-op for every other federation value
          # (see `PairingsEngine.Federation.normalize/1`).
          federation: Federation.normalize(tournament.federation),
          start_date: tournament.start_date,
          end_date: tournament.end_date,
          number_of_rated_players: Enum.count(trf_players, &((&1.fide_rating || 0) > 0)),
          type: tournament.type,
          chief_arbiter: chief_arbiter_line(tournament),
          deputy_arbiters: deputy_arbiter_lines(tournament),
          time_control: blank_to_nil(tournament.rate_of_play),
          # The tournament's LENGTH, not how much of it this file carries.
          #
          # It used to be the latter, on the reasoning that a `?rounds=1-3`
          # export of a 5-round event should describe itself honestly as 3
          # rounds. That conflated two questions: how many rounds are in
          # this file (which the columns already answer) and how many
          # rounds the event has, which is what TRF26 defines `142` as and
          # what every reader does with it. A pairing engine handed the
          # file applies the final-round colour exception by this number,
          # so understating it makes the engine treat an ordinary round as
          # the last one. `round_dates` below stays filtered to `rounds` -
          # a date the file does not cover is a date it should not claim.
          number_of_rounds: max(tournament.rounds_count || 0, last_round),
          round_dates: filter_round_dates(tournament.round_dates, rounds),
          generator: "OpenPairings v#{app_version()}",
          # TRF26's headers and records - what FIDE reads, in FIDE's
          # spelling. `192` names the system that paired the boards, `202`
          # the tie-breaks as configured (already FIDE's own codes), `222`
          # the rate of play where its wording encodes (`RateOfPlay`),
          # `162` a point system other than 1/half/0, `260` the prohibited
          # pairings - explicit ones and those by club or federation.
          type_code: tournament_type_code(tournament),
          tie_breaks: tie_break_codes(tournament),
          time_control_code: PairingsEngine.RateOfPlay.trf26_code(tournament.rate_of_play),
          point_system: point_system,
          free_points: free_point_records(players, tournament),
          forbidden_pairs:
            Pairing.forbidden_pairs(tournament.id, players) ++
              Pairing.exclusion_pairs(tournament, players)
        },
        players: trf_players,
        teams: team_records(tournament, players, trf_players)
      },
      # `:trf26` for the file an arbiter uploads; `:engine` on request, for
      # a pairing program that reads the older `XX*`/`BB*` spelling.
      dialect: dialect,
      column_legend: true,
      # This file leaves the building - it is what an arbiter submits to
      # FIDE - so it must survive a byte-oriented reader. See
      # `Trf.serialize/2`'s `:ascii` option.
      ascii: true
    )
  end

  ## ---------- postponed games: TRF26's `?` ----------
  #
  # A postponed game (`"*"`, VCL4THP Q164-165) is written as TRF26's unknown
  # result, `?`, on both players' `001` lines, and the `162` record declares
  # what an unknown result is worth with `X` - a draw, because that is what
  # the game counts as until it is played, so a reader adding up the columns
  # gets the same points column this file states. A file carrying `?` is by
  # construction not a final report: no reader can take an unknown result
  # for a known one.
  #
  # `Ainalrami.Trf.serialize/2` refuses `?` in both dialects (its moduledoc,
  # "The `?` unknown result"). So the game goes to the writer as the draw
  # `Pairing.trf_player_rows/3` already hands the engine, and the character
  # is swapped afterwards at the one column the round block defines for it.
  # The swap checks the character it replaces, so a column that is not the
  # draw it expects raises rather than being written over. The engine
  # dialect keeps the draw: that spelling exists to be read by a pairing
  # program, which pairs a postponed game as a draw and cannot read `?`.
  #
  # When Ainalrami's writer accepts `?` (an `allow_unknown_result` switch on
  # `serialize/2`, which today only `parse/1` passes), this becomes a
  # `result: "?"` on the game and `mark_unknown/2` goes away.
  # In a TRF26 report every game that is `?` - an open postponed game, and
  # one that was sent as `?` in a report marked as sent (`finalised_open`),
  # whose real result goes in the postponed-games file and never here - is
  # written as the draw `mark_unknown/2` turns into `?`, and scores what the
  # file's own `X` says: a draw. So the points column adds up from the file
  # itself, whatever the club counts a postponed game as in its standings.
  # A file for sending that disagreed with itself would be wrong data.
  defp report_unknown(row, :trf26) do
    games =
      Enum.map(row.games, fn game ->
        if Map.get(game, :postponed) == true or Map.get(game, :finalised_open) == true do
          %{game | result: "="} |> Map.put(:postponed, true) |> Map.put(:provisional_points, nil)
        else
          game
        end
      end)

    %{row | games: games}
  end

  defp report_unknown(row, _dialect), do: row

  ## ---------- the postponed-games file ----------

  @doc """
  The TRF26 file for postponed games that were sent as `?` in a report
  marked as sent and have been played since (`PostponedGames.sendable_late_games/1`),
  packed into as few extra rounds as possible with nobody twice in a round
  (`PostponedGames.pack/1`). Each round is dated by the latest date one of
  its games was played on. Only the players in those games are in the file,
  under their own starting ranks, so every opponent reference is the same
  number it is in the main report.

  Returns `{:ok, text, games}` - the games it carries, for the caller to
  mark as sent - or `{:error, :nothing_to_send}` /
  `{:error, %ValidationError{}}`. Before it returns a file it reads it back
  and checks it says exactly what was meant: every game once, nobody twice
  in a round, the result each board holds. A file that fails that is not
  returned at all.
  """
  def postponed_export(tournament) do
    case PairingsEngine.PostponedGames.sendable_late_games(tournament) do
      [] ->
        {:error, :nothing_to_send}

      games ->
        rounds = games |> Enum.map(& &1.pairing) |> PairingsEngine.PostponedGames.pack()
        text = build_postponed(tournament, rounds)
        :ok = verify_postponed!(text, rounds)
        {:ok, text, games}
    end
  rescue
    e in ValidationError -> {:error, e}
  end

  defp build_postponed(tournament, rounds) do
    roster = Pairing.full_roster_players(tournament.id) |> Map.new(&{&1.id, &1})

    ids =
      rounds
      |> List.flatten()
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.uniq()

    blank = %{opponent_rank: nil, colour: nil, result: nil}

    rows =
      ids
      |> Enum.map(&Map.fetch!(roster, &1))
      |> Enum.sort_by(& &1.pairing_number)
      |> Enum.map(fn p ->
        games =
          Enum.map(rounds, fn games ->
            case Enum.find(games, &(p.id in [&1.white_player_id, &1.black_player_id])) do
              nil -> blank
              pairing -> Pairing.trf_game(pairing, p.id, roster, tournament)
            end
          end)

        %{
          rank: p.pairing_number,
          sex: p.sex,
          title: p.title,
          name: p.name,
          fide_rating: p.fide_rating,
          federation: p.federation,
          fide_number: p.fide_id,
          points: Pairing.player_points(games, tournament),
          games: games
        }
      end)

    dates =
      Enum.map(rounds, fn games ->
        games
        |> Enum.map(& &1.played_on)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(Date, fn -> nil end)
      end)

    Trf.serialize(
      %{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          federation: Federation.normalize(tournament.federation),
          start_date: tournament.start_date,
          end_date: tournament.end_date,
          number_of_rated_players: Enum.count(rows, &((&1.fide_rating || 0) > 0)),
          type: tournament.type,
          chief_arbiter: chief_arbiter_line(tournament),
          deputy_arbiters: deputy_arbiter_lines(tournament),
          time_control: blank_to_nil(tournament.rate_of_play),
          number_of_rounds: length(rounds),
          round_dates: Enum.map(dates, &(&1 && Date.to_iso8601(&1))),
          generator: "OpenPairings v#{app_version()}",
          type_code: tournament_type_code(tournament),
          time_control_code: PairingsEngine.RateOfPlay.trf26_code(tournament.rate_of_play),
          point_system: Tournament.engine_point_system(tournament)
        },
        players: rows
      },
      dialect: :trf26,
      column_legend: true,
      ascii: true
    )
  end

  # Reads the file back and checks it against what was meant to be in it.
  # Nothing here trusts the builder above: a file for sending is checked the
  # way the federation will read it.
  defp verify_postponed!(text, rounds) do
    parsed = Trf.parse(text)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    rounds
    |> Enum.with_index()
    |> Enum.each(fn {games, index} ->
      in_round =
        parsed.players
        |> Enum.filter(&(Enum.at(&1.games, index, %{})[:opponent_rank] != nil))
        |> length()

      if in_round != 2 * length(games) do
        raise ValidationError,
          message:
            "postponed-games file, round #{index + 1}: #{in_round} players with a game, " <>
              "#{2 * length(games)} expected"
      end

      # Each game where it was meant to be: White against Black, in this
      # round, with the colours the board had.
      for pairing <- games do
        white = pairing.white_player.pairing_number
        black = pairing.black_player.pairing_number
        w = by_rank |> Map.fetch!(white) |> Map.fetch!(:games) |> Enum.at(index)
        b = by_rank |> Map.fetch!(black) |> Map.fetch!(:games) |> Enum.at(index)

        unless w[:opponent_rank] == black and b[:opponent_rank] == white and
                 w[:colour] == "w" and b[:colour] == "b" do
          raise ValidationError,
            message:
              "postponed-games file, round #{index + 1}: the game #{white}-#{black} " <>
                "is not written as it was played"
        end
      end
    end)

    total =
      parsed.players |> Enum.flat_map(& &1.games) |> Enum.count(&(&1[:opponent_rank] != nil))

    if total != 2 * length(List.flatten(rounds)) or map_size(by_rank) != length(parsed.players) do
      raise ValidationError, message: "postponed-games file does not carry each game exactly once"
    end

    :ok
  end

  defp postponed_columns(trf_players) do
    for player <- trf_players,
        {game, column} <- Enum.with_index(player.games, 1),
        Map.get(game, :postponed) == true,
        do: {player.rank, column}
  end

  defp unknown_point_value(system, []), do: system
  defp unknown_point_value(system, _unknown), do: Map.put(system, :unknown, system.draw)

  defp mark_unknown(text, []), do: text

  defp mark_unknown(text, unknown) do
    by_rank = Enum.group_by(unknown, &elem(&1, 0), &elem(&1, 1))

    text
    |> String.split("\r\n")
    |> Enum.map(&mark_line(&1, by_rank))
    |> Enum.join("\r\n")
  end

  defp mark_line("001" <> _ = line, by_rank) do
    rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()

    Enum.reduce(Map.get(by_rank, rank, []), line, fn column, acc ->
      # Round blocks start at column 92, ten columns each, the result in the
      # eighth: column 99 for round 1. Zero-based here, one-based in TRF.
      at = 98 + (column - 1) * 10

      case binary_part(acc, at, 1) do
        "=" ->
          binary_part(acc, 0, at) <> "?" <> binary_part(acc, at + 1, byte_size(acc) - at - 1)

        other ->
          raise ValidationError,
            message:
              "postponed game of starting rank #{rank}, round #{column}: expected the draw " <>
                "it is written as, found #{inspect(other)}"
      end
    end)
  end

  defp mark_line(line, _by_rank), do: line

  # The TRF16 team section: one `013` record per team, its name and the
  # starting ranks of its players in board order - which, in this app, are
  # their pairing numbers, the same values every game's opponent column
  # carries. Only players the file actually contains are listed, so a record
  # never names a rank with no `001` line behind it.
  #
  # Empty for an individual tournament, so its file is byte-for-byte what it
  # was: the `082` header was already written as 0, and no `013` line appears.
  # The individual games stay on the `001` lines exactly as before; the team
  # section only says who played for whom.
  defp team_records(tournament, players, trf_players) do
    if PairingsEngine.Tournaments.Tournament.team?(tournament) do
      exported = MapSet.new(trf_players, & &1.rank)

      tournament.id
      |> Tournaments.list_teams()
      |> Enum.map(fn team ->
        ranks =
          players
          |> Enum.filter(&(&1.team_id == team.id))
          |> Tournaments.sort_roster()
          |> Enum.map(& &1.pairing_number)
          |> Enum.filter(&MapSet.member?(exported, &1))

        %{name: team.name, player_ranks: ranks}
      end)
    else
      []
    end
  end

  # `PairingsEngine.Build` is the one place that knows. This used to mirror
  # `PairingsEngineWeb.Layouts.app_version/0` under a comment saying the
  # duplication was deliberate to avoid reaching into the web layer - which
  # was the right instinct and the wrong fix: the answer belonged in neither.
  #
  # The RELEASE here, not the build id: this string goes into the TRF's
  # generator field, which a FIDE reader parses, and "0.18.0+3f2a1c9" is not
  # what that field is for.
  defp app_version, do: PairingsEngine.Build.version()

  # TRF26's `192`: which system paired the boards, in ETT26's vocabulary.
  # JaVaFo implements the Dutch system as it stood before 1 February 2026
  # and Ainalrami the edition in force since; Keizer and the two match
  # formats have no FIDE code and are what the table calls CUSTOM. A team
  # event gets the family's default.
  defp tournament_type_code(t) do
    baku = if t.acceleration == "baku", do: "_BAKU", else: ""
    team? = t.type in ["team-swiss", "team-roundrobin"]

    cond do
      team? and t.pairing_system == "round_robin" -> "FIDE_TEAM_ROUNDROBIN"
      team? -> "FIDE_TEAM" <> baku
      t.pairing_system == "keizer" -> "CUSTOM_SWISS"
      t.pairing_system == "round_robin" and t.rr_match_format -> "CUSTOM_ROUNDROBIN"
      t.pairing_system == "round_robin" -> "BERGER_ROUNDROBIN_G#{t.rr_cycles || 1}"
      t.swiss_match_format -> "CUSTOM_SWISS"
      t.pairing_engine == "javafo" -> "FIDE_DUTCH_2017" <> baku
      true -> "FIDE_DUTCH_2026" <> baku
    end
  end

  # The configured tie-breaks are FIDE's own C.07 codes (`Tiebreaks`), so
  # they go out as they are; anything that is not a code shape is dropped
  # rather than let the writer refuse the file over it.
  defp tie_break_codes(t) do
    (t.tiebreaks || [])
    |> Enum.map(&String.upcase(to_string(&1)))
    |> Enum.filter(&Regex.match?(~r/^[A-Z][A-Z0-9]*$/, &1))
  end

  # 102: chief arbiter, as "<FIDE id> <name>" when the id is known (e.g.
  # "102 208418 Boutchon, Gaston"), else just the name. Skipped entirely
  # (nil) when the chief arbiter isn't known at all - `Trf.serialize/1`
  # already drops a nil/blank header line.
  defp chief_arbiter_line(tournament) do
    name = tournament.chief_arbiter || ""
    fide_id = officials(tournament)["chief_arbiter_fide_id"]

    cond do
      name == "" -> nil
      present?(fide_id) -> "#{fide_id} #{name}"
      true -> name
    end
  end

  # 112: one line per deputy/extra arbiter found among the officials map's
  # `deputyN_name` (N in 1..2 - FIDE only ever ranks 2 deputies by name) and
  # `arbiterN_name` (N in 1..extra_arbiters_count - everyone past that,
  # unranked - see `PairingsEngine.Tournaments.Tournament`'s `officials`
  # field docs and docs/norms.md's "Arbiters beyond chief + 2 deputies")
  # keys, same "<FIDE id> <name>" formatting as the chief arbiter. A slot
  # with no name set is skipped.
  defp deputy_arbiter_lines(tournament) do
    officials = officials(tournament)

    keys =
      Enum.map(1..2, &"deputy#{&1}") ++ Enum.map(extra_arbiter_range(officials), &"arbiter#{&1}")

    for key <- keys,
        name = officials["#{key}_name"],
        present?(name) do
      fide_id = officials["#{key}_fide_id"]
      if present?(fide_id), do: "#{fide_id} #{name}", else: name
    end
  end

  # 1..count is a *descending* range (iterating count..1) when count is 0 -
  # an easy footgun - so 0 (the common case: no extra arbiters) has to
  # short-circuit to an empty range explicitly.
  defp extra_arbiter_range(officials) do
    case extra_arbiters_count(officials) do
      n when n > 0 -> 1..n
      _ -> 1..0//1
    end
  end

  defp extra_arbiters_count(officials) do
    case officials["extra_arbiters_count"] do
      n when is_integer(n) -> n
      s when is_binary(s) -> s |> Integer.parse() |> extra_count_from_parse()
      _ -> 0
    end
  end

  defp extra_count_from_parse({n, _}), do: n
  defp extra_count_from_parse(:error), do: 0

  defp officials(tournament), do: tournament.officials || %{}

  defp present?(v), do: v not in [nil, ""]

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  defp filter_player_games(player, rounds, tournament) do
    empty = %{opponent_rank: nil, colour: nil, result: nil}
    games = Enum.map(rounds, &Enum.at(player.games, &1 - 1, empty))

    %{player | games: games, points: Pairing.player_points(games, tournament)}
  end

  # A bye the arbiter has already granted for a round nobody has paired
  # yet. Everything else in the report is a record of rounds played; this
  # is the one forward-looking thing in it, and the reason it belongs here
  # is that the next round is the one somebody else may be pairing - from
  # this file. TRF26 carries it as a `240` record, the older spelling as
  # the `0000 - H` column an engine reads as "leave this player out"; both
  # come from the same game entry, which `Ainalrami.Trf.serialize/2` lifts
  # out again in the TRF26 dialect.
  #
  # Only on a full export. A `?rounds=1-3` slice is a historical excerpt
  # and says nothing about what comes next, and appending a future round to
  # one would put a column where the reader expects the file to end.
  defp append_future_byes(rows, tournament, rounds, paired) do
    if rounds == Enum.to_list(1..paired//1) do
      byes =
        tournament.id
        |> Tournaments.list_byes_from_round(paired + 1)
        |> Enum.group_by(& &1.player_id)

      Enum.map(rows, fn row -> Map.update!(row, :games, &(&1 ++ future_bye_games(byes, row))) end)
    else
      rows
    end
  end

  defp future_bye_games(byes, row) do
    case Map.get(byes, row.id, []) do
      [] ->
        []

      granted ->
        by_round = Map.new(granted, &{&1.round, &1.type})
        last = granted |> Enum.map(& &1.round) |> Enum.max()
        blank = %{opponent_rank: nil, colour: nil, result: nil}

        for round <- (length(row.games) + 1)..last//1 do
          case Map.get(by_round, round) do
            nil -> blank
            type -> %{opponent_rank: nil, colour: nil, result: future_bye_code(type)}
          end
        end
    end
  end

  # `absent` is a zero-point bye by any reader's reading: the player is not
  # playing and scores nothing for it.
  defp future_bye_code("requested-half"), do: "H"
  defp future_bye_code(_zero), do: "Z"

  # `players.extra_points` - the administrative bonus or penalty the
  # standings add on top of the game points (SWAR's "XtPts"). TRF's own
  # points column is game points by definition, so before this the bonus
  # left the building nowhere at all: a FIDE report and a re-import both
  # lost it silently. TRF26's untyped `299` record is exactly this, one per
  # distinct value with the players it applies to.
  defp free_point_records(players, tournament) do
    if tournament.count_extra_points do
      players
      |> Enum.filter(&(&1.pairing_number && (&1.extra_points || 0.0) != 0.0))
      |> Enum.group_by(& &1.extra_points, & &1.pairing_number)
      |> Enum.sort()
      |> Enum.map(fn {points, ranks} ->
        %{type: "", match_points: nil, points: points, round: nil, ranks: Enum.sort(ranks)}
      end)
    else
      []
    end
  end

  defp filter_round_dates(nil, _rounds), do: []
  defp filter_round_dates([], _rounds), do: []
  defp filter_round_dates(dates, rounds), do: Enum.map(rounds, &Enum.at(dates, &1 - 1))

  # FIDE wants a date for every round in the file, and one that arrives
  # without them comes back - after the event, when fixing it means
  # re-exporting and re-submitting rather than filling in a field. Refused
  # here instead, while it is still five minutes of work.
  #
  # Only for an export that CLAIMS rounds. A roster taken before the first
  # pairing has no rounds to date and is a perfectly good file - it is what an
  # arbiter checks a registration list against, and refusing it would make the
  # commonest pre-tournament export impossible. Same for `?rounds=1-3` of a
  # nine-round event: only those three rounds need dates, because only those
  # three are in the file.
  defp ensure_round_dates(tournament, rounds_spec) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)
    dates = tournament.round_dates || []

    case Enum.filter(rounds, &(Enum.at(dates, &1 - 1) in [nil, ""])) do
      [] ->
        :ok

      missing ->
        {:error,
         %ValidationError{
           message:
             "no date is set for #{describe_rounds(missing)}. FIDE requires a date for " <>
               "every round in the file. Set them under Settings, Dates."
         }}
    end
  end

  defp describe_rounds([n]), do: "round #{n}"
  defp describe_rounds(ns), do: "rounds " <> Enum.map_join(ns, ", ", &Integer.to_string/1)
end
