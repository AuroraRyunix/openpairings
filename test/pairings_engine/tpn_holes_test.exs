defmodule PairingsEngine.TpnHolesTest do
  @moduledoc """
  The three ways a Swiss came to be played on pairing numbers that do not
  follow the ratings, and what closes each: numbers left behind by a round
  1 that was only ever a practice run (`Pairing.delete_round/2` takes them
  back), late entrants appended at the end without anybody being asked
  (`Tpn.gate/1` asks, before rounds 2 to 4), and a grandfathered "at the
  end" nobody chose (`Tournaments.late_entry_notice?/1`). Plus where a new
  tournament's `late_entry_numbering` can come from.
  """

  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, Tournaments, Tpn, TournamentExport, TournamentImport}
  alias PairingsEngine.{TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{name: "Holes", type: "swiss", pairing_system: "swiss", rounds_count: 9},
        attrs
      )
    )
  end

  defp add_player(t, name, rating, attrs \\ %{}) do
    {:ok, p} =
      Tournaments.create_player(
        t.id,
        Map.merge(%{"name" => name, "fide_rating" => rating}, attrs)
      )

    p
  end

  defp add_batch(t, prefix, ratings) do
    for {rating, i} <- Enum.with_index(ratings, 1), do: add_player(t, "#{prefix}#{i}", rating)
  end

  defp pair(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    round
  end

  defp play_round(t) do
    round = pair(t)

    for p <- Repo.preload(round, :pairings, force: true).pairings,
        p.black_player_id != nil and p.result in [nil, ""] do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    round
  end

  defp players(t), do: Tournaments.list_players(t.id)
  defp number(%Player{id: id}), do: Repo.get!(Player, id).pairing_number

  defp ratings_by_number(t) do
    t
    |> players()
    |> Enum.filter(& &1.pairing_number)
    |> Enum.sort_by(& &1.pairing_number)
    |> Enum.map(&Player.rating(&1, t))
  end

  defp scope do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    PairingsEngine.Accounts.Scope.for_user(user)
  end

  # Thirteen players, 1900 down to 1300.
  defp first_thirteen(t), do: add_batch(t, "First", Enum.map(0..12, &(1900 - &1 * 50)))

  describe "the production sequence" do
    test "round 1 paired and unpaired for practice, the field entered afterwards, late entrants at the end" do
      t = tournament(%{late_entry_numbering: "end"})
      first_thirteen(t)

      # Paired and unpaired, several times, with only the first thirteen in.
      for _ <- 1..5 do
        pair(t)
        assert ratings_by_number(t) |> length() == 13
        assert Pairing.numbers_cleared_by_unpairing(t.id, 1) == 13
        :ok = Pairing.delete_round(t.id, 1)
        assert Enum.all?(players(t), &is_nil(&1.pairing_number))
      end

      # The rest of the field, in batches, some of them stronger than
      # anybody who was there for the practice runs - with one more
      # practice run in between, as there was.
      add_batch(t, "Second", [2100, 1450])
      pair(t)
      :ok = Pairing.delete_round(t.id, 1)
      add_batch(t, "Third", Enum.map(0..15, &(2260 - &1 * 55)))
      add_batch(t, "Fourth", Enum.map(0..10, &(2050 - &1 * 45)))

      # Round 1 for real: 42 players, numbered by rating and nothing else.
      play_round(t)
      ratings = ratings_by_number(t)
      assert length(ratings) == 42
      assert ratings == Enum.sort(ratings, :desc)
      assert Tpn.gate(Repo.reload!(t)) == []

      # Genuine late entrants, the strongest player of the event among them.
      im = add_player(t, "Late, IM", 2365)
      _other = add_player(t, "Late, Other", 1000)

      # Asked BEFORE round 2 is paired: the number they are about to get.
      rows = Tpn.gate(Repo.reload!(t))
      assert %{number: 43, expected: 1, rating: 2365} = Enum.find(rows, &(&1.player.id == im.id))
      # The 1000 goes last and belongs last: not out of place.
      refute Enum.any?(rows, &(&1.player.name == "Late, Other"))
      # Everybody the IM should be ahead of is one too high.
      assert length(rows) == 43

      # "Pair anyway": remembered for exactly this set of players.
      {:ok, _} = Tpn.accept(Repo.reload!(t), rows)
      assert Tpn.gate(Repo.reload!(t)) == []
      play_round(t)
      assert number(im) == 43
      assert Tpn.gate(Repo.reload!(t)) == []
      # The page's list goes back to the quiet one: the late entrants at the
      # end are the tournament's setting, asked about and answered.
      assert Tpn.warning(Repo.reload!(t)) == []

      # Another late entrant: a different set, so the question comes back.
      fm = add_player(t, "Late, FM", 2260)
      rows = Tpn.gate(Repo.reload!(t))
      assert Enum.any?(rows, &(&1.player.id == fm.id))
      assert Tpn.warning(Repo.reload!(t)) == Tpn.out_of_place(Repo.reload!(t))

      # "Renumber by rating and pair": the Players page's regeneration.
      {:ok, _} = Tpn.regenerate(Repo.reload!(t))
      assert Tpn.gate(Repo.reload!(t)) == []
      assert number(im) == 1
      play_round(t)
      ratings = ratings_by_number(t)
      assert length(ratings) == 45
      assert ratings == Enum.sort(ratings, :desc)
    end

    test "left alone until round 4 is paired: no question any more, and a note that can explain it" do
      t = tournament(%{late_entry_numbering: "end"})
      first_thirteen(t)
      play_round(t)
      im = add_player(t, "Late, IM", 2365)

      for _ <- 2..4 do
        rows = Tpn.gate(Repo.reload!(t))
        if rows != [], do: {:ok, _} = Tpn.accept(Repo.reload!(t), rows)
        play_round(t)
      end

      t = Repo.reload!(t)
      refute Tpn.editable?(t)
      assert Tpn.gate(t) == []
      assert Tpn.warning(t) == []

      assert %{number: 14, expected: 1} =
               Enum.find(Tpn.locked_out_of_place(t), &(&1.player.id == im.id))

      assert {:error, :locked} = Tpn.regenerate(t)
    end
  end

  describe "the question before pairing (Tpn.gate/1)" do
    test "nothing before round 1, and nothing when the numbers follow the ratings" do
      t = tournament()
      first_thirteen(t)
      assert Tpn.gate(t) == []
      play_round(t)
      assert Tpn.gate(Repo.reload!(t)) == []
    end

    test "under \"rating\" a waiting late entrant is not asked about: the pairing places them" do
      t = tournament()
      first_thirteen(t)
      play_round(t)
      late = add_player(t, "Late, Strong", 2400)

      assert Tpn.gate(Repo.reload!(t)) == []
      play_round(t)
      assert number(late) == 1
      assert Tpn.gate(Repo.reload!(t)) == []
    end

    test "under \"after\" the late entrant is asked about too, once" do
      t = tournament(%{late_entry_numbering: "after"})
      first_thirteen(t)
      play_round(t)
      late = add_player(t, "Late, Strong", 2400)

      rows = Tpn.gate(Repo.reload!(t))
      assert %{number: 14, expected: 1} = Enum.find(rows, &(&1.player.id == late.id))
      # The lenient list still excuses them, as it always did.
      play_round_accepting(t, rows)
      assert Tpn.out_of_order(Repo.reload!(t)) == []
      assert Tpn.gate(Repo.reload!(t)) == []
    end

    test "a rating corrected after round 1 is asked about" do
      t = tournament()
      [_ | _] = first_thirteen(t)
      play_round(t)
      last = Enum.find(players(t), &(&1.name == "First13"))
      {:ok, _} = Tournaments.update_player(last, %{"fide_rating" => 2500})

      assert %{number: 13, expected: 1} =
               Enum.find(Tpn.gate(Repo.reload!(t)), &(&1.player.id == last.id))
    end

    test "an exchange between equal ratings never is" do
      t = tournament()
      first_thirteen(t)
      a = add_player(t, "Equal, A", 1625)
      b = add_player(t, "Equal, B", 1625)
      {:ok, _} = Tpn.exchange(t, a.id, b.id)
      play_round(t)

      assert number(b) < number(a)
      assert Tpn.gate(Repo.reload!(t)) == []
      assert Tpn.out_of_place(Repo.reload!(t)) == []
    end

    test "round robin, Keizer and team events are never asked" do
      for attrs <- [
            %{pairing_system: "round_robin"},
            %{pairing_system: "keizer"},
            %{type: "team-swiss"}
          ] do
        t = tournament(attrs)
        refute Tpn.applies?(t)
        assert Tpn.gate(t) == []
        assert Tpn.out_of_place(t) == []
        assert Tpn.locked_out_of_place(t) == []
      end
    end
  end

  defp play_round_accepting(t, rows) do
    {:ok, _} = Tpn.accept(Repo.reload!(t), rows)
    play_round(t)
  end

  describe "unpairing the last remaining round" do
    test "takes back the numbers the pairing issued, and only when no round is left" do
      t = tournament()
      first_thirteen(t)
      play_round(t)
      play_round(t)

      assert Pairing.numbers_cleared_by_unpairing(t.id, 2) == 0
      :ok = Pairing.delete_round(t.id, 2)
      assert length(ratings_by_number(t)) == 13

      assert Pairing.numbers_cleared_by_unpairing(t.id, 1) == 13
      :ok = Pairing.delete_round(t.id, 1)
      assert ratings_by_number(t) == []
    end

    test "a rating changed between two attempts at round 1 is followed" do
      t = tournament()
      first_thirteen(t)
      pair(t)
      :ok = Pairing.delete_round(t.id, 1)

      last = Enum.find(players(t), &(&1.name == "First13"))
      {:ok, _} = Tournaments.update_player(last, %{"fide_rating" => 2500})
      pair(t)

      assert number(last) == 1
      assert ratings_by_number(t) == Enum.sort(ratings_by_number(t), :desc)
    end

    test "a match-format Swiss unpairs both legs and takes the numbers back with them" do
      t = tournament(%{swiss_match_format: true, rounds_count: 4})
      first_thirteen(t)
      pair(t)
      assert Pairing.paired_rounds_count(t.id) == 2

      assert Pairing.numbers_cleared_by_unpairing(t.id, 2) == 13
      :ok = Pairing.delete_round(t.id, 2)
      assert ratings_by_number(t) == []
    end

    test "an arbiter's exchange stays, and a newcomer is still placed by rating among them" do
      t = tournament()
      first_thirteen(t)
      a = add_player(t, "Equal, A", 1625)
      b = add_player(t, "Equal, B", 1625)
      {:ok, _} = Tpn.exchange(t, a.id, b.id)
      assert Repo.reload!(t).pairing_numbers_origin == "exchange"

      pair(t)
      assert Pairing.numbers_cleared_by_unpairing(t.id, 1) == 0
      :ok = Pairing.delete_round(t.id, 1)
      assert length(ratings_by_number(t)) == 15
      assert number(b) < number(a)

      strong = add_player(t, "New, Strong", 2000)
      middle = add_player(t, "New, Middle", 1630)
      pair(t)

      assert number(strong) == 1
      assert number(middle) < number(b)
      assert number(b) < number(a)
      ratings = ratings_by_number(t)
      assert length(ratings) == 17
      assert ratings == Enum.sort(ratings, :desc)
    end

    test "a kept number is still handed back by a player absent from the new round 1" do
      t = tournament(%{round_one_absentees_late: true})
      first_thirteen(t)
      [a, b] = [add_player(t, "Equal, A", 1625), add_player(t, "Equal, B", 1625)]
      {:ok, _} = Tpn.exchange(t, a.id, b.id)
      pair(t)
      :ok = Pairing.delete_round(t.id, 1)

      third = Enum.find(players(t), &(&1.name == "First3"))
      assert third.pairing_number == 3
      {:ok, _} = Tournaments.update_player(third, %{"absent_rounds" => "1"})
      pair(t)

      assert number(third) == nil

      assert t
             |> players()
             |> Enum.map(& &1.pairing_number)
             |> Enum.reject(&is_nil/1)
             |> Enum.sort() ==
               Enum.to_list(1..14)
    end

    test "an imported file's own numbers stay" do
      t = tournament(%{pairing_numbers_origin: "import"})

      for {p, n} <- Enum.zip(first_thirteen(t), 13..1//-1) do
        Repo.update_all(from(x in Player, where: x.id == ^p.id), set: [pairing_number: n])
      end

      pair(t)
      assert Pairing.numbers_cleared_by_unpairing(t.id, 1) == 0
      :ok = Pairing.delete_round(t.id, 1)
      assert length(ratings_by_number(t)) == 13
      assert Tpn.imported?(t)

      # Regenerated, they are no longer the file's.
      pair(t)
      {:ok, _} = Tpn.regenerate(Repo.reload!(t))
      refute Tpn.imported?(t)
      assert Repo.reload!(t).pairing_numbers_origin == nil
    end

    test "a round robin and a Keizer keep theirs" do
      for system <- ~w(round_robin keizer) do
        t = tournament(%{pairing_system: system, rounds_count: 5})
        for n <- 1..6, do: add_player(t, "P#{n}", 2000 - n * 10)
        {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

        last = Pairing.paired_rounds_count(t.id)

        for n <- last..1//-1 do
          assert Pairing.numbers_cleared_by_unpairing(t.id, n) == 0
          :ok = Pairing.delete_round(t.id, n)
        end

        assert Pairing.paired_rounds_count(t.id) == 0
        assert length(ratings_by_number(t)) == 6, system
      end
    end

    test "the answer to \"pair anyway\" goes with the numbers it was about" do
      t = tournament(%{late_entry_numbering: "end"})
      first_thirteen(t)
      play_round(t)
      add_player(t, "Late, IM", 2365)
      {:ok, _} = Tpn.accept(Repo.reload!(t), Tpn.gate(Repo.reload!(t)))
      assert Repo.reload!(t).tpn_order_accepted != nil

      :ok = Pairing.delete_round(t.id, 1)
      assert Repo.reload!(t).tpn_order_accepted == nil
    end
  end

  describe "the grandfathered \"at the end\" notice" do
    test "shown for an individual Swiss on \"end\" until round 4 is paired, and until answered" do
      t = tournament(%{late_entry_numbering: "end"})
      first_thirteen(t)
      assert Tournaments.late_entry_notice?(t)
      refute Tournaments.late_entry_notice?(tournament())
      refute Tournaments.late_entry_notice?(tournament(%{late_entry_numbering: "after"}))

      refute Tournaments.late_entry_notice?(
               tournament(%{late_entry_numbering: "end", pairing_system: "keizer"})
             )

      refute Tournaments.late_entry_notice?(
               tournament(%{late_entry_numbering: "end", type: "team-swiss"})
             )

      for _ <- 1..3, do: play_round(t)
      assert Tournaments.late_entry_notice?(Repo.reload!(t))
      play_round(t)
      refute Tournaments.late_entry_notice?(Repo.reload!(t))
    end

    test "switch: the setting becomes \"rating\", mid-event too, and the notice is gone" do
      t = tournament(%{late_entry_numbering: "end"})
      first_thirteen(t)
      play_round(t)

      assert {:ok, updated} = Tournaments.switch_late_entry_numbering(Repo.reload!(t))
      assert updated.late_entry_numbering == "rating"
      assert updated.late_entry_notice_dismissed
      refute Tournaments.late_entry_notice?(updated)

      late = add_player(t, "Late, Strong", 2400)
      play_round(t)
      assert number(late) == 1
    end

    test "keep: the setting stays, the notice does not come back" do
      t = tournament(%{late_entry_numbering: "end"})
      assert {:ok, updated} = Tournaments.dismiss_late_entry_notice(t)
      assert updated.late_entry_numbering == "end"
      refute Tournaments.late_entry_notice?(updated)
    end
  end

  describe "where a tournament's late_entry_numbering comes from" do
    test "created from the form's params: \"rating\", with or without account defaults" do
      scope = scope()

      form = %{
        "name" => "New",
        "type" => "swiss",
        "pairing_system" => "swiss",
        "rounds_count" => "7"
      }

      assert {:ok, t} = Tournaments.create_tournament(scope, form)
      assert t.late_entry_numbering == "rating"
      assert Repo.reload!(t).late_entry_numbering == "rating"
      assert t.round_one_absentees_late
      assert t.pairing_numbers_origin == nil

      {:ok, user} =
        PairingsEngine.Accounts.update_tournament_defaults(scope.user, %{
          "pairing_system" => "swiss",
          "rounds_count" => "9",
          "city" => "Somewhere",
          "federation" => "BEL"
        })

      hidden = PairingsEngine.Accounts.TournamentDefaults.hidden_params(user.tournament_defaults)
      assert {:ok, t} = Tournaments.create_tournament(scope, Map.merge(hidden, form))
      assert Repo.reload!(t).late_entry_numbering == "rating"

      assert {:ok, team} = Tournaments.create_tournament(scope, %{form | "type" => "team-swiss"})
      assert Repo.reload!(team).late_entry_numbering == "rating"
    end

    test "the unowned create path too" do
      assert {:ok, t} = Tournaments.create_tournament(%{"name" => "New", "type" => "swiss"})
      assert Repo.reload!(t).late_entry_numbering == "rating"
    end

    test "a TRF import: \"rating\", and the numbers are marked as the file's" do
      t =
        tournament(%{
          start_date: "2026-09-01",
          end_date: "2026-09-09",
          round_dates: for(n <- 1..9, do: "2026-09-0#{n}")
        })

      first_thirteen(t)
      play_round(t)
      {:ok, text} = TrfExport.export(Repo.reload!(t))

      assert {:ok, imported, _warnings} = TrfImport.import_text(text, scope())
      imported = Repo.reload!(imported)
      assert imported.late_entry_numbering == "rating"
      assert imported.pairing_numbers_origin == "import"
    end

    test "a backup: the file's own value; \"end\" only for one older than the setting" do
      scope = scope()

      entry = fn attrs ->
        %{
          "tournament" =>
            Map.merge(%{"name" => "Backup", "type" => "swiss", "rounds_count" => 5}, attrs),
          "players" => [%{"id" => 1, "name" => "A"}]
        }
      end

      payload = %{
        "format" => "openpairings-export",
        "version" => 1,
        "tournaments" => [
          entry.(%{}),
          entry.(%{"late_entry_numbering" => "rating"}),
          entry.(%{"late_entry_numbering" => "after"}),
          entry.(%{"swar_guid" => "{ABC}"}),
          entry.(%{"pairing_numbers_origin" => "exchange"})
        ]
      }

      assert {:ok, [old, rating, chosen, swar, exchanged]} =
               TournamentImport.import(payload, scope)

      assert Repo.reload!(old).late_entry_numbering == "end"
      assert Repo.reload!(rating).late_entry_numbering == "rating"
      assert Repo.reload!(chosen).late_entry_numbering == "after"
      # Whose the numbers are: the file says, or what it carries gives away.
      assert Repo.reload!(old).pairing_numbers_origin == nil
      assert Repo.reload!(swar).pairing_numbers_origin == "import"
      assert Repo.reload!(exchanged).pairing_numbers_origin == "exchange"
    end

    test "a tournament exported and imported again keeps what it had" do
      t = tournament(%{user_id: nil})
      first_thirteen(t)
      a = add_player(t, "Equal, A", 1625)
      b = add_player(t, "Equal, B", 1625)
      {:ok, _} = Tpn.exchange(t, a.id, b.id)

      envelope =
        t
        |> Repo.reload!()
        |> TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, [copy]} = TournamentImport.import(envelope, scope())
      copy = Repo.reload!(copy)
      assert copy.late_entry_numbering == "rating"
      assert copy.pairing_numbers_origin == "exchange"
      assert copy.tpn_order_accepted == nil
    end

    test "the migration marks the tournaments that came from a file" do
      file = tournament(%{import_findings: %{"trf_version" => "TRF16"}})
      swar = tournament(%{swar_guid: "{ABC}"})
      own = tournament()

      Repo.update_all(Tournament, set: [pairing_numbers_origin: nil])

      Repo.query!("""
      UPDATE tournaments SET pairing_numbers_origin = 'import'
      WHERE import_findings IS NOT NULL OR (swar_guid IS NOT NULL AND swar_guid != '')
      """)

      assert Repo.reload!(file).pairing_numbers_origin == "import"
      assert Repo.reload!(swar).pairing_numbers_origin == "import"
      assert Repo.reload!(own).pairing_numbers_origin == nil
    end
  end
end
