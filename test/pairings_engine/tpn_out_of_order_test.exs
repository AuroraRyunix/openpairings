defmodule PairingsEngine.TpnOutOfOrderTest do
  @moduledoc """
  `Tpn.out_of_order/1`: issued pairing numbers that no longer follow the
  ratings, reported while C.04.2 still lets them be corrected (round 4 not
  paired). It warns; it never refuses a pairing.
  """

  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, Tournaments, Tpn}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  # Sixteen players, 2370 down to 1920 in steps of 30.
  defp tournament(attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          %Tournament{name: "Order", type: "swiss", pairing_system: "swiss", rounds_count: 7},
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

  defp set_number(%Player{id: id}, n),
    do: Repo.update_all(from(p in Player, where: p.id == ^id), set: [pairing_number: n])

  defp named(t, name), do: Enum.find(Tournaments.list_players(t.id), &(&1.name == name))

  # What an older version left behind (production, 2026-10): a 2090, absent
  # when round 1 was first paired, round 1 unpaired and paired again with
  # them on a board - and numbered 17th, after the field, not 11th.
  defp production_case(attrs \\ %{}) do
    t = tournament(Map.merge(%{late_entry_numbering: "end"}, attrs))
    x = add_player(t, "Late, Number", 2090)
    play_round(t)
    assert Repo.get!(Player, x.id).pairing_number == 11

    for n <- 11..16, do: set_number(named(t, "P#{n}"), n)
    set_number(x, 17)
    {Repo.reload!(t), x}
  end

  test "the production case: the 2090 numbered 17 is reported, with the number its rating earns" do
    {t, x} = production_case()

    rows = Tpn.out_of_order(t)
    row = Enum.find(rows, &(&1.player.id == x.id))
    assert %{rating: 2090, number: 17, expected: 11} = row
    # The players it should sit above move down one each in a regeneration.
    assert rows |> Enum.map(&{&1.number, &1.expected}) |> Enum.sort() ==
             [{11, 12}, {12, 13}, {13, 14}, {14, 15}, {15, 16}, {16, 17}, {17, 11}]
  end

  test "a rating corrected after round 1 is reported" do
    t = tournament()
    play_round(t)

    {:ok, _} = Tournaments.update_player(named(t, "P16"), %{"fide_rating" => 2500})

    assert %{number: 16, expected: 1} =
             Enum.find(Tpn.out_of_order(Repo.reload!(t)), &(&1.player.name == "P16"))
  end

  test "an exchange between equal ratings is not" do
    t = tournament()
    a = add_player(t, "Equal, A", 2090)
    b = add_player(t, "Equal, B", 2090)
    {:ok, _} = Tpn.exchange(t, a.id, b.id)
    play_round(t)

    assert Repo.get!(Player, b.id).pairing_number < Repo.get!(Player, a.id).pairing_number
    assert Tpn.out_of_order(Repo.reload!(t)) == []
  end

  test "a late entrant numbered after the field under \"after\" is not" do
    t = tournament(%{late_entry_numbering: "after"})
    play_round(t)
    late = add_player(t, "Late, Strong", 2500, %{"start_round" => 2})
    play_round(t)

    assert Repo.get!(Player, late.id).pairing_number == 17
    assert Tpn.out_of_order(Repo.reload!(t)) == []
  end

  test "nor is a round-1 absentee of a new Swiss numbered after the field on arrival" do
    t = tournament(%{late_entry_numbering: "after", round_one_absentees_late: true})
    x = add_player(t, "Arrives, Round Two", 2500, %{"absent_rounds" => "1"})
    play_round(t)
    play_round(t)

    assert Repo.get!(Player, x.id).pairing_number == 17
    assert Tpn.out_of_order(Repo.reload!(t)) == []
  end

  test "under \"end\" in an old tournament, the round-1 absentee numbered with the field is checked" do
    t = tournament(%{late_entry_numbering: "end"})
    x = add_player(t, "Absent, Round One", 2090, %{"absent_rounds" => "1"})
    play_round(t)
    assert Repo.get!(Player, x.id).pairing_number == 11
    assert Tpn.out_of_order(Repo.reload!(t)) == []

    set_number(x, 99)
    assert Enum.any?(Tpn.out_of_order(Repo.reload!(t)), &(&1.player.id == x.id))
  end

  test "once round 4 is paired there is nothing to report: the numbers are fixed" do
    {t, _x} = production_case()
    refute Tpn.out_of_order(t) == []

    play_round(t)
    play_round(t)
    assert Tpn.out_of_order(Repo.reload!(t)) != []

    play_round(t)
    assert Tpn.out_of_order(Repo.reload!(t)) == []
  end

  test "a round robin is never checked" do
    {t, _x} = production_case()

    Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
      set: [pairing_system: "round_robin"]
    )

    assert Tpn.out_of_order(Repo.reload!(t)) == []
  end
end
