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

  alias PairingsEngine.{
    Audit,
    EngineSlots,
    ManualPairing,
    PairingRationale,
    PostponedGames,
    Snapshots,
    Tournaments,
    Tpn
  }

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Tournament}
  alias PairingsEngineWeb.ByePreferenceText

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
end
