defmodule PairingsEngine.TrfExport do
  @moduledoc """
  User-facing FIDE TRF16 export of a tournament's full roster, as opposed to
  `PairingsEngine.Pairing.javafo_input/2` (a JaVaFo-only input file, built
  from active players and fed straight into the pairing engine — never
  downloaded by a user).

  The distinguishing feature here is **round selection**: `export/2` can
  produce a TRF containing only a chosen subset of rounds — the header's
  round-dates line and every player's per-round result columns are trimmed
  to match, and points are recomputed from the filtered games only. See
  `parse_rounds/2` for the accepted `rounds` query-param syntax and
  `docs/import-export.md` for the user-facing reference.

  Only players who have actually been included in a paired round (i.e. have
  a `pairing_number`) are exported — see
  `PairingsEngine.Pairing.trf_player_rows/2`.
  """

  alias PairingsEngine.{Pairing, SwarImport, Tournaments, Trf}
  alias PairingsEngine.Trf.ValidationError

  @doc """
  Builds the TRF16 text for `tournament`, limited to `rounds_spec` (either a
  raw query-param string per `parse_rounds/2`, or an already-parsed list of
  round numbers). Defaults to every paired round when `rounds_spec` is
  `nil`/blank.

  Returns `{:ok, text}`, or `{:error, %PairingsEngine.Trf.ValidationError{}}`
  if the filtered result set fails `Trf`'s own legality validation (an
  unrecognized or mutually-inconsistent result code) — never raises.
  """
  def export(tournament, rounds_spec \\ nil) do
    {:ok, build(tournament, rounds_spec)}
  rescue
    e in ValidationError -> {:error, e}
  end

  # SWAR parity #23 (manual standings override) is deliberately NOT
  # surfaced in this file — see docs/manual-standings.md for the full
  # reasoning. In short: the FIDE "086-089 Rank" column and the "005-008
  # Starting rank" column both carry `pairing_number` in this codebase (see
  # `Pairing.trf_player_rows/2`), and every game's opponent cross-reference
  # is baked against that same value — rewriting it per player to the
  # standings rank would desync those references and fail
  # `Trf.serialize/1`'s own cross-check, so this doesn't touch it. There is
  # therefore no hidden override to disclose in this file at all: the TRF's
  # rank column was never affected by manual ranking in the first place.
  # The UI (the page offering this download) carries the caveat instead —
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
  e.g. from `parse_rounds/2`) — SWAR's "this FIDE ID applies to rounds X-Y"
  model (`tournament.fide_id_ranges`, see
  `PairingsEngine.Tournaments.Tournament`'s schema doc).

  Resolution:

    * If exactly one configured range fully covers `rounds` (its
      `from_round..to_round` spans at least `min(rounds)..max(rounds)`),
      that range's ID is used — this is the common case (a report cleanly
      split by round).
    * Otherwise — no ranges configured, the round span crosses more than
      one range's boundary, only partially overlaps one, or matches none —
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

  defp build(tournament, rounds_spec) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)

    players = Tournaments.list_players(tournament.id)

    trf_players =
      tournament
      |> Pairing.trf_player_rows(players)
      |> Enum.map(&filter_player_games(&1, rounds, tournament))

    Trf.serialize(
      %{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          # Defensive normalization: `SwarImport.create_tournament/2` already
          # normalizes a Belgian regional marker (VSF/FEFB/FRBE/"FIDE"/...) to
          # "BEL" on import, but a tournament imported before that
          # normalization existed may still carry the raw marker in the
          # database — reusing the same helper here means it exports "032
          # BEL" either way, with no re-import required. A no-op for every
          # other federation value (see `SwarImport.normalize_federation/1`).
          federation: SwarImport.normalize_federation(tournament.federation),
          start_date: tournament.start_date,
          end_date: tournament.end_date,
          number_of_rated_players: Enum.count(trf_players, &((&1.fide_rating || 0) > 0)),
          type: tournament.type,
          chief_arbiter: chief_arbiter_line(tournament),
          deputy_arbiters: deputy_arbiter_lines(tournament),
          time_control: blank_to_nil(tournament.rate_of_play),
          # The count of rounds actually represented in *this* file, not the
          # tournament's configured total — matches `round_dates` below, which
          # is filtered to `rounds` the same way (a `?rounds=1-3` export of a
          # 5-round event describes itself as 3 rounds, honestly).
          number_of_rounds: length(rounds),
          round_dates: filter_round_dates(tournament.round_dates, rounds),
          generator: "OpenPairings v#{app_version()}"
        },
        players: trf_players
      },
      column_legend: true
    )
  end

  # Mirrors `PairingsEngineWeb.Layouts.app_version/0` — duplicated rather
  # than reused so this domain module doesn't reach into the web layer for
  # one string.
  defp app_version do
    case Application.spec(:pairings_engine, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> "0.0.0"
    end
  end

  # 102: chief arbiter, as "<FIDE id> <name>" when the id is known (e.g.
  # "102 208418 Boutchon, Gaston"), else just the name. Skipped entirely
  # (nil) when the chief arbiter isn't known at all — `Trf.serialize/1`
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
  # `deputyN_name` (N in 1..2 — FIDE only ever ranks 2 deputies by name) and
  # `arbiterN_name` (N in 1..extra_arbiters_count — everyone past that,
  # unranked — see `PairingsEngine.Tournaments.Tournament`'s `officials`
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

  # 1..count is a *descending* range (iterating count..1) when count is 0 —
  # an easy footgun — so 0 (the common case: no extra arbiters) has to
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

  defp filter_round_dates(nil, _rounds), do: []
  defp filter_round_dates([], _rounds), do: []
  defp filter_round_dates(dates, rounds), do: Enum.map(rounds, &Enum.at(dates, &1 - 1))
end
