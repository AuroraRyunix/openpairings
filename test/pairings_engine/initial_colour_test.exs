defmodule PairingsEngine.InitialColourTest do
  @moduledoc """
  The initial colour (C.04.3 Art. 5.1, C.04.6 Art. 4.1): drawn by lot before
  round 1 by default, or set by the arbiter; stored, shown, locked with
  round 1, handed to both Swiss engines as the TRF's `XXC` line.
  """
  # Pairing runs write whole rounds; SQLite's single writer.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.Tournament

  setup do
    handler_id = "initial-colour-trf-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config -> send(test_pid, {:trf_built, meta.trf}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp swiss(attrs \\ %{}) do
    tournament =
      Repo.insert!(struct(%Tournament{name: "Colours", type: "swiss", rounds_count: 3}, attrs))

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    tournament
  end

  # Round 1's boards as {white name, black name}, board order.
  defp round_one(tournament) do
    round =
      tournament.id
      |> Tournaments.get_round(1)
      |> Repo.preload(pairings: [:white_player, :black_player])

    round.pairings
    |> Enum.sort_by(& &1.board)
    |> Enum.map(&{&1.white_player.name, &1.black_player.name})
  end

  defp last_trf do
    receive do
      {:trf_built, trf} -> last_trf_after(trf)
    after
      0 -> flunk("no TRF was built")
    end
  end

  defp last_trf_after(trf) do
    receive do
      {:trf_built, newer} -> last_trf_after(newer)
    after
      0 -> trf
    end
  end

  describe "the setting" do
    test "defaults to drawn by lot, with nothing drawn" do
      t = %Tournament{}
      assert t.initial_colour == "lot"
      assert t.initial_colour_drawn == nil
      assert Tournament.effective_initial_colour(t) == nil
    end

    test "accepts lot, white and black, nothing else" do
      for value <- ~w(lot white black) do
        assert Tournament.changeset(%Tournament{}, %{name: "T", initial_colour: value}).valid?
      end

      refute Tournament.changeset(%Tournament{}, %{name: "T", initial_colour: "red"}).valid?
    end

    test "the drawn colour is never cast from a form" do
      changeset = Tournament.changeset(%Tournament{}, %{name: "T", initial_colour_drawn: "black"})
      refute Map.has_key?(changeset.changes, :initial_colour_drawn)
    end

    test "the arbiter's choice outranks a draw on record" do
      assert Tournament.effective_initial_colour(%Tournament{
               initial_colour: "black",
               initial_colour_drawn: "white"
             }) ==
               "black"

      assert Tournament.effective_initial_colour(%Tournament{
               initial_colour: "lot",
               initial_colour_drawn: "black"
             }) ==
               "black"
    end
  end

  describe "the draw" do
    test "happens once, is stored, and is not drawn again" do
      t = swiss()

      drawn = Tournaments.ensure_initial_colour(t, fn -> "black" end)
      assert drawn.initial_colour_drawn == "black"
      assert Repo.reload!(t).initial_colour_drawn == "black"

      again = Tournaments.ensure_initial_colour(drawn, fn -> flunk("drew twice") end)
      assert again.initial_colour_drawn == "black"
    end

    test "is not drawn when the arbiter set the colour" do
      t = swiss(%{initial_colour: "white"})
      assert Tournaments.ensure_initial_colour(t, fn -> flunk("drew anyway") end) == t
    end

    test "a lot that gives anything but white or black is refused" do
      t = swiss()
      assert_raise ArgumentError, fn -> Tournaments.ensure_initial_colour(t, fn -> "grey" end) end
    end

    test "pairing round 1 draws and stores it (the test lot gives White)" do
      t = swiss()
      assert {:ok, _} = Pairing.pair_next_round(t)
      assert Repo.reload!(t).initial_colour_drawn == "white"
    end

    test "the draw is random without the test configuration" do
      previous = Application.get_env(:pairings_engine, :initial_colour_lot)
      Application.delete_env(:pairings_engine, :initial_colour_lot)

      try do
        draws = for _ <- 1..60, do: Tournaments.draw_lot()
        assert Enum.all?(draws, &(&1 in ~w(white black)))
        assert Enum.uniq(draws) |> Enum.sort() == ~w(black white)
      after
        Application.put_env(:pairings_engine, :initial_colour_lot, previous)
      end
    end

    test "a later round does not draw" do
      t = swiss()
      assert {:ok, _} = Pairing.pair_next_round(t)

      t =
        t |> Repo.reload!() |> Ecto.Changeset.change(initial_colour_drawn: nil) |> Repo.update!()

      finish_round(t, 1)
      assert {:ok, _} = Pairing.pair_next_round(t)
      assert Repo.reload!(t).initial_colour_drawn == nil
    end
  end

  describe "Ainalrami honours it" do
    test "a White draw gives the top seed White on board 1, and writes XXC white1" do
      t = swiss() |> Tournaments.ensure_initial_colour(fn -> "white" end)
      assert {:ok, _} = Pairing.pair_next_round(t)

      assert round_one(t) == [{"Alice", "Carol"}, {"Dave", "Bob"}]
      assert last_trf() =~ ~r/^XXC white1\r?$/m
    end

    test "a Black draw turns every board of round 1 round, and writes XXC black1" do
      t = swiss() |> Tournaments.ensure_initial_colour(fn -> "black" end)
      assert {:ok, _} = Pairing.pair_next_round(t)

      assert round_one(t) == [{"Carol", "Alice"}, {"Bob", "Dave"}]
      assert last_trf() =~ ~r/^XXC black1\r?$/m
    end

    test "the arbiter's Black is honoured the same way" do
      t = swiss(%{initial_colour: "black"})
      assert {:ok, _} = Pairing.pair_next_round(t)

      assert round_one(t) == [{"Carol", "Alice"}, {"Bob", "Dave"}]
      assert Repo.reload!(t).initial_colour_drawn == nil
    end

    test "a tournament with no draw on record writes no initial-colour line, as before" do
      t = swiss()
      assert {:ok, _} = Pairing.pair_next_round(t)

      t =
        t |> Repo.reload!() |> Ecto.Changeset.change(initial_colour_drawn: nil) |> Repo.update!()

      finish_round(t, 1)
      flush_trfs()

      assert {:ok, _} = Pairing.pair_next_round(t)
      refute last_trf() =~ ~r/^(152|XXC)/m
    end
  end

  describe "JaVaFo honours it" do
    @describetag :javafo

    test "a Black draw turns every board of round 1 round" do
      t =
        swiss(%{pairing_engine: "javafo"}) |> Tournaments.ensure_initial_colour(fn -> "black" end)

      assert {:ok, _} = Pairing.pair_next_round(t)

      assert round_one(t) == [{"Carol", "Alice"}, {"Bob", "Dave"}]
      assert last_trf() =~ ~r/^XXC black1\r?$/m
    end

    test "a White draw gives the top seed White" do
      t =
        swiss(%{pairing_engine: "javafo"}) |> Tournaments.ensure_initial_colour(fn -> "white" end)

      assert {:ok, _} = Pairing.pair_next_round(t)

      assert round_one(t) == [{"Alice", "Carol"}, {"Dave", "Bob"}]
    end
  end

  describe "the lock" do
    test "it can be changed until round 1 is paired, and not after" do
      t = swiss()
      assert {:ok, t} = Tournaments.update_tournament(t, %{"initial_colour" => "black"})
      assert {:ok, t} = Tournaments.update_tournament(t, %{"initial_colour" => "lot"})

      assert {:ok, _} = Pairing.pair_next_round(t)
      t = Repo.reload!(t)

      assert :initial_colour in Tournaments.locked_fields(t)

      assert {:error, :locked_after_pairing} =
               Tournaments.ensure_unlocked(t, %{"initial_colour" => "black"})
    end
  end

  describe "backup and import" do
    test "the setting, the draw and a team Swiss's pairing mode survive a round trip" do
      scope = user_scope()

      t =
        Repo.insert!(%Tournament{
          name: "Round trip",
          type: "team-swiss",
          rounds_count: 5,
          user_id: scope.user.id,
          initial_colour: "lot",
          initial_colour_drawn: "black",
          team_pairing_mode: "teams"
        })

      envelope = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, [imported]} = TournamentImport.import(envelope, scope)
      imported = Repo.reload!(imported)

      assert imported.initial_colour == "lot"
      assert imported.initial_colour_drawn == "black"
      assert imported.team_pairing_mode == "teams"

      explicit =
        Repo.insert!(%Tournament{
          name: "Explicit",
          type: "swiss",
          rounds_count: 5,
          user_id: scope.user.id,
          initial_colour: "white"
        })

      envelope =
        explicit |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, [imported]} = TournamentImport.import(envelope, scope)
      assert Repo.reload!(imported).initial_colour == "white"
    end

    test "a backup from before the draw existed imports with nothing drawn" do
      scope = user_scope()

      t =
        Repo.insert!(%Tournament{
          name: "Old",
          type: "swiss",
          rounds_count: 5,
          user_id: scope.user.id
        })

      envelope = TournamentExport.export_tournament(t) |> Jason.encode!() |> Jason.decode!()

      envelope =
        update_in(envelope, ["tournaments", Access.at(0), "tournament"], fn attrs ->
          Map.drop(attrs, ~w(initial_colour initial_colour_drawn team_pairing_mode))
        end)

      assert {:ok, [imported]} = TournamentImport.import(envelope, scope)
      imported = Repo.reload!(imported)
      assert imported.initial_colour == "lot"
      assert imported.initial_colour_drawn == nil
    end
  end

  describe "TRF import" do
    test "a file's drawn colour is kept as the draw, in either spelling" do
      scope = user_scope()

      for {line, colour} <- [{"XXC black1", "black"}, {"152 W", "white"}] do
        trf =
          Enum.join(
            [
              "012 From a file",
              line,
              "001    1      Alpha                             2000                             0.0    1",
              "001    2      Beta                              1900                             0.0    2",
              "XXR 5"
            ],
            "\n"
          ) <> "\n"

        assert {:ok, t, _warnings} = PairingsEngine.TrfImport.import_text(trf, scope)
        assert Repo.reload!(t).initial_colour_drawn == colour
      end
    end

    test "a team Swiss file with games carries on player by player" do
      scope = user_scope()

      trf =
        Enum.join(
          [
            "012 Team file",
            "092 Team: Swiss System",
            "001    1      Alpha                             2000                             1.0    1     2 w 1",
            "001    2      Beta                              1900                             0.0    2     1 b 0",
            "XXR 5"
          ],
          "\n"
        ) <> "\n"

      assert {:ok, t, _warnings} = PairingsEngine.TrfImport.import_text(trf, scope)
      t = Repo.reload!(t)
      assert t.type == "team-swiss"
      assert t.team_pairing_mode == "players"
      refute Tournament.paired_as_teams?(t)
    end
  end

  ## ---------- helpers ----------

  defp finish_round(t, number) do
    round = t.id |> Tournaments.get_round(number) |> Repo.preload(:pairings)

    for p <- round.pairings, p.result == "" do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end
  end

  defp flush_trfs do
    receive do
      {:trf_built, _} -> flush_trfs()
    after
      0 -> :ok
    end
  end

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "colour#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end
end
