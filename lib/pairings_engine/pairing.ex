defmodule PairingsEngine.Pairing do
  @moduledoc """
  Round lifecycle: builds the TRF input for the Swiss engine, runs it, and
  creates the round with its pairings.

  Ainalrami (github.com/AuroraRyunix/Ainalrami), a from-scratch Dutch-system
  engine in pure Elixir, is the engine. It implements C.04.3 as it stands
  in the edition effective 1 February 2026, and runs in this BEAM: no
  subprocess, no JVM, no scratch file. Its input is still TRF text
  (`trf_input/5`), because that is the one form of the field FIDE's tools
  can also read.

  See `docs/pairing-systems.md` for the arbiter-facing description, and
  `docs/fide-endorsement.md` for where that leaves the endorsement
  paperwork.
  """

  import Ecto.Query
  require Logger

  alias PairingsEngine.{
    Repo,
    PostponedGames,
    Standings,
    Tournaments,
    Exclusions,
    Categories
  }

  alias PairingsEngine.Tournaments.{Player, Round, Pairing, Tournament}
  alias PairingsEngine.ExplanationJobs
  alias PairingsEngine.PairTiming
  alias PairingsEngine.PairingDisplay
  alias PairingsEngine.Pairing.Explainer
  alias PairingsEngine.RoundExplanation

  # The app has one TRF16 implementation and it lives in the engine. There
  # used to be a second, `PairingsEngine.Trf`, photocopied into Ainalrami and
  # then left behind while the copy grew: this file already handed its own
  # serialized text to `Ainalrami.Trf.parse/1` to read back, so the file was
  # written by one implementation and read by another on every pairing.
  alias Ainalrami.Trf

  # Fires with the exact TRF text about to be handed to the engine. The text
  # never touches disk and is gone once the round is paired, so this is the
  # only way to observe it afterward. Exists purely for test observability
  # (tests attach a handler to inspect the generated TRF's colour/rank
  # content) - nothing in the app itself subscribes to it.
  defp emit_trf_built(tournament_id, round_number, category_name, trf) do
    :telemetry.execute(
      [:pairings_engine, :pairing, :trf_built],
      %{},
      %{tournament_id: tournament_id, round: round_number, category: category_name, trf: trf}
    )
  end

  @doc """
  Pairs the next round. Dispatches on `tournament.pairing_system`:

    * `"swiss"` (default) - the Dutch path below, paired by Ainalrami
      in-process.
    * `"round_robin"` - delegates to `PairingsEngine.RoundRobin.pair_next_round/1`.
    * `"keizer"` - delegates to `PairingsEngine.Keizer.pair_next_round/1`.

  Returns `{:ok, round}` or `{:error, reason}`. This is the single public
  entry point the UI calls (see `PairingsEngineWeb.PairingsLive`'s "pair"
  event) - it never crashes on an unimplemented pairing system, it just
  returns an error the caller renders through
  `PairingsEngineWeb.SettingsSupport.error_text/1`. Most refusals are still
  plain strings; `{:all_rounds_paired, rounds_count}` is a reason instead,
  for every pairing system, because round robin's own loop decides by it.

  ## Postponed games

  A postponed game (`"*"`) does not hold the next round up: it counts as a
  draw for this pairing, from `PairingsEngine.Results`. Two situations wait
  for the arbiter to confirm them first, by passing the warning's id in
  `opts[:acknowledged]` (see `PairingsEngine.PostponedGames.pairing_warnings/1`):

    * `:missing_results_recorded_as_adjourned` (VCL4THP Q159, Q160) - the
      last round still has boards without a result. Unconfirmed, the round
      is refused exactly as it always was; confirmed, those boards are
      recorded as postponed and the round is paired. If the pairing itself
      then fails, they are put back to no result.
    * `:adjourned_older_round_open` (Q168) - a postponed game from a round
      before the last one is still open. Unconfirmed, this returns
      `{:error, {:needs_acknowledgement, [:adjourned_older_round_open]}}`.

  A round robin pairs from its schedule rather than from results, so none
  of this applies to it.
  """
  # A frozen tournament is refused before the pairing-system dispatch below,
  # so this covers Swiss, round robin and Keizer in one place. Returns a
  # plain-string error like every other refusal here, since the caller
  # renders these as-is.
  #
  # This used to pattern-match `archived_at` directly rather than calling
  # `Tournaments.ensure_writable/1`. That was equivalent while archiving was
  # the only reason a tournament could be read-only, and stopped being
  # equivalent the moment hand-off was a second one: a handed-off tournament
  # went straight past this clause and got paired, which is precisely the
  # divergence ("both copies paired round 6, differently") the hand-off lock
  # exists to make impossible. Duplicating a gate is how a gate gets missed.
  def pair_next_round(%Tournament{} = tournament, opts \\ []) do
    # "Pair anyway, ignoring the exclusion for X": one player's bye exclusion
    # lifted for this run only - see `with_bye_exclusions/4`.
    tournament = %{
      tournament
      | bye_exclusion_override: opts[:bye_exclusion_override],
        fide_departure_guard: opts[:fide_departure_guard] == true
    }

    case Tournaments.ensure_writable(tournament) do
      :ok -> pair_with_postponed_games(tournament, Keyword.get(opts, :acknowledged, []))
      {:error, reason} -> {:error, Tournaments.refusal_message(reason, "pairing")}
    end
  end

  # See the doc's "Postponed games". The missing-results warning is the one
  # whose refusal is not new: left unconfirmed it falls through to the
  # engines' own "still has missing results", so nothing about pairing a
  # tournament that never postpones a game has changed.
  defp pair_with_postponed_games(tournament, acknowledged) do
    warnings = PairTiming.span(:warnings, fn -> PostponedGames.pairing_warnings(tournament) end)
    missing = Enum.find(warnings, &(&1.id == :missing_results_recorded_as_adjourned))
    guarded = Enum.reject(warnings, &(&1.id == :missing_results_recorded_as_adjourned))

    with :ok <- PostponedGames.check_acknowledged(guarded, acknowledged) do
      if missing && :missing_results_recorded_as_adjourned in acknowledged do
        pair_after_recording_missing(tournament, missing.round)
      else
        dispatch_pair_next_round(tournament)
      end
    end
  end

  defp pair_after_recording_missing(tournament, round_number) do
    case PostponedGames.record_missing(tournament, round_number) do
      {:ok, recorded} ->
        case dispatch_pair_next_round(tournament) do
          {:ok, _round} = ok ->
            ok

          error ->
            PostponedGames.clear(recorded)
            error
        end

      error ->
        error
    end
  end

  defp dispatch_pair_next_round(%Tournament{pairing_system: "round_robin"} = tournament) do
    dispatch_stub(tournament, PairingsEngine.RoundRobin)
  end

  defp dispatch_pair_next_round(%Tournament{pairing_system: "keizer"} = tournament) do
    dispatch_stub(tournament, PairingsEngine.Keizer)
  end

  # A Swiss (teams) is paired team against team (C.04.6) unless its rounds
  # were already paired player by player, which it then carries on doing -
  # see `PairingsEngine.TeamSwiss.settle_mode/1` for how the two are told
  # apart.
  defp dispatch_pair_next_round(%Tournament{type: "team-swiss", pairing_system: "swiss"} = t) do
    t = PairingsEngine.TeamSwiss.settle_mode(t)

    if Tournament.team_swiss?(t),
      do: dispatch_stub(t, PairingsEngine.TeamSwiss),
      else: dispatch_swiss(t)
  end

  defp dispatch_pair_next_round(%Tournament{} = tournament), do: dispatch_swiss(tournament)

  defp dispatch_swiss(%Tournament{} = tournament) do
    paired = PairTiming.span(:load, fn -> paired_rounds_count(tournament.id) end)

    next_number = paired + 1
    # One read of the active roster for the whole run. This used to be
    # queried three times per pairing click - here, again inside
    # `eligible_players/2` on the next line, and a third time inside
    # `do_pair/2` - for the same rows. `eligible_players/2` keeps its own
    # arity for its other caller (Keizer) and its tests; the filtering half
    # is `eligible_from/2`, which both share.
    active = PairTiming.span(:load, fn -> active_players(tournament.id) end)
    eligible = eligible_from(active, next_number)

    result =
      cond do
        # A reason, not a sentence: the same one round robin's loop recognises
        # a finished schedule by (`PairingsEngine.RoundRobin.after_step/1`),
        # and Keizer gives too. The words are
        # `PairingsEngineWeb.SettingsSupport.error_text/1`'s.
        next_number > max_pairable_round(tournament) ->
          {:error, {:all_rounds_paired, tournament.rounds_count}}

        length(eligible) < 2 ->
          {:error, "At least two active players are needed"}

        not round_complete?(tournament.id, paired) ->
          {:error, "Round #{paired} still has missing results"}

        true ->
          active =
            tournament
            |> seed_newcomers_before_round_one(next_number, active)
            |> then(&release_late_round_one_absentees(tournament, next_number, &1))

          guard_fide_departures(tournament, next_number, fn ->
            tournament
            |> draw_initial_colour_before_round_one(next_number)
            |> ensure_pairing_numbers(late_entry_numbering_pool(tournament, active, next_number))
            |> freeze_baku_group_a(next_number)
            |> do_pair(next_number, active)
          end)
      end

    case result do
      {:ok, round, sections} ->
        # Synchronous, and before anything else sees the round: the
        # deviation facts are on the pending record already, so the stamp
        # is what it always was. Only the account is left for later.
        PairTiming.span(:deviations, fn -> record_pairing_deviations(tournament, next_number) end)

        PairTiming.span(:broadcast, fn ->
          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
        end)

        PairTiming.span(:status, fn -> Tournaments.refresh_status!(tournament.id) end)

        {:ok,
         PairTiming.span(:explanation, fn ->
           start_explanation(tournament, next_number, sections, round)
         end)}

      other ->
        other
    end
  end

  # VCL4THP Q43: a pairing that takes a tournament out of FIDE mode (a bye
  # exclusion or preference that moves the bye, a soft rule that moves a
  # board, extra points in the pairing) is a Level-4 act, so the arbiter is
  # asked before it is written. What moved is only known once the engine has
  # run, so the run happens inside one transaction and is rolled back when
  # it turns out to depart - nothing is kept of it (the pairing numbers, the
  # drawn colour and the round all go). Only when the caller asked
  # (`opts[:fide_departure_guard]`) and the tournament is in FIDE mode now;
  # every other run is exactly what it was. The caller confirms by pairing
  # again without the guard.
  defp guard_fide_departures(%Tournament{fide_departure_guard: true} = tournament, number, run) do
    if PairingsEngine.Compliance.fide_mode?(tournament) do
      outcome =
        Repo.transaction(fn ->
          case run.() do
            {:ok, _round, _sections} = ok ->
              case pairing_deviations(tournament, number) do
                [] -> ok
                deviations -> Repo.rollback({:fide_departure, deviations})
              end

            other ->
              other
          end
        end)

      case outcome do
        {:ok, result} -> result
        {:error, {:fide_departure, _deviations} = reason} -> {:error, reason}
        {:error, other} -> {:error, other}
      end
    else
      run.()
    end
  end

  defp guard_fide_departures(_tournament, _number, run), do: run.()

  # `swiss_match_format` inserts BOTH legs of a match (rounds `next_number`
  # and `next_number + 1`) in one `do_pair/2` call - see that function -
  # so the pairing boundary must leave room for both legs of the *next*
  # match, not just the next single round: with 2 rounds left, pairing
  # must still be allowed (it fills the final match); with 1 round left,
  # it must not (there's no room for a second leg). Hence `rounds_count -
  # 1` rather than `rounds_count`. As a consequence, `paired_rounds_count/1`
  # always lands on an even number after a successful match-format pairing
  # (each call adds exactly 2 rounds), so `next_number = paired + 1` is
  # always odd the next time `pair_next_round/1` runs - every match-format
  # pairing run always starts a fresh match at its first leg, never lands
  # mid-match.
  # C.04.3 Art. 5.1: the initial colour is drawn "before the pairing of the
  # first round". Only then - a later round reads the stored draw, and a
  # tournament that paired round 1 before the draw was recorded is left to
  # its engine's reading of the boards, exactly as before.
  defp draw_initial_colour_before_round_one(tournament, 1),
    do: Tournaments.ensure_initial_colour(tournament)

  defp draw_initial_colour_before_round_one(tournament, _next_number), do: tournament

  # C.04.7 1.2: Group A is decided before round 1, from the starting list -
  # so it is fixed here, once the round-1 numbers are out, and every later
  # round, export and preview reads it back (`baku_group_a_last/2`). Round 1
  # always fixes it afresh: a round 1 that was unpaired and is paired again,
  # perhaps over a different field, starts the event again. A later round
  # finds it already fixed - or, for a tournament that switched Baku on
  # after round 1 or was restored from a file older than the column, works
  # it out from round 1 once and keeps it.
  defp freeze_baku_group_a(
         %Tournament{acceleration: "baku", pairing_system: "swiss"} = tournament,
         next_number
       ) do
    tournament = if next_number == 1, do: %{tournament | baku_group_a_last: nil}, else: tournament

    if is_nil(tournament.baku_group_a_last) do
      last = baku_group_a_last(tournament, full_roster_players(tournament.id))

      tournament
      |> Ecto.Changeset.change(baku_group_a_last: last)
      |> Repo.update!()
    else
      tournament
    end
  end

  defp freeze_baku_group_a(tournament, _next_number), do: tournament

  # C.04.2 2.4: a Late Entry is "taken into account for the pairing of
  # rounds after the first", "given an appropriate TPN and paired only when
  # they actually arrive". So a player who is absent from round 1 - a
  # requested bye, an absence, a later start round - is not on round 1's
  # list: not numbered, and numbered on the round they turn up, like any
  # late entrant (`late_entry_numbering` deciding where). Everybody already
  # holding a number keeps it, whatever they are doing this round; it is
  # only the unnumbered who wait. In a Baku event it also keeps them out of
  # N (C.04.7 1.2 forms Group A from "the list of participants to be
  # paired"; 1.3.1 sends everybody else through C.04.2 Article 2).
  #
  # Baku always; any other Swiss when it was created under the rule
  # (`round_one_absentees_late?/1`). An older tournament keeps numbering its
  # round-1 absentees with the field, as it did when it started.
  defp late_entry_numbering_pool(tournament, active, next_number) do
    if round_one_absentees_late?(tournament),
      do: Enum.reject(active, &(is_nil(&1.pairing_number) and not_arrived?(&1, next_number))),
      else: active
  end

  @doc """
  Whether `tournament` treats a player absent from round 1 as a late entry
  (C.04.2 2.4): no pairing number until they arrive. Every Baku Swiss
  (C.04.7 1.2, VCL4THP Q111), and every other Swiss created since the rule
  was generalised (`Tournament`'s `round_one_absentees_late`). Never a
  round robin or Keizer, whose numbers are fixed with the schedule or are
  not C.04.2's.
  """
  def round_one_absentees_late?(%{pairing_system: "swiss"} = tournament) do
    Map.get(tournament, :acceleration) == "baku" or
      Map.get(tournament, :round_one_absentees_late) == true
  end

  def round_one_absentees_late?(_tournament), do: false

  defp not_arrived?(player, round_number),
    do: absent_for_round?(player, round_number) or not_yet_started?(player, round_number)

  # The other half of the rule above, for numbers issued before round 1 was
  # paired - a TPN exchange numbers the whole field in advance, and a round
  # 1 that was unpaired leaves its numbers behind. Whoever holds one and is
  # not on round 1's list after all hands it back, and the rest close ranks
  # in the order they had: 1..N over the players actually paired, which is
  # the N Group A is counted over. Returns the active roster, read again
  # when anything was written.
  defp release_late_round_one_absentees(tournament, 1, active) do
    if round_one_absentees_late?(tournament),
      do: release_round_one_absentees(tournament, active),
      else: active
  end

  defp release_late_round_one_absentees(_tournament, _next_number, active), do: active

  defp release_round_one_absentees(tournament, active) do
    arrived = active |> Enum.reject(&not_arrived?(&1, 1)) |> MapSet.new(& &1.id)

    {keep, release} =
      tournament.id |> full_roster_players() |> Enum.split_with(&(&1.id in arrived))

    if release == [] do
      active
    else
      Repo.transaction(fn ->
        ids = Enum.map(release, & &1.id)
        Repo.update_all(from(p in Player, where: p.id in ^ids), set: [pairing_number: nil])

        for {player, number} <- Enum.with_index(keep, 1), player.pairing_number != number do
          Repo.update_all(from(p in Player, where: p.id == ^player.id),
            set: [pairing_number: number]
          )
        end
      end)

      active_players(tournament.id)
    end
  end

  defp with_baku_group_a(
         %Tournament{acceleration: "baku", pairing_system: "swiss", baku_group_a_last: nil} = t,
         roster
       ),
       do: %{t | baku_group_a_last: baku_group_a_last(t, roster)}

  defp with_baku_group_a(tournament, _roster), do: tournament

  @doc """
  Creates the next round of an individual Swiss with no boards at all, for
  the arbiter to pair by hand - VCL4THP Q63: when the pairing rules leave no
  legal pairing (fewer players than rounds, say), the tournament must still
  be finishable. Every player the engine would have paired is left in the
  round's pool; the absentees get their bye rows exactly as a paired round
  gives them. The caller opens the round's manual pairing alteration
  (`PairingsEngine.ManualPairing.start/2`), whose end checks it and records
  the MPA PIBE.

  Refused for anything but an individual Swiss paired as one round at a
  time (`{:error, :not_by_hand}`), when every round is paired, and while the
  previous round still has missing results - the same guards as pairing.
  """
  def create_round_by_hand(%Tournament{} = tournament) do
    paired = paired_rounds_count(tournament.id)
    next_number = paired + 1
    active = active_players(tournament.id)

    cond do
      refusal = Tournaments.write_refused(tournament) ->
        refusal

      tournament.pairing_system != "swiss" or tournament.swiss_match_format or
          Tournament.team_swiss?(tournament) ->
        {:error, :not_by_hand}

      next_number > max_pairable_round(tournament) ->
        {:error, {:all_rounds_paired, tournament.rounds_count}}

      not round_complete?(tournament.id, paired) ->
        {:error, "Round #{paired} still has missing results"}

      true ->
        # Numbered as the engine's round 1 numbers them: a newcomer among
        # numbers left by an unpaired round 1 placed by rating, not last.
        active =
          tournament
          |> seed_newcomers_before_round_one(next_number, active)
          |> then(&release_late_round_one_absentees(tournament, next_number, &1))
          |> Enum.reject(&not_yet_started?(&1, next_number))

        round_specific = Enum.filter(active, &absent_for_round?(&1, next_number))

        tournament =
          tournament
          |> draw_initial_colour_before_round_one(next_number)
          |> ensure_pairing_numbers(late_entry_numbering_pool(tournament, active, next_number))
          |> freeze_baku_group_a(next_number)

        with {:ok, round} <-
               create_round(
                 [],
                 tournament,
                 next_number,
                 round_absentees(tournament, next_number, round_specific),
                 nil
               ) do
          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
          Tournaments.refresh_status!(tournament.id)
          {:ok, Tournaments.get_round(tournament.id, round.number)}
        end
    end
  end

  @doc false
  def max_pairable_round(%Tournament{swiss_match_format: true, rounds_count: n}), do: n - 1
  def max_pairable_round(%Tournament{rounds_count: n}), do: n

  # Calls `module.pair_next_round(tournament)` (module dispatched at runtime
  # so the compiler doesn't over-narrow the result type to today's single
  # `{:error, :not_implemented}` stub return value - once RoundRobin/Keizer
  # are actually implemented this same function keeps working unchanged)
  # and turns a not-implemented stub result into a friendly, user-facing
  # string. PairingsLive's "pair" handler renders any non-changeset error
  # through `SettingsSupport.error_text/1`, so a plain string here is what
  # ends up on screen - no atom formatting, no crash.
  #
  # On success, refreshes the tournament's derived status the same way the
  # Swiss path below does - RoundRobin/Keizer pair a round and broadcast
  # `:rounds` themselves, but neither calls `Tournaments.refresh_status!/1`,
  # so without this a round-robin/Keizer tournament would stay stuck on
  # "setup" after its first round is paired. Centralized here (rather than
  # in each engine module) so it's a single call site for both.
  defp dispatch_stub(tournament, module) do
    case module.pair_next_round(tournament) do
      {:error, :not_implemented} ->
        {:error, "This pairing system is not available yet"}

      {:ok, _round} = result ->
        Tournaments.refresh_status!(tournament.id)
        result

      other ->
        other
    end
  end

  @doc """
  Deletes a paired round (only the latest one, to keep history sane).

  Under `tournament.swiss_match_format`, a single `do_pair/2` call inserts
  BOTH legs of a match (rounds N and N+1 - see `create_mirrored_leg/4` and
  the comment above `max_pairable_round/1`, which documents that
  `paired_rounds_count/1` always lands on an even number after a
  match-format pairing run). Deleting only one leg would break that
  invariant - orphaning leg 1, or stranding the tournament with a
  `next_number` `max_pairable_round/1` can never reach again - so both legs
  of the match are deleted together here.

  Also deletes the round's `byes` rows: the `byes` table has no `round_id`
  foreign key (see the migration), so a plain `Round` delete would otherwise
  leave orphaned bye rows behind that collide (`UNIQUE(player_id, round)`)
  the next time this round number is paired.
  """
  def delete_round(tournament_id, number) do
    case Tournaments.ensure_writable(tournament_id) do
      :ok -> do_delete_round(tournament_id, number)
      {:error, reason} -> {:error, Tournaments.refusal_message(reason, "unpairing")}
    end
  end

  defp do_delete_round(tournament_id, number) do
    if number == paired_rounds_count(tournament_id) do
      match_format? =
        Repo.one(
          from t in Tournament, where: t.id == ^tournament_id, select: t.swiss_match_format
        )

      numbers = if match_format? and number > 1, do: [number - 1, number], else: [number]

      if round_sent?(tournament_id, numbers),
        do: {:error, :round_sent_in_trf},
        else: really_delete_rounds(tournament_id, numbers)
    else
      {:error, "Only the latest round can be unpaired"}
    end
  end

  # A round whose results went out in a TRF finalised for sending stays:
  # unpairing and re-pairing it would leave the games that were sent with
  # nothing behind them, and put new ones in the next file. Asked of the
  # sent-games record too, so it holds after a restore.
  defp round_sent?(tournament_id, numbers),
    do: Enum.any?(numbers, &PairingsEngine.PostponedGames.round_sent?(tournament_id, &1))

  defp really_delete_rounds(tournament_id, numbers) do
    round_ids =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament_id and r.number in ^numbers,
          select: r.id
      )

    # One transaction, because the two deletes are one act. A crash
    # between them used to leave orphan `byes` rows behind, and every bye
    # insert in the module uses `on_conflict: :nothing` - so on
    # re-pairing the orphan wins and the player is scored for a bye they
    # are not taking. Every round-CREATING path here wraps Round +
    # Pairings + byes the same way; see `keizer.ex:474-478`.
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.delete_all(
          from r in Round, where: r.tournament_id == ^tournament_id and r.number in ^numbers
        )

        kept = granted_bye_ids(tournament_id, numbers)

        Repo.delete_all(
          from b in "byes",
            where: b.tournament_id == ^tournament_id and b.round in ^numbers,
            where: b.id not in ^kept
        )

        # A team event's draw order is only frozen while a round exists.
        # Unpairing the last one gives the teams back to the Teams page, so
        # a team can still be added, removed or re-seeded before the event
        # starts again. Players' own numbers are left alone, exactly as an
        # individual round robin leaves them.
        unless Repo.exists?(from r in Round, where: r.tournament_id == ^tournament_id) do
          Repo.update_all(
            from(t in PairingsEngine.Tournaments.Team,
              where: t.tournament_id == ^tournament_id
            ),
            set: [pairing_number: nil]
          )

          # Nothing paired any more, so how a team Swiss is paired is open
          # again: an event that went player by player and is unpaired back
          # to nothing pairs by teams from its new round 1. And a Baku
          # Group A was the round-1 field's, so the next round 1 decides it
          # again (`freeze_baku_group_a/2`).
          Repo.update_all(
            from(t in Tournament, where: t.id == ^tournament_id),
            set: [team_pairing_mode: nil, baku_group_a_last: nil]
          )
        end

        :ok
      end)

    # A round still having its account worked out: the result could no
    # longer be stored (`PairingsEngine.ExplanationJobs.store/3` wants the
    # row and its fingerprint), so stop spending the server's cores on it.
    ExplanationJobs.cancel(round_ids)

    Tournaments.broadcast_tournament_change(tournament_id, :rounds)
    Tournaments.refresh_status!(tournament_id)
    :ok
  end

  # The bye rows an unpairing leaves standing: a half-point, zero-point or
  # full-point bye for a player who is still out of that round
  # (`absent_rounds`, or absent altogether). Those were the arbiter's, not
  # the pairing's - imported ahead of the round (`TrfImport`'s
  # `import_future_byes/4`) or granted in it - and the pairing that comes
  # next writes its absentees `on_conflict: :nothing`, so a kept row is the
  # bye that comes back. Deleting them all, as this did, turned a granted
  # half point into a plain absence at whatever the tournament pays for one.
  #
  # Everything else goes: the pairing's own `"absent"` and allocated byes,
  # and an individual round robin's structural zero-point bye, which its
  # schedule hands out again (its import keeps no granted bye either).
  defp granted_bye_ids(tournament_id, numbers) do
    tournament = Repo.get!(Tournament, tournament_id)

    if tournament.pairing_system == "round_robin" and not Tournament.team?(tournament) do
      []
    else
      from(b in "byes",
        join: p in Player,
        on: p.id == b.player_id,
        where:
          b.tournament_id == ^tournament_id and b.round in ^numbers and
            b.type in ["requested-half", "requested-zero", "full-point"],
        select: {b.id, b.round, p.absent, p.absent_rounds}
      )
      |> Repo.all()
      |> Enum.filter(fn {_id, round, absent, rounds} ->
        absent == true or round in Player.parse_absent_rounds(to_string(rounds))
      end)
      |> Enum.map(&elem(&1, 0))
    end
  end

  def paired_rounds_count(tournament_id) do
    Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament_id), :count)
  end

  def round_complete?(_tournament_id, 0), do: true

  def round_complete?(tournament_id, number) do
    not Repo.exists?(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and r.number == ^number and p.result == ""
    )
  end

  ## ---------- the next-round preview ----------
  #
  # See `PairingsEngine.NextRoundPreview`. `preview_context/1` reads, once,
  # everything the real pairing would read from the database;
  # `preview_round/2` then pairs the next round in memory for one set of
  # results for the open games, through `plan_round/4` - the function the
  # real pairing runs - and returns its boards. `preview_variants/2` does
  # the same for many sets in one engine call, and says so when it cannot.
  # Nothing is written, ever: a late entrant's pairing number is handed out
  # in memory only, and `save_plan/3` is never called.

  @doc """
  What pairing round `paired + 1` of an individual Swiss would read, read
  once for the preview. `{:ok, context}` or `{:error, reason}`, the reason
  one of `:not_individual_swiss`, `:read_only`, `:no_round`,
  `:all_rounds_paired` and `:too_few_players` - the cases in which the real
  "pair next round" would refuse whatever the results.

  Everything that does not depend on the open games' results is worked out
  here, once: the history with every player's games (`precompute_games/2`),
  and the numbers a late entrant is about to get. `preview_base/2` adds the
  engine's field as parsed, so that each outcome only re-ranks it.
  """
  def preview_context(%Tournament{} = tournament) do
    with {:ok, checked} <- preview_check(tournament), do: {:ok, build_preview_context(checked)}
  end

  @doc """
  `preview_context/1`'s refusals without the work: `{:ok, %{tournament:,
  round_number:, next_number:, active:}}` when the next round could be
  previewed, or the `{:error, reason}` `preview_context/1` would return.
  Cheap - a few small reads - so a preview whose outcomes are all known
  already (`PairingsEngine.NextRoundPreview.Memo`) asks this instead.
  """
  def preview_check(%Tournament{} = tournament) do
    tournament = %{tournament | bye_exclusion_override: nil}
    paired = paired_rounds_count(tournament.id)
    next_number = paired + 1
    active = active_players(tournament.id)

    cond do
      tournament.pairing_system != "swiss" or Tournament.team?(tournament) ->
        {:error, :not_individual_swiss}

      Tournaments.ensure_writable(tournament) != :ok ->
        {:error, :read_only}

      paired == 0 ->
        {:error, :no_round}

      next_number > max_pairable_round(tournament) ->
        {:error, :all_rounds_paired}

      length(eligible_from(active, next_number)) < 2 ->
        {:error, :too_few_players}

      true ->
        {:ok,
         %{
           tournament: tournament,
           round_number: paired,
           next_number: next_number,
           active: active
         }}
    end
  end

  defp build_preview_context(%{tournament: tournament, active: active} = checked) do
    # `dispatch_swiss/1` numbers a player who has none yet
    # (`ensure_pairing_numbers/2`) before it reads the history; here
    # the numbers go into the history's roster in memory instead - a
    # late entrant's, and those of the players they move down - and
    # Baku's line moves with them as it will on disk.
    {numbers, group_a_last} =
      new_pairing_numbers(
        tournament,
        late_entry_numbering_pool(tournament, active, checked.next_number)
      )

    tournament = %{tournament | baku_group_a_last: group_a_last}

    history =
      tournament
      |> build_shared_history()
      |> with_pairing_numbers(numbers)
      |> then(&precompute_games(tournament, &1))

    # Group A read once here rather than once per outcome, for the rare
    # Baku event that has none stored yet (see `baku_group_a_last/2`).
    tournament = with_baku_group_a(tournament, Map.values(history.full_roster))

    Map.merge(checked, %{tournament: tournament, history: history, base: nil})
  end

  @doc """
  The next round as `pair_next_round/2` would pair it once the open games of
  `context.round_number` had the given results - `results` is
  `%{pairing_id => result code}` - without writing anything.

  `{:ok, boards}`, the boards as `plan_boards/1` numbers them (`{board,
  white, black}`, players as structs, `black` nil for the pairing-allocated
  bye), or the `{:error, reason}` the real pairing would have returned.
  """
  def preview_round(context, results, opts \\ []) when is_map(results) do
    history = outcome_history(context, results)

    # With a base (`preview_base/2`) the engine's field is the base's,
    # re-ranked for this outcome; `text: true` builds and parses the TRF
    # instead, as the real pairing does - the tests compare the two.
    base = if Keyword.get(opts, :text, false), do: nil, else: context.base
    run = %{history: history, preview?: true, base: base}

    case plan_round(context.tournament, context.next_number, context.active, run) do
      {:ok, plan} -> {:ok, plan_boards(plan)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  `context` with the engine's field of one outcome, `results`, parsed
  once: the players as `Ainalrami.Trf.parse/1` reads them off the TRF the
  real pairing builds, with their ranks. `preview_round/2` then re-ranks
  it for each outcome (`rerank_field/4`) instead of writing and reading a
  whole TRF again - about 0.1 s per outcome on 600 players, more than the
  engine itself takes.

  A tournament paired by category keeps the TRF path: its field is one
  file per category.
  """
  def preview_base(context, results) when is_map(results) do
    run = %{history: outcome_history(context, results), preview?: true, base: :capture}

    case plan_round(context.tournament, context.next_number, context.active, run) do
      {:ok, %{kind: :base, base: base}} -> %{context | base: base}
      _other -> context
    end
  end

  @doc """
  Several outcomes of `context` (a `preview_base/2` one) paired in ONE call
  into the engine, `Ainalrami.Pairing.pair_variants/3`: `{:ok, outcomes}`,
  one `preview_round/2` answer per entry of `results_list`, in order - or
  `:fallback` when the batch cannot be trusted to give exactly those, and
  the caller is to pair the outcomes one by one instead.

  The field is built once, for the first outcome, exactly as
  `preview_round/2` builds it. An outcome then differs from it in the
  players of the open games and nothing else: their result in the round
  being played and their score (`with_outcome/4`, the same function the
  one-by-one path applies). Everything else the engine is handed - the
  ranks, every other player, the forbidden and soft pairs, the bye
  exclusions, the options - is worked out from the roster, the settings
  and the round number, none of which a result moves. The one input that
  could still differ is the bye preferences, and those the batch does not
  take: with any in play, `:fallback`. Likewise without a base (pairing by
  category, or a TRF the engine would not read), and when the batch raises
  anything other than the refusal it reports per variant.

  A refusal comes back as `preview_round/2` returns it, logged and worded
  the same.
  """
  def preview_variants(context, [_ | _] = results_list) do
    case context.base do
      %{} = base ->
        histories = Enum.map(results_list, &outcome_history(context, &1))
        run = %{history: hd(histories), preview?: true, base: base, variants: histories}

        case plan_round(context.tournament, context.next_number, context.active, run) do
          {:ok, %{kind: :variants, outcomes: outcomes}} -> {:ok, outcomes}
          _other -> :fallback
        end

      nil ->
        :fallback
    end
  end

  @doc false
  # The engine's field for one outcome, both ways - for the test that holds
  # `rerank_field/4` to what `Ainalrami.Trf.parse/1` reads off the real TRF.
  def preview_fields(context, results) do
    history = outcome_history(context, results)

    [context.base, :capture]
    |> Enum.map(fn base ->
      run = %{history: history, preview?: true, base: base, field_only?: true}

      case plan_round(context.tournament, context.next_number, context.active, run) do
        {:ok, %{kind: :field, field: field}} -> field
        other -> other
      end
    end)
  end

  # The history of one outcome: the open games' results filled in, and the
  # games of the players who played them walked again - nobody else's
  # games depend on the results, so theirs are the context's.
  defp outcome_history(context, results) do
    history = with_results(context.history, context.round_number, results)

    changed =
      history.rounds
      |> Enum.find(&(&1.number == context.round_number))
      |> then(&((&1 && &1.pairings) || []))
      |> Enum.filter(&Map.has_key?(results, &1.id))
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1, Map.fetch!(history.full_roster, &1)})

    games =
      Map.merge(
        history.games,
        walk_games(context.tournament, Map.delete(history, :games), changed)
      )

    %{history | games: games}
    |> Map.put(:changed, MapSet.new(Map.keys(changed)))
  end

  defp with_results(history, round_number, results) do
    rounds =
      Enum.map(history.rounds, fn
        %Round{number: ^round_number} = round ->
          pairings =
            Enum.map(round.pairings, fn pairing ->
              case Map.fetch(results, pairing.id) do
                {:ok, result} -> %{pairing | result: result}
                :error -> pairing
              end
            end)

          %{round | pairings: pairings}

        round ->
          round
      end)

    %{history | rounds: rounds}
  end

  defp with_pairing_numbers(history, numbers) do
    roster =
      Enum.reduce(numbers, history.full_roster, fn {player, number}, roster ->
        Map.put(roster, player.id, %{player | pairing_number: number})
      end)

    %{history | full_roster: roster}
  end

  ## ---------- pairing numbers ----------

  @doc """
  Assigns `pairing_number` to every player in `players` that doesn't have
  one yet, in the initial order (`initial_order/2`: Tournament Rating, FIDE
  title, then the tournament's last criterion - C.04.2 2.2), and returns
  `tournament` - with `baku_group_a_last` moved if a late entrant was put
  above Group A's last player - so it composes in a pipe the way the Swiss
  path above uses it.

  Before any number exists the field is numbered 1, 2, ... in that order. A
  late entrant - somebody numbered when others already are - goes after the
  highest number by default. With the Swiss tournament's
  `late_entry_numbering` on `"rating"` they are given "an appropriate TPN"
  instead (C.04.2 2.4; C.04.7 1.3.1: "accommodated in the pairing list
  according to Article 2"): the number of the first numbered player they
  outrank, everybody from there down moving one place. That is 2.5's "the
  TPNs given at the start of the tournament are provisional".
  Players already numbered keep their order among themselves, so no
  earlier round's pairing changes meaning: the Dutch rules read the TPN
  only for that order, and the round-1 colour parity is taken on a
  numbering of the players who had arrived (the SPP ruling of 2026-08-27),
  which the late entrant was not part of. Round robin and Keizer append
  instead: a Berger schedule is fixed at its freeze, and Keizer is not
  C.04.2's.

  Exposed (not private) so `PairingsEngine.Keizer` and
  `PairingsEngine.RoundRobin` freeze pairing numbers the same way.
  """
  def ensure_pairing_numbers(tournament, players) do
    {numbers, group_a_last} = new_pairing_numbers(tournament, players)

    Repo.transaction(fn ->
      Enum.each(numbers, fn
        # A player who already holds a number is only ever moved down by a
        # late entrant above them. Written past `update_player/2`, whose
        # round-4 freeze (C.04.2 2.3) is about correcting the ranking data,
        # not about 2.4's late entries.
        {%Player{pairing_number: old} = player, number} when is_integer(old) ->
          Repo.update_all(from(p in Player, where: p.id == ^player.id),
            set: [pairing_number: number]
          )

        {player, number} ->
          {:ok, _} = Tournaments.update_player(player, %{pairing_number: number})
      end)
    end)

    if group_a_last != Map.get(tournament, :baku_group_a_last) do
      tournament |> Ecto.Changeset.change(baku_group_a_last: group_a_last) |> Repo.update!()
    else
      tournament
    end
  end

  # Numbers issued before round 1 - by a TPN exchange (`PairingsEngine.Tpn`),
  # or left from a round 1 that was unpaired - and a player entered since:
  # round 1 places them by rating among the others rather than last, as it
  # would have numbered them with everybody else. With no number issued, or
  # nobody new, nothing happens and `ensure_pairing_numbers/2` numbers the
  # field as it always did. Returns the active roster, read again when
  # numbers were written, so nothing after this sees a newcomer as still
  # unnumbered.
  defp seed_newcomers_before_round_one(tournament, 1, active) do
    if PairingsEngine.Tpn.seed_newcomers(tournament, active) == :seeded,
      do: active_players(tournament.id),
      else: active
  end

  defp seed_newcomers_before_round_one(_tournament, _next_number, active), do: active

  # The numbers `ensure_pairing_numbers/2` would hand out, as
  # `{[{player, number}], baku_group_a_last}` - every player whose number is
  # new or moves, and Group A's line after the move - without writing them:
  # the next-round preview (`preview_context/1`) numbers a late entrant in
  # memory exactly as the real pairing will on disk.
  defp new_pairing_numbers(tournament, players) do
    newcomers =
      players |> Enum.filter(&is_nil(&1.pairing_number)) |> initial_order(tournament)

    group_a_last = Map.get(tournament, :baku_group_a_last)

    cond do
      newcomers == [] ->
        {[], group_a_last}

      inserts_late_entrants?(tournament) ->
        tournament.id
        |> full_roster_players()
        |> number_late_entrants(newcomers, tournament, group_a_last)

      true ->
        max_existing = highest_pairing_number(tournament.id)
        {Enum.with_index(newcomers, max_existing + 1), group_a_last}
    end
  end

  defp inserts_late_entrants?(
         %Tournament{pairing_system: "swiss", late_entry_numbering: "rating"} = t
       ),
       do: not Tournament.team_swiss?(t)

  defp inserts_late_entrants?(_tournament), do: false

  @doc """
  The pure core of a Swiss late entry (`ensure_pairing_numbers/2`):
  `numbered` is the roster holding numbers, `newcomers` the players to
  number, already in `initial_order/2`. Each newcomer, best first, takes the
  number of the first numbered player (by number) they rank ahead of, and
  every number from there on moves up one; one who outranks nobody goes
  after the highest number. `group_a_last` (Baku's line, or nil) moves with
  the player who holds it (C.04.7 1.3.2), so a newcomer put above it is in
  Group A.

  Returns `{[{player, number}], group_a_last}` with only the players whose
  number is new or changed. With no numbered roster this is plain 1..N.
  """
  def number_late_entrants(numbered, newcomers, tournament, group_a_last) do
    start = numbered |> Enum.sort_by(& &1.pairing_number) |> Enum.map(&{&1, &1.pairing_number})

    {final, last} =
      Enum.reduce(newcomers, {start, group_a_last}, fn newcomer, {list, last} ->
        key = initial_order_key(newcomer, tournament)

        case Enum.find(list, fn {p, _n} -> key < initial_order_key(p, tournament) end) do
          nil ->
            highest = list |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
            {list ++ [{newcomer, highest + 1}], last}

          {_p, at} ->
            shifted = Enum.map(list, fn {p, n} -> if n >= at, do: {p, n + 1}, else: {p, n} end)
            last = if is_integer(last) and at <= last, do: last + 1, else: last
            {Enum.sort_by([{newcomer, at} | shifted], &elem(&1, 1)), last}
        end
      end)

    changed = Enum.reject(final, fn {p, n} -> p.pairing_number == n end)
    {changed, last}
  end

  @doc """
  The order pairing numbers are handed out in (C.04.2 2.2): the Tournament
  Rating highest first (`Player.rating/2` under the tournament's
  `rating_method`), then the FIDE title (GM-IM-WGM-FM-WIM-CM-WFM-WCM-none),
  then the tournament's `initial_order_tiebreak` - alphabetical unless the
  arbiter chose another (2.2.3) - and the name and id last so the order is
  always total.

  One definition, used by `ensure_pairing_numbers/2` when it issues the real
  numbers and by `PairingsEngine.Snapshot` when it numbers the field
  provisionally before round 1 is paired - so the public list a spectator
  reads before the first round is the same order the numbers will actually
  come out in.
  """
  def initial_order(players, tournament),
    do: Enum.sort_by(players, &initial_order_key(&1, tournament))

  @doc "The sort key of `initial_order/2`: smaller ranks first."
  def initial_order_key(%Player{} = player, tournament) do
    {-Player.rating(player, tournament), Player.title_rank(player),
     last_criterion(player, Map.get(tournament, :initial_order_tiebreak)), player.name || "",
     player.id || 0}
  end

  # Unknown values go after known ones, so a player with no FIDE ID or no
  # date of birth does not jump the queue.
  defp last_criterion(%Player{fide_id: id}, "fide_id") when is_integer(id) and id > 0,
    do: {0, id}

  defp last_criterion(_player, "fide_id"), do: {1, 0}

  defp last_criterion(player, "age_older") do
    case birth_key(player) do
      nil -> {1, 0}
      days -> {0, days}
    end
  end

  defp last_criterion(player, "age_younger") do
    case birth_key(player) do
      nil -> {1, 0}
      days -> {0, -days}
    end
  end

  defp last_criterion(_player, _name), do: {0, 0}

  # A date of birth as a day number; a year alone counts as 1 July of it.
  defp birth_key(%Player{birth_date: %Date{} = date}), do: Date.to_gregorian_days(date)

  defp birth_key(%Player{birth_year: year}) when is_integer(year) and year > 0,
    do: Date.to_gregorian_days(Date.new!(year, 7, 1))

  defp birth_key(_player), do: nil

  # The highest number ever ISSUED in this tournament, over the whole roster.
  #
  # It used to be `Enum.max` over the `players` argument, and both callers
  # hand that argument `active_players/1` - which excludes `status != active`,
  # `absent` and `forfeit`. So marking the top-numbered player absent removed
  # their number from the maximum while the number itself stayed frozen on
  # their row, and the next player to register was handed a number already in
  # use. Nothing rejected it: there is no unique index and no changeset check,
  # and `guard_pairing_number_freeze/2` only guards CHANGING a number, not
  # issuing a duplicate.
  #
  # "Which numbers exist" is a question about the roster, never about who is
  # currently eligible - the same distinction `full_roster_players/1` and
  # `build_shared_history/1` already exist to make. This is one query rather
  # than reusing those because it needs the maximum, not the rows.
  defp highest_pairing_number(tournament_id) do
    Repo.one(
      from p in Player,
        where: p.tournament_id == ^tournament_id and not is_nil(p.pairing_number),
        select: max(p.pairing_number)
    ) || 0
  end

  ## ---------- the pairing run ----------

  # Runs the engine once for `next_number` and inserts its result as a `Round`.
  # When `tournament.swiss_match_format` is set, this is leg 1 of a match:
  # `create_round/5` also inserts leg 2 (`next_number + 1`) in the same
  # transaction, an exact colour-reversed mirror of leg 1 - no second
  # engine call, no new TRF file (see `create_mirrored_leg/4`). Round-
  # specific absentees for `next_number` (`round_absentees` below) are
  # threaded through so leg 2 can mirror their requested-bye rows too,
  # rather than independently re-evaluating `absent_for_round?/2` for
  # `next_number + 1` - a deliberate scope limitation, see
  # `create_mirrored_leg/4`.
  #
  # Split in two since the next-round preview: `plan_round/4` works out the
  # round - who plays whom, on which board - and writes nothing;
  # `save_plan/3` writes it. The preview (`preview_round/2`) runs the very
  # same `plan_round/4` over a history with the open games' results filled
  # in, and never calls `save_plan/3`.
  #
  # `@pair_run` is how the real pairing runs `plan_round/4`: its history
  # read from the database, and the round's deviation facts worked out (a
  # second engine run each, only when their setting is in play) for the
  # record it saves. The preview hands in its own history and skips those:
  # they are facts about the saved round's account, not about who plays
  # whom.
  @pair_run %{history: nil, preview?: false}

  defp do_pair(tournament, next_number, active) do
    case plan_round(tournament, next_number, active, @pair_run) do
      {:ok, plan} -> PairTiming.span(:save, fn -> save_plan(plan, tournament, next_number) end)
      {:error, _reason} = error -> error
    end
  end

  # The click's stages are timed (`PairingsEngine.PairTiming`); a preview's
  # hundreds of runs are not the click.
  defp run_span(%{preview?: true}, _stage, fun), do: fun.()
  defp run_span(_run, stage, fun), do: PairTiming.span(stage, fun)

  defp run_history(%{history: nil}, tournament),
    do: PairTiming.span(:load, fn -> pairing_history(tournament) end)

  defp run_history(%{history: history}, _tournament), do: history

  defp plan_round(tournament, next_number, active, run) do
    # A late entrant is dropped here, before the absent/present split, and
    # so lands in NEITHER list: not sent to the engine, and not given an
    # absentee bye row either. They are not absent - they have not joined
    # yet, and a round before `start_round` is a round the tournament did
    # not have them for. What that round is WORTH is not decided here: with
    # `late_entry_absences` on and points paid for an absence it counts as
    # one, derived when scores are read and never written as a row - see
    # `PairingsEngine.LateEntry`.
    #
    # `pair_next_round/1` has always computed this filter (that is what
    # `eligible_players/2` is), but only ever used the result to count
    # heads for the "at least two players" guard. The roster handed to the
    # engine was rebuilt here from `active_players/1` and never had the
    # filter applied, so a Swiss tournament restored from a backup with a
    # player at `start_round: 3` paired them in rounds 1 and 2. Keizer read
    # `start_round` correctly all along; only this path did not.
    active = Enum.reject(active, &not_yet_started?(&1, next_number))

    {players, round_specific} =
      Enum.split_with(active, &(not absent_for_round?(&1, next_number)))

    # A player marked absent for the whole tournament never reached this
    # function at all: `active_players/1` filters them out in SQL, so they
    # were not in `active`, not in the split above, and got no bye row for
    # any round. No board, no forfeit, no row - they simply vanished from
    # the round, scoring zero no matter what the tournament's absence value
    # said. Keizer had always recorded them; Swiss never did.
    #
    # Both kinds are the same event. You only ever know somebody is absent
    # BEFORE the round is paired because they told you - an unannounced
    # no-show gets paired and forfeits - so "requested a bye" and "marked
    # absent" are one thing wearing two names, and they score through one
    # value and one allowance.
    # The absentees themselves - `round_specific` plus the whole-tournament
    # ones - are only needed to write their bye rows, so `save_plan/3` reads
    # the latter (`round_absentees/3`); the preview never asks.
    #
    # Players requesting an absence for this specific round get a bye row
    # instead of being sent to the engine, so the
    # pairing engine never considers them for this round. Computed once over
    # the whole active/round_absentees split, before any category
    # partitioning happens below - unaffected by `pair_by_category`.
    #
    # The actual `insert_round_absentee_byes/3` call happens later, inside
    # `create_round/5`'s or `insert_category_round/3`'s `Repo.transaction`
    # (after the engine has already succeeded) rather than here - see those
    # functions. Running it here, before the engine is even invoked, would
    # permanently commit these bye rows even if the engine then failed, bricking
    # the round on retry (UNIQUE(player_id, round) violation).
    result =
      if tournament.pair_by_category do
        do_pair_by_category(tournament, players, next_number, run)
      else
        do_pair_single(tournament, players, next_number, run)
      end

    case result do
      {:ok, plan} -> {:ok, Map.put(plan, :round_specific, round_specific)}
      {:error, _reason} = error -> error
    end
  end

  defp round_absentees(tournament, next_number, round_specific),
    do: round_specific ++ absent_players(tournament.id, next_number)

  # Writes what `plan_round/4` worked out: the Round, its boards
  # (`plan_boards/1`, the one numbering the preview shows too) and the bye
  # rows of the round's absentees, in one transaction.
  defp save_plan(%{kind: :single} = plan, tournament, next_number) do
    round_absentees = round_absentees(tournament, next_number, plan.round_specific)

    plan
    |> plan_boards()
    |> create_round(
      tournament,
      next_number,
      round_absentees,
      pending_payload(tournament, next_number, plan.sections)
    )
    |> with_deferred(plan.sections)
  end

  defp save_plan(%{kind: :categories} = plan, tournament, next_number) do
    round_absentees = round_absentees(tournament, next_number, plan.round_specific)
    insert_category_round(tournament, plan, next_number, round_absentees)
  end

  @doc false
  # The boards of a planned round, in board order: `{board, white, black}`,
  # players as structs, `black` nil for a pairing-allocated bye. Board
  # numbers run 1.. in the engine's order; per category they continue from
  # one category to the next, in `tournament.categories` order, a
  # one-player category's automatic bye taking a board of its own.
  def plan_boards(%{kind: :single, pairs: pairs, by_rank: by_rank}) do
    pairs
    |> Enum.with_index(1)
    |> Enum.map(fn {{w, b}, board} ->
      {board, Map.fetch!(by_rank, w), if(b == 0, do: nil, else: Map.fetch!(by_rank, b))}
    end)
  end

  def plan_boards(%{kind: :categories, groups: groups}) do
    {boards, _next} =
      Enum.flat_map_reduce(groups, 1, fn
        {_category_name, :bye, player}, board ->
          {[{board, player, nil}], board + 1}

        {_category_name, :paired, pairs, by_rank, _explanation}, board ->
          boards = plan_boards(%{kind: :single, pairs: pairs, by_rank: by_rank})
          {Enum.map(boards, fn {n, w, b} -> {n + board - 1, w, b} end), board + length(pairs)}
      end)

    boards
  end

  # `players` here is `next_number`'s round-specific ELIGIBLE subset of
  # `active_players/1` (see `do_pair/2`'s `Enum.split_with/2`), not the whole
  # frozen `pairing_number` pool - `active_players/1` covers permanent
  # absentees/forfeits/inactive status, but a player sitting out only THIS
  # round (`absent_rounds`) still holds their global `pairing_number` and
  # still appears in `active_players/1`, just not here.
  #
  # We still need a LOCAL contiguous 1..M rank map: a TRF whose starting
  # ranks aren't contiguous 1..N is not one a TRF pairing program can be
  # trusted with (the external engine this app used to run died on one with
  # a bare NullPointerException - see `test/pairings_engine/swar_import_test.exs`'s
  # "pairing a new round after import doesn't crash when a historical
  # opponent is now excluded").
  #
  # Crucially, that local map is now built over the FULL frozen roster
  # (`full_roster_players/1` - every player who ever held a `pairing_number`,
  # regardless of current active/absent/forfeit/withdrawn status), NOT just
  # `players`. If it were scoped to `players`, any historical opponent now
  # outside that subset - a withdrawn/forfeited player, a round-specific
  # absentee - would miss the rank map, and
  # `remap_trf_rows_to_local_ranks/2` would rewrite that genuinely-played
  # game into a synthetic bye code, silently destroying its colour history
  # and letting the engine violate FIDE colour alternation. Scoping the map to
  # the full roster guarantees every possible historical opponent resolves
  # to a real rank with a real TRF row.
  #
  # A row is sent for every full-roster player (a rank column with no
  # matching row is meaningless). Players who aren't actually candidates
  # for THIS round - everyone not in `players` - are still marked with an
  # explicit `0000 - Z` line via `trf_input/5`'s `eligible_ids`
  # (`mark_ineligible_for_round/2`), the TRF-native way to keep a player's
  # real history while excluding them from pairing this run.
  #
  # The engine's output pairs (local ranks) are translated back to real
  # players via the inverse map in `create_round/5`. Board numbering (the
  # output *order*, not its rank values) is completely unaffected by this.
  defp do_pair_single(tournament, players, next_number, run) do
    # The same tournament-wide history the per-category path has always
    # built, which this path had not. Without it, the old standings ordering
    # and then `trf_player_rows/3` each fell through to their own
    # `build_shared_history/1` - three queries and a full roster walk, twice
    # over, for one answer. `shared_history.full_roster` is the same set
    # `full_roster_players/1` was re-querying.
    shared_history = run_history(run, tournament)

    full_roster =
      shared_history.full_roster
      |> Map.values()
      |> in_pairing_number_order()

    eligible_ids = MapSet.new(players, & &1.id)

    local_rank_by_player_id =
      full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)

    by_id = Map.new(full_roster, &{&1.id, &1})

    player_by_local_rank =
      Map.new(local_rank_by_player_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

    # The engine's input: the TRF, or - for a preview outcome with a base in
    # hand - the base's parsed field re-ranked (`preview_base/2`).
    input =
      case run do
        %{base: %{} = base} ->
          {:parsed,
           rerank_field(base, tournament, full_roster, local_rank_by_player_id, shared_history)}

        _ ->
          run_span(run, :input, fn ->
            {:trf,
             trf_input(
               tournament,
               full_roster,
               local_rank_by_player_id,
               eligible_ids,
               shared_history
             )}
          end)
      end

    soft =
      run_span(run, :input, fn ->
        soft_pairs(
          tournament,
          full_roster,
          local_rank_by_player_id,
          shared_history.forbidden_pairings,
          next_number,
          shared_history.pairing_rules
        )
      end)

    with {:trf, trf} <- input,
         false <- run.preview?,
         do: emit_trf_built(tournament.id, next_number, nil, trf)

    tournament = with_bye_exclusions(tournament, players, local_rank_by_player_id, next_number)

    cond do
      Map.get(run, :base) == :capture or Map.get(run, :field_only?, false) ->
        preview_field(input, local_rank_by_player_id, run)

      Map.has_key?(run, :variants) ->
        run_variants(
          tournament,
          input,
          next_number,
          soft,
          run,
          local_rank_by_player_id,
          player_by_local_rank
        )

      true ->
        run_single_engine(tournament, input, next_number, soft, run, player_by_local_rank)
    end
  end

  # `preview_variants/2`'s engine call: `input` is the first outcome's
  # field, and every outcome (`run.variants`, its history) is that field
  # with the open games' players given their own result and score - what
  # `rerank_field/5` does to them, and all it does that depends on a
  # result. One call, one `{:ok | :error, _}` per outcome, each turned into
  # what `run_single_engine/6` would have made of it.
  #
  # Bye preferences are resolved around the engine (`pair_with_preferences/3`),
  # not inside `pair_variants/3`, so with any in play this declines and the
  # preview pairs one outcome at a time, as it always did.
  defp run_variants(
         tournament,
         {:parsed, parsed},
         next_number,
         soft,
         run,
         rank_by_id,
         player_by_local_rank
       ) do
    if (tournament.engine_bye_preferences || []) != [] do
      {:error, :variants_unsupported}
    else
      round_index = length(run.history.rounds) - 1
      field = Map.new(parsed.players, &{&1.rank, &1})

      variants =
        Enum.map(run.variants, fn history ->
          Map.new(history.changed, fn id ->
            rank = Map.fetch!(rank_by_id, id)
            row_games = Map.fetch!(history.games, id)
            {rank, with_outcome(Map.fetch!(field, rank), row_games, round_index, tournament)}
          end)
        end)

      engine_opts = ainalrami_opts(tournament, parsed, soft)

      outcomes =
        parsed.players
        |> Ainalrami.Pairing.pair_variants(variants, engine_opts)
        |> Enum.map(fn
          {:ok, raw_pairs} ->
            pairs = Enum.map(raw_pairs, &ainalrami_bye_to_zero/1)
            {:ok, plan_boards(%{kind: :single, pairs: pairs, by_rank: player_by_local_rank})}

          {:error, e} ->
            e
            |> ainalrami_refusal(tournament, next_number, nil)
            |> bye_exclusion_error(player_by_local_rank)
        end)

      {:ok, %{kind: :variants, outcomes: outcomes}}
    end
  rescue
    # Anything but a per-variant refusal: the one-by-one path pairs these
    # outcomes again and reports whatever it reports, crash included.
    _e -> {:error, :variants_unsupported}
  end

  defp run_variants(_tournament, _input, _next_number, _soft, _run, _rank_by_id, _by_rank),
    do: {:error, :variants_unsupported}

  defp run_single_engine(tournament, input, next_number, soft, run, player_by_local_rank) do
    case run_span(run, :engine, fn ->
           run_engine(tournament, input, next_number, nil, soft, run)
         end) do
      {:ok, pairs, deferred} ->
        {:ok,
         %{
           kind: :single,
           pairs: pairs,
           by_rank: player_by_local_rank,
           sections: [{nil, deferred, player_by_local_rank}]
         }}

      {:error, _message} = error ->
        bye_exclusion_error(error, player_by_local_rank)
    end
  end

  ## ---------- native per-category Swiss pairing (SWAR-parity #24) ----------

  # Partitions `players` by `player.category`, in `tournament.categories`
  # list order, plus a trailing "Uncategorized" pool for players whose
  # category is blank or doesn't match any listed category - a deliberate
  # product decision to still pair these players together as their own
  # pool, rather than excluding them from pairing entirely. Runs every
  # category's independent engine run (or synthesizes a 1-player group's
  # automatic bye) FIRST, entirely before any DB round/pairing row exists -
  # deliberately mirroring `do_pair_single/4`'s own ordering (build TRF /
  # run the engine, only touch the DB once every pairing decision is known).
  # This isn't just style parity: `games_per_player/2` (used while building
  # each category's TRF input) queries "every paired Round of this
  # tournament" with no round-number filter, so if the `next_number` Round
  # row already existed (even pairing-less) while a later category's TRF
  # was being built, every player would pick up a phantom "Z" (zero-point
  # bye) game for the round STILL BEING PAIRED - corrupting the TRF's game
  # history and (confirmed by hitting it) crashing the engine. Only once every
  # category's pairing decision is known does `insert_category_round/3`
  # open ONE transaction and write the Round + every category's pairings,
  # in category-list order, boards numbered continuously - the single
  # combined pairing sheet that's the whole point of doing this natively.
  defp do_pair_by_category(tournament, players, next_number, run) do
    groups = category_groups(tournament, players)

    # Tournament-wide history (every round/pairing, every bye, the full
    # roster) is identical for every category - computed once here and
    # threaded through, rather than each category's TRF build re-running
    # the same three queries (see `games_per_player/2`'s doc). Safe to
    # compute now: no DB round row exists yet at this point (see this
    # function's own moduledoc above for why that ordering matters).
    shared_history = run_history(run, tournament)

    # The local contiguous rank map (and the row set that goes with it) now
    # spans the FULL frozen roster, exactly as in `do_pair_single/4` - every
    # category's TRF carries every player, so a category-A player's historical
    # opponent in category B (or now ineligible) always resolves to a real
    # rank with a real row, instead of being bye-rewritten and losing its
    # colour history. `shared_history.full_roster` is already `%{id =>
    # player}`, so reuse it rather than re-querying.
    full_roster =
      shared_history.full_roster
      |> Map.values()
      |> in_pairing_number_order()

    local_rank_by_player_id =
      full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)

    case compute_category_pairs(
           tournament,
           groups,
           next_number,
           shared_history,
           full_roster,
           local_rank_by_player_id,
           run
         ) do
      {:ok, group_results} -> {:ok, %{kind: :categories, groups: group_results}}
      {:error, _reason} = error -> error
    end
  end

  # Runs (or synthesizes) each category group's pairing decision in turn,
  # stopping at the first failure - no DB writes happen here at all (see
  # `do_pair_by_category/3`'s doc for why). A `{:error, reason}` from any
  # category short-circuits the whole round: `do_pair_by_category/3` never
  # reaches `insert_category_round/3`, so nothing is written for ANY
  # category - the round-level "all or nothing" guarantee, established here
  # rather than via `Repo.rollback/1` since no transaction is open yet at
  # this point.
  defp compute_category_pairs(
         tournament,
         groups,
         next_number,
         shared_history,
         full_roster,
         local_rank_by_player_id,
         run
       ) do
    result =
      groups
      |> Enum.reduce_while({:ok, []}, fn {category_name, group_players}, {:ok, acc} ->
        case compute_category_group(
               tournament,
               category_name,
               group_players,
               next_number,
               shared_history,
               full_roster,
               local_rank_by_player_id,
               run
             ) do
          {:ok, group_result} -> {:cont, {:ok, [group_result | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # A 1-player group can't go through the engine at all - it's given a
  # pairing-allocated bye directly once `insert_category_round/3` writes it.
  defp compute_category_group(
         _tournament,
         category_name,
         [player],
         _next_number,
         _shared_history,
         _full_roster,
         _local_rank_by_player_id,
         _run
       ) do
    {:ok, {category_name, :bye, player}}
  end

  defp compute_category_group(
         tournament,
         category_name,
         group_players,
         next_number,
         shared_history,
         full_roster,
         local_rank_by_player_id,
         run
       ) do
    eligible_ids = MapSet.new(group_players, & &1.id)
    by_id = Map.new(full_roster, &{&1.id, &1})

    player_by_local_rank =
      Map.new(local_rank_by_player_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

    trf =
      run_span(run, :input, fn ->
        build_category_trf(
          tournament,
          full_roster,
          eligible_ids,
          local_rank_by_player_id,
          shared_history,
          next_number
        )
      end)

    soft =
      run_span(run, :input, fn ->
        soft_pairs(
          tournament,
          full_roster,
          local_rank_by_player_id,
          shared_history.forbidden_pairings,
          next_number,
          shared_history.pairing_rules
        )
      end)

    unless run.preview?, do: emit_trf_built(tournament.id, next_number, category_name, trf)

    tournament =
      with_bye_exclusions(tournament, group_players, local_rank_by_player_id, next_number)

    case run_span(run, :engine, fn ->
           run_engine(tournament, {:trf, trf}, next_number, category_name, soft, run)
         end) do
      {:ok, pairs, explanation} ->
        {:ok, {category_name, :paired, pairs, player_by_local_rank, explanation}}

      {:error, _message} = error ->
        bye_exclusion_error(error, player_by_local_rank)
    end
  end

  ## ---------- bye exclusions (an organiser's rule, not FIDE's) ----------
  #
  # A player with `no_bye` set must not receive the pairing-allocated bye in
  # the rounds it covers. Ainalrami takes the list as `:bye_exclusions` and
  # treats each listed player exactly as C.04.3 [C2] treats one who already
  # had a bye; nothing else about the pairing changes. See
  # docs/pairing-systems.md.

  # The ranks to exclude from the bye in this run, on the tournament struct
  # the engine call already receives (see `Tournament`'s
  # `engine_bye_exclusions`). `players` is the round's pairing pool; an
  # exclusion the arbiter lifted for this run ("pair anyway") is left out.
  defp with_bye_exclusions(
         %Tournament{} = tournament,
         players,
         local_rank_by_player_id,
         round_number
       ) do
    ranks =
      players
      |> Enum.filter(
        &(&1.id != tournament.bye_exclusion_override and
            Player.no_bye_for_round?(&1, round_number))
      )
      |> Enum.flat_map(&List.wrap(Map.get(local_rank_by_player_id, &1.id)))

    %{
      tournament
      | engine_bye_exclusions: Enum.sort(ranks),
        engine_bye_preferences:
          bye_preference_ranks(tournament, players, local_rank_by_player_id, round_number)
    }
  end

  ## ---------- bye preferences (an organiser's wish, not FIDE's) ----------
  #
  # "Must get", "rather gets" and "rather not" the pairing-allocated bye
  # (`Player`'s `bye_preference`) - the fourth setting, "must not get", is
  # the bye exclusion above. Ainalrami resolves them
  # (`Ainalrami.ByePreference`). NOT on a
  # FIDE-rated tournament (`fide_homologated`): a stored preference is
  # ignored there, not deleted, and the Players and Pairings pages say so.

  # `[{rank, preference}]` for the round being paired.
  defp bye_preference_ranks(%Tournament{fide_homologated: true}, _players, _ranks, _round),
    do: []

  defp bye_preference_ranks(_tournament, players, local_rank_by_player_id, round_number) do
    players
    |> Enum.flat_map(fn player ->
      case Player.bye_preference_for_round(player, round_number) do
        nil ->
          []

        pref ->
          player.id
          |> then(&Map.get(local_rank_by_player_id, &1))
          |> List.wrap()
          |> Enum.map(&{&1, pref})
      end
    end)
    |> Enum.sort()
  end

  @doc """
  The players of `tournament` whose stored bye preference is being ignored
  because the tournament is FIDE-rated, by name - for the pages' warning.
  Empty on a tournament that is not FIDE-rated, or where nobody has one.
  """
  def ignored_bye_preferences(%Tournament{fide_homologated: true, id: id}) do
    Repo.all(
      from p in Player,
        where: p.tournament_id == ^id and p.bye_preference in ^Player.bye_preferences(),
        order_by: p.name,
        select: p.name
    )
  end

  def ignored_bye_preferences(_tournament), do: []

  @doc """
  The round in which `player_id` first received the pairing-allocated bye
  in `tournament_id`, or nil - the fact FIDE's rule C2 turns into "no
  second one", which a "must get the bye" preference for a later round
  would ask for.
  """
  def first_pairing_allocated_bye(tournament_id, player_id) do
    from_boards =
      Repo.one(
        from p in PairingsEngine.Tournaments.Pairing,
          join: r in Round,
          on: r.id == p.round_id,
          where:
            r.tournament_id == ^tournament_id and p.white_player_id == ^player_id and
              is_nil(p.black_player_id) and p.result == "bye",
          select: min(r.number)
      )

    from_byes =
      Repo.one(
        from b in "byes",
          where:
            b.tournament_id == ^tournament_id and b.player_id == ^player_id and
              b.type == "pairing-allocated",
          select: min(b.round)
      )

    [from_boards, from_byes] |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
  end

  # The engine names excluded players by rank; the page needs players.
  defp bye_exclusion_error({:error, {:bye_exclusions, info}}, player_by_local_rank) do
    id = fn rank -> player_by_local_rank |> Map.fetch!(rank) |> Map.fetch!(:id) end

    {:error,
     {:bye_exclusions,
      %{
        info
        | excluded: Enum.map(info.excluded, id),
          override: info.override && id.(info.override)
      }}}
  end

  defp bye_exclusion_error({:error, {:bye_preference_refused, info}}, player_by_local_rank) do
    id = fn rank -> player_by_local_rank |> Map.fetch!(rank) |> Map.fetch!(:id) end

    {:error,
     {:bye_preference_refused,
      %{info | players: Enum.map(info.players, &Map.put(&1, :player_id, id.(&1.rank)))}}}
  end

  defp bye_exclusion_error(error, _player_by_local_rank), do: error

  @doc """
  The ways `round_number` was paired away from what C.04.3 alone produces,
  when any of them actually changed the round - an empty list otherwise:

    * `:bye_exclusion` - an organiser's bye exclusion moved the
      pairing-allocated bye (someone was passed over for it).
    * `:soft_pairs` - the arbiter's "only if possible" wishes (soft
      forbidden pairings, clubmates apart) moved at least one board: the
      engine run again without them pairs the round differently.
    * `:bye_preference` - a player's bye preference (must get / rather
      gets / rather not the bye) changed the round.
    * `:extra_points` - extra points reached the engine as virtual points
      (acceleration mode, or a counted handicap): a player in the round had
      some, or an earlier round's recorded ones are in the history the
      engine judged floats by.

  Baku acceleration is FIDE's own (C.04.7) and is never listed. A setting
  that was on but changed nothing - an exclusion for a player who was never
  going to get the bye, a wish the rules already honoured, extra points of
  zero - leaves the round exactly as FIDE's rules pair it and is not listed.
  """
  def pairing_deviations(%Tournament{} = tournament, round_number) do
    case Tournaments.get_round(tournament.id, round_number) do
      nil ->
        []

      round ->
        sections =
          case round.explanation do
            %{"sections" => sections} when is_list(sections) -> sections
            _ -> []
          end

        [
          {:bye_exclusion, Enum.any?(sections, &((&1["bye_passed_over"] || []) != []))},
          {:soft_pairs, Enum.any?(sections, &(&1["soft_pairs_moved"] == true))},
          {:bye_preference, Enum.any?(sections, &bye_preference_moved?/1)},
          {:extra_points, extra_points_reached_engine?(tournament, round)}
        ]
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))
    end
  end

  defp bye_preference_moved?(%{"bye_preference" => %{"moved" => true}}), do: true
  defp bye_preference_moved?(_section), do: false

  # Whether the engine was handed any non-zero virtual points from extra
  # points for this round: the round's own recorded ones (the players it
  # paired, `virtual_points_used/2`), or an earlier round's, which travel in
  # every player's `XXA` history (`extra_point_accelerations/3`) - a SWAR
  # file's rounds bring theirs. Negative values are floored to nothing on the
  # way to the engine (`virtual_value/1`), so they do not count here either.
  defp extra_points_reached_engine?(tournament, round) do
    Tournament.extra_points_pairing?(tournament) and
      (positive_virtual_points?(round.virtual_points) or
         tournament.id
         |> recorded_virtual_points()
         |> Enum.any?(fn {number, points} ->
           number < round.number and positive_virtual_points?(points)
         end))
  end

  defp positive_virtual_points?(%{} = by_player),
    do: Enum.any?(by_player, fn {_id, points} -> is_number(points) and points > 0 end)

  defp positive_virtual_points?(_none), do: false

  # A round paired away from C.04.3 (`pairing_deviations/2`) is on the
  # tournament's FIDE history: the first such round is stamped as the one the
  # tournament stopped matching the FIDE rules, the same record a non-FIDE
  # setting leaves (`fide_compliance_lost_round`, never cleared). A round
  # where none of them changed anything records nothing. The audit trail's
  # copy is written by the page that asked for the pairing
  # (`PairingsLive`), which knows who did it.
  defp record_pairing_deviations(tournament, round_number) do
    if is_nil(tournament.fide_compliance_lost_round) and
         pairing_deviations(tournament, round_number) != [] do
      Repo.update_all(
        from(t in Tournament,
          where: t.id == ^tournament.id and is_nil(t.fide_compliance_lost_round)
        ),
        set: [fide_compliance_lost_round: round_number]
      )
    end

    :ok
  end

  # Writes the Round and every category's pairings in ONE transaction, board
  # numbers running continuously across `group_results` (already in
  # `tournament.categories` list order - see `category_groups/2`). Only
  # reached once every category's pairing decision succeeded (see
  # `do_pair_by_category/3`), so this itself can no longer fail on a
  # category's engine run - the `Repo.transaction/1` wrapper here exists
  # for ordinary DB-write atomicity (Round + N Pairings as one unit), not to
  # guard against an engine failure (that's already been ruled out).
  defp insert_category_round(tournament, plan, next_number, round_absentees) do
    group_results = plan.groups

    # One section per category that the engine actually paired. A 1-player
    # group's automatic bye never reaches an engine, so it contributes none.
    sections =
      Enum.flat_map(group_results, fn
        {category_name, :paired, _pairs, by_rank, deferred} ->
          [{category_name, deferred, by_rank}]

        _bye ->
          []
      end)

    explanation = pending_payload(tournament, next_number, sections)

    paired_players =
      Enum.flat_map(group_results, fn
        {_category_name, :bye, player} ->
          [player]

        {_category_name, :paired, pairs, by_rank, _explanation} ->
          for {w, b} <- pairs, rank <- [w, b], rank != 0, do: Map.fetch!(by_rank, rank)
      end)

    Repo.transaction(fn ->
      published_at = Tournaments.compute_published_at(tournament, next_number)

      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing",
          published_at: published_at,
          publish_due_at: Tournaments.due_publish_at(published_at),
          explanation: explanation,
          virtual_points: virtual_points_used(tournament, paired_players)
        })

      insert_round_absentee_byes(tournament, next_number, round_absentees)

      # Every category's boards, numbered on from one category to the next
      # (`plan_boards/1`), with their frozen labels (`insert_boards/2`).
      boards = plan_boards(plan)
      insert_boards(round, boards)
      any_bye? = Enum.any?(boards, fn {_board, _white, black} -> is_nil(black) end)

      # A pairing-allocated bye (from any category's engine output, or a
      # 1-player group's automatic bye) awards points immediately without
      # ever going through Tournaments.update_pairing_result/2 - same
      # point-changing-write gap as elsewhere in this module. See
      # docs/manual-standings.md (Fix 3).
      if any_bye?, do: Tournaments.invalidate_manual_ranking(tournament.id)

      round
    end)
    |> with_deferred(sections)
  end

  # A player can carry several categories, but only one of them can pool
  # them here - three pools would mean three opponents in one round. Which
  # one is `PairingsEngine.Categories.pairing_category/2`'s answer and
  # nothing else's; this used to compare `player.category` to each name
  # itself, and the pairing-explanation page derived the same fact its own
  # way, which is how the label and the pool came to disagree.
  #
  # Still a partition: every player yields exactly one value, and the values
  # are `tournament.categories ++ [""]`.
  defp category_groups(tournament, players) do
    named_categories = tournament.categories || []
    pool_by_player_id = Map.new(players, &{&1.id, Categories.pairing_category(tournament, &1)})

    named_groups =
      Enum.map(named_categories, fn cat_name ->
        {cat_name, Enum.filter(players, &(Map.fetch!(pool_by_player_id, &1.id) == cat_name))}
      end)

    # Blank/unlisted category players still get paired - as their own
    # "Uncategorized" pool, deliberately not excluded from pairing.
    uncategorized = Enum.filter(players, &(Map.fetch!(pool_by_player_id, &1.id) == ""))

    (named_groups ++ [{"Uncategorized", uncategorized}])
    |> Enum.reject(fn {_name, group} -> group == [] end)
  end

  # Builds one category's TRF input. Unlike the earlier design, this is NOT
  # scoped to just the category's players: every category's TRF now carries
  # the FULL frozen roster (`full_roster` - every category, every historical
  # opponent), remapped to one shared local 1..M numbering, with only THIS
  # category's players (`eligible_ids`) left un-marked as pairing candidates.
  # Everyone else - other categories, now-ineligible players - gets an
  # explicit `0000 - Z` line via `mark_ineligible_for_round/2` so the engine
  # keeps their real history (needed so a past opponent's colour/result
  # resolves via `remap_trf_rows_to_local_ranks/2` instead of being
  # bye-rewritten) while still not pairing them this run. Same reasoning as
  # `do_pair_single/4`'s doc comment.
  #
  # `forbidden_pairs/3`/`exclusion_pairs/3`/`accelerations/4`
  # now also see the full roster rather than just this category - intentional
  # and harmless: a forbidden/exclusion line naming a player who's
  # ineligible-this-round is inert to the engine, and this incidentally widens
  # `accelerations`' roster scope too (a direction a separate Baku
  # acceleration audit finding wants; not verified here). `shared_history`
  # (see `build_shared_history/1`) is computed once by
  # `do_pair_by_category/4` and passed straight through.
  #
  # `current_round` is the round being paired - or, for a pending account
  # rebuilt after a restart (`recompute_explanation/2`), the round it was.
  defp build_category_trf(
         tournament,
         full_roster,
         eligible_ids,
         local_rank_by_player_id,
         shared_history,
         current_round
       ) do
    trf_rows =
      tournament
      |> trf_player_rows(full_roster, shared_history)
      |> mark_ineligible_for_round(eligible_ids)
      |> remap_trf_rows_to_local_ranks(local_rank_by_player_id)
      # Physical row order, not just the `:rank` field - see the identical
      # re-sort (and its full rationale) in `trf_input/5`.
      |> Enum.sort_by(& &1.rank)

    engine_trf(
      tournament,
      trf_rows,
      full_roster,
      local_rank_by_player_id,
      current_round,
      shared_history.forbidden_pairings,
      shared_history.pairing_rules
    )
  end

  # The one place either pairing path turns rows into TRF text. Both used to
  # serialize the TRF16 core and then STRING-CONCATENATE the extension lines
  # onto the finished text - `"XXR " <> ...`, then the `XXA` lines, then the
  # `XXP` ones - which put the part of the file carrying the arbiter's rules
  # outside the writer entirely. Nothing checked those lines' columns, and
  # nothing checked that the ranks they name are ranks the file actually
  # has; the `XXA` column bug that made every accelerated export unreadable
  # by other TRF readers (see `accelerations/4`) lived in exactly that gap
  # for as long as it did because the writer never saw the line.
  #
  # They are all fields of the tournament map now, so `Ainalrami.Trf` emits
  # them itself, from the same data and under the same validation as every
  # other column.
  defp engine_trf(
         tournament,
         trf_rows,
         roster,
         rank_by_player_id,
         current_round,
         forbidden,
         rules
       ) do
    accelerations = accelerations(tournament, roster, current_round)

    Trf.serialize(
      %{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          federation: tournament.federation,
          type: tournament.type,
          chief_arbiter: tournament.chief_arbiter,
          # Written as `XXR`, not as the `142` header - see the `xxr: true`
          # below. Read back off the FILE by `run_ainalrami/6`, so the
          # engine is told what a checker reproducing the round is told.
          number_of_rounds: tournament.rounds_count,
          # The drawing of lots (or the arbiter's choice), written as
          # `XXC white1` / `XXC black1` - see `xxc: true` below - and handed
          # to Ainalrami as its `:initial_colour` option by
          # `ainalrami_opts/3`, which reads it back off the file. nil - no
          # draw on record, for a tournament that paired round 1 before the
          # draw was stored - writes no line, and the engine works the
          # colour out from the boards as it always did.
          initial_colour: engine_initial_colour(tournament),
          # One group per forbidden pairing, plus the club/federation
          # exclusion rules, deduplicated against them.
          # Both halves read the SAME forbidden-pairing list, handed in by
          # the caller. They each queried it independently before, so one
          # TRF build cost two identical reads and a five-category run cost
          # ten.
          forbidden_pairs:
            forbidden_pairs(tournament.id, roster, rank_by_player_id, forbidden) ++
              exclusion_pairs(
                tournament,
                roster,
                rank_by_player_id,
                forbidden,
                current_round,
                rules
              )
        },
        players: attach_accelerations(trf_rows, accelerations)
      },
      # The `XXR`/`XXC` spelling rather than `142`/`152`: the extension
      # lines TRF pairing programs (and FIDE's checkers) read, so the file
      # the engine pairs from is one they can replay. See
      # `Ainalrami.Trf.serialize/2`.
      xxr: true,
      xxc: true
    )
  end

  defp engine_initial_colour(tournament) do
    case Tournament.effective_initial_colour(tournament) do
      "white" -> "w"
      "black" -> "b"
      nil -> nil
    end
  end

  # Baku virtual points ride on the row they belong to rather than being
  # emitted against a separately-computed rank. That rank had to be kept in
  # step with the player rows by hand - `accelerations/4` used to look the
  # emitted rank up in `rank_by_player_id` itself, so a local-rank pairing
  # run had two independent answers to "what number is this player" and a
  # disagreement would have referenced a starting rank the file does not
  # contain. Attaching by player id leaves exactly one answer: the `:rank`
  # already on the row.
  @doc """
  `rows` (from `trf_player_rows/3`) with each Group-A player's Baku virtual
  points attached, as `Ainalrami.Trf.serialize/2` writes them - `XXA` lines
  for the engines, `250` records in the TRF26 dialect. For the FIDE-facing
  export, which had left acceleration out of the file entirely; a
  tournament without acceleration gets its rows back as they were.

  Acceleration-mode extra points are acceleration too, and go in the same
  way: they are what the rounds were paired with. A HANDICAP is not: the
  report's score is game points, and a head start is not a virtual point
  a pairing checker should add back - it stays out of the file (the `299`
  records carry it when it counts, `TrfExport.free_point_records/2`).
  """
  def accelerated_rows(tournament, rows, players, current_round) do
    if Tournament.extra_points_pairing?(tournament) and
         not Tournament.extra_points_acceleration?(tournament),
       do: rows,
       else: attach_accelerations(rows, accelerations(tournament, players, current_round))
  end

  defp attach_accelerations(rows, accelerations) when map_size(accelerations) == 0, do: rows

  defp attach_accelerations(rows, accelerations) do
    Enum.map(rows, fn row ->
      case Map.fetch(accelerations, row.id) do
        {:ok, points} -> Map.put(row, :accelerations, points)
        :error -> row
      end
    end)
  end

  # TRF16 pairing-program convention: a player row that already carries a result for
  # the round about to be paired is treated as already decided for that
  # round and excluded from pairing this run. Used so a round-specific
  # absentee or a permanently withdrawn/forfeited player can still be SENT a
  # row (needed so their past opponents' colour/result history resolves
  # correctly via `remap_trf_rows_to_local_ranks/2` below) while the engine still
  # leaves them unpaired this round. `rows`' games lists never include the
  # round about to be paired in the first place (`games_per_player/3` only
  # ever iterates already-paired rounds), so appending one more entry always
  # lands in exactly that round's TRF column.
  defp mark_ineligible_for_round(rows, eligible_ids) do
    Enum.map(rows, fn row ->
      if MapSet.member?(eligible_ids, row.id) do
        row
      else
        zero_bye = %{
          opponent_rank: nil,
          opponent_id: nil,
          colour: nil,
          result: "Z",
          points_kind: "zero"
        }

        %{row | games: row.games ++ [zero_bye]}
      end
    end)
  end

  # Remaps `trf_player_rows/2`'s output (global `pairing_number`-based ranks)
  # to a local 1..M numbering (a category's own pool, or - since this fix -
  # a single-pool pairing run's round-specific eligible subset, see
  # `do_pair_single/4`): each row's own `rank`, and each of its games'
  # `opponent_rank` (looked up via the `opponent_id` `trf_game/3` now carries
  # alongside it - see that function).
  #
  # An opponent not present in `local_rank_by_player_id` at all - a game
  # against a player outside this run's local pool (category or, for
  # `do_pair_single/4`, a player excluded from THIS round only, e.g. a
  # different round's `absent_rounds` entry, or someone who's since gone
  # permanently absent/forfeited) - resolves `opponent_rank` to `nil`, same
  # as a genuinely opponentless game already does upstream. But unlike a
  # genuinely opponentless game, `game.result` here can still be a real
  # PLAYED-game code (the game against that historical opponent really was
  # played and scored) - pairing a nil rank with a played-game code is
  # exactly the illegal "0000 - 1"-style TRF row `bye_safe_result/2` exists
  # to prevent (see `trf_game/3`), so the same reinterpretation is reapplied
  # here for this second way a played game can end up with no resolvable
  # rank for its opponent.
  defp remap_trf_rows_to_local_ranks(rows, local_rank_by_player_id) do
    Enum.map(rows, fn row ->
      local_rank = Map.fetch!(local_rank_by_player_id, row.id)

      remapped_games =
        Enum.map(row.games, fn game ->
          local_opponent_rank =
            game[:opponent_id] && Map.get(local_rank_by_player_id, game.opponent_id)

          result =
            if game[:opponent_id] != nil and is_nil(local_opponent_rank) do
              bye_safe_result(game.result, nil)
            else
              game.result
            end

          game
          |> Map.put(:opponent_rank, local_opponent_rank)
          |> Map.put(:result, result)
        end)

      %{row | rank: local_rank, games: remapped_games}
    end)
  end

  # The boards of a planned round (`plan_boards/1`), written in a few
  # multi-row inserts with their frozen labels already on them; a board
  # without a Black is the pairing-allocated bye, written with its result
  # already set.
  #
  # This used to be one INSERT per board and then
  # `Tournaments.freeze_round_display_boards!/1`: the round read back with
  # both players of every board, and one UPDATE per board for its label - a
  # thousand statements and the round's whole roster loaded again, for a
  # 1,000-player round, inside the click. The rows are the same: the labels
  # come from the same `PairingDisplay.compute_labels/1`, over the same
  # boards, with each player's `fixed_board` read in this same transaction
  # as the freeze read it; and every column is what `Repo.insert!/1` of the
  # struct wrote (its non-nil fields; `black_player_id` always, as the bye's
  # nil).
  @board_insert_chunk 200

  defp insert_boards(round, boards) do
    fixed_board =
      Repo.all(
        from p in Player,
          where: p.tournament_id == ^round.tournament_id,
          select: {p.id, p.fixed_board}
      )
      |> Map.new()

    seated = fn
      nil -> nil
      player -> %{player | fixed_board: Map.get(fixed_board, player.id)}
    end

    # `id` stands in for the row id `compute_labels/1` keys its answer by:
    # the board number, unique within the round and in the same order.
    drafts =
      for {board, white, black} <- boards do
        %Pairing{
          id: board,
          round_id: round.id,
          board: board,
          white_player_id: white.id,
          black_player_id: black && black.id,
          result: if(black, do: "", else: "bye"),
          white_player: seated.(white),
          black_player: seated.(black)
        }
      end

    labels = PairingDisplay.compute_labels(drafts)

    drafts
    |> Enum.map(fn draft ->
      %{display_board: display_board, display_special: display_special} =
        Map.fetch!(labels, draft.id)

      board_row(%{
        draft
        | id: nil,
          display_board: display_board,
          display_special: display_special
      })
    end)
    |> Enum.chunk_every(@board_insert_chunk)
    |> Enum.each(&Repo.insert_all(Pairing, &1))
  end

  @board_row_fields Pairing.__schema__(:fields) -- [:id]

  defp board_row(%Pairing{} = pairing) do
    @board_row_fields
    |> Enum.reduce(%{}, fn field, row ->
      case Map.fetch!(pairing, field) do
        nil -> row
        value -> Map.put(row, field, value)
      end
    end)
    |> Map.put(:black_player_id, pairing.black_player_id)
  end

  defp insert_round_absentee_byes(_tournament, _round_number, []), do: :ok

  defp insert_round_absentee_byes(tournament, round_number, round_absentees) do
    rows =
      Enum.map(round_absentees, fn p ->
        %{
          tournament_id: tournament.id,
          player_id: p.id,
          round: round_number,
          type: "absent"
        }
      end)

    Repo.insert_all("byes", rows, on_conflict: :nothing)

    # A requested bye immediately awards points (see
    # PairingsEngine.Standings) without ever going through
    # Tournaments.update_pairing_result/2 - a hand-set manual standings
    # order must be marked stale here too, same as any other point-changing
    # write. See docs/manual-standings.md (Fix 3).
    Tournaments.invalidate_manual_ranking(tournament.id)
    :ok
  end

  ## ---------- the pairing engine ----------
  #
  # The single seam where the engine's input becomes a list of pairs. Both
  # Swiss pairing paths (`do_pair_single/4` and the per-category
  # `compute_category_group/7`) funnel through here, so neither can drift
  # from the other.
  #
  #   * IN - the exact TRF text `trf_input/5` produced, unmodified, or - for
  #     a preview outcome - a parsed field re-ranked from its base
  #     (`rerank_field/5`). `emit_trf_built/4` fires once per real run with
  #     the text.
  #   * IN - `soft`, the arbiter's wishes from `soft_pairs/5`, in the same
  #     local ranks as the TRF. The TRF has no way to say "if you can", so
  #     it rides alongside the file.
  #   * OUT - `{:ok, [{white_rank, black_rank}], deferred}` in the LOCAL
  #     contiguous rank numbering the TRF was built in, `0` for the
  #     pairing-allocated bye (`parse_pairs/1`'s long-standing shape), or
  #     `{:error, message}` with a plain user-facing string.
  defp run_engine(tournament, input, round_number, category_name, soft, run),
    do: run_ainalrami(tournament, input, round_number, category_name, soft, run)

  defp engine_log_scope(tournament, round_number, nil),
    do: "tournament #{tournament.id} round #{round_number}"

  defp engine_log_scope(tournament, round_number, category_name),
    do: "tournament #{tournament.id} round #{round_number} category #{category_name}"

  # Ainalrami reads the TRF text through its own `Ainalrami.Trf.parse/1`
  # and returns pairs in local ranks, spelling the pairing-allocated bye
  # `nil`; `ainalrami_bye_to_zero/1` turns that into the `0` the rest of
  # this module (and every TRF pairing program's output) uses.
  #
  # `expected_rounds` is read back out of the TRF rather than off the
  # tournament struct on purpose: it must be whatever the FILE says (`XXR`),
  # because the file is what a FIDE checker reproduces the round from, and
  # the final-round colour exception keys off it.
  # The options every Ainalrami call takes, built once so that the
  # pairing, its explanation, and a page judging an alternative afterwards
  # all read the same values. They were written out twice and happened to
  # agree; the next option added to one would not have, and the failure is
  # quiet - a report describing a pairing that was made under other rules.
  defp ainalrami_opts(tournament, parsed, soft) do
    [
      expected_rounds: parsed.tournament[:number_of_rounds],
      # `Ainalrami.Trf.parse/1` lifts every `XXP` line into
      # `tournament[:forbidden_pairs]`, but the engine takes them as an
      # OPTION rather than reading them off the parsed struct - so omitting
      # this parsed them and threw them away. Every explicit forbidden
      # pairing and every club/federation exclusion was silently ignored,
      # which is the exact failure the extension guard exists to prevent: a
      # complete, legal-looking round that seats two players the arbiter
      # separated.
      forbidden_pairs: parsed.tournament[:forbidden_pairs],
      # What a result is WORTH. Omitting this paired every tournament on the
      # standard 1/half/0 system regardless of what the arbiter had
      # configured, so a 3-1-0 event was scored one way and bracketed
      # another. The TRF carries each player's TOTAL, which the engine
      # reconciles, but not the values behind it.
      point_system: Tournament.engine_point_system(tournament),
      # The arbiter's wishes, as opposed to the rules above: pairs to keep
      # apart where the criteria allow it (`soft_pairs/5`), and how hard to
      # try. An empty list leaves the engine's ladder untouched.
      soft_pairs: soft,
      soft_position: soft_position(tournament),
      # C.04.3 5.1's drawing of lots, read back off the file's `XXC` line
      # like the round count above, so the two engines are told the same
      # thing. Without it Ainalrami parsed the line and then inferred the
      # colour from the boards instead, which before round 1 means White
      # whatever was drawn. nil (no line) leaves that inference in place for
      # a tournament with no draw on record.
      initial_colour: parsed.tournament[:initial_colour],
      # Players the organiser keeps from the pairing-allocated bye this
      # round (`with_bye_exclusions/4`) - not a FIDE rule. `[]` pairs
      # exactly as the option's absence does, byte for byte.
      bye_exclusions: tournament.engine_bye_exclusions || []
    ]
  end

  defp soft_position(%Tournament{soft_position: "weak"}), do: :weak
  defp soft_position(_tournament), do: :strong

  defp alternatives(players, pairs, opts, tournament, round_number, category_name) do
    Explainer.impl().alternatives(players, pairs, opts)
  rescue
    e ->
      Logger.warning(
        "Ainalrami could not judge the alternatives for #{engine_log_scope(tournament, round_number, category_name)}: #{Exception.message(e)}"
      )

      %{floats: [], bye: nil}
  end

  @doc """
  The field exactly as the engine saw it when `round_number` was paired -
  the parsed TRF players, the engine options, and the rank <-> player maps -
  rebuilt from history strictly BEFORE that round.

  This is what lets a page judge an alternative to a round that has already
  been played: the scores, colours and float history are those of the
  moment the decision was made, not today's. Only the players actually
  seated in that round (and its bye) are eligible in the rebuilt field, so
  a late entrant who joined afterwards is not conjured into a bracket they
  were never in.

  Single-pool tournaments only: a category-paired round has one field per
  category, which this does not reconstruct.
  """
  def engine_field(%Tournament{} = tournament, round_number) do
    case tournament.id |> Tournaments.get_round(round_number) |> Repo.preload(:pairings) do
      nil ->
        {:error, :no_such_round}

      round ->
        history = history_before(tournament, round_number)

        full_roster =
          history.full_roster
          |> Map.values()
          |> in_pairing_number_order()

        seated =
          round.pairings
          |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        local_rank_by_player_id =
          full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)

        by_id = Map.new(full_roster, &{&1.id, &1})

        player_by_local_rank =
          Map.new(local_rank_by_player_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

        trf = trf_input(tournament, full_roster, local_rank_by_player_id, seated, history)
        parsed = Ainalrami.Trf.parse(trf)

        # The wishes as they stand NOW, like the forbidden pairings in the
        # TRF above - the record does not keep either as of the round.
        soft =
          soft_pairs(
            tournament,
            full_roster,
            local_rank_by_player_id,
            history.forbidden_pairings,
            round_number,
            history.pairing_rules
          )

        # Unlike the wishes, the bye exclusions are read off the round's own
        # record: they were decided per round (and one may have been lifted
        # for it), so today's player settings are not what it was paired on.
        organiser = recorded_bye_exclusions(round, local_rank_by_player_id)

        # And the players the round's bye preferences kept from the bye, so
        # the round is judged under the exclusions it was really paired by.
        preference =
          case round.explanation do
            %{"sections" => sections} ->
              recorded_preference_exclusions(sections, local_rank_by_player_id)

            _ ->
              []
          end

        tournament = %{
          tournament
          | engine_bye_exclusions: Enum.sort(Enum.uniq(organiser ++ preference))
        }

        {:ok,
         %{
           round: round,
           players: parsed.players,
           opts:
             tournament
             |> ainalrami_opts(parsed, soft)
             |> preference_labels(preference, organiser),
           organiser_exclusions: organiser,
           player_by_local_rank: player_by_local_rank,
           local_rank_by_player_id: local_rank_by_player_id,
           bye_exclusion_lifted: recorded_bye_exclusion_lifted(round)
         }}
    end
  end

  # A rebuilt field's options with only the organiser's own exclusions -
  # what the round's account records as its "bye_exclusions".
  defp organiser_opts(field),
    do: Keyword.put(field.opts, :bye_exclusions, field.organiser_exclusions)

  # The bye exclusions a round was paired under, from its stored account
  # (`put_bye_exclusions/3`), as the rebuilt field's ranks. A player no
  # longer in the field is dropped rather than guessed at.
  defp recorded_bye_exclusions(%Round{explanation: %{"sections" => sections}}, rank_by_id) do
    sections
    |> Enum.flat_map(&(&1["bye_exclusions"] || []))
    |> Enum.flat_map(&List.wrap(Map.get(rank_by_id, &1)))
    |> Enum.sort()
  end

  defp recorded_bye_exclusions(_round, _rank_by_id), do: []

  defp recorded_bye_exclusion_lifted(%Round{explanation: %{"sections" => sections}}),
    do: Enum.find_value(sections, & &1["bye_exclusion_lifted"])

  defp recorded_bye_exclusion_lifted(_round), do: nil

  @doc """
  The boards of `field.round` as played, in the engine's rank space:
  `{white, black}`, the pairing-allocated bye as `{player, nil}`.

  `:error` when the boards are not a complete pairing of the players seated
  in the round - a board with an empty white seat, a player on two boards,
  a seat nobody in the field holds, more byes than the round can have, as a
  hand-edited round can be. Ainalrami refuses to explain such a thing (a
  player left out of it used to be read as a player given the bye), so it
  is not handed over: there is no account of boards that are not a round.
  """
  def field_pairs(field) do
    rank = &Map.get(field.local_rank_by_player_id, &1)
    boards = Enum.sort_by(field.round.pairings, & &1.board)

    seated =
      boards
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(rank)

    pairs =
      Enum.flat_map(boards, fn p ->
        white = rank.(p.white_player_id)
        black = p.black_player_id && rank.(p.black_player_id)

        if white, do: [{white, black}], else: []
      end)

    if pairs != [] and not Enum.any?(seated, &is_nil/1) and complete_pairing?(pairs, seated),
      do: {:ok, pairs},
      else: :error
  end

  @doc """
  Whether `pairs` (`{white, black}`, the bye `{rank, nil}`) is a complete
  pairing of `active` (a list of ranks): every one of them exactly once and
  nobody else, nobody against themselves, and exactly the byes that many
  players have - one if odd, none if even. The terms
  `Ainalrami.Pairing.explain_round/3` and the `Ainalrami.Alternatives`
  questions hold a supplied pairing to.
  """
  def complete_pairing?(pairs, active) do
    seated = Enum.flat_map(pairs, fn {a, b} -> if is_nil(b), do: [a], else: [a, b] end)
    byes = Enum.count(pairs, fn {_a, b} -> is_nil(b) end)
    expected = Enum.uniq(active)

    Enum.all?(pairs, fn {a, b} -> a != b end) and
      length(seated) == length(Enum.uniq(seated)) and
      Enum.sort(seated) == Enum.sort(expected) and
      byes == rem(length(expected), 2)
  end

  @doc """
  Whether a round's stored engine account is current, or could be brought
  up to date by `reexplain_round/2`:

    * `:current` - a version-3 record; nothing to do.
    * `:stale` - no record, or one from before the alternatives existed,
      and the boards still match what the engine paired: recomputable.
    * `:hand_edited` - the boards were changed after pairing. The stored
      record is the engine's original decision and is kept as it is.
    * `:ineligible` - not a single-pool Swiss round. Which engine paired it
      does not matter; see `reexplain_round/2`.
    * `:pending` / `:failed` - the round's account is still being worked
      out after pairing, or that failed (`explanation_state/1`). Its own
      job, or its own "Try again", owns it; a recompute leaves it alone.
  """
  def reexplain_status(%Tournament{} = tournament, round) do
    cond do
      is_nil(round) -> :ineligible
      explanation_state(round) in [:pending, :failed] -> explanation_state(round)
      not reexplainable?(tournament) -> :ineligible
      current_account?(round) -> :current
      hand_edited?(round) -> :hand_edited
      true -> :stale
    end
  end

  # Any single-pool Swiss round. The account explains the boards AS PLAYED,
  # so it does not need a record of the engine's own reasoning; a round
  # paired before accounts existed is exactly where an after-the-fact
  # analysis is worth the most.
  # A team Swiss paired by teams is not: its rounds were decided team against
  # team by C.04.6, which the individual engine's account cannot describe.
  defp reexplainable?(t),
    do: t.pairing_system == "swiss" and not t.pair_by_category and not Tournament.team_swiss?(t)

  defp current_account?(%{explanation: %{"version" => v}}) when is_integer(v) and v >= 3,
    do: true

  defp current_account?(_round), do: false

  # A record whose pairs no longer match the boards was edited by hand after
  # the engine paired it. No record at all is not "edited".
  defp hand_edited?(round) do
    round = Repo.preload(round, :pairings)
    match?({:changed, _}, PairingsEngine.RoundExplanation.divergence(round))
  end

  @doc """
  Recomputes one round's engine account from the boards AS PLAYED - the
  field rebuilt as it stood before the round, the actual pairs explained
  under the engine's ladder, the float and bye alternatives judged - and
  stores it as a version-3 record, marked `"origin" => "recomputed"`.

  **This never changes a pairing.** It reads the boards and writes
  `rounds.explanation`, nothing else; the searches it runs to judge the
  alternatives happen in memory and are thrown away. It is not a re-pair -
  a re-pair could give a different answer, and the question is about the
  round that was played.

  A round whose boards were changed by hand after pairing is left alone
  (`{:skip, :hand_edited}`): the stored record is the engine's original
  decision, the page already says the boards diverged from it, and
  overwriting it would erase exactly that. "What if?" still judges such a
  round live.

  A round paired before accounts existed - or by the external engine this
  app used to offer - is analysed the same way: this is the only account
  it can ever have.
  """
  def reexplain_round(%Tournament{} = tournament, round_number) do
    with false <- Tournaments.write_refused(tournament),
         round when not is_nil(round) <- Tournaments.get_round(tournament.id, round_number),
         :stale <- reexplain_status(tournament, round),
         {:ok, field} <- engine_field(tournament, round_number),
         {:ok, pairs} <- field_pairs(field) do
      account =
        Map.merge(
          %{brackets: Explainer.impl().brackets(field.players, pairs, field.opts)}
          |> Map.merge(bye_exclusion_account(organiser_opts(field), field.bye_exclusion_lifted)),
          alternatives(field.players, pairs, field.opts, tournament, round_number, nil)
        )

      payload =
        [{nil, account, field.player_by_local_rank}]
        |> explanation_payload()
        |> keep_bye_preference(round.explanation)
        |> Map.put("origin", "recomputed")

      round |> Ecto.Changeset.change(explanation: payload) |> Repo.update()
    else
      {:error, :no_such_round} ->
        {:skip, :no_such_round}

      {:error, reason} ->
        {:skip, {:refused, reason}}

      nil ->
        {:skip, :no_such_round}

      :error ->
        {:skip, :no_boards}

      status when status in [:current, :hand_edited, :ineligible, :pending, :failed] ->
        {:skip, status}
    end
  end

  @doc """
  `reexplain_round/2` over every round of the tournament, in order. Returns
  `%{recomputed: n, skipped: %{reason => count}}`. Idempotent: a second run
  skips everything as `:current`.
  """
  def reexplain_tournament(%Tournament{} = tournament) do
    numbers =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament.id,
          order_by: r.number,
          select: r.number
      )

    Enum.reduce(numbers, %{recomputed: 0, skipped: %{}}, fn number, acc ->
      case reexplain_round(tournament, number) do
        {:ok, _round} -> %{acc | recomputed: acc.recomputed + 1}
        {:skip, reason} -> %{acc | skipped: Map.update(acc.skipped, reason, 1, &(&1 + 1))}
      end
    end)
  end

  @doc """
  Works out the alternatives the pairing-time cap left out - "why did HE
  float, or get the bye, and not me" for a bracket with more candidates
  than `Ainalrami.Alternatives.max_candidates/0` - and stores them in the
  round's account. One full pairing per candidate, so it runs on request
  from the rationale page rather than for every round paired: a top bracket
  of a hundred players costs about a hundred pairings of the round.

  Like `reexplain_round/2` it writes `rounds.explanation` and nothing else;
  the boards are read, never touched. A round with no account yet gets one
  as `reexplain_round/2` would have given it, at full depth. Refused for a
  hand-edited or per-category round, for the reasons given there. The
  account keeps its `"origin"` (and an old record's `"paired_by"`) and gains
  `"depth" => "full"`.
  """
  def deepen_round(%Tournament{} = tournament, round_number) do
    with false <- Tournaments.write_refused(tournament),
         round when not is_nil(round) <- Tournaments.get_round(tournament.id, round_number),
         status when status in [:current, :stale] <- reexplain_status(tournament, round),
         # A current record is the engine's decision as stored; if the
         # boards were changed by hand since, `reexplain_status/2` still
         # says `:current` (it only asks whether the record is up to date),
         # so the hand-edit check is asked here on its own.
         false <- hand_edited?(round),
         {:ok, field} <- engine_field(tournament, round_number),
         {:ok, pairs} <- field_pairs(field),
         opts = Keyword.put(field.opts, :max_candidates, :all),
         account =
           Map.merge(
             %{brackets: Explainer.impl().brackets(field.players, pairs, opts)}
             |> Map.merge(
               bye_exclusion_account(organiser_opts(field), field.bye_exclusion_lifted)
             ),
             alternatives(field.players, pairs, opts, tournament, round_number, nil)
           ),
         payload when not is_nil(payload) <-
           explanation_payload([{nil, account, field.player_by_local_rank}]) do
      provenance =
        case status do
          # No usable record before this: the provenance a recompute would
          # have written, since that is what this is, at full depth.
          :stale -> %{"origin" => "recomputed"}
          :current -> Map.take(round.explanation || %{}, ["origin", "paired_by"])
        end

      payload =
        payload
        |> Map.merge(provenance)
        |> Map.put("depth", "full")
        |> keep_soft_pairs_moved(round.explanation)
        |> keep_bye_preference(round.explanation)

      round |> Ecto.Changeset.change(explanation: payload) |> Repo.update()
    else
      {:error, :no_such_round} -> {:skip, :no_such_round}
      {:error, reason} -> {:skip, {:refused, reason}}
      nil -> {:skip, :no_such_round}
      :error -> {:skip, :no_boards}
      true -> {:skip, :hand_edited}
      status when status in [:hand_edited, :ineligible, :pending, :failed] -> {:skip, status}
    end
  end

  ## ---------- the account, after the round is saved ----------
  #
  # See `PairingsEngine.ExplanationJobs` for why the account is no longer
  # worked out inside the click, and docs/pairing-systems.md ("The engine's
  # account, after the click") for what the arbiter sees meanwhile.

  @doc """
  Where a round's engine account stands:

    * `:ready` - an account is stored.
    * `:pending` - the round is saved and its account is being worked out
      (`PairingsEngine.ExplanationJobs`), or was when the node went down.
    * `:failed` - working it out failed; the explanation page offers to try
      again.
    * `:none` - no account at all: a round from before accounts existed
      (or paired by the external engine this app no longer has), or no
      round.

  A pending or failed record already carries the round's deviation facts
  (who an exclusion passed over for the bye, whether the arbiter's wishes
  moved a board), so `pairing_deviations/2` reads the same either way.
  """
  def explanation_state(%Round{explanation: %{"status" => "pending"}}), do: :pending
  def explanation_state(%Round{explanation: %{"status" => "failed"}}), do: :failed
  def explanation_state(%Round{explanation: %{"sections" => _}}), do: :ready
  def explanation_state(_round), do: :none

  @doc "`explanation_state/1` of a round by number, reading the one column."
  def explanation_state(tournament_id, round_number) do
    explanation =
      Repo.one(
        from r in Round,
          where: r.tournament_id == ^tournament_id and r.number == ^round_number,
          select: r.explanation
      )

    explanation_state(%Round{explanation: explanation})
  end

  @doc """
  For a page that wants to show a round's account: when it is pending and
  nothing in this node is working on it - the job was lost with a restart -
  starts working it out again, from the round's history
  (`recompute_explanation/2`). Returns the round's `explanation_state/1`.
  """
  def ensure_explanation(%Tournament{} = tournament, %Round{} = round) do
    with :pending <- explanation_state(round),
         false <- ExplanationJobs.running?(round.id) do
      start_recompute(tournament, round)
    end

    explanation_state(round)
  end

  # By number, reading only what it needs - for a page that has not loaded
  # the round's boards.
  def ensure_explanation(%Tournament{} = tournament, round_number)
      when is_integer(round_number) do
    round =
      Repo.one(
        from r in Round,
          where: r.tournament_id == ^tournament.id and r.number == ^round_number,
          select: struct(r, [:id, :number, :explanation])
      )

    ensure_explanation(tournament, round)
  end

  def ensure_explanation(_tournament, round), do: explanation_state(round)

  @doc """
  "Try again" on a failed account: puts it back to pending and works it out
  from the round's history. `:ok`, or `:stale` when the round no longer
  holds that failed record.
  """
  def retry_explanation(%Tournament{} = tournament, %Round{} = round) do
    with :failed <- explanation_state(round),
         :stored <- ExplanationJobs.mark_pending(round.id, round.explanation["job"]) do
      start_recompute(tournament, round)
      :ok
    else
      _ -> :stale
    end
  end

  defp start_recompute(tournament, round) do
    number = round.number

    ExplanationJobs.run(tournament.id, round.id, round.explanation["job"], fn ->
      recompute_explanation(tournament, number)
    end)
  end

  ## ---------- one alternative, when somebody opens it ----------

  @doc """
  Somebody opened `question` (`PairingsEngine.RoundExplanation.parse_question/2`)
  on round `round_number`'s explanation page. Returns

    * `:stored` - its answer is already stored (`stored_alternatives/1`);
      nothing to do.
    * `:started` - it is being worked out now (or already was, by somebody
      else's click): `PairingsEngine.ExplanationJobs.run_alternative/5`
      broadcasts when it is stored or failed.
    * `{:error, :stale}` - the round no longer holds a finished version-4
      account asking that question: unpaired, paired again, or never one.

  `full: true` works it out past `Ainalrami.Alternatives.max_candidates/0`
  - the arbiter asked, and knows it is one full pairing per candidate - and
  replaces the capped answer. `job: fingerprint` refuses (`:stale`) unless
  the round still holds that account: a page opened on a pairing since
  undone must not start work on the one that replaced it.

  Like `reexplain_round/2` this never touches a board: the forced searches
  happen in memory and only the answer is kept.
  """
  def open_alternative(%Tournament{} = tournament, round_number, question, opts \\ []) do
    full? = Keyword.get(opts, :full, false)
    expected = Keyword.get(opts, :job)

    with %Round{explanation: %{"job" => job} = record} = round <-
           Tournaments.get_round(tournament.id, round_number),
         true <- is_nil(expected) or expected == job,
         :ready <- explanation_state(round),
         {:ok, parsed} <- RoundExplanation.parse_question(record, question) do
      if not full? and Map.has_key?(ExplanationJobs.stored_alternatives(round.id, job), question) do
        :stored
      else
        ExplanationJobs.run_alternative(tournament.id, round.id, job, question, fn ->
          work_out_alternative(tournament, round_number, job, parsed, full?)
        end)

        :started
      end
    else
      _ -> {:error, :stale}
    end
  end

  @doc """
  The stored answers of a round's version-4 account, by question - `%{}`
  for any other round. The questions being worked out in this node are
  `PairingsEngine.ExplanationJobs.running_alternatives/2`.
  """
  def stored_alternatives(%Round{id: id, explanation: %{"job" => job} = record}) do
    if RoundExplanation.on_demand?(record),
      do: ExplanationJobs.stored_alternatives(id, job),
      else: %{}
  end

  def stored_alternatives(_round), do: %{}

  # The work behind one opened question: the section's field rebuilt as it
  # stood before the round, the pairs the engine made (from the record, not
  # the boards - a board changed by hand since is not what the account
  # describes), and one forced search per candidate. `{:ok, answer JSON}`
  # or `{:error, reason}`; stores nothing.
  defp work_out_alternative(tournament, round_number, job, parsed, full?) do
    with %Round{explanation: %{"job" => ^job, "sections" => sections}} <-
           Tournaments.get_round(tournament.id, round_number),
         section when is_map(section) <- Enum.at(sections, elem(parsed, 1)) do
      {_history, _roster, rank_by_id, by_rank} =
        rebuilt = field_before(tournament, round_number)

      recorded = section["pairs"] || []
      field = recorded |> List.flatten() |> Enum.reject(&is_nil/1) |> MapSet.new()

      # A player deleted since the round was paired: the field it was
      # paired from can no longer be rebuilt.
      if Enum.any?(field, &is_nil(rank_by_id[&1])) do
        {:error, :field_changed}
      else
        pairs = Enum.map(recorded, fn [w, b] -> {rank_by_id[w], b && rank_by_id[b]} end)
        input = section_input(tournament, round_number, section, field, rebuilt)
        opts = if full?, do: Keyword.put(input.opts, :max_candidates, :all), else: input.opts
        answer_question(parsed, section, input.players, pairs, opts, rank_by_id, by_rank)
      end
    else
      _ -> {:error, :stale}
    end
  end

  defp answer_question({:bye, _s}, _section, players, pairs, opts, _rank_by_id, by_rank) do
    case Explainer.impl().bye_question(players, pairs, opts) do
      nil -> {:error, :no_bye}
      bye -> {:ok, bye_json(bye, by_rank)}
    end
  end

  defp answer_question({:float, _s, b, id}, section, players, pairs, opts, rank_by_id, by_rank) do
    group = section["brackets"] |> Enum.at(b) |> Map.fetch!("group")

    case Explainer.impl().float_question(players, pairs, opts, group, rank_by_id[id]) do
      nil -> {:error, :not_a_floater}
      float -> {:ok, alternative_json(float, by_rank)}
    end
  end

  @doc """
  Works a pending round's account out again from scratch: the field rebuilt
  as it stood before the round (`history_before/2`), one section per
  pending section, over the players that section paired (its `"field"`),
  and the boards as they now stand. What the click already worked out - the
  deviation facts - is carried over from the pending record, not redone.

  Marked `"origin" => "recomputed"`, since it is an account of the boards
  as played rather than of the decision in memory. `{:ok, payload}` or
  `{:error, reason}`; writes nothing (`PairingsEngine.ExplanationJobs`
  does, under its guard).
  """
  def recompute_explanation(%Tournament{} = tournament, round_number) do
    case tournament.id |> Tournaments.get_round(round_number) |> Repo.preload(:pairings) do
      # Pending only. A finished account keeps its "job" too, and a page
      # that read the round while it was pending can ask for this just as
      # the job finishes: the finished sections carry no "field" to rebuild
      # the round from, so there would be nothing to explain and no pending
      # record left for the answer to be written to.
      %Round{explanation: %{"status" => "pending", "job" => _, "sections" => sections}} =
          round ->
        {_history, _roster, _rank_by_id, by_rank} =
          rebuilt = field_before(tournament, round_number)

        accounts =
          Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, acc} ->
            case recomputed_account(tournament, round, section, rebuilt) do
              {:ok, account} -> {:cont, {:ok, [{section["category"], account, by_rank} | acc]}}
              {:error, _} = error -> {:halt, error}
            end
          end)

        with {:ok, accounts} <- accounts do
          case explanation_payload(Enum.reverse(accounts)) do
            nil ->
              {:error, :nothing_to_explain}

            payload ->
              {:ok, Map.put(payload, "origin", "recomputed")}
          end
        end

      _ ->
        {:error, :not_pending}
    end
  end

  # The roster as it stood before `round_number`, in pairing order, and the
  # rank <-> player maps over it - what the engine saw, rebuilt from history.
  defp field_before(tournament, round_number) do
    history = history_before(tournament, round_number)

    full_roster =
      history.full_roster
      |> Map.values()
      |> in_pairing_number_order()

    rank_by_id = full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)
    by_id = Map.new(full_roster, &{&1.id, &1})
    by_rank = Map.new(rank_by_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

    {history, full_roster, rank_by_id, by_rank}
  end

  # One section's engine input, rebuilt: the players of `field` (ids) as the
  # engine saw them before the round, and the options it paired them under -
  # the section's own recorded bye exclusions, today's wishes (the record
  # keeps neither the wishes nor the forbidden pairings as of the round).
  defp section_input(tournament, round_number, section, field, rebuilt) do
    {history, full_roster, rank_by_id, _by_rank} = rebuilt
    rank = &List.wrap(Map.get(rank_by_id, &1))

    trf =
      build_category_trf(tournament, full_roster, field, rank_by_id, history, round_number)

    parsed = Ainalrami.Trf.parse(trf)

    soft =
      soft_pairs(
        tournament,
        full_roster,
        rank_by_id,
        history.forbidden_pairings,
        round_number,
        history.pairing_rules
      )

    organiser = section |> Map.get("bye_exclusions", []) |> Enum.flat_map(rank) |> Enum.sort()
    preference = recorded_preference_exclusions([section], rank_by_id)

    tournament = %{
      tournament
      | engine_bye_exclusions: Enum.sort(Enum.uniq(organiser ++ preference))
    }

    %{
      players: parsed.players,
      opts:
        tournament |> ainalrami_opts(parsed, soft) |> preference_labels(preference, organiser),
      organiser_exclusions: organiser
    }
  end

  # The players a bye preference, not the organiser, kept from the bye: the
  # engine then says `:bye_preference` for them in "why not me" rather than
  # `:organiser_exclusion` (Ainalrami's `:bye_preference_exclusions`).
  defp preference_labels(opts, preference, organiser) do
    case Enum.uniq(preference) -- organiser do
      [] -> opts
      ranks -> Keyword.put(opts, :bye_preference_exclusions, Enum.sort(ranks))
    end
  end

  defp recomputed_account(tournament, round, section, rebuilt) do
    {_history, _roster, rank_by_id, _by_rank} = rebuilt
    field = MapSet.new(section["field"] || [])
    rank = &List.wrap(Map.get(rank_by_id, &1))
    input = section_input(tournament, round.number, section, field, rebuilt)

    pairs =
      round.pairings
      |> Enum.sort_by(& &1.board)
      |> Enum.filter(&MapSet.member?(field, &1.white_player_id))
      |> Enum.flat_map(fn p ->
        case {Map.get(rank_by_id, p.white_player_id), p.black_player_id} do
          {nil, _} -> []
          {white, nil} -> [{white, nil}]
          {white, black} -> [{white, Map.get(rank_by_id, black)}]
        end
      end)

    ranks = field |> Enum.map(&Map.get(rank_by_id, &1)) |> Enum.uniq()

    # The boards as they stand have to be this section's round: a board
    # edited since (a seat emptied, a player moved to another board) leaves
    # a pairing the engine will not explain, so say so instead of asking.
    if ranks != [] and nil not in ranks and complete_pairing?(pairs, ranks) do
      {:ok,
       deferred_account(%{
         players: input.players,
         pairs: pairs,
         opts: input.opts,
         organiser_exclusions: input.organiser_exclusions,
         lifted: section["bye_exclusion_lifted"],
         soft_pairs_moved: section["soft_pairs_moved"] == true,
         bye_passed_over: section |> Map.get("bye_passed_over", []) |> Enum.flat_map(rank),
         bye_preference_json: section["bye_preference"]
       })}
    else
      {:error, :boards_changed}
    end
  end

  # The account of one engine run, from what the click kept in memory
  # (`run_ainalrami/5`'s `deferred`) or what `recomputed_account/6` rebuilt.
  # The bye chain was worked out in the click, so the engine is asked not to
  # repeat it. A failure of the brackets fails the job (and the page says
  # so).
  #
  # The brackets only - a second or so on a 450-player field. The "why him
  # and not me" alternatives, one forced re-pairing per candidate and most
  # of the old job's minutes, are worked out one question at a time when
  # somebody opens it (`open_alternative/4`), from the pairs recorded here.
  defp deferred_account(deferred) do
    brackets =
      Explainer.impl().brackets(
        deferred.players,
        deferred.pairs,
        Keyword.put(deferred.opts, :bye_passed_over, false)
      )

    deferred
    |> deviation_account()
    |> Map.put(:brackets, brackets)
    |> Map.put(:pairs_played, deferred.pairs)
  end

  # What the click itself knows about one engine run: the organiser's
  # deviations. It is the whole of a pending record's section, and part of
  # the finished one.
  defp deviation_account(deferred) do
    organiser = Map.get(deferred, :organiser_exclusions, deferred.opts[:bye_exclusions])

    %{brackets: [], bye_passed_over: deferred.bye_passed_over}
    |> Map.merge(
      bye_exclusion_account(
        Keyword.put(deferred.opts, :bye_exclusions, organiser),
        deferred.lifted
      )
    )
    |> Map.merge(if(deferred.soft_pairs_moved, do: %{soft_pairs_moved: true}, else: %{}))
    |> Map.merge(bye_preference_entry(deferred))
  end

  defp bye_preference_entry(%{bye_preference: %{} = account}), do: %{bye_preference: account}

  defp bye_preference_entry(%{bye_preference_json: %{} = json}),
    do: %{bye_preference_json: json}

  defp bye_preference_entry(_deferred), do: %{}

  # The record a round is saved with: per section, the players it paired
  # (`"field"`, so the account can be rebuilt after a restart), the
  # deviation facts, and no brackets yet - `PairingsEngine.RoundExplanation`
  # reads that as "no account", which is what it is until the job is done.
  # nil when no section has anything to work out.
  defp pending_payload(tournament, round_number, sections) do
    built =
      for {category_name, %{} = deferred, by_rank} <- sections do
        field =
          deferred.pairs
          |> Enum.flat_map(fn {w, b} -> [w, b] end)
          |> Enum.map(&player_id(&1, by_rank))
          |> Enum.reject(&is_nil/1)

        %{"category" => category_name, "brackets" => [], "bye" => nil, "field" => field}
        |> put_bye_exclusions(deviation_account(deferred), by_rank)
      end

    case built do
      [] ->
        nil

      built ->
        pairs = for {c, %{} = d, _} <- sections, do: {c, d.pairs}

        %{
          "engine" => "ainalrami",
          "status" => "pending",
          "job" => ExplanationJobs.fingerprint({tournament.id, round_number, pairs}),
          "sections" => built
        }
    end
  end

  defp with_deferred({:ok, round}, sections), do: {:ok, round, sections}
  defp with_deferred(error, _sections), do: error

  # Hands the saved round's account to `PairingsEngine.ExplanationJobs`,
  # built from the very field the engine just paired. The record is looked
  # up by number because a match-format pairing returns its second leg,
  # while the account is the first's.
  defp start_explanation(tournament, round_number, sections, returned) do
    target =
      Repo.one(
        from r in Round,
          where: r.tournament_id == ^tournament.id and r.number == ^round_number,
          select: %{id: r.id, job: fragment("json_extract(?, '$.job')", r.explanation)}
      )

    case target do
      %{id: id, job: job} when is_binary(job) ->
        ExplanationJobs.run(tournament.id, id, job, fn ->
          accounts =
            for {category_name, %{} = deferred, by_rank} <- sections,
                do: {category_name, deferred_account(deferred), by_rank}

          case explanation_payload(accounts) do
            nil -> {:error, :nothing_to_explain}
            payload -> {:ok, payload}
          end
        end)

        # Worked out before returning (tests): hand back the finished row.
        if ExplanationJobs.mode() == :inline and returned.id == id,
          do: Repo.reload!(returned),
          else: returned

      _ ->
        returned
    end
  end

  # Deepening re-explains the boards as played; it does not pair the round
  # again, so it cannot tell whether the wishes moved it. What pairing time
  # found is kept (`soft_pairs_moved?/4`).
  defp keep_soft_pairs_moved(%{"sections" => [first | rest]} = payload, %{"sections" => old})
       when is_list(old) do
    if Enum.any?(old, &(&1["soft_pairs_moved"] == true)),
      do: %{payload | "sections" => [Map.put(first, "soft_pairs_moved", true) | rest]},
      else: payload
  end

  defp keep_soft_pairs_moved(payload, _old), do: payload

  # The shared history with everything from `round_number` onwards removed -
  # what `pairing_history/1` would have returned the moment that round was
  # about to be paired.
  defp history_before(tournament, round_number) do
    history = build_shared_history(tournament)

    %{
      history
      | rounds: Enum.filter(history.rounds, &(&1.number < round_number)),
        bye_map:
          history.bye_map
          |> Enum.filter(fn {{_player_id, round}, _type} -> round < round_number end)
          |> Map.new()
    }
    |> then(&precompute_games(tournament, &1))
  end

  defp run_ainalrami(tournament, input, round_number, category_name, soft, run) do
    case ainalrami_field(input) do
      {:ok, parsed} ->
        engine_opts = ainalrami_opts(tournament, parsed, soft)

        # `engine_opts` verbatim, NOT a second list spelling out the same
        # three keys. They were written out twice and happened to agree; the
        # next option added to one of them would not have, and the failure
        # mode is quiet - `explain_round/3` would describe a pairing that is
        # not the one the arbiter is looking at.
        #
        # With bye preferences the engine resolves them into bye exclusions
        # and hands back the options it finally paired under (`opts`), which
        # everything explaining the round then uses; `engine_opts` keeps the
        # organiser's own exclusions for their account.
        {raw_pairs, opts, preference} =
          pair_with_preferences(parsed.players, engine_opts, tournament)

        # The organiser deviations are worked out HERE, in the click,
        # because the round's FIDE-compliance stamp and its audit rows are
        # written from them the moment it is saved
        # (`record_pairing_deviations/2`, `PairingsLive`). Each is a second
        # pairing run, and each only runs when its setting is in play.
        #
        # A preview (`preview_round/2`) keeps no record, so it skips both.
        # The exclusion chain re-pairs the round without preferences, so it
        # describes the round only when they did not move it; when they did,
        # the preference account says what happened to the bye instead.
        {soft_moved?, passed_over} =
          cond do
            run.preview? ->
              {false, []}

            preference && preference.moved ->
              {soft_pairs_moved?(parsed.players, raw_pairs, opts, tournament), []}

            true ->
              {soft_pairs_moved?(parsed.players, raw_pairs, opts, tournament),
               bye_passed_over(parsed.players, raw_pairs, engine_opts, tournament)}
          end

        # Everything else about the round's account - the brackets
        # (`explain_round/3`, a second call because it analyses a pairing
        # it is GIVEN) and the alternatives (one forced search per
        # candidate: the expensive part) - is commentary. It is worked out
        # after the round is saved (`PairingsEngine.ExplanationJobs`), from
        # exactly this field, so the arbiter sees the boards as soon as the
        # engine has them.
        deferred = %{
          players: parsed.players,
          pairs: raw_pairs,
          opts: opts,
          organiser_exclusions: engine_opts[:bye_exclusions] || [],
          lifted: tournament.bye_exclusion_override,
          soft_pairs_moved: soft_moved?,
          bye_passed_over: passed_over,
          bye_preference: preference
        }

        {:ok, Enum.map(raw_pairs, &ainalrami_bye_to_zero/1), deferred}

      {:unsupported, codes} ->
        {:error, ainalrami_unsupported_message(codes, category_name)}
    end
  rescue
    # Ainalrami raises on a proven structural deadlock, not a search that
    # gave up (see the exception's own doc). Mapped onto an
    # `{:error, string}` shape so `pair_next_round/1`'s callers can render
    # the reason as-is.
    # The organiser's bye exclusions, not the rules, made the round
    # impossible: handed back as data, so the page can name the players and
    # offer to pair without one of them (`bye_exclusion_error/2` turns the
    # engine's ranks into players on the way up).
    # A "must get the bye" for a player FIDE's rule C2 rules out - a second
    # pairing-allocated bye: nothing is paired, and the page names the
    # player and the round of their earlier bye
    # (`bye_exclusion_error/2` turns the ranks into players).
    e in Ainalrami.ByePreference.RefusedError ->
      {:error,
       {:bye_preference_refused,
        %{players: e.players, round: round_number, category: category_name}}}

    e in Ainalrami.Pairing.NoValidPairingError ->
      ainalrami_refusal(e, tournament, round_number, category_name)

    # The TRF we just built is our own, so this should be unreachable; it is
    # caught rather than allowed to escape because an unhandled raise here
    # would take down the whole LiveView instead of showing the arbiter a
    # message, and because Ainalrami validates result-code combinations
    # eagerly.
    e in Ainalrami.Trf.ValidationError ->
      Logger.error(
        "Ainalrami rejected the generated TRF for #{engine_log_scope(tournament, round_number, category_name)}: #{Exception.message(e)}"
      )

      {:error,
       ainalrami_scoped(
         "Ainalrami could not read the generated pairing file: #{Exception.message(e)}",
         category_name
       )}

    # Any other crash. Unlike the two clauses above (proven, well-understood
    # refusals) this is unexpected - but it must still leave the round
    # unpaired and the arbiter with a message, not take the LiveView down.
    # Nothing has been written to the database at this point (`create_round`
    # is only reached from the `{:ok, ...}` branch above), so the tournament
    # is unchanged. Logged WITHOUT player data - only the exception's type
    # and where it was raised - same discipline as
    # `PairingsEngine.Federations.BEL.Sync.crashed/4`.
    e ->
      Logger.error(
        "Ainalrami pairing crashed for #{engine_log_scope(tournament, round_number, category_name)}: " <>
          "#{inspect(e.__struct__)}\n" <>
          Exception.format_stacktrace(Enum.take(__STACKTRACE__, 5))
      )

      {:error, {:pairing_crashed, round_number, category_name}}
  end

  # `{pairs, opts, preference_account | nil}`. Without preferences exactly
  # the call it always was.
  defp pair_with_preferences(players, engine_opts, tournament) do
    case tournament.engine_bye_preferences || [] do
      [] ->
        {Ainalrami.Pairing.pair_next_round(players, engine_opts), engine_opts, nil}

      prefs ->
        {pairs, report} =
          Ainalrami.ByePreference.pair(players, engine_opts ++ [bye_preferences: prefs])

        organiser = engine_opts[:bye_exclusions] || []

        account = %{
          bye: report.bye,
          moved: report.moved,
          decided_by: report.decided_by,
          fide_bye: report.fide_bye,
          exclusions: report.exclusions -- organiser,
          outcomes: report.outcomes
        }

        {pairs, report.opts, account}
    end
  end

  # The field the engine pairs: the TRF read back, unless it carries an
  # extension Ainalrami would not act on - or a preview outcome's field,
  # already read (`rerank_field/5`).
  defp ainalrami_field({:trf, trf}) do
    case ainalrami_unsupported_extensions(trf) do
      [] -> {:ok, Ainalrami.Trf.parse(trf)}
      codes -> {:unsupported, codes}
    end
  end

  defp ainalrami_field({:parsed, parsed}), do: {:ok, parsed}

  ## ---------- the preview's field, re-ranked per outcome ----------

  # What `preview_base/2` keeps (`base: :capture`) and what
  # `preview_fields/2` compares (`field_only?`): the field as parsed, and
  # the ranks it was parsed under. Never reaches the engine.
  defp preview_field(input, rank_by_id, run) do
    case ainalrami_field(input) do
      {:ok, parsed} ->
        id_by_rank = Map.new(rank_by_id, fn {id, rank} -> {rank, id} end)

        field = %{
          parsed: parsed,
          id_by_rank: id_by_rank,
          players_by_id: Map.new(parsed.players, &{Map.fetch!(id_by_rank, &1.rank), &1})
        }

        if Map.get(run, :field_only?, false),
          do: {:ok, %{kind: :field, field: parsed}},
          else: {:ok, %{kind: :base, base: field}}

      {:unsupported, _codes} ->
        {:error, :unsupported}
    end
  end

  # One outcome's field from the base's: every player renumbered to this
  # outcome's rank (the pairing number since the ranks stopped following
  # the standings, so normally unchanged - kept so a rank map that differs
  # still holds), every opponent likewise, and the players who played an open
  # game given its result and their new score - exactly what
  # `Ainalrami.Trf.parse/1` would read off this outcome's TRF, which
  # `preview_fields/2`'s test holds it to. The forbidden pairs are worked
  # out again from the new ranks, as `engine_trf/6` does.
  defp rerank_field(base, tournament, roster, rank_by_id, history) do
    round_index = length(history.rounds) - 1

    players =
      base.players_by_id
      |> Enum.map(fn {id, player} ->
        rank = Map.fetch!(rank_by_id, id)

        # The rows carry no standings, so the file's rank column is the
        # starting rank again (`Ainalrami.Trf`'s fallback) - the new one.
        player = %{
          player
          | rank: rank,
            final_rank: rank,
            games: Enum.map(player.games, &rerank_game(&1, base.id_by_rank, rank_by_id))
        }

        if MapSet.member?(history.changed, id),
          do: with_outcome(player, Map.fetch!(history.games, id), round_index, tournament),
          else: player
      end)
      |> Enum.sort_by(& &1.rank)

    forbidden =
      forbidden_pairs(tournament.id, roster, rank_by_id, history.forbidden_pairings) ++
        exclusion_pairs(
          tournament,
          roster,
          rank_by_id,
          history.forbidden_pairings,
          length(history.rounds) + 1,
          history.pairing_rules
        )

    parsed_tournament =
      if forbidden == [],
        do: Map.delete(base.parsed.tournament, :forbidden_pairs),
        else: Map.put(base.parsed.tournament, :forbidden_pairs, forbidden)

    %{base.parsed | players: players, tournament: parsed_tournament}
  end

  defp rerank_game(%{opponent_rank: nil} = game, _id_by_rank, _rank_by_id), do: game

  defp rerank_game(%{opponent_rank: rank} = game, id_by_rank, rank_by_id),
    do: %{game | opponent_rank: Map.fetch!(rank_by_id, Map.fetch!(id_by_rank, rank))}

  # A player of an open game: its result, as the TRF spells it, and the
  # score the file would carry - written with one decimal and read back,
  # as `Ainalrami.Trf` does.
  defp with_outcome(player, row_games, round_index, tournament) do
    result = Enum.at(row_games, round_index).result

    games =
      List.update_at(player.games, round_index, fn game ->
        %{game | result: if(result in [nil, ""], do: nil, else: result)}
      end)

    points =
      row_games
      |> player_points(tournament)
      |> Kernel./(1)
      |> :erlang.float_to_binary(decimals: 1)
      |> Float.parse()
      |> elem(0)

    %{player | games: games, points: points}
  end

  # The engine's "no legal round", as the page reads it. One function for
  # the raise `run_ainalrami/6` rescues and the `{:error, e}` the variant
  # batch hands back (`run_variants/7`), so the two cannot word it apart.
  defp ainalrami_refusal(e, tournament, round_number, category_name) do
    if Map.get(e, :reason) == :bye_exclusions do
      {:error,
       {:bye_exclusions,
        %{
          excluded: e.excluded,
          override: e.override,
          category: category_name,
          round: round_number
        }}}
    else
      no_legal_pairing(e, tournament, round_number, category_name)
    end
  end

  defp no_legal_pairing(e, tournament, round_number, category_name) do
    Logger.error(
      "Ainalrami found no legal pairing for #{engine_log_scope(tournament, round_number, category_name)}: #{Exception.message(e)}"
    )

    # Tagged, so the Pairings page can offer to pair the round by hand
    # (VCL4THP Q63, `create_round_by_hand/1`); the words are the same.
    {:error,
     {:no_legal_pairing,
      ainalrami_scoped(
        "Ainalrami found no legal pairing for this round - every remaining player would have to repeat an opponent or take a forbidden colour. #{Exception.message(e)}",
        category_name
      )}}
  end

  # What the round's account records about bye exclusions: the ranks the
  # engine was told to keep from the bye, and the player whose exclusion the
  # arbiter lifted for this round. Empty - so the stored account is exactly
  # what it was before the feature - when there was none of either.
  defp bye_exclusion_account(engine_opts, lifted) do
    %{}
    |> then(fn m ->
      case engine_opts[:bye_exclusions] do
        excluded when excluded not in [nil, []] -> Map.put(m, :bye_exclusions, excluded)
        _ -> m
      end
    end)
    |> then(fn m -> if lifted, do: Map.put(m, :bye_exclusion_lifted, lifted), else: m end)
  end

  # Whether the arbiter's "only if possible" wishes changed the round: the
  # same field paired again with no wishes, everything else - bye exclusions
  # included - as it was. Soft pairs are not part of C.04.3 (Ainalrami's
  # README lists them under "Organiser deviations"): even the weak position,
  # below every quality criterion, replaces the Dutch system's own last word
  # ("generated earlier") among equally good pairings, so a round they moved
  # is not the round a FIDE checker reproduces. Only run when there are
  # wishes, so a tournament without any pays nothing for it.
  #
  # Compared as the set of boards with their colours; board order is not a
  # pairing decision. A second run that fails - it has fewer constraints
  # than the first, so it should not - counts as moved: a round that cannot
  # be shown to be the FIDE one is not claimed to be.
  defp soft_pairs_moved?(players, raw_pairs, engine_opts, tournament) do
    if (engine_opts[:soft_pairs] || []) == [] do
      false
    else
      plain =
        Ainalrami.Pairing.pair_next_round(players, Keyword.put(engine_opts, :soft_pairs, []))

      Enum.sort(plain) != Enum.sort(raw_pairs)
    end
  rescue
    e ->
      Logger.warning(
        "Ainalrami could not pair tournament #{tournament.id} without its soft pairs to compare: #{Exception.message(e)}"
      )

      true
  end

  # Who the organiser's bye exclusions passed over for the bye, in the order
  # they would have had it - the ranks `explain_round/3` reports as a
  # bracket's `bye_passed_over`, by the same chain: pair the round with no
  # exclusion, and while the bye lands on an excluded player, exclude just
  # the ones found so far and pair again. Empty when the exclusions changed
  # nothing, and without a single extra run when none is in force or the
  # round has no bye.
  #
  # Worked out here, in the click, rather than read off `explain_round/3`
  # as it used to be: that call moved after the round is saved, and a round
  # whose bye an exclusion moved is stamped as leaving the FIDE rules
  # (`pairing_deviations/2`) the moment it is. The later account is asked
  # not to repeat the chain (`bye_passed_over: false`) and carries this
  # list instead, so the record and the stamp are one answer.
  #
  # A run that fails stops the chain where it got to, as the engine's does.
  defp bye_passed_over(players, raw_pairs, engine_opts, tournament) do
    excluded = engine_opts[:bye_exclusions] || []
    holder = Enum.find_value(raw_pairs, fn {w, b} -> if is_nil(b), do: w end)

    if excluded == [] or is_nil(holder) do
      []
    else
      passed_over_chain(players, engine_opts, MapSet.new(excluded), [])
    end
  rescue
    e ->
      Logger.warning(
        "Ainalrami could not pair tournament #{tournament.id} without its bye exclusions to compare: #{Exception.message(e)}"
      )

      []
  end

  defp passed_over_chain(players, engine_opts, excluded, passed) do
    pairs =
      Ainalrami.Pairing.pair_next_round(
        players,
        Keyword.put(engine_opts, :bye_exclusions, Enum.reverse(passed))
      )

    holder = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

    if MapSet.member?(excluded, holder) and holder not in passed,
      do: passed_over_chain(players, engine_opts, excluded, [holder | passed]),
      else: Enum.reverse(passed)
  rescue
    Ainalrami.Pairing.NoValidPairingError -> Enum.reverse(passed)
  end

  defp ainalrami_bye_to_zero({white, nil}), do: {white, 0}
  defp ainalrami_bye_to_zero({white, black}), do: {white, black}

  defp ainalrami_scoped(message, nil), do: message
  defp ainalrami_scoped(message, category_name), do: "#{message} (category \"#{category_name}\")"

  # The line codes TRF16 itself defines: the two record types and every
  # header `Ainalrami.Trf` writes. Anything else in a generated file is an
  # EXTENSION - a line carrying a rule on top of the format - and is what
  # `ainalrami_unsupported_extensions/1` below has to account for.
  @trf16_line_codes ~w(001 013 012 022 032 042 052 062 072 082 092 102 112 122 132 142 182)

  # Which extension lines this integration actually carries through to the
  # engine. Not "which ones Ainalrami's PARSER reads" - it reads more than
  # this - but which ones reach `Ainalrami.Pairing.pair_next_round/2` as
  # something it will act on:
  #
  #   * `XXR` - the round count, read back off the file by `run_ainalrami/4`
  #     and passed as `expected_rounds`. (`142` is the same field under
  #     TRF16's own spelling and is on the TRF16 list above; `serialize/2`
  #     writes one or the other, never both.)
  #   * `XXP`, `260` - forbidden pairings and club/federation exclusions,
  #     passed as `forbidden_pairs`.
  #   * `XXA`, `250` - Baku virtual points, which the engine reads straight
  #     off each parsed player's `:accelerations`.
  #   * `BB*`, `162` - what a result is worth. Carried by
  #     `Tournament.engine_point_system/1`, which is the same tournament
  #     record the line would have been written from, so the file and the
  #     option cannot disagree.
  #   * `XXC`, `152` - the initial colour drawn by lot, in the extension
  #     spelling (what `engine_trf/6` writes, `xxc: true`) and TRF16's. `parse/1`
  #     reads either into `tournament[:initial_colour]`, and
  #     `ainalrami_opts/3` passes that as `:initial_colour` - the OPTION
  #     `pair_next_round/2` actually acts on.
  #
  # Both were deliberately kept OFF this list until 2026-09-13, and why is
  # the guard's whole point: Ainalrami takes the initial colour as an option
  # only, `run_ainalrami/5` did not pass it, and the engine would have
  # inferred round one's colours instead of honouring the draw the file
  # states. The line went into `engine_trf/6` and the option into
  # `ainalrami_opts/3` in the same change that added them here; one without
  # the other would pair every board of round one the wrong way round after a
  # Black draw, silently.
  #
  # `XXP`/`XXA` were added upstream precisely because this integration
  # surfaced their absence. Before that, Ainalrami's parser discarded them as
  # unknown header codes - measured on its own fuzz corpus, a 20% forbidden
  # rate meant 27.72% of rounds seated a pair the arbiter had excluded, and
  # that figure was its ENTIRE disagreement with bbpPairings on that axis.
  @ainalrami_supported_extensions ~w(XXR XXP XXA XXC 250 260 162 152 BBW BBD BBL BBZ BBF BBU)

  # The extension codes in `trf` that Ainalrami would parse and then not act
  # on. Checked against the generated TRF itself rather than against the
  # tournament's settings, so it stays true by construction: any extension
  # line this pipeline learns to emit in future is caught here without
  # anyone remembering to update a second list.
  #
  # This guard is not tidiness, and it stays even though every extension the
  # app currently emits is supported. An extension line carries a RULE -
  # `XXP` the arbiter's forbidden pairings, `XXA` the acceleration's virtual
  # points - and an engine that ignores one still returns a complete,
  # entirely legal-looking pairing that just happens to break it. There is
  # nothing downstream that could notice the difference, so refusing to pair
  # is the only safe answer, and it has to be the DEFAULT for anything not
  # explicitly known to work.
  #
  # It used to look only at lines beginning `XX`, which was the whole
  # extension vocabulary while this file hand-built its own extension lines
  # and could only hand-build those. `Ainalrami.Trf.serialize/2` writes the
  # numeric and `BB*` extensions too, from keys in the map it is given, so
  # the scan has to cover everything that is not TRF16 - otherwise the first
  # non-`XX` extension key anyone adds to `engine_trf/5` passes a guard that
  # is not looking at it.
  defp ainalrami_unsupported_extensions(trf) do
    trf
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&String.slice(&1, 0, 3))
    |> Enum.reject(&(&1 in @trf16_line_codes))
    |> Enum.reject(&(&1 in @ainalrami_supported_extensions))
    |> Enum.uniq()
  end

  defp ainalrami_unsupported_message(codes, category_name) do
    reasons = Enum.map_join(codes, "; ", &"the TRF extension #{&1}")

    ainalrami_scoped(
      "Ainalrami does not implement #{reasons}. Nothing was paired - Ainalrami would have ignored the rule rather than applied it.",
      category_name
    )
  end

  # `player_by_local_rank` is `do_pair_single/4`'s local 1..M rank map
  # (inverse of `local_rank_by_player_id`), NOT global `pairing_number` - see
  # that function's doc comment for why. The engine's output pairs are starting
  # ranks in whatever numbering it was given, so the lookup here must use
  # the exact same map that was fed into `trf_input/5`.
  ## ---------- the engine's own account of the round ----------

  # Turns what `Ainalrami.Pairing.explain_round/3` reports into something a
  # round row can hold and a page can read years later.
  #
  # Two translations matter. First, RANKS: the engine speaks in the local
  # contiguous numbering the TRF was built in, which is an artefact of who
  # was in the field that day and means nothing once the roster changes.
  # Everything is stored as player ids instead. Second, SHAPE: the report is
  # full of tuples (`{a, b}` pairs, `{label, value}` rungs) and a `:map`
  # column is JSON, where tuples do not exist - so pairs become two-element
  # lists and rungs become labelled maps.
  #
  # Returns nil when no section has anything to report, so such a round
  # stores nothing at all rather than an empty husk that reads, to the page,
  # like an explanation that came back blank.
  defp explanation_payload(sections) do
    built =
      sections
      |> Enum.flat_map(fn
        {_category_name, nil, _by_rank} ->
          []

        {category_name, account, by_rank} ->
          account = if is_list(account), do: %{brackets: account}, else: account
          floats_by_group = account |> Map.get(:floats, []) |> Enum.group_by(& &1.group)

          [
            %{
              "category" => category_name,
              "brackets" =>
                Enum.map(
                  account.brackets,
                  &bracket_json(&1, by_rank, Map.get(floats_by_group, &1.group, []))
                ),
              "bye" => bye_json(Map.get(account, :bye), by_rank)
            }
            |> put_bye_exclusions(account, by_rank)
            |> put_on_demand(account, by_rank)
          ]
      end)

    on_demand? = Enum.any?(built, &Map.has_key?(&1, "pairs"))

    case built do
      [] ->
        nil

      # Version 4 (2026-09-28): the alternatives are not in the record. Each
      # section carries the pairs the engine made instead ("pairs", player
      # ids, board order) and who had the bye, and each question is worked
      # out from those when somebody opens it (`open_alternative/4`), kept
      # in `round_alternatives` against the record's "job".
      sections when on_demand? ->
        %{
          "engine" => "ainalrami",
          "version" => 4,
          "alternatives" => "on_demand",
          "sections" => sections
        }

      # Version 2 (2026-09-06) added, per bracket, the state the pairing was
      # made FROM - subgroups, colour states, excluded pairs. Version 3 (the
      # same day) adds the alternatives: for every float and for the bye,
      # what each other candidate would have cost. An older record simply
      # lacks the keys, and `PairingsEngine.RoundExplanation` reads them as
      # empty rather than refusing the round.
      sections ->
        %{"engine" => "ainalrami", "version" => 3, "sections" => sections}
    end
  end

  # A version-4 section: the pairs its questions are worked out from, and
  # the bye holder the bye's question is about. The brackets lose their
  # always-empty "float_alternatives": the answers live elsewhere.
  defp put_on_demand(section, %{pairs_played: pairs}, by_rank) do
    section
    |> Map.put(
      "pairs",
      Enum.map(pairs, fn {w, b} -> [player_id(w, by_rank), player_id(b, by_rank)] end)
    )
    |> Map.put(
      "bye_holder",
      Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: player_id(w, by_rank) end)
    )
    |> Map.update!("brackets", fn brackets ->
      Enum.map(brackets, &Map.delete(&1, "float_alternatives"))
    end)
  end

  defp put_on_demand(section, _account, _by_rank), do: section

  # The organiser's bye exclusions, when the round had any (not a FIDE rule):
  # who was excluded, who was passed over for the bye because of it - the
  # engine's own account, in the order they would have had it - and whose
  # exclusion the arbiter lifted for this round. Absent otherwise, so a
  # round paired without exclusions stores exactly what it always did.
  # `"soft_pairs_moved"` rides along for the same reason: set only when the
  # arbiter's "only if possible" wishes changed the round
  # (`soft_pairs_moved?/4`), the other organiser deviation the round's
  # record has to keep.
  #
  # The passed-over list comes from the account itself when the pairing
  # click worked it out (`bye_passed_over/4`, ranks), and from the engine's
  # brackets otherwise (`reexplain_round/2`, `deepen_round/2`).
  defp put_bye_exclusions(section, account, by_rank) do
    passed_over =
      case Map.fetch(account, :bye_passed_over) do
        {:ok, ranks} when is_list(ranks) ->
          ranks

        _ ->
          account.brackets
          |> Enum.flat_map(&Map.get(&1, :bye_passed_over, []))
          |> Enum.map(& &1.rank)
      end
      |> Enum.map(&player_id(&1, by_rank))

    section
    |> put_unless_empty(
      "bye_exclusions",
      player_ids(Map.get(account, :bye_exclusions, []), by_rank)
    )
    |> put_unless_empty("bye_passed_over", passed_over)
    |> put_unless_empty("bye_exclusion_lifted", Map.get(account, :bye_exclusion_lifted))
    |> put_unless_empty("soft_pairs_moved", Map.get(account, :soft_pairs_moved))
    |> put_bye_preference(account, by_rank)
  end

  # What the players' bye preferences (not a FIDE rule) did in this round,
  # in player ids: whether they changed it, which setting decided the bye,
  # who would have had it without them, the extra players they kept from
  # the bye (so the account can be rebuilt under the same rules), and what
  # happened to each preference. Absent when the round had none.
  defp put_bye_preference(section, %{bye_preference: %{} = pref}, by_rank) do
    id = &player_id(&1, by_rank)

    Map.put(section, "bye_preference", %{
      "moved" => pref.moved,
      "bye" => pref.bye && id.(pref.bye),
      "decided_by" => pref.decided_by && Atom.to_string(pref.decided_by),
      "fide_bye" => pref.fide_bye && id.(pref.fide_bye),
      "exclusions" => pref.exclusions |> Enum.map(id) |> Enum.reject(&is_nil/1),
      "outcomes" =>
        Enum.map(pref.outcomes, fn o ->
          %{
            "player" => id.(o.rank),
            "preference" => Atom.to_string(o.preference),
            "outcome" => Atom.to_string(o.outcome)
          }
          |> put_unless_empty("reason", o[:reason] && Atom.to_string(o.reason))
          |> put_unless_empty("with", o[:with] && Atom.to_string(o.with))
          |> put_unless_empty("holder", o[:holder] && id.(o.holder))
        end)
    })
  end

  defp put_bye_preference(section, %{bye_preference_json: %{} = json}, _by_rank),
    do: Map.put(section, "bye_preference", json)

  defp put_bye_preference(section, _account, _by_rank), do: section

  # The extra players a round's recorded bye preferences kept from the bye,
  # as the rebuilt field's ranks - added to its exclusions, so an account
  # rebuilt later judges the round under the rules it was paired by.
  defp recorded_preference_exclusions(sections, rank_by_id) when is_list(sections) do
    sections
    |> Enum.flat_map(&(get_in(&1, ["bye_preference", "exclusions"]) || []))
    |> Enum.flat_map(&List.wrap(Map.get(rank_by_id, &1)))
  end

  defp recorded_preference_exclusions(_sections, _rank_by_id), do: []

  # Re-explaining reads the boards as played and does not pair the round
  # again, so it cannot tell what the preferences did; what pairing time
  # found is kept, as `keep_soft_pairs_moved/2` keeps the wishes'.
  defp keep_bye_preference(%{"sections" => [first | rest]} = payload, %{"sections" => old})
       when is_list(old) do
    case Enum.find_value(old, & &1["bye_preference"]) do
      nil -> payload
      pref -> %{payload | "sections" => [Map.put(first, "bye_preference", pref) | rest]}
    end
  end

  defp keep_bye_preference(payload, _old), do: payload

  defp put_unless_empty(map, _key, value) when value in [nil, []], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp bracket_json(bracket, by_rank, float_alternatives) do
    %{
      # "Why did HE float and not me": one entry per player who floated out
      # of this bracket, each with a verdict for every other member.
      "float_alternatives" => Enum.map(float_alternatives, &alternative_json(&1, by_rank)),
      "group" => bracket.group,
      "mdps" => player_ids(bracket.mdps, by_rank),
      "residents" => player_ids(bracket.residents, by_rank),
      "floats" => player_ids(bracket.floats, by_rank),
      "pairs" =>
        Enum.map(bracket.pairs, fn {a, b} -> [player_id(a, by_rank), player_id(b, by_rank)] end),
      "edge_count" => Map.get(bracket, :edge_count),
      # Per-board attribution: which pair carries which criterion's cost.
      # The engine reports one rung vector per edge, in `pairs` order and
      # then the cross edges the floats leave on, and the bracket's own
      # rungs are their column-wise sum.
      #
      # The cross edges are kept rather than dropped, tagged "float". They
      # are a lower bracket's boards, so they will appear again there - but
      # without them the per-board rows would not add up to the bracket
      # total sitting right above them, and a reader checking the arithmetic
      # would be right to distrust the whole panel.
      "edges" => edges_json(bracket, by_rank),
      # Only the criteria that actually scored. A bracket reports every rung
      # on the ladder and most are zero; keeping them all would triple the
      # stored size to say "this criterion did not come into it".
      "rungs" =>
        bracket.rungs
        |> Enum.reject(fn {_label, value} -> value == 0 end)
        |> Enum.map(fn {label, value} -> %{"label" => label, "value" => value} end),
      # ---- what the bracket was paired FROM (Ainalrami >= 0.18) ----
      #
      # Everything above is the outcome. These are the inputs to it: the
      # S1/S2 the engine paired off, each player's colour and float state,
      # and the pairs the absolute criteria removed before the search began.
      # The removed pairs are the ones that answer "why am I not playing
      # him", which is the only question this record is ever opened for.
      #
      # `Map.get` with defaults rather than `bracket.s1`: an older engine
      # simply does not report these, and a missing key must degrade to
      # "not recorded", never to a crash inside a pairing transaction.
      "heterogeneous" => Map.get(bracket, :heterogeneous?, false),
      "s1" => player_ids(Map.get(bracket, :s1, []), by_rank),
      "s2" => player_ids(Map.get(bracket, :s2, []), by_rank),
      "states" => states_json(Map.get(bracket, :states, []), by_rank),
      "exclusions" => exclusions_json(Map.get(bracket, :exclusions, []), by_rank)
    }
  end

  # One row per bracket member. Atoms become strings here because this is
  # stored as JSON and read back by a module that never sees the engine.
  defp states_json(states, by_rank) do
    states
    |> Enum.map(fn state ->
      %{
        "player" => player_id(state.rank, by_rank),
        "colours" => state.colours,
        "whites" => state.whites,
        "blacks" => state.blacks,
        "difference" => state.difference,
        "preference" => state.preference,
        "class" => Atom.to_string(state.class),
        "repeated" => state.repeated,
        "floated_last_round" => float_json(state.floated_last_round),
        "floated_round_before" => float_json(state.floated_round_before)
      }
    end)
    |> Enum.reject(&is_nil(&1["player"]))
  end

  defp float_json(dir) when dir in [:up, :down], do: Atom.to_string(dir)
  defp float_json(_), do: nil

  defp bye_json(nil, _by_rank), do: nil

  defp bye_json(bye, by_rank) do
    bye
    |> alternative_json(by_rank)
    |> Map.put("holder", player_id(bye.holder, by_rank))
    |> Map.put("group", bye.group)
    |> Map.delete("floater")
  end

  defp alternative_json(%{skipped: why} = entry, by_rank) do
    %{
      "floater" => player_id(Map.get(entry, :floater), by_rank),
      "skipped" => Atom.to_string(why),
      "count" => entry.count
    }
  end

  defp alternative_json(entry, by_rank) do
    %{
      "floater" => player_id(Map.get(entry, :floater), by_rank),
      "candidates" =>
        entry.candidates
        |> Enum.map(&candidate_json(&1, by_rank))
        |> Enum.reject(&is_nil(&1["player"]))
    }
  end

  defp candidate_json(candidate, by_rank) do
    %{
      "player" => player_id(candidate.rank, by_rank),
      "outcome" => Atom.to_string(candidate.outcome),
      "reason" => candidate |> Map.get(:reason) |> reason_json(),
      "at" => candidate |> Map.get(:differs_at) |> differs_json(),
      "fate" => candidate |> Map.get(:fate) |> fate_json(by_rank),
      "stayed" => Map.get(candidate, :floater_stayed?)
    }
  end

  defp reason_json(nil), do: nil
  defp reason_json(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_json(reason) when is_binary(reason), do: reason

  defp differs_json(nil), do: nil

  defp differs_json(at) do
    %{
      "group" => at.group,
      "label" => Map.get(at, :label),
      "actual" => Map.get(at, :actual),
      "alternative" => Map.get(at, :alternative),
      "lex" => at |> Map.get(:lex) |> then(&if(&1, do: Atom.to_string(&1)))
    }
  end

  defp fate_json(nil, _by_rank), do: nil

  defp fate_json(fate, by_rank) do
    %{
      "opponent" => fate.opponent && player_id(fate.opponent, by_rank),
      "score" => fate.score
    }
  end

  defp exclusions_json(exclusions, by_rank) do
    exclusions
    |> Enum.map(fn %{players: [a, b]} = x ->
      %{
        "players" => [player_id(a, by_rank), player_id(b, by_rank)],
        "reason" => Atom.to_string(x.reason),
        "round" => Map.get(x, :round),
        "colour" => Map.get(x, :colour)
      }
    end)
    |> Enum.reject(fn x -> Enum.any?(x["players"], &is_nil/1) end)
  end

  # The six criteria whose value can be read as a verdict about ONE board,
  # kept even when zero because zero is the whole point: every one of these
  # is phrased so that higher is better, so a 0 is the board where something
  # was given up, and a filtered-out 0 is indistinguishable from a criterion
  # the engine never reported.
  #
  # The rest of the ladder is deliberately NOT in here. C7, C8 and C19-C21
  # are score-scale magnitudes the matcher ranks candidates by, not
  # statements about a board, and C14/C16 REWARD pairing a recent
  # downfloater rather than penalising anything - a zero there means this
  # board did not happen to pair one, which is not a compromise and must
  # never be rendered as one.
  @board_verdicts [
    "C10 topscorer colour diff",
    "C11 topscorer same colour x3",
    "C12 colour preference",
    "C13 strong colour preference",
    "C15 upfloat repeat r-1",
    "C17 upfloat repeat r-2"
  ]

  defp edges_json(bracket, by_rank) do
    kept = length(bracket.pairs)

    bracket
    |> Map.get(:edge_rungs, [])
    |> Enum.with_index()
    |> Enum.map(fn {{{a, b}, rungs}, index} ->
      %{
        "players" => [player_id(a, by_rank), player_id(b, by_rank)],
        "kind" => if(index < kept, do: "pair", else: "float"),
        "rungs" =>
          rungs
          |> Enum.filter(fn {label, value} -> value != 0 or label in @board_verdicts end)
          |> Enum.map(fn {label, value} -> %{"label" => label, "value" => value} end)
      }
    end)
  end

  defp player_ids(ranks, by_rank), do: Enum.map(ranks, &player_id(&1, by_rank))

  # A rank with no player behind it should be impossible - the map is built
  # over the same roster the TRF was - but a nil here would be a crash on a
  # page rendering an explanation, so an unknown rank is simply dropped from
  # the account rather than taking the page down with it.
  defp player_id(0, _by_rank), do: nil
  defp player_id(nil, _by_rank), do: nil

  defp player_id(rank, by_rank) do
    case Map.get(by_rank, rank) do
      nil -> nil
      player -> player.id
    end
  end

  # `boards` is `plan_boards/1`'s: `{board, white, black}`, `black` nil for
  # the pairing-allocated bye.
  defp create_round(
         boards,
         tournament,
         next_number,
         round_absentees,
         explanation
       ) do
    pairing_allocated_bye? = Enum.any?(boards, fn {_board, _white, black} -> is_nil(black) end)

    paired_players =
      for {_board, white, black} <- boards, player <- [white, black], player != nil, do: player

    Repo.transaction(fn ->
      published_at = Tournaments.compute_published_at(tournament, next_number)

      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing",
          published_at: published_at,
          publish_due_at: Tournaments.due_publish_at(published_at),
          explanation: explanation,
          virtual_points: virtual_points_used(tournament, paired_players)
        })

      insert_boards(round, boards)

      insert_round_absentee_byes(tournament, next_number, round_absentees)

      # A pairing-allocated bye's pairing row is created with its result
      # ("bye") already set, awarding points immediately without ever going
      # through Tournaments.update_pairing_result/2 - the same
      # point-changing-write gap as insert_round_absentee_byes/3 above. See
      # docs/manual-standings.md (Fix 3).
      if pairing_allocated_bye?, do: Tournaments.invalidate_manual_ranking(tournament.id)

      if tournament.swiss_match_format do
        leg1_pairings =
          Repo.all(from p in Pairing, where: p.round_id == ^round.id, order_by: p.id)

        create_mirrored_leg(
          tournament,
          leg1_pairings,
          round_absentees,
          next_number + 1,
          round.virtual_points
        )
      else
        round
      end
    end)
  end

  # `swiss_match_format`'s second leg: same match, same boards, colours
  # reversed - an exact mirror of leg 1's freshly-inserted pairings, built
  # from Elixir data (no second engine call, no new TRF file). See the
  # field's doc comment on PairingsEngine.Tournaments.Tournament and the
  # module doc above `do_pair/2`.
  #
  # No extra `Tournaments.invalidate_manual_ranking/1` call is needed here:
  # every bye-type row leg 2 introduces (pairing-allocated or
  # requested-zero) is a mirror of a leg-1 event that already triggered its
  # own invalidation call above (pairing-allocated) or in
  # `insert_round_absentee_byes/3` (requested-zero, called by `do_pair/2`
  # before this transaction even starts) - `manual_ranking_stale` is a
  # single boolean flag, not per-round, so re-firing it for the mirrored
  # row would be a harmless but redundant broadcast-adjacent write.
  #
  # Leg 2 is leg 1 played again, so it records leg 1's virtual points: the
  # history the next match's `XXA` line carries says both legs were paired
  # on the same scores.
  defp create_mirrored_leg(tournament, leg1_pairings, round_absentees, leg2_number, virtual) do
    leg2_published_at = Tournaments.compute_published_at(tournament, leg2_number)

    leg2 =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: leg2_number,
        status: "playing",
        published_at: leg2_published_at,
        publish_due_at: Tournaments.due_publish_at(leg2_published_at),
        virtual_points: virtual
      })

    Enum.each(leg1_pairings, fn p ->
      {white_id, black_id} =
        if p.black_player_id do
          # Ordinary pairing - same board, colours swapped.
          {p.black_player_id, p.white_player_id}
        else
          # Pairing-allocated bye - no colour to swap, same player earns
          # `bye_value` again for this leg (deliberate: a match-format bye
          # is two bye-legs, not one).
          {p.white_player_id, nil}
        end

      Repo.insert!(%Pairing{
        round_id: leg2.id,
        board: p.board,
        white_player_id: white_id,
        black_player_id: black_id,
        result: if(black_id, do: "", else: "bye")
      })
    end)

    # Round-specific absentees sit out both legs identically - see the
    # module doc above `do_pair/2` for the deliberate scope limitation
    # (leg 2's absentee set is leg 1's, not independently re-evaluated).
    unless round_absentees == [] do
      rows =
        Enum.map(round_absentees, fn player ->
          %{
            tournament_id: tournament.id,
            player_id: player.id,
            round: leg2_number,
            type: "absent"
          }
        end)

      Repo.insert_all("byes", rows, on_conflict: :nothing)
    end

    Tournaments.freeze_round_display_boards!(leg2.id)

    leg2
  end

  ## ---------- the engine's TRF input ----------

  @doc """
  Builds the TRF text the engine takes as input (TRF16 + XXR/XXA/XXP extensions).

  `rank_by_player_id` is an optional override, same idea as
  `forbidden_pairs/3`/`exclusion_pairs/3`'s own override: when
  `nil` (every existing caller's behaviour, unaffected), player rows/games
  keep using each player's raw global `pairing_number` exactly as before.
  `do_pair_single/4` passes a local contiguous 1..M rank map instead (built
  over the full frozen roster), so a gap in the middle of the global
  `pairing_number` range - an absent player excluded from THIS round only,
  not from the tournament's frozen numbering - never reaches the engine as
  a gap in the TRF's starting-rank sequence. See the `do_pair_single/4` doc
  comment for the full story.

  `eligible_ids`, when given, is a `MapSet` of the player ids that are
  actual pairing candidates for the round about to be paired. Every other
  player in `players` gets a `0000 - Z` line appended via
  `mark_ineligible_for_round/2` instead - the TRF-native way to keep a
  player's real history in the file while excluding them from pairing this
  run. The pairing path (`do_pair_single/4`/`build_category_trf/5`) uses this
  to send the engine the full roster while still only offering the actually-
  eligible players as candidates. `nil` (every existing caller, including
  tests and `PairingsEngine.TrfExport`-adjacent callers) skips this step
  entirely, so behaviour is byte-identical when omitted.
  """
  def trf_input(
        tournament,
        players \\ nil,
        rank_by_player_id \\ nil,
        eligible_ids \\ nil,
        shared_history \\ nil
      ) do
    players = players || active_players(tournament.id)
    trf_players = trf_player_rows(tournament, players, shared_history)

    trf_players =
      if eligible_ids do
        mark_ineligible_for_round(trf_players, eligible_ids)
      else
        trf_players
      end

    trf_players =
      if rank_by_player_id do
        # `remap_trf_rows_to_local_ranks/2` only rewrites each row's `:rank`
        # field - it preserves `trf_players`' own list order, and
        # `Trf.serialize/1` writes rows in list order verbatim. The rows go
        # in rank order so the file reads in the order its ranks say. The
        # pairing runs number by pairing number (`in_pairing_number_order/1`,
        # which says why the rank must be the TPN); a caller passing another
        # map still gets a file whose rows follow it.
        trf_players
        |> remap_trf_rows_to_local_ranks(rank_by_player_id)
        |> Enum.sort_by(& &1.rank)
      else
        trf_players
      end

    engine_trf(
      tournament,
      trf_players,
      players,
      rank_by_player_id,
      paired_rounds_count(tournament.id) + 1,
      # nil for a caller with no run history in hand (TRF export, tests):
      # `forbidden_pairs/4` and `exclusion_pairs/6` fall back to reading it
      # themselves, exactly as they always did.
      shared_history && shared_history.forbidden_pairings,
      shared_history && shared_history.pairing_rules
    )
  end

  @doc """
  The forbidden pairings of `tournament_id` as starting-rank groups -
  `[[1, 2], [4, 7]]` - which `Ainalrami.Trf.serialize/2` writes as one `XXP`
  line each. Each pair's player ids are translated to their starting rank
  (`pairing_number`) among `players` for this pairing run. A pair is
  skipped silently if either player isn't in `players` at all, or hasn't
  been assigned a `pairing_number` yet - the engine only needs to hear about
  players it's actually being asked to pair.

  Returns ranks rather than the `"XXP a b\\r\\n"` text it used to, because
  the text was concatenated onto a finished TRF and so was never checked by
  anything - see `engine_trf/5`.

  `rank_by_player_id` defaults to `players`' own global `pairing_number`
  (every existing caller's behaviour, unaffected). Per-category Swiss
  pairing (`do_pair_by_category/3`) passes a category's local 1..M rank map
  instead - a pair naming a player outside the category (which can't
  resolve to a local rank) is dropped by the same nil-rejection below, with
  zero extra logic: they could never be paired against each other anyway.
  """
  def forbidden_pairs(tournament_id, players, rank_by_player_id \\ nil, forbidden \\ nil) do
    rank_by_player_id = rank_by_player_id || Map.new(players, &{&1.id, &1.pairing_number})

    forbidden
    |> hard_forbidden_pairings(tournament_id)
    |> Enum.map(fn fp ->
      {rank_by_player_id[fp.player_a_id], rank_by_player_id[fp.player_b_id]}
    end)
    |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
    |> Enum.map(fn {a, b} -> [a, b] end)
  end

  @doc """
  One starting-rank pair per pair a HARD pairing rule keeps apart in
  `round` (`PairingsEngine.Exclusions.hard_pairs/4` - same club, same
  federation, a group), translated to starting ranks the same way
  `forbidden_pairs/4` does (see that function's doc for the optional
  `rank_by_player_id` override, used by per-category Swiss pairing, and for
  why these are ranks rather than `XXP` text). A pair already covered by an
  explicit forbidden pairing is skipped - the engine doesn't need to hear
  the same rule twice - as is any pair where a player isn't in `players` or
  hasn't been assigned a rank yet.

  `round` nil takes every rule whatever its rounds; `rules` nil reads the
  tournament's own.
  """
  def exclusion_pairs(
        tournament,
        players,
        rank_by_player_id \\ nil,
        forbidden \\ nil,
        round \\ nil,
        rules \\ nil
      ) do
    rank_by_player_id = rank_by_player_id || Map.new(players, &{&1.id, &1.pairing_number})

    explicit_rank_pairs =
      forbidden
      |> hard_forbidden_pairings(tournament.id)
      |> Enum.map(fn fp ->
        {rank_by_player_id[fp.player_a_id], rank_by_player_id[fp.player_b_id]}
      end)
      |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
      |> MapSet.new(&normalize_rank_pair/1)

    rules
    |> pairing_rules(tournament.id)
    |> Exclusions.hard_pairs(players, round, tournament.rounds_count)
    |> Enum.map(fn {a, b} -> {rank_by_player_id[a.id], rank_by_player_id[b.id]} end)
    |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
    |> Enum.map(&normalize_rank_pair/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(explicit_rank_pairs, &1))
    |> Enum.map(fn {a, b} -> [a, b] end)
  end

  defp pairing_rules(nil, tournament_id), do: Tournaments.list_pairing_rules(tournament_id)
  defp pairing_rules(rules, _tournament_id) when is_list(rules), do: rules

  # The run's already-read list, or a read of our own for a caller that has
  # none - TRF export and the tests, which build one file and not one per
  # category.
  defp forbidden_pairings(nil, tournament_id),
    do: Tournaments.list_forbidden_pairings(tournament_id)

  defp forbidden_pairings(list, _tournament_id) when is_list(list), do: list

  # The rows that are RULES. A soft row (`ForbiddenPairing.soft`) is a wish
  # for the engine's ladder, handed over by `soft_pairs/5`; as an `XXP` line
  # it would be a rule, which is the one thing the arbiter said it is not.
  defp hard_forbidden_pairings(forbidden, tournament_id) do
    forbidden
    |> forbidden_pairings(tournament_id)
    |> Enum.reject(& &1.soft)
  end

  @doc """
  The pairs `tournament` would RATHER not see in `round_number`, as
  starting-rank groups in the shape `forbidden_pairs/4` returns - handed to
  Ainalrami as its `:soft_pairs` option rather than written into the TRF,
  because the TRF has no way to say "if you can". Two sources:

    * every forbidden pairing the arbiter marked soft
      (`ForbiddenPairing.soft`), as a pair;
    * every SOFT pairing rule that holds in `round_number`
      (`PairingsEngine.Exclusions.soft_groups/4`): each club, federation or
      group it keeps apart, as one group - "same federation, if possible,
      not in the last two rounds" is C.05 5.2's own example.

  Ranks resolve exactly as in `forbidden_pairs/4`; a player with no rank in
  this run drops out of a group the same way, and a group left with fewer
  than two members is dropped with them. Empty when the tournament has no
  soft rules - and an empty list leaves the engine's ladder untouched, so
  its FIDE behaviour is byte for byte what it was.

  Only the Swiss engine reads this. Keizer has no such rung; for it a wish
  is simply not a rule, and the Options page says so beside the control.
  `rules` nil reads the tournament's own.
  """
  def soft_pairs(tournament, players, rank_by_player_id, forbidden, round_number, rules \\ nil) do
    rank_by_player_id = rank_by_player_id || Map.new(players, &{&1.id, &1.pairing_number})

    explicit =
      forbidden
      |> forbidden_pairings(tournament.id)
      |> Enum.filter(& &1.soft)
      |> Enum.map(fn fp -> [fp.player_a_id, fp.player_b_id] end)

    groups =
      rules
      |> pairing_rules(tournament.id)
      |> Exclusions.soft_groups(players, round_number, tournament.rounds_count)

    (explicit ++ groups)
    |> Enum.map(fn ids -> ids |> Enum.map(&rank_by_player_id[&1]) |> Enum.reject(&is_nil/1) end)
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp normalize_rank_pair({a, b}) when a <= b, do: {a, b}
  defp normalize_rank_pair({a, b}), do: {b, a}

  @doc """
  Every Group-A player's virtual-point history, as
  `%{player_id => [1.0, 1.0, 0.5, ...]}` - one value per round played so
  far, per FIDE C.04.7 Baku Acceleration. `engine_trf/5` hangs each list on
  its player's TRF row, and `Ainalrami.Trf.serialize/2` writes it as
  the fixed-column `XXA` extension line.

  Returns `%{}` unless `tournament.pairing_system == "swiss"` and either
  `tournament.acceleration == "baku"` or the players' extra points feed the
  pairing (`Tournament.extra_points_pairing?/1` - acceleration mode, or a
  counted handicap; docs/extra-points.md): round robin's fixed Berger
  schedule ignores acceleration entirely, and Keizer never goes through
  the Swiss engine at all. Baku takes precedence over extra points; the changeset
  refuses the two together.

  Keyed by player id and not by rank on purpose. This used to emit the line
  itself, and so had to work out which number to label it with - the local
  rank when a pairing run was using one, the global `pairing_number`
  otherwise - independently of the player rows in the same file. Two
  independent answers to one question is a divergence waiting to happen, and
  the failure is silent: an `XXA` line naming a rank the file does not
  contain is a rule the engine cannot apply and cannot report. The row's own
  `:rank` is now the only answer.

  ## The `XXA` line (do not re-guess this)

  A TRF pairing program does **not** compute Baku acceleration on its own
  from a single flag: it is told the fictitious points assigned to each
  player, round by round, on `XXA` lines, and it needs the full record
  because that record determines the floaters history. So **we** compute
  every Group-A player's virtual points for every round played so far
  ourselves, straight from the FIDE C.04.7 text, and hand the engine the
  full history - one column per round.

  The format: `"XXA NNNN pp.p pp.p ..."`, `XXA` at column 1, `NNNN` (the
  player's starting rank) from column 5, and each `pp.p` at column
  `10 + 5*(r-1)` (`r` = round). It is **fixed-column**, unlike the
  free-form `XXR`/`XXP` lines beside it: a free-form
  `"XXA 1 1.0 1.0\\r\\n"` line crashed the external engine this app used
  to run. Those columns are `Ainalrami.Trf`'s `@xxa_rank_cols` and
  `xxa_points_cols/1`, checked against bbpPairings' own reader - which is
  what caught the rank field being one column too wide here, an error the
  first reader tolerated for as long as it was the only one.

  ## FIDE C.04.7 Baku Acceleration, as implemented here

  Group A (the group that receives virtual points) is the top half of the
  field by starting rank (`pairing_number`), rounded up to the nearest even
  number of players - FIDE's `2 * ceil(n/4)` - over the starting list round
  1 was paired from, and fixed then for the whole event: every player
  numbered up to `baku_group_a_last/2`. Group A does not grow at the bottom
  when somebody joins (C.04.7 1.3.2); a late entrant numbered above its last
  player (`late_entry_numbering` "rating") is in it, the line having moved
  down with that player (`ensure_pairing_numbers/2`). Group B never receives points.

  "Accelerated rounds" are the first `ceil(rounds_count/2)` rounds. Within
  those, Group A gets 1.0 virtual point per round for the first half
  (rounded up) of the accelerated span, then 0.5 for the remainder, then 0
  forever after - this is the FIDE worked example verbatim: *"In a
  nine-round tournament, the accelerated rounds are five. The players in GA
  are assigned one virtual point in the first three rounds, and half
  virtual point in the next two rounds."*
  """
  def accelerations(tournament, players, current_round)

  def accelerations(
        %Tournament{acceleration: "baku", pairing_system: "swiss"} = tournament,
        players,
        current_round
      )
      when is_integer(current_round) and current_round > 0 do
    ranked =
      players
      |> Enum.filter(&(&1.pairing_number != nil))
      |> Enum.sort_by(& &1.pairing_number)

    # Group-A membership is a tournament-wide FIDE concept computed from
    # GLOBAL starting rank, frozen for the tournament - so it is decided
    # here even for a pairing run that renumbers its rows locally. Which
    # NUMBER the resulting line carries is a separate question, and no
    # longer this function's: see the moduledoc.
    #
    # Frozen at round 1 (`baku_group_a_last/2`), not counted over whoever
    # holds a number today: a late entrant, numbered when they join, used to
    # grow Group A part-way through - and be handed virtual points for
    # rounds already played.
    group_a_last = baku_group_a_last(tournament, ranked)

    accelerated_rounds = ceil_div(tournament.rounds_count, 2)
    first_stage_rounds = ceil_div(accelerated_rounds, 2)

    points =
      Enum.map(1..current_round, &virtual_points(&1, accelerated_rounds, first_stage_rounds))

    ranked
    |> Enum.filter(&(group_a_last != nil and &1.pairing_number <= group_a_last))
    |> Map.new(&{&1.id, points})
  end

  # Extra points as virtual points - acceleration mode always, handicap mode
  # while the points count (`Tournament.extra_points_pairing?/1`). See
  # `extra_point_accelerations/3`.
  def accelerations(%Tournament{} = tournament, players, current_round)
      when is_integer(current_round) and current_round > 0 do
    if Tournament.extra_points_pairing?(tournament),
      do: extra_point_accelerations(tournament, players, current_round),
      else: %{}
  end

  def accelerations(_tournament, _players, _current_round), do: %{}

  # Every player's extra points as an `XXA` history, one value per round
  # 1..`current_round` - the same shape Baku's list has, and for the same
  # reason: the engine judges a float by the two scores AS THE BRACKETS SAW
  # THEM in that round, virtual points included, so each past round needs
  # the value it was paired with and not the player's value today. SWAR does
  # the same (`EcrireXXA_AccelereManuel` writes each round's `ROUND.XtraPts`,
  # frozen when the round was set up).
  #
  # A round already paired gives its recorded `virtual_points` (a player
  # missing from it - absent, not yet entered, or on nothing - had none,
  # which is what SWAR writes for an absent round too). A round paired before
  # that column existed, or by hand, has none recorded and reads the
  # player's current extra points: the closest answer there is. The round
  # being paired, which has no row yet, is the player's current value.
  #
  # A player whose whole history is zero gets no line at all, so a
  # tournament where nobody holds extra points hands the engine exactly the
  # file it always did.
  defp extra_point_accelerations(tournament, players, current_round) do
    recorded = recorded_virtual_points(tournament.id)

    players
    |> Enum.filter(&(&1.pairing_number != nil))
    |> Enum.flat_map(fn p ->
      key = to_string(p.id)
      current = virtual_value(p.extra_points)

      points =
        Enum.map(1..current_round, fn round ->
          case Map.fetch(recorded, round) do
            {:ok, %{} = by_player} -> virtual_value(Map.get(by_player, key))
            _legacy_or_unpaired -> current
          end
        end)

      if Enum.all?(points, &(&1 == 0.0)), do: [], else: [{p.id, points}]
    end)
    |> Map.new()
  end

  # Virtual points are never negative. A negative extra point is a penalty,
  # and it still counts in the standings, but a TRF reader cannot read one in an
  # `XXA` slot: measured 2026-09-27 on a real SWAR file whose player was
  # given -1.0 in one round, the external engine this app used to run died
  # with `NumberFormatException: For input string: "0-1.0"` and paired
  # nothing, and a FIDE checker replaying the file would fare no better. A round's recorded value (a
  # SWAR import can bring a negative one) is kept as it came - the export
  # writes it back - and floored only here, on its way to the engine.
  defp virtual_value(nil), do: 0.0
  defp virtual_value(points) when points < 0, do: 0.0
  defp virtual_value(points), do: points / 1

  defp recorded_virtual_points(tournament_id) do
    Repo.all(
      from r in Round,
        where: r.tournament_id == ^tournament_id,
        select: {r.number, r.virtual_points}
    )
    |> Map.new()
  end

  @doc """
  The extra points `players` are paired with in the round about to be
  paired, as `rounds.virtual_points` stores them - `%{"player id" =>
  points}`, non-zero entries only, `%{}` when the tournament does not pair
  on extra points. Recorded with the round so every later round's `XXA`
  history carries what this one was actually paired with.
  """
  def virtual_points_used(tournament, players) do
    if Tournament.extra_points_pairing?(tournament) do
      for p <- players, p != nil, virtual_value(p.extra_points) != 0.0, into: %{} do
        {to_string(p.id), virtual_value(p.extra_points)}
      end
    else
      %{}
    end
  end

  @doc """
  The pairing number of the last Group-A player of a Baku-accelerated
  tournament (FIDE C.04.7) - Group A is every player numbered up to and
  including it - or nil when there is nobody to put in it.

  C.04.7 1.2 splits "the list of participants to be paired" before round
  1: Group A is the first half of them, rounded up to an even number,
  `2 * ceil(N/4)`. N is the players round 1 is paired from - every player
  holding a pairing number when round 1 is paired. Somebody absent from
  round 1 (a requested bye, an absence, a later start round) holds none
  then: C.04.2 2.4 makes them a Late Entry, "given an appropriate TPN and
  paired only when they actually arrive", so they are not in N
  (`late_entry_numbering_pool/3`, `release_late_round_one_absentees/3`). Until
  2026-10 they were numbered with the field and counted; VCL4THP Q111 says
  that costs 35%, and FIDE's text says it is wrong.

  1.3.2 then keeps "the last GA-participant ... the same participant as in
  the previous round". A late entrant (1.3.1) - the round-1 absentee
  included, on the round they arrive - is numbered after the field, or -
  `late_entry_numbering` "rating" - given the number their rating earns
  (`ensure_pairing_numbers/2`); one put above that player moves the stored
  line down one with them - and is in Group A, as 1.3.2's first note
  foresees - and one put below it changes nothing.

  Read from `tournament.baku_group_a_last` once round 1 has fixed it.
  Before that - the round-1 pairing itself - it is worked out over
  `players`. A tournament with a round 1 and nothing stored (Baku switched
  on later, or restored from a file older than the column) gets the field
  of its round 1: `players` numbered up to the highest number that sat at a
  board in round 1, the pairing-allocated bye included. The
  `AddBakuGroupALast` migration's backfill also counted round 1's bye rows,
  which was right while round-1 absentees were numbered with the field; a
  round-1 absentee now arrives with a number after it, and counting their
  bye row would drag them back into N. That reading assumes nobody was
  numbered in among round 1's players later; a late entrant put above one
  of them in such a tournament is counted into the list.
  """
  def baku_group_a_last(%{baku_group_a_last: last}, _players) when is_integer(last), do: last

  def baku_group_a_last(tournament, players) do
    numbers = players |> Enum.map(& &1.pairing_number) |> Enum.reject(&is_nil/1) |> Enum.sort()

    numbers =
      case round_one_highest_number(tournament) do
        nil -> numbers
        highest -> Enum.filter(numbers, &(&1 <= highest))
      end

    case numbers do
      [] -> nil
      _ -> Enum.at(numbers, min(2 * ceil_div(length(numbers), 4), length(numbers)) - 1)
    end
  end

  # The highest pairing number that was paired in round 1 - at a board, the
  # pairing-allocated bye included - or nil when there is no round 1 (yet).
  # Bye and absence rows do not count: their players were not on round 1's
  # list (C.04.2 2.4), whatever number they hold now.
  defp round_one_highest_number(%{id: id}) when is_integer(id) do
    in_round_one =
      from(g in PairingsEngine.Tournaments.Pairing,
        join: r in Round,
        on: r.id == g.round_id,
        where: r.tournament_id == ^id and r.number == 1,
        select: [g.white_player_id, g.black_player_id]
      )
      |> Repo.all()
      |> List.flatten()

    case Enum.reject(in_round_one, &is_nil/1) do
      [] ->
        nil

      ids ->
        Repo.one(
          from p in Player,
            where: p.tournament_id == ^id and p.id in ^ids,
            select: max(p.pairing_number)
        )
    end
  end

  defp round_one_highest_number(_tournament), do: nil

  defp virtual_points(round, accelerated_rounds, _first_stage_rounds)
       when round > accelerated_rounds,
       do: 0.0

  defp virtual_points(round, _accelerated_rounds, first_stage_rounds)
       when round <= first_stage_rounds,
       do: 1.0

  defp virtual_points(_round, _accelerated_rounds, _first_stage_rounds), do: 0.5

  defp ceil_div(a, b), do: div(a + b - 1, b)

  @doc """
  Builds the `Ainalrami.Trf.serialize/2`-shaped player list (rank,
  identity fields, points, full-history games) for `players`, covering every
  paired round of `tournament` with no filtering. Shared by `trf_input/5`
  (active players only, feeding the pairing engine) and
  `PairingsEngine.TrfExport` (the full roster, for the user-facing TRF
  download, which additionally trims each player's `:games` down to a
  chosen round subset - see that module).

  Players without a `pairing_number` yet (never included in a paired round)
  are dropped: TRF16 requires every player row to carry a numeric starting
  rank, and a player who was never actually paired has nothing meaningful
  to report anyway.

  Each row also carries an `:id` (the player's id) and each game an
  `:opponent_id` alongside the usual `:opponent_rank` - extra keys
  `Ainalrami.Trf.serialize/2` and `PairingsEngine.TrfExport` both
  ignore (they only read the specific keys they need), but that
  per-category Swiss pairing's `remap_trf_rows_to_local_ranks/2` uses to
  translate global `pairing_number`-based ranks to a category's own local
  numbering - see `build_category_trf/5`.

  `shared_history`, when given, is a precomputed `build_shared_history/1`
  result - passed by `do_pair_by_category/3` so every category's call
  reuses the same tournament-wide query results instead of each one
  re-fetching identical data (see `games_per_player/2`). `nil` (every
  other caller) means "compute it fresh" - the original, unchanged
  behaviour.
  """
  def trf_player_rows(tournament, players, shared_history \\ nil) do
    players = Enum.filter(players, &(&1.pairing_number != nil))
    by_id = Map.new(players, &{&1.id, &1})
    games = games_per_player(tournament, by_id, shared_history)

    players
    |> Enum.sort_by(& &1.pairing_number)
    |> Enum.map(fn p ->
      player_games = Map.get(games, p.id, [])

      %{
        id: p.id,
        rank: p.pairing_number,
        sex: p.sex,
        title: p.title,
        name: p.name,
        # TRF16 is a FIDE report - always the FIDE rating, never a fallback
        # to the national rating (SWAR itself emits 0 for an unrated
        # player rather than substituting the national figure).
        fide_rating: p.fide_rating,
        federation: p.federation,
        fide_number: p.fide_id,
        birth_date: player_birth_date(p),
        points: player_points(player_games, tournament),
        games: player_games
      }
    end)
  end

  # Full date of birth (YYYY/MM/DD, via Trf's slash_date) when known,
  # otherwise the year-only fallback ("YYYY/00/00"), otherwise blank.
  defp player_birth_date(%{birth_date: %Date{} = date}), do: Date.to_iso8601(date)
  defp player_birth_date(%{birth_year: year}) when is_integer(year), do: "#{year}/00/00"
  defp player_birth_date(_), do: nil

  @doc """
  Sums `games` into the score that goes in TRF columns 81-84, per
  `tournament`'s point values.

  That number is not decoration: it is what a pairing engine reads to decide
  which score bracket a player belongs in. It therefore has to equal what
  `PairingsEngine.Standings` puts in the crosstable, and for a long time it
  did not.

  Two ways it drifted. The result codes were matched by hand and everything
  unlisted fell through to `points_loss`, which silently swallowed `W` and
  `D` - a game that was PLAYED but is not rated, worth exactly what its
  rated twin is worth. An unrated win was banked as a zero, so the engine
  put that player a full point too low and paired them against the wrong
  people, while the crosstable next to it showed the point.

  And a bye was scored from its TRF LETTER rather than from what it was. The
  letter cannot carry the difference: `Z` is written both for a requested
  zero-point bye and for an absence, and an absence may be worth `abs_value`
  - half a point in most clubs that use it, capped by round and by count.
  Scoring the letter paid every absence `points_loss`, so exactly the
  tournaments that configure a half-point absence had a file disagreeing
  with their own standings.

  The rows built by `games_per_player/2` carry `points_kind` (the bye's real
  type) and `round`, so a bye is now scored by `Standings.bye_points/4` -
  the same function the crosstable calls, rather than a second opinion about
  the same rule. `cumulative_absences` is each absence's `:absence_number`
  - numbered over every round by `games_per_player/3`, so a list that keeps
  only some rounds (a TRF of chosen rounds) still counts the absences in
  the rounds it left out - and otherwise counted along the list, which is
  one entry per round in round order.
  """
  def player_points(games, t) do
    {points, _absences} =
      Enum.reduce(games, {0.0, 0}, fn g, {sum, absences} ->
        absences =
          if Map.get(g, :points_kind) == "absent",
            # Numbered over the whole tournament when the list came from
            # `games_per_player/3` - which matters once rounds are left out.
            do: Map.get(g, :absence_number, absences + 1),
            else: absences

        {sum + game_points(g, t, absences), absences}
      end)

    points
  end

  # The bye kinds, and ONLY those. `points_kind` is also set to "game" on a
  # played board, and matching on the key alone sent every real game to
  # `bye_points/4`'s catch-all and scored the whole tournament as zeroes.
  # Listing the kinds rather than excluding "game" means a kind added later
  # falls back to the result code - today's behaviour - instead of silently
  # becoming a loss.
  @bye_kinds ~w(requested-half requested-zero absent pairing-allocated zero full-point)

  # A round with no board and no `byes` row: before the player joined (and
  # not counted as an absence - `PairingsEngine.LateEntry`), or after they
  # withdrew. The crosstable has no record for it, so it is worth nothing.
  # It went to `bye_points/4`'s catch-all and was scored as a LOSS, which
  # only shows when a loss is worth something: in a 3-2-1 event a player
  # joining in round 3 entered it with two points the standings did not
  # give them, and was paired in the wrong score group.
  defp game_points(%{points_kind: "zero"}, _t, _absences), do: 0.0

  # A bye knows what kind it is; ask the crosstable's own rule.
  defp game_points(%{points_kind: kind} = g, t, absences) when kind in @bye_kinds,
    do: Standings.bye_points(kind, t, Map.get(g, :round), absences)

  # A postponed game: its provisional points, which the standings computed -
  # presence point included - rather than what its `=` would pay.
  defp game_points(%{provisional_points: points}, _t, _absences) when is_number(points),
    do: points

  # Anything else is a game with a result code. `W`/`D`/`L` are TRF16's
  # letter spellings of `1`/`=`/`0` for a played but unrated game and belong
  # with their twins, not in the catch-all.
  defp game_points(g, t, _absences) do
    base =
      case g.result do
        r when r in ~w(1 + F W) -> t.points_win
        # The pairing-allocated bye, with SWAR 3-2-1's PreBye presence
        # point when the tournament pays one - `bye_points/4`'s rule, which
        # the standings use. `t.bye_value` alone left that point out.
        "U" -> Standings.bye_points("pairing-allocated", t)
        r when r in ~w(= H D) -> t.points_draw
        _ -> t.points_loss
      end

    # The third drift this function's own docstring did not know about.
    # `Standings.pairing_records/4` adds SWAR's 3-2-1 presence point on top
    # of every played game's value; this had no presence term at all, so a
    # Belgian 3-2-1 club event - a supported, real-data-tested import path -
    # was scored one way in the crosstable and handed to the engine another,
    # which puts players in the wrong score brackets.
    #
    # SWAR itself sends Points + SpecialPts in the TRF it hands its pairing
    # engine (standings.ex records the SWAR source reference), so this was also
    # sending a different column than the program it was reverse-engineered
    # from. Inert unless `presence_value` is set, i.e. everywhere but 3-2-1.
    base + Standings.presence_points_for_code(t, g.result)
  end

  # The engine's starting ranks: the roster in pairing-number order, so each
  # player's rank in the file IS their pairing number (TPN) - contiguous
  # 1..N, which every pairing number is unless a numbered player was
  # deleted, and then still in the same order.
  #
  # The Dutch rules order a score group by score and then by TPN (C.04.3
  # A.2), Baku's and acceleration-mode extra points included in the score
  # (the `XXA` lines); and 5.2.5's initial-colour parity is taken on the
  # TPN. Both read the starting rank, so the rank has to be the TPN. From
  # 2026-08-03 until this change it was the standings position instead
  # (score plus virtual points, then rating, then pairing number), after a
  # comparison with SWAR. Within a score group that is rating order, which
  # is the TPN order for a field numbered by rating at the start - but not
  # for a late entrant (numbered after the field) or a player whose rating
  # changed, and 5.2.5's parity then flipped colours on boards between
  # players with no game yet. Found 2026-10-02 by pairing through "Pair
  # round" and comparing with bbpPairings and Ainalrami on a file numbered
  # by pairing number.
  #
  # Baku's Group B can no longer be numbered above Group A on the same
  # pairing score: Group A is the top `2 * ceil(n / 4)` pairing numbers, so
  # by TPN it is always ahead - the case the standings order had to add the
  # virtual points for.
  defp in_pairing_number_order(players), do: Enum.sort_by(players, & &1.pairing_number)

  # Every player who ever received a pairing_number, regardless of current
  # active/absent/forfeit/withdrawn status - the full frozen roster. Used to
  # scope the local rank map fed to the engine (see `do_pair_single/4` and
  # `build_category_trf/5`): every possible historical opponent must resolve
  # to a real rank with a real row in the TRF, or `remap_trf_rows_to_local_ranks/2`
  # silently destroys that game's colour history - see that function's doc.
  @doc """
  Every player who holds a `pairing_number`, in that order - regardless of
  their CURRENT status/absent/forfeit flags.

  A pairing number is only ever assigned once (see
  `ensure_pairing_numbers/2`), so this is the roster as frozen, which is a
  different question from "who may be paired this round"
  (`active_players/1`). Swiss needs it to build a TRF that still lists a
  withdrawn player's completed games; round robin needs it because its
  Berger schedule is fixed at freeze time and pulling somebody out would
  change every other player's opponent.

  Public because `PairingsEngine.RoundRobin` had a byte-identical private
  copy under the name `frozen_players/1`. Same precedent as
  `active_players/1` and `ensure_pairing_numbers/2`, which were exposed for
  the same reason and which that module was also not calling.
  """
  def full_roster_players(tournament_id) do
    Repo.all(
      from p in Player,
        where: p.tournament_id == ^tournament_id and not is_nil(p.pairing_number),
        order_by: p.pairing_number
    )
  end

  @doc """
  Players who are candidates for pairing at all: active status, neither
  permanently absent nor forfeited (SWAR Absent/Forfeit checkboxes). This is
  the full pool `ensure_pairing_numbers/2` freezes numbers over - round-
  specific absences (`eligible_players/2`'s extra filter) don't shrink it,
  so a player sitting out one round still gets/keeps a pairing number.

  Exposed so `PairingsEngine.Keizer` can freeze pairing numbers over the
  same player set Swiss does.
  """
  def active_players(tournament_id) do
    Repo.all(
      from p in Player,
        where:
          p.tournament_id == ^tournament_id and p.status == "active" and
            p.absent == false and p.forfeit == false
    )
  end

  @doc """
  Players on the roster who are marked absent for the whole tournament.

  The exact complement of `active_players/1` on the `absent` flag, and
  deliberately still excluding `forfeit`: a forfeited player's rounds are
  scored as forfeit losses on their boards, not as absences, and paying
  them an absence award as well would count the same round twice.
  """
  def absent_players(tournament_id) do
    Repo.all(
      from p in Player,
        where:
          p.tournament_id == ^tournament_id and p.status == "active" and
            p.absent == true and p.forfeit == false
    )
  end

  @doc """
  `absent_players/1`, minus anyone who had not joined by `round_number`.

  A late entrant marked absent used to come back through this query after
  `do_pair/2` had already filtered them out of the active side, so they
  landed in `round_absentees` and were written an absentee bye row for every
  round before they joined - contradicting `do_pair/2`'s own comment, which
  says a late entrant "lands in NEITHER list ... not given an absentee bye
  row either".

  Those phantom rows are read: `Standings.add_bye_records/3` scores them and
  increments the cumulative counter the `abs_nbfois` cap is measured
  against, so on a SWAR-imported event they pay real points for rounds the
  tournament did not have the player for, and burn the allowance doing it.
  `SwarExport.round_record_for/5` emits them too - its `type == "absent"`
  branch is matched BEFORE its own `start_round` guard, so a stray row
  defeats that guard.

  A round-aware arity rather than a filter at the call site, so "did this
  player exist in round N" has one home. `Keizer.insert_absentee_byes/4`
  has the same structural gap and now uses this too; it was harmless there
  only because `Keizer.score_round/5` guards on `start_round` before the bye
  lookup, which the Swiss `Standings` module does not.

  When a tournament DOES count the rounds before joining as absences
  (`late_entry_absences`), that is `PairingsEngine.LateEntry`'s answer,
  derived when scores are read - with the tournament's caps applied once,
  in round order - and still never a row written here.
  """
  def absent_players(tournament_id, round_number) do
    tournament_id
    |> absent_players()
    |> Enum.reject(&not_yet_started?(&1, round_number))
  end

  @doc """
  Players eligible to be paired for `round_number`: active, not permanently
  absent/forfeited (see `active_players/1`), not requesting an absence for
  this specific round via `absent_rounds` (SWAR "Absent at the rounds
  x,y,z"), and not a late entrant whose `start_round` hasn't been reached
  yet (Keizer). Pure with respect to round-specific filtering - safe to
  unit-test without invoking the engine.
  """
  def eligible_players(tournament_id, round_number),
    do: tournament_id |> active_players() |> eligible_from(round_number)

  @doc """
  The round-specific half of `eligible_players/2`, for a caller that already
  holds the active roster - the pairing run reads it once and applies this
  rather than re-querying.
  """
  def eligible_from(active, round_number) do
    active
    |> Enum.reject(&absent_for_round?(&1, round_number))
    |> Enum.reject(&not_yet_started?(&1, round_number))
  end

  @doc "True if `player`'s `absent_rounds` list includes `round_number`."
  def absent_for_round?(%Player{} = player, round_number) do
    round_number in Player.parse_absent_rounds(player.absent_rounds)
  end

  @doc "True if `player.start_round` is set and later than `round_number` - a late entrant not yet eligible to be paired."
  def not_yet_started?(%Player{start_round: nil}, _round_number), do: false

  def not_yet_started?(%Player{start_round: start}, round_number),
    do: round_number < start

  # Games in TRF terms for every paired round: opponent pairing number,
  # colour, TRF result code. Rounds without a record become Z (zero-point bye).
  #
  # `by_id` scopes WHICH players' rows we build (the current round's target
  # set - e.g. `active_players/1`'s result, or a category's local group for
  # the per-category path) and must stay narrow. Historical opponent
  # identity is a different concern: a player paired in an earlier round may
  # since have gone absent/forfeited and dropped out of `by_id`, but the
  # game they played is still real and needs its opponent's true rank, not
  # a blank one. `build_shared_history/1`'s `full_roster` (every player who
  # ever received a pairing_number) is used for that lookup instead, so
  # `trf_game/3` can resolve any past opponent regardless of their current
  # eligibility.
  #
  # `shared_history`, when given, is a precomputed
  # `%{rounds:, bye_map:, full_roster:}` (see `build_shared_history/1`) -
  # reused as-is instead of re-querying. This is tournament-wide data that
  # doesn't depend on `by_id` at all, so per-category Swiss pairing
  # (`do_pair_by_category/3`) computes it ONCE and threads it through every
  # category's `trf_player_rows/3` call, rather than re-running the same
  # three queries once per category (confirmed identical data every time -
  # `by_id` only scopes which players' rows get BUILT from it, not what the
  # queries themselves return).
  defp games_per_player(tournament, by_id, shared_history) do
    history = shared_history || build_shared_history(tournament)

    case history do
      # Already walked for this run (see `precompute_games/2`). Anything
      # `by_id` asks for that is not in there - a caller passing a player
      # outside the frozen roster - still gets computed, so this is a cache
      # and not a narrowing.
      %{games: games} ->
        wanted = Map.keys(by_id)
        cached = Map.take(games, wanted)

        case Map.drop(by_id, Map.keys(cached)) do
          empty when map_size(empty) == 0 -> cached
          rest -> Map.merge(cached, walk_games(tournament, history, rest))
        end

      _not_precomputed ->
        walk_games(tournament, history, by_id)
    end
  end

  defp walk_games(tournament, history, by_id) do
    %{rounds: rounds, bye_map: bye_map, full_roster: full_roster} = history

    # Each round's boards by player, built once: looking every player up
    # with a scan of the round's boards was players x rounds x boards - two
    # million comparisons for a nine-round, 1,000-player event, on every
    # pairing click. The FIRST board holding the player wins, which is what
    # that scan's `Enum.find/2` returned.
    seated_rounds = Enum.map(rounds, &{&1, seats(&1.pairings)})

    for {player_id, _player} <- by_id, into: %{} do
      games =
        Enum.map(seated_rounds, fn {round, seats} ->
          pairing = Map.get(seats, player_id)

          cond do
            pairing != nil ->
              trf_game(pairing, player_id, full_roster, tournament)

            bye_type = bye_map[{player_id, round.number}] ->
              %{
                opponent_rank: nil,
                opponent_id: nil,
                colour: nil,
                result: bye_code(bye_type),
                points_kind: bye_type,
                # For `abs_jusque` - SWAR's "pay an absence only up to round
                # N". `player_points/2` reads it; nothing serialises it.
                round: round.number
              }

            true ->
              %{
                opponent_rank: nil,
                opponent_id: nil,
                colour: nil,
                result: "Z",
                points_kind: "zero",
                round: round.number
              }
          end
        end)

      {player_id, games |> number_absences() |> Enum.map(&code_unplayed(&1, tournament))}
    end
  end

  @unplayed_kinds ~w(requested-half requested-zero absent zero)

  # An unplayed round (not the pairing-allocated bye, which is always `U`)
  # gets the TRF letter for what it is WORTH - the value `player_points/2`
  # adds to the score column - so the letters and the score agree, as TRF
  # and every pairing program reading it require: `Z` for nothing, `H` for a
  # draw's worth, `F` for a win's (`unplayed_code/2`).
  #
  # Every unplayed round used to be written `Z` and the engine told a `Z` is
  # worth the absence value: a round before joining or after withdrawing
  # (worth nothing), an absence paid half a point or a full one, and a
  # capped absence all the same letter at one value. The file contradicted
  # its own score column (bbpPairings refuses it: "the score does not match
  # the game results"), and a full-point absence the engine could not see
  # as one left the pairing-allocated bye to the wrong player.
  defp code_unplayed(%{points_kind: kind} = game, tournament) when kind in @unplayed_kinds do
    value = game_points(game, tournament, Map.get(game, :absence_number))
    %{game | result: unplayed_code(value, tournament)}
  end

  defp code_unplayed(game, _tournament), do: game

  @doc """
  The TRF letter for a round the player did not play and was not given the
  pairing-allocated bye in, from what the round is worth under
  `tournament`'s point system (`Tournament.engine_point_system/1`, which
  values the letters the same way): `Z` for nothing, `H` for a draw's
  worth, `F` for a win's.

  A value that is none of those - an absence paid half a point in a 3-1-0
  event, a 3-2-1 event's zero-point bye or capped absence worth the loss's
  presence point - has no letter of its own in TRF. It is written `Z`;
  the score column still carries the exact total, which is what the engine
  brackets by.
  """
  def unplayed_code(value, tournament) do
    points = Tournament.engine_point_system(tournament)

    cond do
      value == 0 -> "Z"
      value == points.draw -> "H"
      value == points.win -> "F"
      true -> "Z"
    end
  end

  # `%{player_id => first pairing seating them}`, in `pairings` order.
  defp seats(pairings) do
    pairings
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn pr, acc ->
      acc
      |> put_seat(pr.black_player_id, pr)
      |> put_seat(pr.white_player_id, pr)
    end)
  end

  defp put_seat(acc, nil, _pairing), do: acc
  defp put_seat(acc, player_id, pairing), do: Map.put(acc, player_id, pairing)

  # Each absence carries which one it is, counted over EVERY round - the
  # count `abs_nbfois` is measured with (`player_points/2`). A caller that
  # keeps only some rounds (`TrfExport`'s round selection) then still scores
  # an absence at what the standings paid for it, rather than restarting
  # the allowance at the first round it kept.
  defp number_absences(games) do
    {games, _count} =
      Enum.map_reduce(games, 0, fn
        %{points_kind: "absent"} = game, count ->
          {Map.put(game, :absence_number, count + 1), count + 1}

        game, count ->
          {game, count}
      end)

    games
  end

  # The three tournament-wide queries `games_per_player/2` needs, bundled
  # so they can be run ONCE and reused across multiple calls (see that
  # function's doc) - none of this depends on which players a particular
  # call is building rows for.
  #
  #   * `rounds` - every paired Round with its pairings preloaded.
  #   * `bye_map` - every `"byes"`-table row for the tournament, keyed by
  #     `{player_id, round}`.
  #   * `full_roster` - every player who ever received a `pairing_number`,
  #     the widest set a HISTORICAL opponent could possibly be (a player
  #     never actually paired has nothing meaningful to report anyway,
  #     mirroring `trf_player_rows/2`'s own tolerance rule) - deliberately
  #     wider than the `active_players/1`/category-local sets used to
  #     decide who gets rows built or who gets paired THIS round.
  defp build_shared_history(tournament) do
    tournament_id = tournament.id

    # Without the rounds' engine accounts, which nothing reading the history
    # looks at (`Round.without_explanation/1`).
    rounds =
      Repo.all(
        from r in Round.without_explanation(),
          where: r.tournament_id == ^tournament_id,
          order_by: r.number,
          preload: [pairings: []]
      )

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament_id,
          select: %{player_id: b.player_id, round: b.round, type: b.type}
      )

    full_roster =
      Repo.all(
        from p in Player,
          where: p.tournament_id == ^tournament_id and not is_nil(p.pairing_number)
      )
      |> Map.new(&{&1.id, &1})

    # The rounds before a late entrant joined, as the absences they count as
    # when the tournament says so (`PairingsEngine.LateEntry`) - the same
    # rows `Standings` scores, so the score column the engine brackets by
    # and the TRF export's `001` total agree with the crosstable. Written as
    # the `Z` any absence is, and scored by `player_points/2` at the absence
    # value with its caps.
    byes = byes ++ PairingsEngine.LateEntry.absences(tournament)

    %{
      rounds: rounds,
      bye_map: Map.new(byes, &{{&1.player_id, &1.round}, &1.type}),
      full_roster: full_roster,
      # Identical for every category, and read TWICE per TRF build -
      # `forbidden_pairs/3` and `exclusion_pairs/3` each queried it on their
      # own, so a five-category run issued ten of these for one answer.
      forbidden_pairings: Tournaments.list_forbidden_pairings(tournament_id),
      # The pairing rules, read once for the same reason.
      pairing_rules: Tournaments.list_pairing_rules(tournament_id)
    }
  end

  @doc """
  The tournament's history as the report sent for rating has it: what
  `trf_player_rows/3` takes as `shared_history`, with every board corrected
  for the rating report only (`Tournaments.set_rating_correction/3`,
  C.04.2:4.3) carrying its corrected result. Only `PairingsEngine.TrfExport`
  reads it, for the TRF26 report; the pairing engine and the standings go
  on reading the result the event used.
  """
  def rating_history(tournament) do
    history = build_shared_history(tournament)

    rounds =
      Enum.map(history.rounds, fn round ->
        %{round | pairings: Enum.map(round.pairings, &rated_pairing/1)}
      end)

    %{history | rounds: rounds}
  end

  defp rated_pairing(%{rating_result: rated} = pairing) when is_binary(rated),
    do: %{pairing | result: rated}

  defp rated_pairing(pairing), do: pairing

  # Adds each full-roster player's TRF game list to a shared history.
  #
  # `games_per_player/3` walks every round looking for each player's pairing
  # - O(players x rounds x boards) - and produces the same map every time it
  # is asked, because the roster and the rounds are fixed for the whole run.
  # It was being run once by the old standings ordering and then again by
  # `trf_player_rows/3` ONCE PER CATEGORY. Threading the history removed the
  # queries; this removes the walk.
  defp precompute_games(tournament, history) do
    Map.put(history, :games, games_per_player(tournament, history.full_roster, history))
  end

  # The shared history for one pairing run: three queries, one roster walk,
  # one forbidden-pairing read, and every consumer downstream reads from it.
  defp pairing_history(tournament) do
    tournament |> build_shared_history() |> then(&precompute_games(tournament, &1))
  end

  @postponed_codes PairingsEngine.Results.postponed_codes()

  @doc false
  # One player's TRF game map for one stored pairing. Public only so the
  # postponed-games TRF (`TrfExport.postponed_export/2`) writes a game with
  # exactly the character the main file would - see `trf_player_rows/3` for
  # everything else.
  def trf_game(pairing, player_id, full_roster, tournament) do
    white? = pairing.white_player_id == player_id

    opponent_id = if white?, do: pairing.black_player_id, else: pairing.white_player_id
    # Looked up against the FULL tournament roster (every player who ever
    # got a pairing_number), not just whoever is eligible for the round
    # currently being paired - a past opponent may since have gone
    # absent/forfeited and dropped out of that narrower set, but the game
    # they played is still real and its rank must still resolve. See
    # `games_per_player/2`.
    opponent = opponent_id && Map.get(full_roster, opponent_id)

    # Played games use TRF codes 1/0/= ; forfeits use + (win) / - (loss),
    # per FIDE Art. 16 both sides of a forfeit count as unplayed. A played
    # "0-0" (both players lose, e.g. both defaulted after making moves) is
    # code '0' for BOTH sides - distinct from a "0-0FF" double forfeit,
    # which is '-' for both. "1/2-0"/"0-1/2" (VCL.13's asymmetric result) is
    # '=' for the ½ side and '0' for the 0 side - the one case where the two
    # sides' TRF codes deliberately don't mirror each other, since the TRF16
    # spec has no dedicated code for it. "+--"/"--+" are the legacy forfeit
    # notation, kept for historical/SWAR-imported data (see
    # PairingsEngine.Tournaments.Pairing).
    result =
      case {pairing.result, white?} do
        {"bye", _} -> "U"
        {"1-0", true} -> "1"
        {"1-0", false} -> "0"
        {"0-1", true} -> "0"
        {"0-1", false} -> "1"
        {"1/2-1/2", _} -> "="
        {"1/2-0", true} -> "="
        {"1/2-0", false} -> "0"
        {"0-1/2", true} -> "0"
        {"0-1/2", false} -> "="
        {"1-0FF", true} -> "+"
        {"1-0FF", false} -> "-"
        {"0-1FF", true} -> "-"
        {"0-1FF", false} -> "+"
        {"0-0FF", _} -> "-"
        {"0-0", _} -> "0"
        # Unrated but PLAYED: W/D/L are the rated codes' twins, and every
        # pairing rule treats them as contested games.
        {"1-0U", true} -> "W"
        {"1-0U", false} -> "L"
        {"0-1U", true} -> "L"
        {"0-1U", false} -> "W"
        {"1/2-1/2U", _} -> "D"
        {"+--", true} -> "+"
        {"+--", false} -> "-"
        {"--+", true} -> "-"
        {"--+", false} -> "+"
        # Postponed, still to be played: written as a played draw, so the
        # colours count the way any game's do (the two have met and the
        # seats are fixed) and the pair is legal to every engine. What it is
        # WORTH is not the character's to say: the tournament may count it
        # as something else for the player who postponed it, so the game
        # carries `provisional_points` below - from the standings' own
        # function - and `player_points/2` scores it by that. That is the
        # score the engine brackets by (VCL4THP Q167 when it is a draw).
        # `TrfExport` writes TRF26's `?` in its place for a report.
        {code, _} when code in @postponed_codes -> "="
        {"", _} -> nil
        _ -> nil
      end
      |> bye_safe_result(opponent_id)

    %{
      opponent_rank: opponent && opponent.pairing_number,
      # The opponent's raw id, carried alongside `opponent_rank`
      # so per-category Swiss pairing's `remap_trf_rows_to_local_ranks/2` can
      # translate it to a category's own local rank numbering (see
      # `build_category_trf/5`). `Ainalrami.Trf.serialize/2` and
      # `PairingsEngine.TrfExport` both ignore this extra key.
      opponent_id: opponent_id,
      colour:
        cond do
          pairing.result == "bye" or opponent_id == nil -> nil
          white? -> "w"
          true -> "b"
        end,
      result: result,
      points_kind: "game",
      # Read by `PairingsEngine.TrfExport`, which marks these games TRF26's
      # unknown `?`. `Ainalrami.Trf.serialize/2` ignores the key.
      postponed: pairing.result in @postponed_codes,
      # Sent in a TRF marked as sent while it was an open postponed game, so
      # written as `?` there: every later report keeps it that way, and its
      # real result goes in the postponed-games file instead.
      finalised_open: pairing.finalised_open == true,
      # What the game counts as for this player while it is postponed - the
      # score the engine brackets by. See the `@postponed_codes` clause above.
      provisional_points: provisional_points(pairing, white?, tournament)
    }
  end

  # A postponed game's provisional points for one side, from the same
  # function the standings score it with, so the engine's score column and
  # the crosstable cannot disagree. nil for every other game.
  defp provisional_points(%{result: result} = pairing, white?, tournament)
       when result in @postponed_codes,
       do: Standings.provisional_points(pairing, white?, tournament)

  # A SWAR 3-2-1 "0-0" or "0-0FF" pays nothing (`ConvertPoint321`), which
  # its TRF letter cannot say - `0` and `-` are worth a loss. The standings'
  # own number goes with it, the same way as for a postponed game.
  defp provisional_points(%{result: result} = pairing, white?, tournament)
       when result in ["0-0", "0-0FF"] do
    if Standings.presence_scheme?(tournament),
      do: Standings.provisional_points(pairing, white?, tournament)
  end

  defp provisional_points(_pairing, _white?, _tournament), do: nil

  # TRF16 rule: opponent 0000 may only ever carry a bye/unplayed code
  # (F/H/Z/U) - never a played-game code (1/=/0/+/-). Reported bug: a
  # SWAR-imported round could carry a played-game result on a game with no
  # real opponent (e.g. a bye's score recorded as if it were an ordinary
  # game), producing an illegal "0000 - 1" / "0000 - =" row that TRF
  # readers reject ("Unexpected format of player line"). This is the
  # single choke point both `trf_input/5` and `PairingsEngine.TrfExport`
  # go through (via `trf_player_rows/2`), so normalizing here fixes both.
  #
  # A playing code with no opponent is reinterpreted by the point value it
  # represents: a win or forfeit-win is a full-point bye (F), a draw is a
  # half-point bye (H), a loss or forfeit-loss is a zero-point bye (Z).
  # Already-legal codes (bye codes, or any code when a real opponent exists)
  # and a missing result (nil) pass through unchanged.
  # The third private copy of the played-code vocabulary, and the last one.
  # `TrfImport` carried two; both are now policed the same way.
  #
  # Pointing this at `Trf.playing_codes/0` directly does not work, because
  # the question here is not "is this a playing code" but "what point value
  # does it stand for" - a three-way split that runs ACROSS the engine's two
  # lists rather than along them. The engine publishes no function for that
  # partition, and `Trf.points_for/2` keys on a configurable point system, so
  # borrowing it would silently re-bucket a file carrying its own values.
  #
  # What the engine list CAN police is the domain, which is the half that
  # actually broke: `W`/`D`/`L` were missing here until 2026-08-26, and an
  # opponentless unrated result then escaped as an exception rather than as
  # the `{:error, message}` every other refusal returns. The check below
  # fails the BUILD if the engine ever accepts a code this does not handle,
  # instead of waiting for it to reach an arbiter's file.
  #
  # Only playing codes are partitioned. A bye code arriving here is already
  # legal with no opponent and falls through the `other` clause unchanged,
  # which is why `bye_codes/0` is not part of the domain.
  @bye_safe_full ~w(1 + W)
  @bye_safe_half ~w(= D)
  @bye_safe_zero ~w(0 - L)

  @bye_safe_handled Enum.sort(@bye_safe_full ++ @bye_safe_half ++ @bye_safe_zero)
  @bye_safe_domain Enum.sort(Ainalrami.Trf.playing_codes())

  if @bye_safe_handled != @bye_safe_domain do
    raise """
    PairingsEngine.Pairing.bye_safe_result/2 no longer covers Ainalrami.Trf's     playing-code vocabulary.

      handled here: #{inspect(@bye_safe_handled)}
      the engine's: #{inspect(@bye_safe_domain)}
      missing:      #{inspect(@bye_safe_domain -- @bye_safe_handled)}
      unknown:      #{inspect(@bye_safe_handled -- @bye_safe_domain)}

    Every playing code must land in one of the three point-value buckets, or     an opponentless result keeps a playing code and `Trf.validate_games!/2`     raises while BUILDING the file - before `run_engine/5` is called, so the     ValidationError rescue cannot see it either.
    """
  end

  defp bye_safe_result(result, opponent_id) when not is_nil(opponent_id), do: result

  defp bye_safe_result(result, nil) do
    case result do
      # `W`/`D`/`L` are TRF16's unrated twins of `1`/`=`/`0` and belong with
      # them. They were missing until 2026-08-26, so an opponentless unrated
      # result stayed a playing code with a nil opponent - precisely the
      # combination this function exists to make impossible.
      #
      # It did not degrade quietly: `Trf.validate_games!/2` raises on it, and
      # the raise happens while BUILDING the file, before `run_engine/5` is
      # called - so `run_ainalrami/4`'s ValidationError rescue could not see
      # it either. It escaped `pair_next_round/1` as an exception instead of
      # the `{:error, message}` every other refusal here returns, and took
      # the FIDE download down the same way.
      code when code in @bye_safe_full -> "F"
      code when code in @bye_safe_half -> "H"
      code when code in @bye_safe_zero -> "Z"
      other -> other
    end
  end

  defp bye_code("requested-half"), do: "H"
  defp bye_code("requested-zero"), do: "Z"
  defp bye_code("absent"), do: "Z"
  defp bye_code("pairing-allocated"), do: "U"
  # The full-point bye (`Tournaments.award_full_point_bye/3`) is `F` whatever
  # a win is worth: the letter is what tells the engine C.04.3 [C2] rules the
  # player out of the pairing-allocated bye, so it is not left to
  # `code_unplayed/2`'s reading of the value.
  defp bye_code("full-point"), do: "F"
  defp bye_code(_), do: "Z"
end
