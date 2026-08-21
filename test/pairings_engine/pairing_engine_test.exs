defmodule PairingsEngine.PairingEngineTest do
  @moduledoc """
  `tournaments.pairing_engine` - which Swiss engine actually pairs a round.

  JaVaFo stays the default. Ainalrami is opt-in, and may be selected even on
  a FIDE-homologated tournament, with a warning - see
  docs/fide-endorsement.md for what that costs on paper.

  Note which tests carry `@tag :javafo` and which don't. The Ainalrami tests
  are deliberately untagged: Ainalrami needs no jar, no JVM and no external
  binary at all, so unlike every other Swiss pairing test in this suite they
  run on a bare checkout and in CI. That is a real property of the feature,
  not a testing convenience, so it is exercised rather than assumed.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{name: "Engines", type: "swiss", rounds_count: 3, tiebreaks: ~w(BH)},
        attrs
      )
    )
  end

  defp insert_player(tournament, name, attrs) do
    defaults = %{tournament_id: tournament.id, name: name}
    {:ok, player} = Tournaments.create_player(tournament.id, Map.merge(defaults, Map.new(attrs)))
    player
  end

  # Six players, evenly spaced ratings so `ensure_pairing_numbers/2` freezes a
  # predictable 1..6 starting order.
  defp roster(tournament, count \\ 6) do
    for n <- 1..count do
      insert_player(tournament, "P#{n}", fide_rating: 2000 - n * 50)
    end
  end

  defp paired_player_ids(round) do
    round
    |> Repo.preload(:pairings)
    |> Map.fetch!(:pairings)
    |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
    |> Enum.reject(&is_nil/1)
  end

  ## ---------- dispatch ----------

  describe "engine dispatch" do
    test "a Swiss tournament set to ainalrami pairs a round through Ainalrami" do
      t = tournament(%{pairing_engine: "ainalrami"})
      players = roster(t)

      assert {:ok, round} = Pairing.pair_next_round(t)

      round = Repo.preload(round, :pairings)
      assert round.number == 1
      assert length(round.pairings) == 3

      # Everyone was seated, nobody twice.
      ids = paired_player_ids(round)
      assert Enum.sort(ids) == players |> Enum.map(& &1.id) |> Enum.sort()

      # Every board is a real game, and every seat is filled - the shape
      # `create_round/5` writes is identical whichever engine answered.
      assert Enum.all?(round.pairings, &(&1.white_player_id && &1.black_player_id))
      assert Enum.map(round.pairings, & &1.board) == [1, 2, 3]
    end

    @tag :javafo
    test "a Swiss tournament left on the default still pairs through JaVaFo" do
      t = tournament()
      assert t.pairing_engine == "javafo"

      players = roster(t)

      assert {:ok, round} = Pairing.pair_next_round(t)

      round = Repo.preload(round, :pairings)
      assert length(round.pairings) == 3
      assert Enum.sort(paired_player_ids(round)) == players |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "Ainalrami's nil bye is normalized to the pairing-allocated bye row JaVaFo's 0 produces" do
      # Ainalrami returns `{white_rank, nil}` for the pairing-allocated bye
      # where JaVaFo's text output writes a literal `0`. If the adapter
      # dropped that translation, `create_round/5` would try to look up rank
      # `nil` in the local rank map and crash - so an odd field is the
      # cheapest direct test of it.
      t = tournament(%{pairing_engine: "ainalrami"})
      roster(t, 5)

      assert {:ok, round} = Pairing.pair_next_round(t)
      round = Repo.preload(round, :pairings)

      byes = Enum.filter(round.pairings, &is_nil(&1.black_player_id))
      assert [bye] = byes
      assert bye.result == "bye"
      assert bye.white_player_id
      assert length(round.pairings) == 3
    end

    test "Ainalrami pairs several rounds in a row off its own result history" do
      t = tournament(%{pairing_engine: "ainalrami", rounds_count: 3})
      roster(t)

      assert {:ok, r1} = Pairing.pair_next_round(t)
      enter_results(r1)

      assert {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))
      enter_results(r2)

      assert {:ok, r3} = Pairing.pair_next_round(Repo.reload!(t))
      assert r3.number == 3

      # No rematches across the three rounds - the history OpenPairings
      # writes really is being read back into the TRF Ainalrami pairs from.
      opponents =
        [r1, r2, r3]
        |> Enum.flat_map(fn r ->
          r
          |> Repo.preload(:pairings)
          |> Map.fetch!(:pairings)
          |> Enum.reject(&is_nil(&1.black_player_id))
          |> Enum.map(&Enum.sort([&1.white_player_id, &1.black_player_id]))
        end)

      assert length(opponents) == length(Enum.uniq(opponents))
    end
  end

  defp enter_results(round) do
    round
    |> Repo.preload(:pairings)
    |> Map.fetch!(:pairings)
    |> Enum.each(fn p ->
      if p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end
    end)
  end

  ## ---------- TRF extensions ----------

  # This block used to assert that Ainalrami REFUSED a tournament carrying an
  # XXP line, because its TRF parser dropped every extension but XXR: the
  # forbidden pair would have been paired together, and the round would have
  # looked perfectly legal. XXP and XXA are implemented as of ainalrami
  # `451c749`, so what is tested here is the behaviour itself - the pair is
  # kept apart - on both engines, from identical inputs.
  describe "TRF extensions" do
    # These two are a control and its experiment, and they have to be read
    # together. An earlier version of this test asserted only that ranks 1 and
    # 2 were not paired in round 1 of a SIX-player field -- where the Dutch
    # system pairs top half against bottom half, so 1 and 2 could never have
    # met regardless. It passed with the forbidden pairs being thrown away
    # entirely, which is exactly what was happening: `run_ainalrami/4` never
    # passed `:forbidden_pairs` to the engine, so every `XXP` line this app
    # emitted was parsed and discarded. A test that cannot fail is worse than
    # no test, because it is read as cover.
    #
    # Four players fixes that. Round 1 of a 4-player Swiss pairs 1v3 and 2v4 --
    # the control below pins that -- so forbidding {1,3} forbids a pair the
    # engine would otherwise produce, and the experiment can only pass if the
    # constraint actually reached it.
    test "without a forbidden pairing, ranks 1 and 3 are the natural round-1 pair" do
      t = tournament(%{pairing_engine: "ainalrami"})
      [p1, _p2, p3, _p4] = roster(t, 4)

      assert {:ok, round} = Pairing.pair_next_round(t)

      assert met?(round, p1, p3),
             "control failed: if 1v3 is not the natural pairing, the test below proves nothing"
    end

    test "Ainalrami keeps a forbidden pair apart" do
      t = tournament(%{pairing_engine: "ainalrami"})
      [p1, p2, p3, p4] = roster(t, 4)

      # A pairing number has to exist before XXP lines can name anyone, so
      # pair and delete a round to freeze the numbering.
      {:ok, round} = Pairing.pair_next_round(t)
      :ok = delete_round(t, round)

      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p3.id)

      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))

      refute met?(round, p1, p3), "the arbiter's exclusion was ignored"

      # A complete round, not a short one that dodged the constraint by
      # dropping somebody -- and the only other legal shape, so this pins the
      # actual answer rather than just the absence.
      assert length(paired_player_ids(round)) == 4
      assert met?(round, p1, p4)
      assert met?(round, p2, p3)
    end

    test "a club/federation exclusion reaches Ainalrami too, not just an explicit pair" do
      # Exclusions live in their own table and are expanded into the same
      # `XXP` lines (see `Exclusions`), so they travel the identical path --
      # but they are the case an arbiter never enters by hand, and so the one
      # least likely to be noticed if it silently stopped working.
      t = tournament(%{pairing_engine: "ainalrami", club_exclusion: "all"})
      [p1, _p2, p3, _p4] = roster(t, 4)

      {:ok, _} = Tournaments.update_player(p1, %{"club" => "Gent"})
      {:ok, _} = Tournaments.update_player(p3, %{"club" => "Gent"})

      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))

      refute met?(round, p1, p3), "two players from the same club were paired anyway"
      assert length(paired_player_ids(round)) == 4
    end

    defp met?(round, a, b) do
      round
      |> Repo.preload(:pairings)
      |> Map.fetch!(:pairings)
      |> Enum.any?(fn pairing ->
        Enum.sort([pairing.white_player_id, pairing.black_player_id]) ==
          Enum.sort([a.id, b.id])
      end)
    end

    @tag :javafo
    test "the same tournament on JaVaFo pairs that forbidden pair apart, as always" do
      t = tournament(%{pairing_engine: "javafo"})
      [p1, p2 | _] = roster(t)

      {:ok, round} = Pairing.pair_next_round(t)
      :ok = delete_round(t, round)

      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p2.id)

      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))

      met? =
        round
        |> Repo.preload(:pairings)
        |> Map.fetch!(:pairings)
        |> Enum.any?(fn pairing ->
          Enum.sort([pairing.white_player_id, pairing.black_player_id]) ==
            Enum.sort([p1.id, p2.id])
        end)

      refute met?
    end
  end

  defp delete_round(tournament, round) do
    :ok = Pairing.delete_round(tournament.id, round.number)
  end

  ## ---------- changeset guards ----------

  describe "changeset: Ainalrami on a FIDE-homologated tournament is allowed, with warnings in the UI" do
    # Refused outright until 2026-08-21, now the arbiter's call. The engine
    # agrees with bbpPairings across ~488M pairings, and where it differs
    # from JaVaFo it is on Article 5.2.5's TPN parity - where it follows the
    # handbook text and JaVaFo carries pre-2026 behaviour. Blocking asserted
    # a quality judgement the measurements do not support.
    #
    # The exposure is paperwork, not pairings: OpenPairings is endorsed as
    # "Internal engine: NO - thru JaVaFo", so a rated round paired by
    # Ainalrami was not produced by the engine that endorsement names. The
    # UI warns prominently in two places; the data layer does not refuse.
    test "selecting Ainalrami on a FIDE-homologated tournament is allowed" do
      t = tournament(%{fide_homologated: true, fide_tournament_id: "12345"})

      assert {:ok, updated} =
               Tournaments.update_tournament(t, %{"pairing_engine" => "ainalrami"})

      assert updated.pairing_engine == "ainalrami"
      assert updated.fide_homologated
    end

    test "turning ON FIDE homologation while the engine is Ainalrami is allowed" do
      t = tournament(%{pairing_engine: "ainalrami"})

      assert {:ok, updated} =
               Tournaments.update_tournament(t, %{
                 "fide_homologated" => "true",
                 "fide_tournament_id" => "12345"
               })

      assert updated.fide_homologated
      assert updated.pairing_engine == "ainalrami"
    end

    test "JaVaFo on a FIDE-homologated tournament is of course fine" do
      t = tournament(%{fide_homologated: true, fide_tournament_id: "12345"})

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"pairing_engine" => "javafo"})
      assert updated.pairing_engine == "javafo"
    end

    test "an unknown engine name is rejected outright" do
      t = tournament()

      assert {:error, changeset} =
               Tournaments.update_tournament(t, %{"pairing_engine" => "bbppairings"})

      assert %{pairing_engine: _} = errors_on(changeset)
    end
  end

  # These two used to assert the OPPOSITE - that Ainalrami and Baku were
  # mutually exclusive - because Ainalrami's TRF parser discarded `XXA`
  # entirely and would have paired an accelerated tournament on
  # unaccelerated brackets. It reads `XXA` (and `XXP`) as of ainalrami
  # `451c749`, verified against bbpPairings over 1.79M rounds carrying
  # those lines, so the combination is now legal and these assert that it
  # is allowed rather than refused.
  describe "changeset: Ainalrami works with Baku acceleration" do
    test "selecting Ainalrami on a Baku-accelerated tournament is allowed" do
      t = tournament(%{acceleration: "baku"})

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"pairing_engine" => "ainalrami"})
      assert updated.pairing_engine == "ainalrami"
      assert updated.acceleration == "baku"
    end

    test "turning ON Baku acceleration while the engine is Ainalrami is allowed" do
      t = tournament(%{pairing_engine: "ainalrami"})

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"acceleration" => "baku"})
      assert updated.acceleration == "baku"
      assert Repo.reload!(t).acceleration == "baku"
    end
  end

  ## ---------- the lock ----------

  describe "pairing_engine locks once round 1 is paired" do
    test "it is not locked before anything is paired" do
      t = tournament()
      refute :pairing_engine in Tournaments.locked_fields(t)

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"pairing_engine" => "ainalrami"})
      assert updated.pairing_engine == "ainalrami"
    end

    test "it joins locked_fields/1 once a round exists" do
      t = tournament(%{pairing_engine: "ainalrami"})
      roster(t)
      {:ok, _round} = Pairing.pair_next_round(t)

      t = Repo.reload!(t)
      assert :pairing_engine in Tournaments.locked_fields(t)
    end

    test "update_tournament/2 refuses the switch after round 1" do
      t = tournament(%{pairing_engine: "ainalrami"})
      roster(t)
      {:ok, _round} = Pairing.pair_next_round(t)
      t = Repo.reload!(t)

      assert Tournaments.update_tournament(t, %{"pairing_engine" => "javafo"}) ==
               {:error, :locked_after_pairing}

      assert Repo.reload!(t).pairing_engine == "ainalrami"
    end

    test "re-submitting the same engine unchanged still saves" do
      # The ordinary form case: the control is disabled but still posts its
      # current value.
      t = tournament(%{pairing_engine: "ainalrami"})
      roster(t)
      {:ok, _round} = Pairing.pair_next_round(t)
      t = Repo.reload!(t)

      assert {:ok, _} =
               Tournaments.update_tournament(t, %{
                 "pairing_engine" => "ainalrami",
                 "venue" => "Town Hall"
               })
    end
  end

  ## ---------- the other two pairing systems ignore it entirely ----------

  describe "round robin and Keizer are unaffected" do
    test "a round robin set to ainalrami pairs its Berger schedule, engine untouched" do
      t = tournament(%{pairing_system: "round_robin", pairing_engine: "ainalrami"})
      roster(t, 4)

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert length(Repo.preload(round, :pairings).pairings) == 2
    end

    test "a round robin pairs identically whichever engine is selected" do
      # Same roster, same schedule: `pairing_engine` is never read on this
      # path, so the two must produce the same Berger round.
      shape = fn engine ->
        t = tournament(%{pairing_system: "round_robin", pairing_engine: engine})
        roster(t, 4)
        {:ok, round} = Pairing.pair_next_round(t)

        round
        |> Repo.preload(:pairings)
        |> Map.fetch!(:pairings)
        |> Enum.map(fn p ->
          {p.board, player_number(p.white_player_id), player_number(p.black_player_id)}
        end)
      end

      assert shape.("javafo") == shape.("ainalrami")
    end

    test "a Keizer tournament set to ainalrami pairs through Keizer's own algorithm" do
      t = tournament(%{pairing_system: "keizer", pairing_engine: "ainalrami"})
      roster(t, 4)

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert length(Repo.preload(round, :pairings).pairings) == 2
    end

    test "a Keizer tournament pairs identically whichever engine is selected" do
      shape = fn engine ->
        t = tournament(%{pairing_system: "keizer", pairing_engine: engine})
        roster(t, 4)
        {:ok, round} = Pairing.pair_next_round(t)

        round
        |> Repo.preload(:pairings)
        |> Map.fetch!(:pairings)
        |> Enum.map(fn p ->
          {p.board, player_number(p.white_player_id), player_number(p.black_player_id)}
        end)
      end

      assert shape.("javafo") == shape.("ainalrami")
    end

    test "a forbidden pairing on a round robin is not refused, engine notwithstanding" do
      # The XXP guard is Swiss-only: a round robin's fixed schedule never
      # builds a TRF at all, so an Ainalrami round robin with a forbidden
      # pairing must still pair (the schedule ignores the rule by design -
      # see docs/pairing-systems.md).
      t = tournament(%{pairing_system: "round_robin", pairing_engine: "ainalrami"})
      [p1, p2 | _] = roster(t, 4)

      {:ok, round} = Pairing.pair_next_round(t)
      :ok = delete_round(t, round)

      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p2.id)

      assert {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
    end
  end

  defp player_number(nil), do: nil
  defp player_number(id), do: Repo.get!(PairingsEngine.Tournaments.Player, id).pairing_number

  ## ---------- the two engines against each other ----------

  describe "differential: Ainalrami vs JaVaFo on the same tournament" do
    # The settings dialog tells an arbiter that Ainalrami found ZERO
    # disagreements against bbpPairings over ~488 million pairings. That
    # claim is earned in the engine's own repository, on a 36-core machine,
    # over hours -- it cannot be re-run here and should not be.
    #
    # What CAN be checked here, and is worth checking because it is the
    # claim as the arbiter experiences it, is that the two engines wired
    # into THIS app agree about who plays whom on ordinary tournaments,
    # through this app's own TRF construction and result plumbing rather
    # than in isolation.
    #
    # Colours are deliberately not compared. The engines are known to
    # disagree about Article 5.2.5's TPN parity -- an open question raised
    # with FIDE, where Ainalrami follows the handbook text and every
    # reference implementation carries pre-2026 behaviour -- so asserting
    # colour equality would encode the disputed reading as correct.
    @tag :javafo
    test "they agree on the boards, round after round" do
      for size <- [6, 8, 10] do
        a = tournament(%{pairing_engine: "ainalrami", rounds_count: 3})
        j = tournament(%{pairing_engine: "javafo", rounds_count: 3})

        roster(a, size)
        roster(j, size)

        for round_number <- 1..3 do
          {:ok, ra} = Pairing.pair_next_round(a)
          {:ok, rj} = Pairing.pair_next_round(j)

          assert boards(ra) == boards(rj),
                 """
                 #{size} players, round #{round_number}: the two engines seated
                 different boards.

                   ainalrami: #{inspect(boards(ra))}
                   javafo:    #{inspect(boards(rj))}
                 """

          # Advance both on the SAME results, so round n+1 is compared from
          # an identical history rather than from whatever each engine's own
          # previous round happened to produce.
          enter_same_results(ra, rj)
        end
      end
    end

    # A field with a bye every round is where the two most plausibly part
    # company: C2 governs who may receive a second one, and it is the rule
    # the known bbpPairings defects violate.
    @tag :javafo
    test "they agree on an odd field, where a bye is allocated every round" do
      a = tournament(%{pairing_engine: "ainalrami", rounds_count: 3})
      j = tournament(%{pairing_engine: "javafo", rounds_count: 3})

      roster(a, 7)
      roster(j, 7)

      for _round <- 1..3 do
        {:ok, ra} = Pairing.pair_next_round(a)
        {:ok, rj} = Pairing.pair_next_round(j)

        assert boards(ra) == boards(rj)
        assert byes(ra) == byes(rj), "the two engines gave the bye to different players"

        enter_same_results(ra, rj)
      end
    end
  end

  # Unordered pairs, sorted - who played whom, with colour deliberately
  # discarded (see the describe block above).
  defp boards(round) do
    round
    |> Repo.preload(:pairings)
    |> Map.fetch!(:pairings)
    |> Enum.reject(&is_nil(&1.black_player_id))
    |> Enum.map(fn p ->
      Enum.sort([player_seed(p.white_player_id), player_seed(p.black_player_id)])
    end)
    |> Enum.sort()
  end

  defp byes(round) do
    round
    |> Repo.preload(:pairings)
    |> Map.fetch!(:pairings)
    |> Enum.filter(&is_nil(&1.black_player_id))
    |> Enum.map(&player_seed(&1.white_player_id))
    |> Enum.sort()
  end

  # Compares by NAME, not by database id: the two tournaments hold different
  # player rows, so ids are meaningless across them and "P3" is the only
  # thing that means the same player in both.
  defp player_seed(nil), do: nil
  defp player_seed(id), do: Repo.get!(PairingsEngine.Tournaments.Player, id).name

  # Results are decided by WHICH PLAYER wins, never by which seat.
  #
  # Scoring "1-0" on every board looks equivalent and is not: the two
  # engines legitimately disagree about colours (Article 5.2.5's TPN parity
  # - see the describe block), so the same pair can be seated the opposite
  # way round in each tournament and "White wins" then hands the point to a
  # DIFFERENT player. Round two is then compared from two different score
  # histories, and the test reports an engine disagreement that is entirely
  # its own doing. It did exactly that before this was fixed.
  #
  # The lower seed always wins, translated into whichever seat that player
  # actually occupies, so both tournaments carry identical standings into
  # the next round no matter how the colours fell.
  defp enter_same_results(round_a, round_b) do
    for round <- [round_a, round_b] do
      round
      |> Repo.preload(:pairings)
      |> Map.fetch!(:pairings)
      |> Enum.each(fn p ->
        result =
          cond do
            is_nil(p.black_player_id) -> "bye"
            seed_number(p.white_player_id) < seed_number(p.black_player_id) -> "1-0"
            true -> "0-1"
          end

        Repo.update!(Ecto.Changeset.change(p, result: result))
      end)

      Repo.update!(Ecto.Changeset.change(round, status: "finished"))
    end
  end

  defp seed_number(id) do
    "P" <> n = player_seed(id)
    String.to_integer(n)
  end

  ## ---------- the engine's own account of the round ----------

  describe "explanation capture" do
    test "an Ainalrami round records the brackets the engine actually built" do
      t = tournament(%{pairing_engine: "ainalrami", rounds_count: 5})
      players = roster(t, 8)
      roster_ids = players |> Enum.map(& &1.id) |> MapSet.new()

      assert {:ok, round} = Pairing.pair_next_round(t)

      assert %{"engine" => "ainalrami", "version" => 1, "sections" => [section]} =
               round.explanation

      # One pool, so no category name.
      assert section["category"] == nil
      assert [bracket | _] = section["brackets"]

      # The engine speaks in local TRF ranks, which mean nothing once the
      # roster changes. What is STORED has to be player ids - this is the
      # assertion that catches the translation being dropped, because local
      # ranks 1..8 would look perfectly plausible next to real ids.
      stored =
        section["brackets"]
        |> Enum.flat_map(fn b ->
          b["residents"] ++ b["mdps"] ++ b["floats"] ++ List.flatten(b["pairs"])
        end)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      assert MapSet.size(stored) > 0
      assert MapSet.subset?(stored, roster_ids)

      # Round 1 is one bracket at 0 points, and it must carry the criteria
      # that actually scored, with their labels - the whole point of storing
      # this rather than re-deriving it.
      assert bracket["group"] == 0.0
      assert is_integer(bracket["edge_count"])
      assert [%{"label" => label, "value" => value} | _] = bracket["rungs"]
      assert is_binary(label)
      assert value != 0
    end

    test "the stored pairs are the pairs that were actually seated" do
      t = tournament(%{pairing_engine: "ainalrami", rounds_count: 5})
      roster(t, 8)

      assert {:ok, round} = Pairing.pair_next_round(t)
      round = Repo.preload(round, :pairings)

      seated =
        round.pairings
        |> Enum.map(
          &MapSet.new(
            Enum.reject([&1.white_player_id, &1.black_player_id], fn x -> is_nil(x) end)
          )
        )
        |> MapSet.new()

      explained =
        round.explanation["sections"]
        |> Enum.flat_map(& &1["brackets"])
        |> Enum.flat_map(& &1["pairs"])
        |> Enum.map(&MapSet.new(Enum.reject(&1, fn x -> is_nil(x) end)))
        |> MapSet.new()

      assert explained == seated
    end

    @tag :javafo
    test "a JaVaFo round stores nothing rather than an empty explanation" do
      # nil, not %{} - the page distinguishes "this engine cannot explain
      # itself" from "it explained and had nothing to say".
      t = tournament()
      roster(t, 6)

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert round.explanation == nil
    end
  end
end
