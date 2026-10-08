defmodule PairingsEngine.ProhibitionsFideModeTest do
  @moduledoc """
  VCL4THP Q195/Q196 and C.05 5.2: in FIDE mode, prohibitions - forbidden
  pairs and pairing rules, hard or soft - are announced before round 1 is
  paired. Setting them then is no departure. Adding, changing or removing
  one once round 1 is paired is: the act is recorded (`prohibition_changes`),
  stamps `fide_compliance_lost_round` and is written as a `### Prohibition`
  line in TRF26 copies. What a rule does to a late entrant is not an act,
  and nothing done before this existed is re-judged.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{
    Compliance,
    Pairing,
    Repo,
    TournamentExport,
    TournamentImport,
    TrfExport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{ForbiddenPairing, PairingRule, Tournament}

  defp tournament(attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Club championship",
              type: "swiss",
              rounds_count: 4,
              tiebreaks: ~w(BH SB),
              round_dates: for(d <- 1..4, do: "2026-09-0#{d}")
            },
            attrs
          )
        )
      )

    players =
      for {name, rating, club} <- [
            {"Alice", 2000, "Rook"},
            {"Bob", 1900, "Knight"},
            {"Carol", 1800, "Rook"},
            {"Dave", 1700, "Knight"},
            {"Eve", 1600, "Bishop"},
            {"Frank", 1500, "Pawn"}
          ],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{name: name, fide_rating: rating, club: club})

        {name, p}
      end

    {t, players}
  end

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    round = Tournaments.get_round(t.id, round.number)

    for p <- round.pairings, p.black_player_id, p.result == "" do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    round
  end

  defp met?(t, a, b) do
    t.id
    |> Tournaments.list_rounds()
    |> Enum.flat_map(&Tournaments.get_round(t.id, &1.number).pairings)
    |> Enum.any?(
      &(MapSet.new([&1.white_player_id, &1.black_player_id]) == MapSet.new([a.id, b.id]))
    )
  end

  defp copy(t), do: t |> Repo.reload!() |> TrfExport.export(nil, copy: true) |> elem(1)

  describe "before round 1 is paired" do
    test "hard and soft pairs, rules and groups are all allowed, and nothing is recorded" do
      {t, p} = tournament()

      {:ok, _} = Tournaments.add_forbidden_pairing(t, p["Alice"].id, p["Bob"].id)
      {:ok, _} = Tournaments.add_forbidden_pairing(t, p["Carol"].id, p["Dave"].id, soft: true)
      {:ok, _} = Tournaments.add_pairing_rule(t, %{"kind" => "club"})

      {:ok, _} =
        Tournaments.add_pairing_rule(t, %{
          "kind" => "federation",
          "soft" => true,
          "window" => "last",
          "window_rounds" => 2
        })

      {:ok, group} =
        Tournaments.add_forbidden_group(t, [p["Eve"].id, p["Frank"].id, p["Bob"].id])

      assert %PairingRule{kind: "group"} = group
      {:ok, _} = Tournaments.update_pairing_rule(t, group.id, %{"soft" => true})
      {:ok, _} = Tournaments.delete_pairing_rule(t, group.id)

      t = Repo.reload!(t)
      assert Compliance.fide_mode?(t)
      assert t.prohibition_changes == []
      refute Tournaments.prohibition_change_departs?(t)
    end

    test "a rule set then is kept by the pairing, and a pair of the group too" do
      {t, p} = tournament()
      {:ok, _} = Tournaments.add_pairing_rule(t, %{"kind" => "club"})

      pair!(t)
      refute met?(t, p["Alice"], p["Carol"])
      refute met?(t, p["Bob"], p["Dave"])
      assert Compliance.fide_mode?(Repo.reload!(t))
    end
  end

  describe "once round 1 is paired, in FIDE mode" do
    test "adding a pair leaves FIDE mode, recorded, and the copy says so" do
      {t, p} = tournament()
      pair!(t)
      assert Tournaments.prohibition_change_departs?(Repo.reload!(t))

      {:ok, row} = Tournaments.add_forbidden_pairing(Repo.reload!(t), p["Alice"].id, p["Eve"].id)
      assert row.from_round == 2

      t = Repo.reload!(t)
      refute Compliance.fide_mode?(t)
      assert t.fide_compliance_lost_round == 1

      assert [%{"round" => 2, "action" => "added", "what" => "pair", "soft" => false}] =
               t.prohibition_changes

      text = copy(t)
      assert text =~ "### FIDE mode exited @ Round 1"

      a = Repo.reload!(p["Alice"]).pairing_number
      e = Repo.reload!(p["Eve"]).pairing_number
      assert text =~ "### Prohibition @ Round 2: #{a}-#{e} added"

      {:ok, rating} = TrfExport.export(t, [1], for: :rating)
      refute rating =~ "###"
    end

    test "every kind of change counts, and only the first one stamps" do
      {t, p} = tournament()
      {:ok, pair} = Tournaments.add_forbidden_pairing(t, p["Alice"].id, p["Eve"].id)
      {:ok, rule} = Tournaments.add_pairing_rule(t, %{"kind" => "club"})
      pair!(t)

      {:ok, _} = Tournaments.set_forbidden_pairing_soft(Repo.reload!(t), pair.id, true)
      assert Repo.reload!(t).fide_compliance_lost_round == 1

      {:ok, updated} =
        Tournaments.update_pairing_rule(Repo.reload!(t), rule.id, %{
          "window" => "last",
          "window_rounds" => 1
        })

      assert updated.from_round == 2
      {:ok, _} = Tournaments.delete_pairing_rule(Repo.reload!(t), rule.id)
      {:ok, _} = Tournaments.remove_forbidden_pairing(Repo.reload!(t), pair.id)

      t = Repo.reload!(t)
      assert t.fide_compliance_lost_round == 1

      assert Enum.map(t.prohibition_changes, &{&1["what"], &1["action"]}) == [
               {"pair", "changed"},
               {"rule", "changed"},
               {"rule", "removed"},
               {"pair", "removed"}
             ]

      text = copy(t)
      assert text =~ "made a wish (if possible)"
      assert text =~ "rule same club, last 1 rounds changed"
      assert text =~ "rule same club, last 1 rounds removed"
    end

    test "how hard the wishes are tried counts too - but only when there is a wish" do
      {t, _p} = tournament()
      pair!(t)

      assert Tournaments.fide_departures(Repo.reload!(t), %{"soft_position" => "weak"}) == []
      {:ok, t2} = Tournaments.update_tournament(Repo.reload!(t), %{"soft_position" => "weak"})
      assert Compliance.fide_mode?(t2)
      assert t2.prohibition_changes == []

      Repo.insert!(%PairingRule{tournament_id: t.id, kind: "club", soft: true})

      assert [%{code: :prohibition_changed_after_round_1}] =
               Tournaments.fide_departures(Repo.reload!(t), %{"soft_position" => "strong"})

      {:ok, t3} = Tournaments.update_tournament(Repo.reload!(t), %{"soft_position" => "strong"})
      assert t3.fide_compliance_lost_round == 1

      assert [%{"what" => "soft_position", "from" => "weak", "to" => "strong", "round" => 2}] =
               t3.prohibition_changes

      assert copy(t3) =~ "### Prohibition @ Round 2: wishes tried weak -> strong"
    end

    test "a late entrant covered by a rule announced before round 1 is not a change" do
      {t, p} = tournament()
      {:ok, _} = Tournaments.add_pairing_rule(t, %{"kind" => "club"})
      pair!(t)

      {:ok, late} =
        Tournaments.create_player(t.id, %{name: "Gina", fide_rating: 1650, club: "Pawn"})

      pair!(t)

      t = Repo.reload!(t)
      assert Compliance.fide_mode?(t)
      assert t.prohibition_changes == []
      refute met?(t, late, p["Frank"])
    end
  end

  describe "outside FIDE mode, imports and the upgrade" do
    test "a change after round 1 is still recorded, and the stamp is left as it was" do
      {t, p} = tournament()
      pair!(t)
      {:ok, _} = Tournaments.leave_fide_mode(Repo.reload!(t))
      pair!(t)

      {:ok, _} = Tournaments.add_forbidden_pairing(Repo.reload!(t), p["Alice"].id, p["Eve"].id)

      t = Repo.reload!(t)
      assert t.fide_compliance_lost_round == 1
      assert [%{"round" => 3}] = t.prohibition_changes
    end

    test "an import's own prohibitions record nothing" do
      {t, p} = tournament()
      pair!(t)

      {:ok, _} =
        Tournaments.add_forbidden_pairing(Repo.reload!(t), p["Alice"].id, p["Eve"].id,
          import: true
        )

      {:ok, _} = Tournaments.add_pairing_rule(Repo.reload!(t), %{"kind" => "club"}, import: true)

      t = Repo.reload!(t)
      assert Compliance.fide_mode?(t)
      assert t.prohibition_changes == []
    end

    test "prohibitions added after round 1 before this existed do not push a tournament out" do
      {t, p} = tournament()
      pair!(t)

      # What 0.78.0 left behind: rows added late, with nothing recorded.
      Repo.insert!(%ForbiddenPairing{
        tournament_id: t.id,
        player_a_id: p["Alice"].id,
        player_b_id: p["Eve"].id,
        from_round: 2
      })

      Repo.insert!(%PairingRule{tournament_id: t.id, kind: "club", from_round: 2})

      pair!(t)

      t = Repo.reload!(t)
      assert Compliance.fide_mode?(t)
      assert is_nil(t.fide_compliance_lost_round)
      refute copy(t) =~ "### Prohibition"
    end

    test "a JSON copy carries the rules and the record, with its players renumbered" do
      {t, p} = tournament()
      {:ok, _} = Tournaments.add_pairing_rule(t, %{"kind" => "club", "soft" => true})
      pair!(t)

      {:ok, _} =
        Tournaments.add_forbidden_group(Repo.reload!(t), [
          p["Alice"].id,
          p["Eve"].id,
          p["Frank"].id
        ])

      scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      envelope = TournamentExport.export_tournament(Repo.reload!(t))
      {:ok, [copy]} = TournamentImport.import(Jason.decode!(Jason.encode!(envelope)), scope)
      copy = Repo.reload!(copy)

      assert copy.fide_compliance_lost_round == 1
      assert [%{"what" => "rule", "players" => ids}] = copy.prohibition_changes

      names =
        copy.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1.name})

      assert Enum.map(ids, &names[&1]) |> Enum.sort() == ["Alice", "Eve", "Frank"]

      assert [%{kind: "club", soft: true}, %{kind: "group", player_ids: members}] =
               Tournaments.list_pairing_rules(copy.id)

      assert Enum.map(members, &names[&1]) |> Enum.sort() == ["Alice", "Eve", "Frank"]
    end
  end
end
