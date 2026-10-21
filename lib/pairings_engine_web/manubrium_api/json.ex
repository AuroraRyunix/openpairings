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

  alias PairingsEngine.{
    BoardLink,
    ByeTypes,
    Incidents,
    ManualPairing,
    PostponedGames,
    Results,
    Standings,
    Tiebreaks,
    Tournaments
  }

  alias PairingsEngine.Mobile.PhoneResults
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}
  alias PairingsEngine.BoardLink.Link
  alias PairingsEngineWeb.{DeskActions, PublicLink}

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
      settings: settings(t, role),
      bye_kinds: bye_kinds(t),
      # The results site's page, when there is one to hand a spectator
      # (`PublicLink`, the one helper every desk page shows it with).
      openresults_url: PublicLink.url(t)
    }
  end

  @doc """
  The kinds of requested bye a player may be given ahead of a round here:
  the three the player dialog asks between where the tournament asks the
  bye type (`ByeTypes.applies?/1`), else the plain absence, worth what the
  tournament pays an absence. `points` is the value before any limit.
  """
  def bye_kinds(%Tournament{} = t) do
    if ByeTypes.applies?(t) do
      [
        {"requested-half", gettext("Half-point bye")},
        {"requested-zero", gettext("Zero-point bye")},
        {"full-point", gettext("Full-point bye")}
      ]
      |> Enum.map(fn {id, label} -> %{id: id, label: label, points: ByeTypes.points(t, id)} end)
    else
      [%{id: "absent", label: gettext("Absent"), points: Standings.bye_points("absent", t)}]
    end
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

  @doc """
  The settings worth reading from a phone, and - for the desk's roles - the
  ones it may change now (`DeskActions.editable_settings/1`) with the
  tie-break catalogue to pick from.
  """
  def settings(%Tournament{} = t, role) do
    base = %{
      type: t.type,
      venue: blank_nil(t.venue),
      city: blank_nil(t.city),
      federation: blank_nil(t.federation),
      start_date: blank_nil(t.start_date),
      end_date: blank_nil(t.end_date),
      chief_arbiter: blank_nil(t.chief_arbiter),
      deputy_arbiter: blank_nil(t.deputy_arbiter),
      time_control: blank_nil(t.time_control),
      rounds_count: t.rounds_count,
      round_dates: t.round_dates || [],
      tiebreaks: Standings.effective_tiebreaks(t),
      fide_rated: t.fide_homologated == true,
      postponed_games: t.postponed_games == true,
      ask_bye_type: t.ask_bye_type == true,
      shared_places: t.shared_places == true,
      bye_value: t.bye_value,
      publish_mode: t.publish_mode,
      points: %{win: t.points_win, draw: t.points_draw, loss: t.points_loss}
    }

    if role in [:owner, :editor] do
      Map.merge(base, %{
        editable: DeskActions.editable_settings(t),
        # What the tie-break editor starts from: the list as configured,
        # before `effective_tiebreaks/1` drops what does not apply.
        configured_tiebreaks: t.tiebreaks || [],
        tiebreak_options:
          t.type
          |> Tiebreaks.selectable()
          |> Enum.map(&%{code: &1.code, name: &1.name})
      })
    else
      base
    end
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

    phones = PhoneResults.by_pairing(t.id, round.number)
    reports = if BoardLink.connected?(t.id), do: BoardLink.summaries(t.id), else: %{}

    boards =
      round.pairings
      |> Enum.reject(& &1.hidden)
      |> Enum.sort_by(& &1.board)
      |> Enum.map(&board(&1, scores, Map.get(phones, &1.id), report_for(reports, &1)))

    %{
      number: round.number,
      latest: round.number == Engine.paired_rounds_count(t.id),
      publish_level: Tournaments.round_publish_state(t, round).level,
      boards: boards,
      byes:
        t.id
        |> Tournaments.list_byes_for_round(round.number)
        |> Enum.map(fn b -> %{player: player(b.player, scores), type: b.type} end),
      # Everyone not on a board, with why - what a seat is filled from and
      # who a bye or a new board is given to.
      pool:
        t.id
        |> Tournaments.list_round_pool(round.number)
        |> Enum.map(fn e ->
          %{player: player(e.player, scores), type: e.type, absent: e.absent? == true}
        end),
      hand_edits: %{open: ManualPairing.open?(round), pibe: round.mpa_pibe},
      results: Results.entry_codes() -- [""]
    }
  end

  defp report_for(_reports, %Pairing{game_uid: nil}), do: nil
  defp report_for(reports, %Pairing{game_uid: uid}), do: Map.get(reports, uid)

  defp board(%Pairing{} = p, scores, phone, report) do
    bye? = p.result == "bye"

    %{
      id: p.id,
      board: p.board,
      label: p.display_board || Integer.to_string(p.board || 0),
      white: player(p.white_player, scores),
      black: player(p.black_player, scores),
      bye: bye?,
      # One empty seat and no bye: the board waits for a player or a bye.
      vacant: not bye? and is_nil(p.white_player_id) != is_nil(p.black_player_id),
      empty: is_nil(p.white_player_id) and is_nil(p.black_player_id),
      result: p.result || "",
      clearable: not bye? and p.result not in [nil, ""] and Tournaments.result_clearable?(p),
      phone: phone && %{by: phone.label, state: phone.state, at: phone.at},
      board_report: board_report(p, report)
    }
  end

  # What a sensor board in the hall saw of this game (`BoardLink`), beside
  # the result and never instead of it: a board never enters a result.
  # `mismatch` is `BoardLink.compare/2`'s red case, the one the Pairings
  # page draws.
  defp board_report(_pairing, nil), do: nil

  defp board_report(%Pairing{} = p, report) do
    %{
      status: report.status,
      result: report.result,
      mismatch: BoardLink.compare(p.result, report) == :mismatch,
      moves_count: report.plies,
      updated_at: report.reported_at
    }
  end

  @doc """
  A hall-box connect code as the app lists it. Never the secret: that is
  shown once, when the code is made. `kind` is `tournament` or `group`;
  `reach` is `lan` for a code for a box on a desktop copy's network,
  `server` otherwise; `label` is what the box called itself, else the
  code's last four characters.
  """
  def board_link(%Link{} = link) do
    %{
      id: link.id,
      kind: if(link.group_id, do: "group", else: "tournament"),
      label: link.label || link.box_name || "…" <> (link.secret_hint || ""),
      hint: link.secret_hint,
      reach: if(link.reach == "lan", do: "lan", else: "server"),
      created_at: link.inserted_at,
      last_seen_at: link.last_seen_at
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

  @doc """
  A player as the app's player list and editor read it.

  `present` is the Players page's "Pr." column: a player marked absent
  for the whole event (`absent`) is not present. `byes` are the rounds the
  player asked to be left out of (`absent_rounds`), each with its kind: the
  typed bye stored for that round (`ByeTypes`), else a plain `absent`.
  `typed` is `ByeTypes.stored/2` for the player, read here when not given.
  """
  def player_full(%Player{} = p, typed \\ nil) do
    typed = typed || ByeTypes.stored(p.tournament_id, p.id)

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
      present: not p.absent,
      absent_rounds: Player.parse_absent_rounds(p.absent_rounds),
      byes:
        p.absent_rounds
        |> Player.parse_absent_rounds()
        |> Enum.sort()
        |> Enum.map(&%{round: &1, kind: Map.get(typed, &1, "absent")})
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
