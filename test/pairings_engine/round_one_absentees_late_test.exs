defmodule PairingsEngine.RoundOneAbsenteesLateTest do
  @moduledoc """
  C.04.2 2.4 in every Swiss created since 0.79: a player absent from round 1
  is a late entry - no pairing number at round 1, numbered when they arrive
  under `late_entry_numbering`. Baku did this already (VCL4THP Q111,
  `baku_group_a_test.exs`); tournaments that existed before keep numbering
  their round-1 absentees with the field.

  The case that started it, from production: a player absent when round 1
  was first paired, round 1 unpaired and paired again with them present,
  came out with the last number instead of the one their rating earns.
  """

  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Pairing, Repo, Tournaments, Tpn}
  alias PairingsEngine.{TournamentExport, TournamentImport, TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  # Sixteen players, 2370 down to 1920 in steps of 30, plus whoever a test
  # adds. A 2090 sits between P10 (2100) and P11 (2070): number 11.
  defp new_tournament(attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        user_scope_fixture(),
        Map.merge(
          %{
            "name" => "Late entries",
            "type" => "swiss",
            "rounds_count" => 7,
            "start_date" => "2026-09-01",
            "end_date" => "2026-09-07",
            "round_dates" => for(n <- 1..7, do: "2026-09-0#{n}")
          },
          attrs
        )
      )

    for n <- 1..16, do: add_player(t, "P#{String.pad_leading("#{n}", 2, "0")}", 2400 - n * 30)
    t
  end

  defp add_player(t, name, rating, attrs \\ %{}) do
    {:ok, p} =
      Tournaments.create_player(
        t.id,
        Map.merge(%{"name" => name, "fide_rating" => rating}, attrs)
      )

    p
  end

  defp play_round(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    pn = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})

    for p <- Repo.preload(round, :pairings, force: true).pairings,
        p.black_player_id != nil and p.result in [nil, ""] do
      result = if pn[p.white_player_id] < pn[p.black_player_id], do: "1-0", else: "0-1"
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end

    round
  end

  defp number(%Player{id: id}), do: Repo.get!(Player, id).pairing_number

  defp numbers(t),
    do: t.id |> Pairing.full_roster_players() |> Enum.map(& &1.pairing_number) |> Enum.sort()

  describe "the flag" do
    test "is set on a tournament the app creates, and off on one that already existed" do
      assert new_tournament().round_one_absentees_late
      # What the migration gives every existing row, and the schema default.
      refute Repo.insert!(%Tournament{name: "Old", type: "swiss"}).round_one_absentees_late
    end

    test "an imported TRF keeps the file's numbering: off" do
      t = new_tournament()
      play_round(t)
      {:ok, text} = TrfExport.export(Repo.reload!(t))

      {:ok, imported, _warnings} = TrfImport.import_text(text, user_scope_fixture())
      refute Repo.reload!(imported).round_one_absentees_late
    end

    test "travels in a backup; a file from before it comes back off" do
      t = new_tournament()

      envelope =
        t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      scope = user_scope_fixture()

      {:ok, [copy]} = TournamentImport.import(envelope, scope)
      assert Repo.reload!(copy).round_one_absentees_late

      legacy =
        update_in(
          envelope,
          ["tournaments", Access.at(0), "tournament"],
          &Map.delete(&1, "round_one_absentees_late")
        )

      {:ok, [old]} = TournamentImport.import(legacy, scope)
      refute Repo.reload!(old).round_one_absentees_late
    end
  end

  describe "a new Swiss" do
    test "absent at round 1: no number, and the field is numbered 1..N without them" do
      t = new_tournament()
      x = add_player(t, "Absent, Round One", 2090, %{"absent_rounds" => "1"})

      play_round(t)

      assert number(x) == nil
      assert numbers(t) == Enum.to_list(1..16)
    end

    test "the production case: absent when round 1 was paired, present when it is paired again - numbered by rating" do
      t = new_tournament()
      x = add_player(t, "Back, Again", 2090, %{"absent_rounds" => "1"})

      play_round(t)
      assert number(x) == nil

      :ok = Pairing.delete_round(t.id, 1)
      {:ok, _} = Tournaments.update_player(Repo.get!(Player, x.id), %{"absent_rounds" => ""})
      play_round(t)

      assert number(x) == 11
      assert numbers(t) == Enum.to_list(1..17)
    end

    test "the same when the absence was the whole-tournament flag" do
      t = new_tournament()
      x = add_player(t, "Back, Again", 2090)
      {:ok, _} = Tournaments.update_player(x, %{"absent" => true})

      play_round(t)
      assert number(x) == nil

      :ok = Pairing.delete_round(t.id, 1)
      {:ok, _} = Tournaments.update_player(Repo.get!(Player, x.id), %{"absent" => false})
      play_round(t)

      assert number(x) == 11
    end

    test "and the same when round 1 is paired again by hand" do
      t = new_tournament()
      x = add_player(t, "Back, Again", 2090, %{"absent_rounds" => "1"})
      play_round(t)
      :ok = Pairing.delete_round(t.id, 1)
      {:ok, _} = Tournaments.update_player(Repo.get!(Player, x.id), %{"absent_rounds" => ""})

      {:ok, _round} = Pairing.create_round_by_hand(Repo.reload!(t))

      assert number(x) == 11
      assert numbers(t) == Enum.to_list(1..17)
    end

    test "present when round 1 was paired, absent when it is paired again: the number goes back" do
      t = new_tournament()
      play_round(t)
      # Numbers somebody chose (an exchange's) survive the unpairing; the
      # pairing's own are taken back by it, leaving none to hand back.
      Repo.update_all(Tournament, set: [pairing_numbers_origin: "exchange"])
      :ok = Pairing.delete_round(t.id, 1)

      p3 = Enum.find(Tournaments.list_players(t.id), &(&1.name == "P03"))
      assert p3.pairing_number == 3
      {:ok, _} = Tournaments.update_player(p3, %{"absent_rounds" => "1"})
      play_round(t)

      assert number(p3) == nil
      assert numbers(t) == Enum.to_list(1..15)
    end

    test "arriving in round 2 under \"rating\": the number the rating earns, the rest one down" do
      t = new_tournament()
      x = add_player(t, "Arrives, Round Two", 2090, %{"absent_rounds" => "1"})
      p11 = Enum.find(Tournaments.list_players(t.id), &(&1.name == "P11"))

      play_round(t)
      assert number(x) == nil
      assert number(p11) == 11

      play_round(t)

      assert number(x) == 11
      assert number(p11) == 12
      assert numbers(t) == Enum.to_list(1..17)
    end

    test "arriving in round 2 under \"after\": after the field" do
      t = new_tournament(%{"late_entry_numbering" => "after"})
      x = add_player(t, "Arrives, Round Two", 2090, %{"absent_rounds" => "1"})

      play_round(t)
      play_round(t)

      assert number(x) == 17
    end

    test "a later start round is a late entry too" do
      t = new_tournament()
      x = add_player(t, "Starts, Round Three", 2090, %{"start_round" => 3})

      play_round(t)
      play_round(t)
      assert number(x) == nil

      play_round(t)
      assert number(x) == 11
    end

    test "a regeneration while they wait leaves them unnumbered" do
      t = new_tournament()
      x = add_player(t, "Arrives, Round Three", 2090, %{"absent_rounds" => "1,2"})
      play_round(t)

      refute Enum.any?(Tpn.order(Repo.reload!(t)), fn {p, _n} -> p.id == x.id end)
    end

    test "the next-round preview numbers the arrival as the pairing will" do
      t = new_tournament()
      x = add_player(t, "Arrives, Round Two", 2090, %{"absent_rounds" => "1"})
      play_round(t)

      {:ok, context} = Pairing.preview_context(Repo.reload!(t))
      assert context.history.full_roster[x.id].pairing_number == 11
    end
  end

  describe "a tournament from before the rule" do
    test "numbers its round-1 absentee with the field, as it always did" do
      t = new_tournament()

      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [round_one_absentees_late: false]
      )

      x = add_player(t, "Absent, Round One", 2090, %{"absent_rounds" => "1"})
      play_round(t)

      assert number(x) == 11
    end

    test "switched on before round 1, the same tournament treats the absentee as a late entry" do
      t = new_tournament()

      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [round_one_absentees_late: false]
      )

      {:ok, _} =
        Tournaments.update_tournament(Repo.reload!(t), %{"round_one_absentees_late" => "true"})

      x = add_player(t, "Absent, Round One", 2090, %{"absent_rounds" => "1"})
      play_round(t)

      assert number(x) == nil
      assert numbers(t) == Enum.to_list(1..16)
    end

    test "and cannot be switched once round 1 is paired" do
      t = new_tournament()

      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [round_one_absentees_late: false]
      )

      play_round(t)

      assert {:error, _} =
               Tournaments.update_tournament(Repo.reload!(t), %{
                 "round_one_absentees_late" => "true"
               })

      refute Repo.reload!(t).round_one_absentees_late
    end
  end
end
