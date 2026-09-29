defmodule PairingsEngine.ByePreferencesTest do
  @moduledoc """
  Per-player bye preferences - must get / rather gets / rather not the
  pairing-allocated bye, an organiser's wish and not FIDE's
  (docs/pairing-systems.md, "Bye preferences"); "must not get it" is the
  bye exclusion, tested in `PairingsEngine.ByeExclusionsTest`. Ainalrami
  only, so no JVM; never on a FIDE-rated tournament.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, RoundExplanation, TournamentExport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.Player

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "byepref#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        user_scope(),
        Map.merge(
          %{
            "name" => "Bye preferences",
            "type" => "swiss",
            "rounds_count" => "5",
            "pairing_engine" => "ainalrami"
          },
          attrs
        )
      )

    t
  end

  # Five players, evenly spaced ratings: round 1 gives P5 the bye.
  defp roster(t, overrides) do
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

  defp pref(kind, rounds \\ nil) do
    if rounds,
      do: %{
        "bye_preference" => kind,
        "bye_preference_scope" => "rounds",
        "bye_preference_rounds" => rounds
      },
      else: %{"bye_preference" => kind, "bye_preference_scope" => "all"}
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
      t = tournament()
      {:ok, p} = Tournaments.create_player(t.id, Map.put(pref("want_soft", "4-2;7"), "name", "A"))

      assert p.bye_preference == "want_soft"
      assert p.bye_preference_rounds == "2,3,4,7"
      assert Player.bye_preference_for_round(p, 3) == :want_soft
      assert Player.bye_preference_for_round(p, 5) == nil
    end

    test "all rounds keeps no rounds; none clears them" do
      t = tournament()

      {:ok, p} =
        Tournaments.create_player(
          t.id,
          %{"name" => "A"}
          |> Map.merge(pref("want_hard"))
          |> Map.put("bye_preference_rounds", "3")
        )

      assert p.bye_preference_rounds == ""
      assert Player.bye_preference_for_round(p, 9) == :want_hard

      {:ok, p} = Tournaments.update_player(p, pref("avoid_soft", "2"))
      assert p.bye_preference_rounds == "2"
      {:ok, p} = Tournaments.update_player(p, %{"bye_preference" => ""})
      assert p.bye_preference_rounds == ""
      assert Player.bye_preference_for_round(p, 2) == nil
    end

    test "an unknown value, and certain rounds with none typed, are refused" do
      t = tournament()

      assert {:error, cs} =
               Tournaments.create_player(t.id, %{"name" => "A", "bye_preference" => "avoid_hard"})

      assert cs.errors[:bye_preference]

      assert {:error, cs} =
               Tournaments.create_player(t.id, Map.put(pref("want_soft", ""), "name", "A"))

      assert cs.errors[:bye_preference_rounds]
    end

    test "wanting the bye where the player is excluded from it is refused" do
      t = tournament()
      excluded = %{"no_bye" => "true", "no_bye_scope" => "all"}

      assert {:error, cs} =
               Tournaments.create_player(
                 t.id,
                 %{"name" => "A"} |> Map.merge(excluded) |> Map.merge(pref("want_hard"))
               )

      assert {msg, _} = cs.errors[:bye_preference]
      assert msg =~ "excluded"

      some = %{"no_bye" => "true", "no_bye_scope" => "rounds", "no_bye_rounds" => "2-4"}

      assert {:error, cs} =
               Tournaments.create_player(
                 t.id,
                 %{"name" => "B"} |> Map.merge(some) |> Map.merge(pref("want_soft", "4,6"))
               )

      assert {msg, _} = cs.errors[:bye_preference]
      assert msg =~ "(4)"

      # Different rounds, and a "rather not" beside the exclusion: fine.
      assert {:ok, _} =
               Tournaments.create_player(
                 t.id,
                 %{"name" => "C"} |> Map.merge(some) |> Map.merge(pref("want_hard", "5,6"))
               )

      assert {:ok, _} =
               Tournaments.create_player(
                 t.id,
                 %{"name" => "D"} |> Map.merge(excluded) |> Map.merge(pref("avoid_soft"))
               )
    end
  end

  describe "pairing" do
    test "must get it: the player gets the bye, and the round is marked as leaving FIDE" do
      t = tournament()
      [p1 | _] = players = roster(t, %{1 => pref("want_hard")})
      p5 = List.last(players)

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert bye_holder(round) == p1.id

      record = section(round)["bye_preference"]
      assert record["moved"] == true
      assert record["bye"] == p1.id
      assert record["fide_bye"] == p5.id
      assert record["decided_by"] == "want_hard"

      assert [%{"player" => id, "preference" => "want_hard", "outcome" => "honoured"}] =
               record["outcomes"]

      assert id == p1.id

      assert Pairing.pairing_deviations(Repo.reload!(t), 1) == [:bye_preference]
      assert Repo.reload!(t).fide_compliance_lost_round == 1
      assert RoundExplanation.bye_preference_rounds(t.id) == [1]
      # The exclusions it resolved to are not the organiser's.
      refute Map.has_key?(section(round), "bye_exclusions")
    end

    test "rather gets it and rather not decide among the lowest scorers" do
      t = tournament()
      players = roster(t, %{4 => pref("want_soft")})
      assert {:ok, round} = Pairing.pair_next_round(t)
      assert bye_holder(round) == Enum.at(players, 3).id
      assert section(round)["bye_preference"]["decided_by"] == "want_soft"

      t = tournament()
      players = roster(t, %{5 => pref("avoid_soft")})
      assert {:ok, round} = Pairing.pair_next_round(t)
      refute bye_holder(round) == List.last(players).id
      assert section(round)["bye_preference"]["decided_by"] == "avoid_soft"
    end

    test "a preference that changes nothing records no deviation" do
      t = tournament()
      players = roster(t, %{5 => pref("want_hard")})
      assert {:ok, round} = Pairing.pair_next_round(t)
      assert bye_holder(round) == List.last(players).id
      assert section(round)["bye_preference"]["moved"] == false
      assert Pairing.pairing_deviations(Repo.reload!(t), 1) == []
      assert Repo.reload!(t).fide_compliance_lost_round == nil
    end

    test "a preference for other rounds changes nothing in this one" do
      t = tournament()
      players = roster(t, %{1 => pref("want_hard", "3")})
      assert {:ok, round} = Pairing.pair_next_round(t)
      assert bye_holder(round) == List.last(players).id
      refute Map.has_key?(section(round), "bye_preference")
    end

    test "must get it, where no legal pairing allows: paired normally, and why is recorded" do
      t = tournament()
      [p1, p2, p3, p4, p5] = roster(t, %{1 => pref("want_hard")})

      # P2 may meet nobody but P1, so a bye for P1 leaves P2 unpaired.
      for other <- [p3, p4, p5],
          do: {:ok, _} = Tournaments.add_forbidden_pairing(t, p2.id, other.id)

      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      refute bye_holder(round) == p1.id

      record = section(round)["bye_preference"]
      assert record["moved"] == false
      assert [%{"outcome" => "unpairable"}] = record["outcomes"]
      assert Repo.reload!(t).fide_compliance_lost_round == nil
    end

    test "a FIDE-rated tournament ignores them, keeps them, and names them" do
      t = tournament(%{"fide_homologated" => "true"})
      [p1 | _] = players = roster(t, %{1 => pref("want_hard")})

      assert Pairing.ignored_bye_preferences(Repo.reload!(t)) == ["P1"]
      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      assert bye_holder(round) == List.last(players).id
      refute Map.has_key?(section(round), "bye_preference")
      assert Repo.reload!(p1).bye_preference == "want_hard"
    end

    test "a tournament that becomes FIDE-rated stops applying them" do
      t = tournament()
      players = roster(t, %{1 => pref("want_hard")})
      assert Pairing.ignored_bye_preferences(t) == []

      {:ok, t} = Tournaments.update_tournament(t, %{"fide_homologated" => "true"})
      assert Pairing.ignored_bye_preferences(t) == ["P1"]
      assert {:ok, round} = Pairing.pair_next_round(t)
      assert bye_holder(round) == List.last(players).id
    end

    test "the rebuilt field judges the round under the exclusions it was paired by" do
      t = tournament()
      [p1 | _] = roster(t, %{1 => pref("want_hard")})
      assert {:ok, _round} = Pairing.pair_next_round(t)

      {:ok, field} = Pairing.engine_field(Repo.reload!(t), 1)
      rank = field.local_rank_by_player_id[p1.id]
      excluded = field.opts[:bye_exclusions]
      assert length(excluded) == 4
      refute rank in excluded
      assert field.organiser_exclusions == []
    end
  end

  describe "backups and duplicates" do
    test "the fields travel in the export envelope" do
      assert :bye_preference in TournamentExport.player_fields()
      assert :bye_preference_rounds in TournamentExport.player_fields()
    end

    test "a JSON round trip keeps them" do
      t = tournament()

      {:ok, _} =
        Tournaments.create_player(t.id, Map.put(pref("avoid_soft", "2,4"), "name", "Kept"))

      envelope = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, [copy]} = PairingsEngine.TournamentImport.import(envelope, user_scope())

      [p] = Repo.all(from p in Player, where: p.tournament_id == ^copy.id)
      assert p.bye_preference == "avoid_soft"
      assert p.bye_preference_rounds == "2,4"
    end
  end
end
