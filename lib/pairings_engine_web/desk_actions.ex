defmodule PairingsEngineWeb.DeskActions do
  @moduledoc """
  The desk's write actions as the desk does them - the restore point
  before, the context call, the audit rows after - for every caller that is
  not the desk page itself.

  The Pairings and Players pages call these too, so there is one place
  where "pair a round", "unpair the last round", "choose a round's public
  level", "add a player" and "change a player" are written down. The
  Manubrium app's API (`PairingsEngineWeb.ManubriumApi`) is the other
  caller: a phone that pairs a round leaves the same restore point and the
  same audit trail as the desk that pairs it, because it is the same code.

  What stays on the pages is what a page has and a phone does not: the
  dialogs. Where the desk stops to ask (the pairing-number question, the
  FIDE-mode departure, the bye exclusions that leave no legal round, a team
  Swiss that runs for a minute), `pair_next_round/3` here refuses and says
  which question it is; the arbiter answers it at the desk. Nothing here
  answers a question on the arbiter's behalf.
  """

  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{
    Audit,
    ByeTypes,
    EngineSlots,
    HalfByes,
    ManualPairing,
    ManualRoundRobin,
    PairingRationale,
    PostponedGames,
    RoundRobin,
    Snapshots,
    Tiebreaks,
    Tournaments,
    Tpn
  }

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}
  alias PairingsEngineWeb.{ByePreferenceText, SettingsSupport}

  ## ---------- pairing a round ----------

  # How long a phone waits for an engine slot before it is told the engine
  # is busy - the desk's own figure for an individual Swiss.
  @slot_wait_ms 3_000

  @doc """
  Pairs the next round of an individual Swiss (or Keizer) tournament the
  way the desk's "Pair round N" button does when nothing needs asking:
  the restore point, the engine under a slot, the audit rows.

  `acknowledged` are the postponed-game warnings the arbiter confirmed
  (`PostponedGames.acknowledgement_ids/0`), exactly as the desk's button
  carries them.

  Returns `{:ok, round}` or `{:error, reason}`. Besides the engine's own
  refusals, `reason` is one of the questions the desk asks and this does
  not: `:setup_incomplete`, `{:hand_edits_open, round}`, `:round_robin`,
  `:team_event`, `{:tpn_question, rows}`, `{:fide_departure, kinds}`,
  `{:bye_exclusions, info}` - each answered at the desk.
  """
  def pair_next_round(%Tournament{} = t, scope, acknowledged \\ []) do
    cond do
      not Tournament.setup_complete?(t) ->
        {:error, :setup_incomplete}

      open = ManualPairing.open_round(t.id) ->
        {:error, {:hand_edits_open, open}}

      t.pairing_system == "round_robin" ->
        {:error, :round_robin}

      Tournament.team?(t) ->
        {:error, :team_event}

      (rows = Tpn.gate(t)) != [] ->
        {:error, {:tpn_question, rows}}

      true ->
        do_pair(t, scope, acknowledged)
    end
  end

  defp do_pair(t, scope, acknowledged) do
    next = Engine.paired_rounds_count(t.id) + 1
    recorded = recorded_missing(t, acknowledged)

    Snapshots.capture(t, "pairing.round_paired", scope, summary: "Before pairing round #{next}")

    result =
      EngineSlots.run(
        :pairing,
        t.id,
        fn ->
          Engine.pair_next_round(t, acknowledged: acknowledged, fide_departure_guard: true)
        end,
        wait: @slot_wait_ms,
        timeout: EngineSlots.pairing_timeout()
      )

    case result do
      {:ok, round} ->
        if recorded, do: log_recorded_missing(t, scope, recorded)
        audit_round_paired(t, scope, round.number)
        {:ok, round}

      other ->
        other
    end
  end

  @doc """
  The missing results this pairing run will record as postponed, when the
  arbiter confirmed that (`:missing_results_recorded_as_adjourned`), or nil.
  """
  def recorded_missing(%Tournament{} = t, acknowledged) do
    if :missing_results_recorded_as_adjourned in acknowledged do
      Enum.find(
        PostponedGames.pairing_warnings(t),
        &(&1.id == :missing_results_recorded_as_adjourned)
      )
    end
  end

  @doc "The audit row for missing results recorded as postponed by a pairing run."
  def log_recorded_missing(%Tournament{} = t, scope, %{round: n, count: count}) do
    Audit.log(t.id, scope, "pairing.missing_recorded_postponed", %{round: n, count: count})
  end

  @doc """
  Every audit row a freshly paired round gets: the rationale, the bye
  exclusions, the bye preferences and a first loss of FIDE compliance.
  `t` is the tournament as it was BEFORE the pairing (the compliance row is
  written only the first time).
  """
  def audit_round_paired(%Tournament{} = t, scope, round_number) do
    log_round_paired(t, scope, round_number)
    log_bye_exclusions(t, scope, round_number)
    log_bye_preferences(t, scope, round_number)
    log_compliance_loss(t, scope, round_number)
    :ok
  end

  @doc """
  The rich "pairing.round_paired" audit entry, from the same
  `PairingRationale` analysis the "Explain this round" page renders - so
  the durable record and the page describe the same decision.
  """
  def log_round_paired(%Tournament{} = t, scope, round_number) do
    rationale = PairingRationale.for_round(t, round_number)
    Audit.log(t.id, scope, "pairing.round_paired", PairingRationale.audit_payload(rationale))
  end

  @doc """
  What the organiser's bye exclusions did in the round just paired, for the
  audit trail (not a FIDE rule, so it is on record): whose exclusion was
  lifted to pair it, and who was passed over for the bye because of one.
  """
  def log_bye_exclusions(%Tournament{} = t, scope, round_number) do
    sections = round_sections(t.id, round_number)
    name = &player_name(t.id, &1)

    for id <- sections |> Enum.map(& &1["bye_exclusion_lifted"]) |> Enum.reject(&is_nil/1) do
      Audit.log(t.id, scope, "pairing.bye_exclusion_overridden", %{
        round: round_number,
        player_id: id,
        player_name: name.(id)
      })
    end

    passed = Enum.flat_map(sections, &(&1["bye_passed_over"] || []))

    if passed != [] do
      Audit.log(t.id, scope, "pairing.bye_passed_over", %{
        round: round_number,
        player_ids: passed,
        player_names: Enum.map(passed, name)
      })
    end

    :ok
  end

  @doc """
  What the players' bye preferences (not a FIDE rule) did in the round just
  paired: that they changed who got the bye, and every preference that was
  not applied, with why.
  """
  def log_bye_preferences(%Tournament{} = t, scope, round_number) do
    for %{"bye_preference" => %{} = record} <- round_sections(t.id, round_number) do
      {moved, notes} = ByePreferenceText.account(record, &player_name(t.id, &1))

      if moved || notes != [] do
        Audit.log(t.id, scope, "pairing.bye_preference", %{
          round: round_number,
          moved: record["moved"] == true,
          player_id: record["bye"],
          fide_player_id: record["fide_bye"],
          notes: Enum.reject([moved | notes], &is_nil/1)
        })
      end
    end

    :ok
  end

  @doc """
  The first round paired away from C.04.3 is stamped on the tournament by
  the pairing itself; this is the audit trail's copy, one row per
  deviation. Only the first time, and only when THIS round is the one
  recorded: `t` can be a pairing behind the database.
  """
  def log_compliance_loss(%Tournament{} = t, scope, round_number) do
    if is_nil(t.fide_compliance_lost_round) and
         PairingsEngine.Repo.reload!(t).fide_compliance_lost_round == round_number do
      for deviation <- Engine.pairing_deviations(t, round_number) do
        {setting, code} = compliance_loss_names(deviation, t)

        Audit.log(t.id, scope, "tournament.fide_compliance_lost", %{
          setting: setting,
          code: code,
          round: round_number
        })
      end
    end

    :ok
  end

  defp compliance_loss_names(:bye_exclusion, _t), do: {"no_bye", "bye_exclusion"}
  defp compliance_loss_names(:soft_pairs, _t), do: {"soft_pairs", "soft_pairing_wish"}
  defp compliance_loss_names(:bye_preference, _t), do: {"bye_preference", "bye_preference"}

  defp compliance_loss_names(:extra_points, t) do
    if Tournament.extra_points_acceleration?(t),
      do: {"extra_points_pairing", "extra_points_acceleration"},
      else: {"extra_points_pairing", "extra_points_handicap"}
  end

  # The round's account, without its boards: the audit rows above need its
  # sections and nothing else.
  defp round_sections(tournament_id, round_number) do
    case Tournaments.get_round_explanation(tournament_id, round_number) do
      %{"sections" => sections} when is_list(sections) -> sections
      _ -> []
    end
  end

  defp player_name(tournament_id, id) do
    case id && Tournaments.get_player(tournament_id, id) do
      nil -> nil
      p -> p.name
    end
  end

  ## ---------- unpairing ----------

  @doc """
  Unpairs round `number` (the latest only - `Engine.delete_round/2` says
  so otherwise): a restore point first, the delete, the audit row.
  `:ok` or `{:error, reason}`.
  """
  def delete_round(%Tournament{} = t, scope, number) do
    numbers_cleared = Engine.numbers_cleared_by_unpairing(t.id, number)

    # Unpairing deletes the round and every result in it. Snapshot first -
    # see PairingsEngine.Snapshots for why this sits at the call site and
    # why its result is ignored.
    Snapshots.capture(t, "pairing.round_deleted", scope,
      summary: "Before unpairing round #{number}"
    )

    case Engine.delete_round(t.id, number) do
      :ok ->
        Audit.log(
          t.id,
          scope,
          "pairing.round_deleted",
          round_deleted_details(number, numbers_cleared)
        )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp round_deleted_details(round_number, 0), do: %{round: round_number}

  defp round_deleted_details(round_number, cleared),
    do: %{round: round_number, numbers_cleared: cleared}

  ## ---------- the public page ----------

  # Each write a level change made, logged under the action its own switch
  # logged before there was one control, with the same detail key.
  @publish_audit %{
    pairings_published: {"pairing.pairings_published", :through_round},
    pairings_unpublished: {"pairing.pairings_unpublished", :from_round},
    results_published: {"pairing.results_published", :round},
    results_unpublished: {"pairing.results_unpublished", :round},
    standings_published: {"standings.published", :through_round},
    standings_unpublished: {"standings.unpublished", :from_round}
  }

  @doc """
  Sets round `round_number` to public level `level` (0..3,
  `Tournaments.set_round_publish_level/3`) and audits every write it made.
  `{:ok, tournament}` or `{:error, reason}`.
  """
  def set_publish_level(%Tournament{} = t, scope, round_number, level) do
    case Tournaments.set_round_publish_level(t, round_number, level) do
      {:ok, t, steps} ->
        Enum.each(steps, &audit_publish_step(t, scope, &1, round_number))
        {:ok, t}

      {:error, _reason} = error ->
        error
    end
  end

  defp audit_publish_step(tournament, scope, step, round_number) do
    {action, key} = Map.fetch!(@publish_audit, step)
    Audit.log(tournament.id, scope, action, %{key => round_number})
  end

  ## ---------- a new tournament ----------

  # What the "New tournament" form starts from before an account's own
  # defaults are laid over it.
  @new_tournament_defaults %{
    "pairing_system" => "swiss",
    "rounds_count" => "9",
    "standard" => "standard"
  }

  @doc "The \"New tournament\" form's own starting values, as string-keyed params."
  def new_tournament_defaults, do: @new_tournament_defaults

  @doc """
  What a new tournament starts from for an account: the form's own values
  with the account's stored defaults that the form shows laid over them
  (`TournamentDefaults.form_params/1`). Takes the stored defaults (nil for
  none).
  """
  def new_tournament_params(defaults),
    do:
      Map.merge(
        @new_tournament_defaults,
        PairingsEngine.Accounts.TournamentDefaults.form_params(defaults)
      )

  @doc """
  Creates a tournament as the "New tournament" form does: the account's
  defaults that the form does not show (federation, organiser, how rounds
  are published - `TournamentDefaults.hidden_params/1`) go UNDER `params`,
  `type` is derived from the pairing system and the team box and never
  taken from the caller, every round is dated to the start date unless
  `params` dates them itself, and a new double round robin reverses the
  last two rounds of its first cycle. Then `Tournaments.create_tournament/2`
  (the hosted edition's limit) and the audit row.

  `{:ok, tournament}`, `{:error, :tournament_quota}` or the changeset.
  """
  def create_tournament(scope, params) when is_map(params) do
    hidden =
      scope.user.id
      |> PairingsEngine.Accounts.get_user!()
      |> Map.get(:tournament_defaults)
      |> PairingsEngine.Accounts.TournamentDefaults.hidden_params()

    params =
      hidden
      |> Map.merge(params)
      |> Map.put("type", derive_type(params["pairing_system"], params["team"]))
      |> seed_round_dates()
      |> reverse_last_two_default()

    with {:ok, tournament} <- Tournaments.create_tournament(scope, params) do
      Audit.log(tournament.id, scope, "tournament.created", %{
        name: tournament.name,
        pairing_system: tournament.pairing_system
      })

      {:ok, tournament}
    end
  end

  # `type` (the FIDE-report classification: swiss | roundrobin | team-swiss
  # | team-roundrobin) is *always* derived from the single "Pairing system"
  # choice plus the "Team tournament" box, never taken from the client, so
  # the two can never disagree (see docs/pairing-systems.md). Keizer is
  # Swiss-classified for FIDE reporting purposes.
  defp derive_type("round_robin", "true"), do: "team-roundrobin"
  defp derive_type("round_robin", _team?), do: "roundrobin"
  defp derive_type(_swiss_or_keizer, "true"), do: "team-swiss"
  defp derive_type(_swiss_or_keizer, _team?), do: "swiss"

  # One round date per round from the start date, so a fresh tournament is
  # not blocked on the "Round dates" setup item. Only a default - the Dates
  # page refines it - so dates the caller supplied are never overwritten,
  # and nothing happens without a start date or a round count.
  defp seed_round_dates(%{"round_dates" => existing} = params) when existing not in [nil, []],
    do: params

  defp seed_round_dates(params) do
    start_date = String.trim(params["start_date"] || "")
    rounds = parse_rounds_count(params["rounds_count"])

    if start_date != "" and rounds > 0 do
      Map.put(params, "round_dates", List.duplicate(start_date, rounds))
    else
      params
    end
  end

  defp parse_rounds_count(n) when is_integer(n), do: n

  defp parse_rounds_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} when int > 0 -> int
      _ -> 0
    end
  end

  defp parse_rounds_count(_), do: 0

  # A new individual double round robin plays the last two rounds of its
  # first cycle in reverse order - FIDE C.05 Annex 1's recommendation.
  # Decided for a new tournament and not in the context: an import or a
  # restored backup that does not carry the flag keeps its schedule.
  defp reverse_last_two_default(%{"type" => "roundrobin", "rr_cycles" => cycles} = params)
       when cycles in ["2", 2],
       do: Map.put_new(params, "rr_reverse_last_two", "true")

  defp reverse_last_two_default(params), do: params

  ## ---------- players ----------

  @audited_player_fields ~w(name title sex fide_id fide_rating national_rating tournament_rating
    federation club club_number birth_year category categories status absent
    forfeit absent_rounds fixed_board start_round extra_points manual_rank no_bye
    no_bye_rounds bye_preference bye_preference_rounds period_ratings)a

  @doc """
  Adds a player (`Tournaments.create_player/2` - a late entry gets its
  start round and pairing number there) and writes the audit row.
  `{:ok, player}` or `{:error, reason}`; `:setup_incomplete` while the
  tournament setup is not finished, as on the Players page.
  """
  def create_player(%Tournament{} = t, scope, params) do
    if Tournament.setup_complete?(t) do
      with {:ok, player} <- Tournaments.create_player(t.id, params) do
        Audit.log(t.id, scope, "player.created", %{
          player_id: player.id,
          player_name: player.name,
          rating: Player.rating(player)
        })

        {:ok, player}
      end
    else
      {:error, :setup_incomplete}
    end
  end

  @doc """
  Changes `before` as the Players page's dialog does
  (`Tournaments.update_player/3` with the warnings the arbiter confirmed:
  `:sent_round_changed`, `:second_half_bye`) and audits what changed.
  `{:ok, player}`, `{:error, {:needs_acknowledgement, ids}}`, or the
  changeset/reason.
  """
  def update_player(%Tournament{} = t, scope, %Player{} = before, params, acknowledged \\ []) do
    sent = Tournaments.sent_absence_rounds(before, params)
    ack? = :sent_round_changed in acknowledged
    half_ack? = :second_half_bye in acknowledged

    case Tournaments.update_player(before, params, acknowledged: acknowledged) do
      {:ok, player} ->
        changed = player_diff(before, player)

        if changed != %{} do
          Audit.log(
            t.id,
            scope,
            "player.updated",
            Enum.reduce(
              [
                if(ack? and sent != [], do: %{confirmed: "sent_round_changed"}, else: %{}),
                if(half_ack?, do: %{confirmed_second_half_bye: true}, else: %{})
              ],
              %{player_id: player.id, player_name: player.name, changed_fields: changed},
              &Map.merge(&2, &1)
            )
          )
        end

        {:ok, player}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "The audited fields that differ between two versions of a player, as `%{field => [from, to]}`."
  def player_diff(before, after_player) do
    for field <- @audited_player_fields,
        Map.get(before, field) != Map.get(after_player, field),
        into: %{} do
      {to_string(field), [Map.get(before, field), Map.get(after_player, field)]}
    end
  end

  ## ---------- hand edits ----------
  #
  # The Pairings page's hand edits (swap, substitute, mark absent, award a
  # bye, fill a seat, pair two from the pool, delete an empty board), as the
  # page applies them once its confirmation dialog is answered. The dialog's
  # questions come back here as acknowledgement ids: a phone is told which
  # ones the edit needs and sends them back ticked, which is the page's
  # checkbox without the page.

  # The audit action of each edit kind - `PairingsLive.audit_action/1`'s
  # table, so the audit page describes a phone's edit and the desk's with
  # one sentence.
  @hand_edit_audit %{
    swap: "pairing.players_swapped",
    swap_pool: "pairing.player_substituted",
    vacate: "pairing.seat_vacated",
    bye: "pairing.bye_awarded",
    fill: "pairing.seat_filled",
    pool_pair: "pairing.pool_paired",
    pool_bye: "pairing.bye_awarded",
    delete_pairing: "pairing.deleted"
  }

  # The acknowledgements a hand edit can ask for. `:frozen_round` and
  # `:pairing_rules` are the page's own ticks; the other two are the
  # context's (`Tournaments.vacate_seat/4` and friends take them in `opts`).
  @edit_acknowledgements [:frozen_round, :sent_round_changed, :pairing_rules, :second_half_bye]

  @doc "The acknowledgement ids a hand edit may need (`hand_edit/5`)."
  def edit_acknowledgement_ids, do: @edit_acknowledgements

  @doc """
  Applies one hand edit to `round` (pairings preloaded) of `t`, as the
  Pairings page does after its confirmation: the context write, the implicit
  start of the round's manual pairing alteration (Q65), the audit row.

  `action` is one of

    * `{:swap, a, b}` - two seated players trade seats (their own opponent:
      a colour swap); one seated and one from the pool: a substitution;
    * `{:vacate, player_id, bye_type}` - a seated player is marked absent,
      `bye_type` nil/"absent" or, where the tournament asks the type
      (`ByeTypes.applies?/1`), "requested-half", "requested-zero" or
      "full-point";
    * `{:bye, pairing_id}` - the player left alone on a board gets the
      pairing-allocated bye;
    * `{:fill, pairing_id, player_id}` - a pool player takes the empty seat;
    * `{:pool_pair, a, b, board}` - two pool players on a new board (`board`
      nil for the next free one);
    * `{:pool_bye, player_id}` - a pool player gets the pairing-allocated
      bye on a new board;
    * `{:delete_pairing, pairing_id}` - an empty last board is removed.

  `acknowledged` are the questions already answered, from
  `edit_acknowledgement_ids/0`. The ones this edit needs and did not get
  come back as `{:error, {:needs_acknowledgement, ids, info}}`, `info`
  carrying the edit's `summary` and the pairing-rule `warnings` (sentences)
  so the phone can show the same confirmation the desk shows.

  `{:ok, result}` or `{:error, reason}`. Team events and rounds paired as
  teams are the desk's (`:team_event`): their boards count for matches,
  which a phone has no way to see.
  """
  def hand_edit(%Tournament{} = t, scope, %Round{} = round, action, acknowledged \\ []) do
    with :ok <- editable_from_phone(t),
         {:ok, staged} <- stage_edit(t, round, action),
         :ok <- edit_gates(t, round, staged, acknowledged) do
      apply_edit(t, scope, round, staged, acknowledged)
    end
  end

  defp editable_from_phone(t) do
    if Tournament.team?(t) or Tournament.paired_as_teams?(t),
      do: {:error, :team_event},
      else: :ok
  end

  defp stage_edit(_t, _round, {:swap, a, a}), do: {:error, :same_player}

  defp stage_edit(t, round, {:swap, a, b}) do
    cond do
      seated?(round, a) and seated?(round, b) ->
        {:ok, {pa, fa}} = locate_seat(round, a)
        {:ok, {pb, fb}} = locate_seat(round, b)
        same? = pa.id == pb.id

        new_boards =
          if same?,
            do: new_board(pa, [{fa, b}, {fb, a}]),
            else: new_board(pa, [{fa, b}]) ++ new_board(pb, [{fb, a}])

        {:ok,
         %{
           kind: :swap,
           summary: "#{name(t, a)}  ⇄  #{name(t, b)}",
           new_boards: new_boards,
           apply: &Tournaments.swap_players_in_round(round, a, b, &1)
         }}

      seated?(round, a) or seated?(round, b) ->
        {seated, pooled} = if seated?(round, a), do: {a, b}, else: {b, a}

        if pool_member?(t, round, pooled) do
          {:ok, {pairing, field}} = locate_seat(round, seated)

          {:ok,
           %{
             kind: :swap_pool,
             summary: "#{name(t, pooled)} takes #{name(t, seated)}'s place",
             new_boards: new_board(pairing, [{field, pooled}]),
             apply: &Tournaments.swap_seated_with_pool_player(round, seated, pooled, &1)
           }}
        else
          {:error, :not_in_round}
        end

      true ->
        {:error, :not_in_round}
    end
  end

  defp stage_edit(t, round, {:vacate, player_id, bye_type}) do
    with {:ok, {_pairing, _field}} <- locate_seat(round, player_id),
         {:ok, type, needs} <- vacate_type(t, round.number, player_id, bye_type) do
      {:ok,
       %{
         kind: :vacate,
         summary: "#{name(t, player_id)} is not playing round #{round.number}",
         new_boards: [],
         bye_type: type,
         needs: needs,
         apply: &Tournaments.vacate_seat(round, player_id, type, &1)
       }}
    end
  end

  defp stage_edit(t, round, {:bye, pairing_id}) do
    with {:ok, pairing} <- fetch_pairing(round, pairing_id),
         {:ok, remaining} <- lone_player(pairing) do
      {:ok,
       %{
         kind: :bye,
         summary: "#{name(t, remaining)} sits out round #{round.number}",
         new_boards: [{remaining, :pab}],
         apply: &Tournaments.award_bye_for_vacancy(round, pairing, &1)
       }}
    end
  end

  defp stage_edit(t, round, {:fill, pairing_id, player_id}) do
    with {:ok, pairing} <- fetch_pairing(round, pairing_id),
         {:ok, _remaining} <- lone_player(pairing),
         true <- pool_member?(t, round, player_id) || {:error, :not_in_round} do
      field = if is_nil(pairing.white_player_id), do: :white_player_id, else: :black_player_id

      {:ok,
       %{
         kind: :fill,
         summary: "#{name(t, player_id)} joins board #{pairing.board}",
         new_boards: new_board(pairing, [{field, player_id}]),
         apply: &Tournaments.fill_seat(round, pairing, player_id, &1)
       }}
    end
  end

  defp stage_edit(_t, _round, {:pool_pair, a, a, _board}), do: {:error, :same_player}

  defp stage_edit(t, round, {:pool_pair, a, b, board}) do
    if pool_member?(t, round, a) and pool_member?(t, round, b) do
      board = board || Tournaments.next_free_board(round)

      {:ok,
       %{
         kind: :pool_pair,
         summary: "#{name(t, a)} - #{name(t, b)} on board #{board}",
         new_boards: [{a, b}],
         apply: &Tournaments.pair_from_pool(round, a, b, board, &1)
       }}
    else
      {:error, :not_in_round}
    end
  end

  defp stage_edit(t, round, {:pool_bye, player_id}) do
    cond do
      RoundRobin.by_hand?(t) ->
        {:error, :round_robin}

      not pool_member?(t, round, player_id) ->
        {:error, :not_in_round}

      true ->
        board = Tournaments.next_free_board(round)

        {:ok,
         %{
           kind: :pool_bye,
           summary: "#{name(t, player_id)} sits out round #{round.number}",
           new_boards: [{player_id, :pab}],
           apply: &Tournaments.award_pool_bye(round, player_id, board, &1)
         }}
    end
  end

  defp stage_edit(_t, round, {:delete_pairing, pairing_id}) do
    with {:ok, pairing} <- fetch_pairing(round, pairing_id) do
      {:ok,
       %{
         kind: :delete_pairing,
         summary: "Board #{pairing.board} is removed from round #{round.number}",
         new_boards: [],
         apply: fn _ack -> Tournaments.delete_pairing(round, pairing) end
       }}
    end
  end

  defp stage_edit(_t, _round, _action), do: {:error, :unknown_edit}

  # The bye type a vacated seat files the player under, and the tick a
  # second half-point bye needs (Q174). A picked type is only an option
  # where the tournament asks for one.
  defp vacate_type(_t, _n, _player_id, type) when type in [nil, "", "absent"],
    do: {:ok, "absent", []}

  defp vacate_type(t, n, player_id, type)
       when type in ["requested-half", "requested-zero", "full-point"] do
    with true <- ByeTypes.applies?(t) || {:error, :bye_type_not_asked},
         %Player{} = player <- Tournaments.get_player(t.id, player_id) || {:error, :not_in_round} do
      cond do
        type == "requested-half" and player.no_half_bye == true ->
          {:error, :half_bye_not_eligible}

        type == "requested-half" and HalfByes.taken_rounds(t, player) -- [n] != [] ->
          {:ok, type, [:second_half_bye]}

        true ->
          {:ok, type, []}
      end
    end
  end

  defp vacate_type(_t, _n, _player_id, _type), do: {:error, :unknown_bye_type}

  # What this edit needs confirmed, against what was: a round that is not
  # the latest paired one, a round already sent to the federation, boards
  # that break the pairing rules (Q66, Q67), and the edit's own.
  defp edit_gates(t, round, staged, acknowledged) do
    paired = Engine.paired_rounds_count(t.id)
    warnings = rule_warnings(t, round.number, staged.new_boards)

    needed =
      Enum.concat([
        if(paired > 0 and round.number != paired, do: [:frozen_round], else: []),
        if(PostponedGames.round_sent?(t.id, round.number), do: [:sent_round_changed], else: []),
        if(warnings != [], do: [:pairing_rules], else: []),
        Map.get(staged, :needs, [])
      ])

    case needed -- acknowledged do
      [] ->
        :ok

      missing ->
        {:error,
         {:needs_acknowledgement, missing, %{summary: staged.summary, warnings: warnings}}}
    end
  end

  defp apply_edit(t, scope, round, staged, acknowledged) do
    ack = [
      acknowledged: Enum.filter(acknowledged, &(&1 in [:sent_round_changed, :second_half_bye]))
    ]

    case staged.apply.(ack) do
      {:ok, _} = ok ->
        implicit_mpa_start(t, scope, round)

        details =
          %{round: round.number, summary: staged.summary}
          |> Map.merge(
            if(
              :sent_round_changed in acknowledged and
                PostponedGames.round_sent?(t.id, round.number),
              do: %{confirmed: "sent_round_changed"},
              else: %{}
            )
          )
          |> Map.merge(if(staged[:bye_type], do: %{bye_type: staged.bye_type}, else: %{}))
          |> Map.merge(
            if(:second_half_bye in Map.get(staged, :needs, []),
              do: %{confirmed_second_half_bye: true},
              else: %{}
            )
          )
          |> Map.put(:via, "mobile")

        Audit.log(t.id, scope, Map.fetch!(@hand_edit_audit, staged.kind), details)
        ok

      {:error, _reason} = error ->
        error
    end
  end

  # The first hand edit of a round opens its manual pairing alteration, from
  # the boards as they were before it (Q65) - `PairingsLive`'s own rule.
  defp implicit_mpa_start(t, scope, round) do
    if not ManualPairing.open?(round) do
      case ManualPairing.start(round, ManualPairing.boards(round)) do
        {:ok, true} ->
          Audit.log(t.id, scope, "pairing.mpa_started", %{round: round.number, implicit: true})

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Finishes the hand edits of `round` (pairings preloaded) the way the
  Pairings page's "Finish hand edits" does: the pairing checker judges the
  round (`ManualPairing.assess/2`); boards that are not the checker's are
  kept only with `:mpa_pibe` in `acknowledged`, and recorded as the round's
  MPA PIBE.

  `{:ok, pibe_line | nil}`, `{:error, {:needs_acknowledgement, [:mpa_pibe],
  info}}` with the checker's verdict for the phone to show (`checked`,
  `line`, `missing`, `added`, `warnings`, all as sentences), or
  `{:error, reason}`: `:no_hand_edits` when none are open, `{:vacant, board}`
  and `:no_boards` as the page says them.
  """
  def finish_hand_edits(%Tournament{} = t, scope, %Round{} = round, acknowledged \\ []) do
    if ManualPairing.open?(round) do
      case ManualPairing.assess(t, round) do
        {:error, _reason} = error ->
          error

        :unchanged ->
          finish_mpa(t, scope, round, :keep)

        {:matches, _info} ->
          finish_mpa(t, scope, round, :clear)

        {kind, info} when kind in [:differs, :unchecked] ->
          if :mpa_pibe in acknowledged do
            finish_mpa(t, scope, round, {:set, info.line})
          else
            {:error,
             {:needs_acknowledgement, [:mpa_pibe],
              %{
                checked: kind == :differs,
                line: info.line,
                missing: info |> Map.get(:missing, []) |> Enum.map(&pair_text(t, &1)),
                added: info |> Map.get(:added, []) |> Enum.map(&pair_text(t, &1)),
                warnings:
                  info
                  |> Map.get(:warnings, [])
                  |> Enum.map(&rule_warning_text(&1, fn id -> name(t, id) end))
              }}}
          end
      end
    else
      {:error, :no_hand_edits}
    end
  end

  defp finish_mpa(t, scope, round, pibe) do
    with :ok <- ManualPairing.finish(round, pibe) do
      line =
        case pibe do
          {:set, line} -> line
          :keep -> round.mpa_pibe
          :clear -> nil
        end

      Audit.log(t.id, scope, "pairing.mpa_finished", %{round: round.number, pibe: line})
      {:ok, line}
    end
  end

  @doc """
  What the boards a hand edit creates break (Q66, Q67), as sentences - only
  for a tournament the checker can judge, and only when the edit creates
  any. `new_boards` as `ManualPairing.warnings/4` takes them.
  """
  def rule_warnings(_t, _n, []), do: []

  def rule_warnings(%Tournament{} = t, n, boards) do
    names = &name(t, &1)

    case RoundRobin.by_hand?(t) || ManualPairing.field(t, n) do
      true ->
        boards =
          Enum.map(boards, fn
            {w, :pab} -> {w, nil}
            board -> board
          end)

        t |> ManualRoundRobin.warnings(n, boards) |> Enum.map(&rule_warning_text(&1, names))

      {:ok, field} ->
        field |> ManualPairing.warnings(t, n, boards) |> Enum.map(&rule_warning_text(&1, names))

      :error ->
        []
    end
  end

  @doc "One absolute-criteria breach (`ManualPairing.warnings/4`), in words; `name` turns a player id into a name."
  def rule_warning_text(%{kind: :rematch, players: [a, b], round: met}, name),
    do:
      gettext("%{a} and %{b} already played each other, in round %{round}.",
        a: name.(a),
        b: name.(b),
        round: met
      )

  def rule_warning_text(%{kind: :forbidden, players: [a, b]}, name),
    do: gettext("%{a} and %{b} are a prohibited pairing.", a: name.(a), b: name.(b))

  def rule_warning_text(%{kind: :bye, players: [a], reason: :pairing_bye}, name),
    do: gettext("%{name} already had a pairing-allocated bye.", name: name.(a))

  def rule_warning_text(%{kind: :bye, players: [a], reason: :forfeit_win}, name),
    do:
      gettext(
        "%{name} already won a game by forfeit, so may not get the pairing-allocated bye.",
        name: name.(a)
      )

  def rule_warning_text(%{kind: :bye, players: [a]}, name),
    do:
      gettext(
        "%{name} already had a full-point bye, so may not get the pairing-allocated bye.",
        name: name.(a)
      )

  def rule_warning_text(%{kind: :colour_three, players: [a], colour: colour}, name),
    do:
      gettext("%{name} gets %{colour} for the third game running, before the last round.",
        name: name.(a),
        colour: colour_word(colour)
      )

  def rule_warning_text(%{kind: :colour_imbalance, players: [a]}, name),
    do:
      gettext(
        "%{name} gets a colour difference of more than two, before the last round.",
        name: name.(a)
      )

  def rule_warning_text(%{kind: :wrong_colours, players: [a, b]}, name),
    do:
      gettext(
        "%{a} and %{b} both get the colour opposite to the one they are due.",
        a: name.(a),
        b: name.(b)
      )

  def rule_warning_text(%{kind: :rr_repeat, players: [a, b], round: met}, name),
    do:
      gettext("%{a} and %{b} already meet in round %{round}, in the same cycle.",
        a: name.(a),
        b: name.(b),
        round: met
      )

  def rule_warning_text(%{kind: :rr_colour_three, players: [a], colour: colour}, name),
    do:
      gettext("%{name} gets %{colour} for the third round running.",
        name: name.(a),
        colour: colour_word(colour)
      )

  def rule_warning_text(%{kind: :rr_outside, players: [a]}, name),
    do:
      gettext("%{name} is not in the round robin's table, so plays nobody else in it.",
        name: name.(a)
      )

  def rule_warning_text(%{kind: :rr_incomplete, players: [], cycle: cycle}, _name),
    do:
      gettext(
        "The rounds left in cycle %{cycle} can no longer pair everyone who has not met yet exactly once.",
        cycle: cycle
      )

  def rule_warning_text(%{kind: :rr_incomplete, players: players, cycle: cycle}, name),
    do:
      gettext(
        "The rounds left in cycle %{cycle} do not match the opponents still to meet for: %{names}. Not everyone can meet everyone exactly once in this cycle.",
        cycle: cycle,
        names: Enum.map_join(players, ", ", name)
      )

  def rule_warning_text(%{players: players}, name),
    do: Enum.map_join(players, ", ", name)

  defp colour_word("w"), do: gettext("White")
  defp colour_word(_b), do: gettext("Black")

  defp pair_text(t, {w, nil}), do: gettext("%{name} - bye", name: name(t, w))
  defp pair_text(t, {w, b}), do: "#{name(t, w)} - #{name(t, b)}"

  # The board `pairing` becomes with `substitutions` (`{field, player_id}`)
  # applied, as `ManualPairing.warnings/4` takes it.
  defp new_board(pairing, substitutions) do
    {w, b} =
      Enum.reduce(substitutions, {pairing.white_player_id, pairing.black_player_id}, fn
        {:white_player_id, id}, {_w, b} -> {id, b}
        {:black_player_id, id}, {w, _b} -> {w, id}
      end)

    cond do
      pairing.result == "bye" and is_nil(b) and not is_nil(w) -> [{w, :pab}]
      not is_nil(w) and not is_nil(b) -> [{w, b}]
      true -> []
    end
  end

  defp seated?(round, player_id),
    do:
      Enum.any?(
        round.pairings,
        &(&1.white_player_id == player_id or &1.black_player_id == player_id)
      )

  defp locate_seat(round, player_id) do
    Enum.find_value(round.pairings, {:error, :not_in_round}, fn pairing ->
      cond do
        pairing.white_player_id == player_id -> {:ok, {pairing, :white_player_id}}
        pairing.black_player_id == player_id -> {:ok, {pairing, :black_player_id}}
        true -> nil
      end
    end)
  end

  defp fetch_pairing(round, id) do
    case Enum.find(round.pairings, &(&1.id == id)) do
      nil -> {:error, :not_in_round}
      pairing -> {:ok, pairing}
    end
  end

  # The one player on a board with exactly one empty seat and no bye.
  defp lone_player(%{result: "bye"}), do: {:error, :already_bye}

  defp lone_player(pairing) do
    case {pairing.white_player_id, pairing.black_player_id} do
      {nil, nil} -> {:error, :not_vacant}
      {w, nil} -> {:ok, w}
      {nil, b} -> {:ok, b}
      _both -> {:error, :seat_taken}
    end
  end

  defp pool_member?(t, round, player_id) do
    t.id
    |> Tournaments.list_round_pool(round.number)
    |> Enum.any?(&(&1.player.id == player_id))
  end

  defp name(t, id), do: player_name(t.id, id) || "?"

  ## ---------- settings ----------

  # The settings an arbiter changes mid-event, and nothing structural: the
  # round count, the tie-breaks, the time control, the officials, the venue,
  # and the bye policy. Everything else is a desk page with a reason.
  @phone_settings ~w(rounds_count tiebreaks time_control chief_arbiter deputy_arbiter venue city
                     bye_value ask_bye_type shared_places)

  @doc "The settings fields a phone may change (`update_settings/3`), as strings."
  def phone_settings_fields, do: @phone_settings

  @doc """
  The settings fields of `phone_settings_fields/0` that `t` can change now:
  the locked ones (`Tournaments.locked_fields/1`) are left out.
  """
  def editable_settings(%Tournament{} = t) do
    locked = t |> Tournaments.locked_fields() |> Enum.map(&Atom.to_string/1)
    @phone_settings -- locked
  end

  @doc """
  Changes the settings of `t` as the Settings pages do
  (`Tournaments.update_tournament/2`, with its locks) and audits the
  difference. Only `phone_settings_fields/0` are taken from `params`; a
  tie-break list is checked against the tournament's own catalogue first.
  `{:ok, tournament}` or `{:error, reason}`.
  """
  def update_settings(%Tournament{} = t, scope, params) when is_map(params) do
    params = Map.take(params, @phone_settings)

    with :ok <- check_tiebreaks(t, params["tiebreaks"]),
         {:ok, updated} <- Tournaments.update_tournament(t, params) do
      changed = SettingsSupport.tournament_diff(t, updated)

      if changed != %{} do
        Audit.log(t.id, scope, "tournament.settings_updated", %{
          changed_fields: changed,
          via: "mobile"
        })
      end

      {:ok, updated}
    end
  end

  defp check_tiebreaks(_t, nil), do: :ok

  defp check_tiebreaks(t, codes) when is_list(codes) do
    known = t.type |> Tiebreaks.selectable() |> Enum.map(& &1.code)

    if codes != [] and Enum.all?(codes, &(is_binary(&1) and &1 in known)) and
         codes == Enum.uniq(codes),
       do: :ok,
       else: {:error, :unknown_tiebreak}
  end

  defp check_tiebreaks(_t, _codes), do: {:error, :unknown_tiebreak}
end
