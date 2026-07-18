defmodule PairingsEngine.TournamentExport do
  @moduledoc """
  Full-fidelity JSON backup of one or more tournaments — everything
  OpenPairings models for a tournament (settings incl. officials/norm
  metadata, teams, players incl. `norm_data`, rounds, pairings/results,
  byes, forbidden pairings), as opposed to `PairingsEngine.TrfExport`'s
  FIDE-report-shaped TRF16 output. See `docs/import-export.md` for the
  envelope format and `PairingsEngine.TournamentImport` for the inverse.

  The owning user is deliberately never included — an import always creates
  brand-new tournaments owned by whoever imports the file. Every other id
  (tournament, team, player, round) is carried along verbatim as `"id"`
  purely so sibling records within the *same* envelope (pairings under a
  round, byes, forbidden pairings) can reference the right team/player; the
  importer discards these ids and remaps everything to fresh ones.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Tournaments.{Round, Tournament}

  @format "openpairings-export"
  @version 1

  @doc "The envelope's `\"format\"` tag."
  def format, do: @format

  @doc "The envelope's `\"version\"` number."
  def version, do: @version

  @tournament_fields ~w(
    name type venue city federation start_date end_date organizer
    chief_arbiter deputy_arbiter time_control rounds_count rating_type
    points_win points_draw points_loss bye_value presence_value abs_value
    presence_on_allocated_bye tiebreaks acceleration
    status standard rate_of_play organizer_club_number round_dates
    categories event_code fide_tournament_id officials
  )a

  @team_fields ~w(name captain)a

  @player_fields ~w(
    name sex title fide_id fide_rating national_id national_rating
    federation birth_year birth_date club status start_round board_order
    pairing_number paid affiliated absent forfeit special_table
    absent_rounds extra_points category club_number norm_data team_id
  )a

  @round_fields ~w(number date status)a

  @doc "Envelope wrapping a single tournament (caller is responsible for owner-scoping it)."
  def export_tournament(%Tournament{} = tournament), do: envelope([tournament])

  @doc "Envelope wrapping every tournament `scope`'s user owns or collaborates on."
  def export_all(%Scope{} = scope) do
    tournaments =
      scope |> Tournaments.list_tournaments() |> Enum.map(fn {t, _count, _owner?} -> t end)

    envelope(tournaments)
  end

  defp envelope(tournaments) do
    %{
      "format" => @format,
      "version" => @version,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "tournaments" => Enum.map(tournaments, &tournament_map/1)
    }
  end

  defp tournament_map(t) do
    %{
      "tournament" => struct_fields(t, @tournament_fields),
      "teams" => Enum.map(Tournaments.list_teams(t.id), &team_map/1),
      "players" => Enum.map(Tournaments.list_players(t.id), &player_map/1),
      "rounds" => Enum.map(rounds_with_pairings(t.id), &round_map/1),
      "byes" => byes(t.id),
      "forbidden_pairings" => forbidden_pairings(t.id)
    }
  end

  defp team_map(team), do: Map.put(struct_fields(team, @team_fields), "id", team.id)

  defp player_map(player), do: Map.put(struct_fields(player, @player_fields), "id", player.id)

  defp round_map(round) do
    round
    |> struct_fields(@round_fields)
    |> Map.merge(%{"id" => round.id, "pairings" => Enum.map(round.pairings, &pairing_map/1)})
  end

  defp pairing_map(p) do
    %{
      "board" => p.board,
      "result" => p.result,
      "white_player_id" => p.white_player_id,
      "black_player_id" => p.black_player_id
    }
  end

  defp rounds_with_pairings(tournament_id) do
    Repo.all(
      from r in Round,
        where: r.tournament_id == ^tournament_id,
        order_by: r.number,
        preload: [:pairings]
    )
  end

  defp byes(tournament_id) do
    Repo.all(
      from b in "byes",
        where: b.tournament_id == ^tournament_id,
        select: %{player_id: b.player_id, round: b.round, type: b.type}
    )
    |> Enum.map(&stringify_keys/1)
  end

  defp forbidden_pairings(tournament_id) do
    Repo.all(
      from f in "forbidden_pairings",
        where: f.tournament_id == ^tournament_id,
        select: %{player_a_id: f.player_a_id, player_b_id: f.player_b_id}
    )
    |> Enum.map(&stringify_keys/1)
  end

  defp struct_fields(struct, fields) do
    struct |> Map.from_struct() |> Map.take(fields) |> stringify_keys()
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
end
