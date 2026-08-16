defmodule PairingsEngine.PairingEngineTest do
  @moduledoc """
  `tournaments.pairing_engine` — which Swiss engine actually pairs a round.

  JaVaFo stays the default and the only engine permitted for a
  FIDE-homologated tournament (see docs/fide-endorsement.md: OpenPairings'
  whole endorsement story is FE1's "Internal engine: NO — thru JaVaFo").
  OpenPair is an opt-in beta alternative.

  Note which tests carry `@tag :javafo` and which don't. The OpenPair tests
  are deliberately untagged: OpenPair needs no jar, no JVM and no external
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
    test "a Swiss tournament set to openpair pairs a round through OpenPair" do
      t = tournament(%{pairing_engine: "openpair"})
      players = roster(t)

      assert {:ok, round} = Pairing.pair_next_round(t)

      round = Repo.preload(round, :pairings)
      assert round.number == 1
      assert length(round.pairings) == 3

      # Everyone was seated, nobody twice.
      ids = paired_player_ids(round)
      assert Enum.sort(ids) == players |> Enum.map(& &1.id) |> Enum.sort()

      # Every board is a real game, and every seat is filled — the shape
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

    test "OpenPair's nil bye is normalized to the pairing-allocated bye row JaVaFo's 0 produces" do
      # OpenPair returns `{white_rank, nil}` for the pairing-allocated bye
      # where JaVaFo's text output writes a literal `0`. If the adapter
      # dropped that translation, `create_round/5` would try to look up rank
      # `nil` in the local rank map and crash — so an odd field is the
      # cheapest direct test of it.
      t = tournament(%{pairing_engine: "openpair"})
      roster(t, 5)

      assert {:ok, round} = Pairing.pair_next_round(t)
      round = Repo.preload(round, :pairings)

      byes = Enum.filter(round.pairings, &is_nil(&1.black_player_id))
      assert [bye] = byes
      assert bye.result == "bye"
      assert bye.white_player_id
      assert length(round.pairings) == 3
    end

    test "OpenPair pairs several rounds in a row off its own result history" do
      t = tournament(%{pairing_engine: "openpair", rounds_count: 3})
      roster(t)

      assert {:ok, r1} = Pairing.pair_next_round(t)
      enter_results(r1)

      assert {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))
      enter_results(r2)

      assert {:ok, r3} = Pairing.pair_next_round(Repo.reload!(t))
      assert r3.number == 3

      # No rematches across the three rounds — the history OpenPairings
      # writes really is being read back into the TRF OpenPair pairs from.
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

  # This block used to assert that OpenPair REFUSED a tournament carrying an
  # XXP line, because its TRF parser dropped every extension but XXR: the
  # forbidden pair would have been paired together, and the round would have
  # looked perfectly legal. XXP and XXA are implemented as of openpair
  # `451c749`, so what is tested here is the behaviour itself — the pair is
  # kept apart — on both engines, from identical inputs.
  describe "TRF extensions" do
    test "OpenPair keeps a forbidden pair apart" do
      t = tournament(%{pairing_engine: "openpair"})
      [p1, p2 | _] = roster(t)

      # A pairing number has to exist before XXP lines can name anyone, so
      # pair and delete a round to freeze the numbering.
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

      # And it is a complete round, not a short one that dodged the
      # constraint by dropping somebody.
      assert length(paired_player_ids(round)) == 6
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

  describe "changeset: OpenPair and FIDE homologation are mutually exclusive" do
    test "selecting OpenPair on a FIDE-homologated tournament is refused" do
      t = tournament(%{fide_homologated: true, fide_tournament_id: "12345"})

      assert {:error, changeset} =
               Tournaments.update_tournament(t, %{"pairing_engine" => "openpair"})

      assert %{pairing_engine: [message]} = errors_on(changeset)
      assert message =~ "FIDE-homologated"
      assert Repo.reload!(t).pairing_engine == "javafo"
    end

    test "turning ON FIDE homologation while the engine is OpenPair is refused" do
      # The reverse direction. Checking only the changed field would let this
      # through and leave a homologated event running on a non-endorsed
      # engine — the exact state the rule exists to make unreachable.
      t = tournament(%{pairing_engine: "openpair"})

      assert {:error, changeset} =
               Tournaments.update_tournament(t, %{
                 "fide_homologated" => "true",
                 "fide_tournament_id" => "12345"
               })

      assert %{pairing_engine: [message]} = errors_on(changeset)
      assert message =~ "FIDE-homologated"
      refute Repo.reload!(t).fide_homologated
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

  # These two used to assert the OPPOSITE — that OpenPair and Baku were
  # mutually exclusive — because OpenPair's TRF parser discarded `XXA`
  # entirely and would have paired an accelerated tournament on
  # unaccelerated brackets. It reads `XXA` (and `XXP`) as of openpair
  # `451c749`, verified against bbpPairings over 1.79M rounds carrying
  # those lines, so the combination is now legal and these assert that it
  # is allowed rather than refused.
  describe "changeset: OpenPair works with Baku acceleration" do
    test "selecting OpenPair on a Baku-accelerated tournament is allowed" do
      t = tournament(%{acceleration: "baku"})

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"pairing_engine" => "openpair"})
      assert updated.pairing_engine == "openpair"
      assert updated.acceleration == "baku"
    end

    test "turning ON Baku acceleration while the engine is OpenPair is allowed" do
      t = tournament(%{pairing_engine: "openpair"})

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

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"pairing_engine" => "openpair"})
      assert updated.pairing_engine == "openpair"
    end

    test "it joins locked_fields/1 once a round exists" do
      t = tournament(%{pairing_engine: "openpair"})
      roster(t)
      {:ok, _round} = Pairing.pair_next_round(t)

      t = Repo.reload!(t)
      assert :pairing_engine in Tournaments.locked_fields(t)
    end

    test "update_tournament/2 refuses the switch after round 1" do
      t = tournament(%{pairing_engine: "openpair"})
      roster(t)
      {:ok, _round} = Pairing.pair_next_round(t)
      t = Repo.reload!(t)

      assert Tournaments.update_tournament(t, %{"pairing_engine" => "javafo"}) ==
               {:error, :locked_after_pairing}

      assert Repo.reload!(t).pairing_engine == "openpair"
    end

    test "re-submitting the same engine unchanged still saves" do
      # The ordinary form case: the control is disabled but still posts its
      # current value.
      t = tournament(%{pairing_engine: "openpair"})
      roster(t)
      {:ok, _round} = Pairing.pair_next_round(t)
      t = Repo.reload!(t)

      assert {:ok, _} =
               Tournaments.update_tournament(t, %{
                 "pairing_engine" => "openpair",
                 "venue" => "Town Hall"
               })
    end
  end

  ## ---------- the other two pairing systems ignore it entirely ----------

  describe "round robin and Keizer are unaffected" do
    test "a round robin set to openpair pairs its Berger schedule, engine untouched" do
      t = tournament(%{pairing_system: "round_robin", pairing_engine: "openpair"})
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

      assert shape.("javafo") == shape.("openpair")
    end

    test "a Keizer tournament set to openpair pairs through Keizer's own algorithm" do
      t = tournament(%{pairing_system: "keizer", pairing_engine: "openpair"})
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

      assert shape.("javafo") == shape.("openpair")
    end

    test "a forbidden pairing on a round robin is not refused, engine notwithstanding" do
      # The XXP guard is Swiss-only: a round robin's fixed schedule never
      # builds a TRF at all, so an OpenPair round robin with a forbidden
      # pairing must still pair (the schedule ignores the rule by design —
      # see docs/pairing-systems.md).
      t = tournament(%{pairing_system: "round_robin", pairing_engine: "openpair"})
      [p1, p2 | _] = roster(t, 4)

      {:ok, round} = Pairing.pair_next_round(t)
      :ok = delete_round(t, round)

      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p2.id)

      assert {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
    end
  end

  defp player_number(nil), do: nil
  defp player_number(id), do: Repo.get!(PairingsEngine.Tournaments.Player, id).pairing_number
end
