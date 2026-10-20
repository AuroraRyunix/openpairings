defmodule PairingsEngineWeb.ManubriumApi.Json do
  @moduledoc """
  What the Manubrium API says about things - plain maps for `json/2`.

  Read-only: everything here is computed by the same functions the desk
  pages read (`Tournaments`, `Standings`, `PostponedGames`, `Incidents`),
  never by a copy of their rules. The shapes are the contract in
  docs/manubrium.md ("Full app", "API"); keep the two in step, because the
  app is built from the document.
  """
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{Incidents, PostponedGames, Results, Standings, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @doc "What a role may do from the app, as the list the app switches its screens on."
  def capabilities(role) when role in [:owner, :editor],
    do: ~w(results incidents pair publish players standings settings)

  def capabilities(:arbiter), do: ~w(results incidents)
  def capabilities(_role), do: []

  @doc "One line of the tournament list."
  def tournament_line(%Tournament{} = t, role) do
    %{
      id: t.id,
      name: t.name,
      role: role,
      status: t.status,
      start_date: blank_nil(t.start_date),
      end_date: blank_nil(t.end_date),
      city: blank_nil(t.city),
      rounds_count: t.rounds_count,
      paired_rounds: Engine.paired_rounds_count(t.id)
    }
  end

  @doc """
  One tournament, for the app's tournament screen: who may do what, the
  rounds with their public level, whether the next round can be paired and
  what pairing it would ask to confirm, and the settings worth reading
  from a phone.
  """
  def tournament(%Tournament{} = t, role) do
    paired = Engine.paired_rounds_count(t.id)
    rounds = Tournaments.list_rounds(t.id)
    desk? = role in [:owner, :editor]

    %{
      id: t.id,
      name: t.name,
      role: role,
      can: capabilities(role),
      status: t.status,
      read_only: Tournaments.ensure_writable(t) != :ok,
      archived: not is_nil(t.archived_at),
      handed_off: not is_nil(t.handed_off_at),
      pairing_system: t.pairing_system,
      team: Tournament.team?(t),
      rounds_count: t.rounds_count,
      paired_rounds: paired,
      rounds:
        Enum.map(rounds, fn r ->
          %{
            number: r.number,
            publish_level: Tournaments.round_publish_state(t, r).level,
            missing_results: missing_results(t.id, r.number)
          }
        end),
      next_round: if(desk?, do: next_round(t, paired)),
      settings: settings(t)
    }
  end

  # `count_missing_results/2` counts every round through the one given; the
  # round's own share is the difference.
  defp missing_results(tournament_id, number) do
    Tournaments.count_missing_results(tournament_id, number) -
      Tournaments.count_missing_results(tournament_id, number - 1)
  end

  defp next_round(%Tournament{} = t, paired) do
    number = paired + 1

    blocker =
      cond do
        number > (t.rounds_count || 0) -> "all_rounds_paired"
        not Tournament.setup_complete?(t) -> "setup_incomplete"
        t.pairing_system == "round_robin" -> "desk_only"
        Tournament.team?(t) -> "desk_only"
        Tournaments.ensure_writable(t) != :ok -> "read_only"
        true -> nil
      end

    warnings =
      if is_nil(blocker) do
        t
        |> PostponedGames.pairing_warnings()
        |> Enum.map(fn w ->
          %{
            id: w.id,
            confirm: w.id in PostponedGames.acknowledgement_ids(),
            message: PairingsEngineWeb.Postponed.pairing_warning_text(w, number)
          }
        end)
      else
        []
      end

    %{number: number, blocker: blocker, warnings: warnings}
  end

  defp settings(%Tournament{} = t) do
    %{
      type: t.type,
      venue: blank_nil(t.venue),
      city: blank_nil(t.city),
      federation: blank_nil(t.federation),
      start_date: blank_nil(t.start_date),
      end_date: blank_nil(t.end_date),
      chief_arbiter: blank_nil(t.chief_arbiter),
      time_control: blank_nil(t.time_control),
      round_dates: t.round_dates || [],
      tiebreaks: Standings.effective_tiebreaks(t),
      fide_rated: t.fide_homologated == true,
      postponed_games: t.postponed_games == true,
      ask_bye_type: t.ask_bye_type == true,
      publish_mode: t.publish_mode,
      points: %{win: t.points_win, draw: t.points_draw, loss: t.points_loss}
    }
  end

  @doc """
  A round as the hall sees it: every board with its players, their score
  coming into the round (as a printed pairing sheet shows it), the result,
  and whether this account may clear it; then the players not on a board
  and why.
  """
  def round(%Tournament{} = t, %Round{} = round) do
    scores =
      t
      |> Standings.standings(through_round: round.number - 1)
      |> Map.new(&{&1.player.id, &1.points})

    boards =
      round.pairings
      |> Enum.reject(& &1.hidden)
      |> Enum.sort_by(& &1.board)
      |> Enum.map(&board(&1, scores))

    %{
      number: round.number,
      latest: round.number == Engine.paired_rounds_count(t.id),
      publish_level: Tournaments.round_publish_state(t, round).level,
      boards: boards,
      byes:
        t.id
        |> Tournaments.list_byes_for_round(round.number)
        |> Enum.map(fn b -> %{player: player(b.player, scores), type: b.type} end),
      results: Results.entry_codes() -- [""]
    }
  end

  defp board(%Pairing{} = p, scores) do
    bye? = is_nil(p.black_player_id)

    %{
      id: p.id,
      board: p.board,
      label: p.display_board || Integer.to_string(p.board || 0),
      white: player(p.white_player, scores),
      black: if(bye?, do: nil, else: player(p.black_player, scores)),
      bye: bye?,
      result: p.result || "",
      clearable: not bye? and p.result not in [nil, ""] and Tournaments.result_clearable?(p)
    }
  end

  defp player(nil, _scores), do: nil

  defp player(%Player{} = p, scores) do
    %{
      id: p.id,
      name: p.name,
      title: blank_nil(p.title),
      rating: Player.rating(p),
      score: Map.get(scores, p.id, 0.0)
    }
  end

  @doc "The standings, with the tie-breaks the tournament actually applies."
  def standings(%Tournament{pairing_system: "keizer"} = t) do
    entries = PairingsEngine.Keizer.standings(t)

    %{
      tiebreaks: [],
      rows:
        Enum.map(entries, fn e ->
          %{
            rank: Map.get(e, :rank),
            player: player_brief(e.player),
            points: Map.get(e, :points),
            tiebreaks: %{}
          }
        end)
    }
  end

  def standings(%Tournament{} = t) do
    codes = Standings.effective_tiebreaks(t)

    entries =
      t
      |> Standings.standings(pending: true)
      |> Standings.apply_manual_ranking(t)

    %{
      tiebreaks:
        Enum.map(codes, fn code ->
          %{code: code, name: (PairingsEngine.Tiebreaks.get(code) || %{name: code}).name}
        end),
      rows:
        Enum.map(entries, fn e ->
          %{
            rank: Standings.shown_rank_label(e, t),
            player: player_brief(e.player),
            points: Map.get(e, :total, e.points),
            tiebreaks: Map.get(e, :tiebreaks, %{})
          }
        end)
    }
  end

  defp player_brief(%Player{} = p),
    do: %{id: p.id, name: p.name, title: blank_nil(p.title), rating: Player.rating(p)}

  defp player_brief(_other), do: nil

  @doc "A player as the app's player list and editor read it."
  def player_full(%Player{} = p) do
    %{
      id: p.id,
      name: p.name,
      title: blank_nil(p.title),
      sex: blank_nil(p.sex),
      federation: blank_nil(p.federation),
      club: blank_nil(p.club),
      birth_year: p.birth_year,
      fide_id: p.fide_id,
      fide_rating: p.fide_rating,
      national_rating: p.national_rating,
      rating: Player.rating(p),
      pairing_number: p.pairing_number,
      start_round: p.start_round,
      status: status(p),
      absent: p.absent,
      absent_rounds: Player.parse_absent_rounds(p.absent_rounds)
    }
  end

  defp status(p) do
    cond do
      Player.expelled?(p) -> "expelled"
      Player.withdrawn?(p) -> "withdrawn"
      true -> "active"
    end
  end

  @doc "An incident as the desk's incident list shows it, without its photo."
  def incident(%Incidents.Incident{} = i) do
    %{
      id: i.id,
      round: i.round_number,
      board: i.board,
      kind: i.kind,
      note: i.note,
      white: i.white_name,
      black: i.black_name,
      occurred_at: i.occurred_at,
      by: i.enrollment_label,
      has_photo: i.has_photo
    }
  end

  defp blank_nil(""), do: nil
  defp blank_nil(v), do: v
end
