defmodule PairingsEngine.ByeExclusionsTest do
  @moduledoc """
  "No pairing-allocated bye" per player - an organiser's rule, not FIDE's
  (docs/pairing-systems.md, "Bye exclusions"). Ainalrami only, so every test
  here runs without a JVM.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, RoundExplanation, TournamentExport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.Player

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "byeexcl#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Bye exclusions",
            "type" => "swiss",
            "rounds_count" => "5",
            "pairing_engine" => "ainalrami"
          },
          attrs
        )
      )

    t
  end

  # Five players, evenly spaced ratings, so P5 is the lowest-ranked and the
  # one round 1 gives the bye to when nobody is excluded.
  defp roster(t, overrides \\ %{}) do
    for n <- 1..5 do
      attrs =
        Map.merge(
          %{"name" => "P#{n}", "fide_rating" => 2000 - n * 50},
          Map.get(overrides, n, %{})
        )

      {:ok, p} = Tournaments.create_player(t.id, attrs)
      p
    end
  end

  defp bye_holder(round) do
    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.find_value(fn p -> if is_nil(p.black_player_id), do: p.white_player_id end)
  end

  defp section(round),
    do: round |> Repo.reload!() |> Map.fetch!(:explanation) |> Map.fetch!("sections") |> hd()

  describe "the player setting" do
    test "certain rounds are typed like absences and stored the same way" do
      t = tournament(user_scope())

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "A",
          "no_bye" => "true",
          "no_bye_scope" => "rounds",
          "no_bye_rounds" => "4-2;7"
        })

      assert p.no_bye
      assert p.no_bye_rounds == "2,3,4,7"
      assert Player.no_bye_for_round?(p, 3)
      refute Player.no_bye_for_round?(p, 5)
    end

    test "all rounds keeps no rounds, and applies to every round" do
      t = tournament(user_scope())

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "A",
          "no_bye" => "true",
          "no_bye_scope" => "all",
          "no_bye_rounds" => "3"
        })

      assert p.no_bye_rounds == ""
      assert Player.no_bye_for_round?(p, 1)
      assert Player.no_bye_for_round?(p, 9)
    end

    test "certain rounds with none typed is refused" do
      t = tournament(user_scope())

      assert {:error, changeset} =
               Tournaments.create_player(t.id, %{
                 "name" => "A",
                 "no_bye" => "true",
                 "no_bye_scope" => "rounds",
                 "no_bye_rounds" => ""
               })

      assert Keyword.has_key?(changeset.errors, :no_bye_rounds)
    end

    test "rubbish in the rounds is refused like an absence would be" do
      t = tournament(user_scope())

      assert {:error, changeset} =
               Tournaments.create_player(t.id, %{
                 "name" => "A",
                 "no_bye" => "true",
                 "no_bye_scope" => "rounds",
                 "no_bye_rounds" => "three"
               })

      assert Keyword.has_key?(changeset.errors, :no_bye_rounds)
    end

    test "turning it off clears the rounds" do
      t = tournament(user_scope())

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "A",
          "no_bye" => "true",
          "no_bye_scope" => "rounds",
          "no_bye_rounds" => "2"
        })

      {:ok, p} = Tournaments.update_player(p, %{"no_bye" => "false"})
      refute p.no_bye
      assert p.no_bye_rounds == ""
      refute Player.no_bye_for_round?(p, 2)
    end
  end

  describe "pairing" do
    test "the excluded lowest-ranked player is skipped for the bye" do
      t = tournament(user_scope())
      players = roster(t, %{5 => %{"no_bye" => "true", "no_bye_scope" => "all"}})
      p5 = List.last(players)

      assert {:ok, round} = Pairing.pair_next_round(t)
      holder = bye_holder(round)
      assert holder
      refute holder == p5.id

      section = section(round)
      assert section["bye_exclusions"] == [p5.id]
      assert section["bye_passed_over"] == [p5.id]

      # The round did not pair the way FIDE's rules would have, and the
      # tournament's record and the TRF note say so.
      assert Repo.reload!(t).fide_compliance_lost_round == 1
      assert RoundExplanation.bye_exclusion_rounds(t.id) == [1]

      [resolved] = RoundExplanation.for_round(Repo.reload!(round), players)
      assert Enum.map(resolved.bye_passed_over, & &1.id) == [p5.id]
    end

    test "an exclusion for other rounds changes nothing in this one" do
      t = tournament(user_scope())

      players =
        roster(t, %{
          5 => %{"no_bye" => "true", "no_bye_scope" => "rounds", "no_bye_rounds" => "3"}
        })

      p5 = List.last(players)

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert bye_holder(round) == p5.id

      section = section(round)
      refute Map.has_key?(section, "bye_exclusions")
      refute Map.has_key?(section, "bye_passed_over")
      assert Repo.reload!(t).fide_compliance_lost_round == nil
      assert RoundExplanation.bye_exclusion_rounds(t.id) == []
    end

    test "an exclusion that does not bite pairs exactly as none, and records no deviation" do
      scope = user_scope()
      plain = tournament(scope)
      roster(plain)
      {:ok, plain_round} = Pairing.pair_next_round(plain)

      t = tournament(scope)
      roster(t, %{1 => %{"no_bye" => "true", "no_bye_scope" => "all"}})
      {:ok, round} = Pairing.pair_next_round(t)

      boards = fn r ->
        r
        |> Repo.preload(:pairings, force: true)
        |> Map.fetch!(:pairings)
        |> Enum.map(fn p ->
          {p.board, Repo.get!(Player, p.white_player_id).name,
           p.black_player_id && Repo.get!(Player, p.black_player_id).name}
        end)
      end

      assert boards.(round) == boards.(plain_round)
      assert section(round)["bye_exclusions"] != nil
      refute Map.has_key?(section(round), "bye_passed_over")
      assert Repo.reload!(t).fide_compliance_lost_round == nil
    end

    test "everyone excluded: refused with the players and an override, which then pairs" do
      t = tournament(user_scope())
      all = for n <- 1..5, into: %{}, do: {n, %{"no_bye" => "true", "no_bye_scope" => "all"}}
      players = roster(t, all)
      p5 = List.last(players)

      assert {:error, {:bye_exclusions, info}} = Pairing.pair_next_round(t)
      assert Enum.sort(info.excluded) == players |> Enum.map(& &1.id) |> Enum.sort()
      assert info.override == p5.id
      assert Tournaments.list_rounds(t.id) == []

      assert {:ok, round} = Pairing.pair_next_round(t, bye_exclusion_override: p5.id)
      assert bye_holder(round) == p5.id
      assert section(round)["bye_exclusion_lifted"] == p5.id
      refute p5.id in section(round)["bye_exclusions"]

      # Lifted for that round only: the setting itself is untouched.
      assert Repo.reload!(p5).no_bye
    end
  end

  describe "backups and duplicates" do
    test "the fields travel in the export envelope" do
      assert :no_bye in TournamentExport.player_fields()
      assert :no_bye_rounds in TournamentExport.player_fields()
    end

    test "a JSON round trip keeps them" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Kept",
          "no_bye" => "true",
          "no_bye_scope" => "rounds",
          "no_bye_rounds" => "2,4"
        })

      envelope = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, [copy]} = PairingsEngine.TournamentImport.import(envelope, user_scope())

      [p] = Repo.all(from p in Player, where: p.tournament_id == ^copy.id)
      assert p.no_bye
      assert p.no_bye_rounds == "2,4"
    end
  end
end
