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

  alias PairingsEngine.{Pairing, Tournaments, Trf}
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

  defp all_rounds(max_round) when is_integer(max_round) and max_round > 0, do: Enum.to_list(1..max_round)
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

  defp build(tournament, rounds_spec) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)

    players = Tournaments.list_players(tournament.id)

    trf_players =
      tournament
      |> Pairing.trf_player_rows(players)
      |> Enum.map(&filter_player_games(&1, rounds, tournament))

    Trf.serialize(%{
      tournament: %{
        name: tournament.name,
        city: tournament.city,
        federation: tournament.federation,
        start_date: tournament.start_date,
        end_date: tournament.end_date,
        number_of_rated_players: Enum.count(trf_players, &((&1.fide_rating || 0) > 0)),
        type: tournament.type,
        chief_arbiter: chief_arbiter_line(tournament),
        deputy_arbiters: deputy_arbiter_lines(tournament),
        time_control: blank_to_nil(tournament.rate_of_play),
        round_dates: filter_round_dates(tournament.round_dates, rounds)
      },
      players: trf_players
    })
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

  # 112: one line per deputy arbiter found among the officials map's
  # `deputyN_name` / `deputyN_fide_id` keys (N in 1..4 — see
  # `PairingsEngine.Tournaments.Tournament`'s `officials` field docs),
  # same "<FIDE id> <name>" formatting as the chief arbiter. A deputy slot
  # with no name set is skipped.
  defp deputy_arbiter_lines(tournament) do
    officials = officials(tournament)

    for n <- 1..4,
        name = officials["deputy#{n}_name"],
        present?(name) do
      fide_id = officials["deputy#{n}_fide_id"]
      if present?(fide_id), do: "#{fide_id} #{name}", else: name
    end
  end

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
