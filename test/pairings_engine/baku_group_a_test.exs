defmodule PairingsEngine.BakuGroupATest do
  @moduledoc """
  Baku acceleration's Group A is the round-1 field's, for the whole event
  (FIDE C.04.7 1.2 and 1.3.2), and a late entrant never moves it.

  It used to be `2 * ceil(N/4)` over whoever held a pairing number at the
  moment it was asked, and a late entrant is numbered when they join: eight
  players have a Group A of four, the ninth made it six. The rounds after
  the entry were paired with the bigger group - the two new members even
  carrying virtual points for rounds they had played without - and every
  TRF exported afterwards wrote the bigger group into rounds 1..k as well,
  so a checker replaying those rounds found pairings the file could not
  explain (found by `trf_flow_validation_test.exs`, 2026-10-03).
  """

  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, Snapshots, Tournaments}
  alias PairingsEngine.{TournamentExport, TournamentImport, TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.{Player, Tournament}
  alias PairingsEngine.Accounts.{Scope, User}
  alias Ainalrami.Trf

  @migration "priv/repo/migrations/20261003152729_add_baku_group_a_last.exs"
  @migration_module PairingsEngine.Repo.Migrations.AddBakuGroupALast

  setup_all do
    unless Code.ensure_loaded?(@migration_module), do: Code.require_file(@migration)
    :ok
  end

  setup do
    handler = "baku-group-a-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config -> Process.put({:trf, meta.round}, meta.trf) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(rounds_count, players, attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Baku Group A",
            type: "swiss",
            rounds_count: rounds_count,
            acceleration: "baku",
            initial_colour: "white",
            start_date: "2026-09-01",
            end_date: "2026-09-0#{rounds_count}",
            round_dates: for(n <- 1..rounds_count, do: "2026-09-0#{n}")
          },
          attrs
        )
      )

    for n <- 1..players, do: add_player(t, "P#{n}, Baku", 2400 - n * 50, 1)
    t
  end

  # Rated above everybody: a program that re-sorted the list would number
  # them first. This one numbers a late entrant after everybody already
  # numbered, so they could only ever reach Group A by the group growing.
  defp late_entrant(t, name) do
    add_player(t, name, 2700, Tournaments.next_start_round(t.id))
  end

  defp add_player(t, name, rating, start_round) do
    {:ok, p} =
      Tournaments.create_player(t.id, %{
        "name" => name,
        "fide_rating" => rating,
        "start_round" => start_round
      })

    p
  end

  # Pairs the next round and enters a result on every board: the lower
  # pairing number wins.
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

  defp accelerated_ranks(text) do
    for p <- Trf.parse(text).players,
        Enum.any?(Map.get(p, :accelerations) || [], &(&1 > 0)),
        do: p.rank
  end

  defp check(text) do
    path = Path.join(System.tmp_dir!(), "baku-group-a-#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn -> Process.put(:code, Ainalrami.CLI.run(["-c", path])) end)
      end)

      Process.get(:code)
    after
      File.rm(path)
    end
  end

  defp player_named(t, name),
    do: t.id |> Tournaments.list_players() |> Enum.find(&(&1.name == name))

  # The player holding Group A's line - C.04.7 1.3.2's "last GA-participant".
  defp ga_last_player(t) do
    t = Repo.reload!(t)

    t.id
    |> Pairing.full_roster_players()
    |> Enum.find(&(&1.pairing_number == t.baku_group_a_last))
  end

  defp records_250(text), do: text |> String.split("\r\n") |> Enum.filter(&(&1 =~ ~r/^250 /))

  describe "a late entrant" do
    test "joining during the accelerated rounds is not in Group A, and Group A does not grow" do
      # Seven rounds: four accelerated (1.0, 1.0, 0.5, 0.5). Eight players:
      # Group A is numbers 1-4. A ninth would make it six.
      t = tournament(7, 8)
      play_round(t)
      assert Repo.reload!(t).baku_group_a_last == 4

      late = late_entrant(t, "Late, Entrant")
      play_round(t)

      assert Repo.get!(Player, late.id).pairing_number == 9
      assert Repo.reload!(t).baku_group_a_last == 4
      # What the engine was handed for round 2: Group A's four rows only.
      assert Process.get({:trf, 2}) |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4]

      roster = Pairing.full_roster_players(t.id)
      group_a = t |> Repo.reload!() |> Pairing.accelerations(roster, 2) |> Map.keys()
      assert Enum.sort(group_a) == roster |> Enum.take(4) |> Enum.map(& &1.id) |> Enum.sort()

      play_round(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert text |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4]
      assert check(text) == 0
    end

    test "joining after the accelerated rounds leaves every round's 250 records alone" do
      # Five rounds: three accelerated (1.0, 1.0, 0.5).
      t = tournament(5, 8)
      for _ <- 1..3, do: play_round(t)
      {:ok, before} = TrfExport.export(Repo.reload!(t))

      late_entrant(t, "Late, Entrant")
      play_round(t)
      play_round(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert records_250(text) == records_250(before)

      group_a =
        for p <- Trf.parse(text).players, p[:accelerations] not in [nil, []] do
          {p.rank,
           p.accelerations |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) |> Enum.reverse()}
        end

      assert Enum.sort(group_a) == for(rank <- 1..4, do: {rank, [1.0, 1.0, 0.5]})

      assert check(text) == 0

      {:ok, engine} = TrfExport.export(Repo.reload!(t), nil, dialect: :engine)
      assert engine |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4]
    end
  end

  # VCL4THP Q111. C.04.7 1.2 forms Group A "before the first round" from
  # "the list of participants to be paired"; C.04.2 2.4 says a participant
  # only taken into account for rounds after the first is a Late Entry,
  # "given an appropriate TPN and paired only when they actually arrive";
  # C.04.7 1.3.1 sends late entries through C.04.2 Article 2 and 1.3.2 keeps
  # the last GA participant the same participant. So a round-1 bye is not in
  # N and holds no number until it turns up.
  describe "a round-1 absentee (C.04.2 2.4, C.04.7 1.2)" do
    test "is not in N: round 1's Group A is counted over the eight who were paired" do
      t = tournament(5, 9)
      {:ok, _} = Tournaments.update_player(player_named(t, "P9, Baku"), %{"absent_rounds" => "1"})

      play_round(t)

      # Eight on round 1's list: 2 * ceil(8/4) = 4. Counting the bye made it 6.
      assert Repo.reload!(t).baku_group_a_last == 4
      assert player_named(t, "P9, Baku").pairing_number == nil

      assert t.id |> Pairing.full_roster_players() |> Enum.map(& &1.pairing_number) ==
               Enum.to_list(1..8)

      # The engine's round-1 field: eight rows, the absentee not among them.
      assert length(Trf.parse(Process.get({:trf, 1})).players) == 8
    end

    test "a round-1 bye arriving in round 2 is numbered after the field and Group A stays put" do
      # Rated above everybody: by rating they would be number 1.
      t = tournament(7, 8)
      bye = add_player(t, "Bye, Round One", 2700, 1)
      {:ok, _} = Tournaments.update_player(bye, %{"absent_rounds" => "1"})

      play_round(t)
      assert Repo.get!(Player, bye.id).pairing_number == nil
      assert Repo.reload!(t).baku_group_a_last == 4
      before = ga_last_player(t)
      assert before.name == "P4, Baku"

      play_round(t)

      # C.04.2 2.4 with "After the field": the next number.
      assert Repo.get!(Player, bye.id).pairing_number == 9
      # C.04.7 1.3.2: the same last GA participant, the group no bigger.
      assert Repo.reload!(t).baku_group_a_last == 4
      assert ga_last_player(t).id == before.id
      assert Process.get({:trf, 2}) |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4]
      # And paired in round 2, now that they are here.
      assert Enum.any?(Trf.parse(Process.get({:trf, 2})).players, &(&1.rank == 9))
    end

    test "with \"By rating\" they take the number their rating earns, and the line moves with its player" do
      t = tournament(7, 8, %{late_entry_numbering: "rating"})
      bye = add_player(t, "Bye, Round One", 2700, 1)
      {:ok, _} = Tournaments.update_player(bye, %{"absent_rounds" => "1"})

      play_round(t)
      assert Repo.reload!(t).baku_group_a_last == 4
      before = ga_last_player(t)

      play_round(t)

      # "An appropriate TPN" (C.04.2 2.4): first, everybody else one down.
      assert Repo.get!(Player, bye.id).pairing_number == 1
      # C.04.7 1.3.2: the last GA participant is still P4, now number 5, so
      # Group A is the newcomer plus the four it had - 1.3.2's first note.
      assert Repo.reload!(t).baku_group_a_last == 5
      assert ga_last_player(t).id == before.id
      assert Process.get({:trf, 2}) |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4, 5]
    end

    test "a later start round entered before the event is not numbered at round 1 either" do
      t = tournament(5, 8)
      starter = add_player(t, "Starts, Round Two", 1000, 2)

      play_round(t)
      assert Repo.get!(Player, starter.id).pairing_number == nil
      assert Repo.reload!(t).baku_group_a_last == 4

      play_round(t)
      assert Repo.get!(Player, starter.id).pairing_number == 9
      assert Repo.reload!(t).baku_group_a_last == 4
    end

    test "absent for rounds 1 and 2 waits for round 3 for a number" do
      t = tournament(7, 8)
      bye = add_player(t, "Bye, Twice", 1000, 1)
      {:ok, _} = Tournaments.update_player(bye, %{"absent_rounds" => "1,2"})

      play_round(t)
      play_round(t)
      assert Repo.get!(Player, bye.id).pairing_number == nil

      play_round(t)
      assert Repo.get!(Player, bye.id).pairing_number == 9
      assert Repo.reload!(t).baku_group_a_last == 4
    end

    test "a number issued before round 1 is handed back, and the field closes ranks" do
      # Round 1 paired over nine, then unpaired: everybody holds a number.
      t = tournament(5, 9)
      play_round(t)
      assert Repo.reload!(t).baku_group_a_last == 6
      :ok = Pairing.delete_round(t.id, 1)

      p3 = player_named(t, "P3, Baku")
      assert p3.pairing_number == 3
      {:ok, _} = Tournaments.update_player(p3, %{"absent_rounds" => "1"})

      play_round(t)

      assert Repo.get!(Player, p3.id).pairing_number == nil

      assert t.id |> Pairing.full_roster_players() |> Enum.map(& &1.pairing_number) ==
               Enum.to_list(1..8)

      assert player_named(t, "P4, Baku").pairing_number == 3
      assert Repo.reload!(t).baku_group_a_last == 4
    end

    test "the TRF numbers them as they arrived, checks clean, and comes back the same" do
      t = tournament(7, 8)
      bye = add_player(t, "Bye, Round One", 2700, 1)
      {:ok, _} = Tournaments.update_player(bye, %{"absent_rounds" => "1"})
      play_round(t)

      # Between rounds 1 and 2 they hold no TPN, so the file has no row for them.
      {:ok, early} = TrfExport.export(Repo.reload!(t))
      assert length(Trf.parse(early).players) == 8

      play_round(t)
      play_round(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      row = Enum.find(Trf.parse(text).players, &(&1.rank == 9))
      assert row.name =~ "Bye"
      # Round 1 is their bye, not a game.
      refute Trf.participated_in_pairing?(hd(row.games))
      assert text |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4]
      assert check(text) == 0

      assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())
      assert imported.acceleration == "baku"
      assert Repo.reload!(imported).baku_group_a_last == 4
      refute Enum.any?(warnings, &(&1[:text] && &1.text =~ "Baku"))

      copy = imported.id |> Tournaments.list_players() |> Enum.find(&(&1.name =~ "Bye"))
      assert copy.pairing_number == 9

      {:ok, again} = TrfExport.export(Repo.reload!(imported))
      assert records_250(again) == records_250(text)
    end

    test "the fallback for a tournament with nothing stored counts round 1's boards, not its byes" do
      t = tournament(7, 8)
      bye = add_player(t, "Bye, Round One", 2700, 1)
      {:ok, _} = Tournaments.update_player(bye, %{"absent_rounds" => "1"})
      play_round(t)
      play_round(t)
      Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [baku_group_a_last: nil])

      assert Pairing.baku_group_a_last(Repo.reload!(t), Pairing.full_roster_players(t.id)) == 4
    end

    test "outside Baku nothing changes: the absentee is numbered with the field" do
      t = tournament(5, 9, %{acceleration: "none"})
      {:ok, _} = Tournaments.update_player(player_named(t, "P9, Baku"), %{"absent_rounds" => "1"})

      play_round(t)

      assert player_named(t, "P9, Baku").pairing_number == 9
    end
  end

  describe "round 1 fixes it" do
    test "and unpairing round 1 lets the next round 1 decide it again" do
      t = tournament(5, 8)
      play_round(t)
      assert Repo.reload!(t).baku_group_a_last == 4

      :ok = Pairing.delete_round(t.id, 1)
      assert Repo.reload!(t).baku_group_a_last == nil

      late_entrant(t, "Ninth, Player")
      add_player(t, "Tenth, Player", 1000, 1)
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

      assert Repo.reload!(t).baku_group_a_last == 6
    end

    test "as 2 * ceil(N/4) over the starting list - exactly the old count when nobody joins late" do
      for n <- 1..40 do
        players = for i <- 1..n, do: %Player{id: i, pairing_number: i}
        old = Enum.at(players, min(2 * div(n + 3, 4), n) - 1).pairing_number
        assert Pairing.baku_group_a_last(%Tournament{acceleration: "baku"}, players) == old
      end
    end
  end

  describe "a tournament with a round 1 and nothing stored" do
    # An event from before the column, restored from an old backup, or one
    # that switched Baku on after round 1.
    setup do
      t = tournament(7, 8)
      play_round(t)
      late_entrant(t, "Late, Entrant")
      play_round(t)
      Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [baku_group_a_last: nil])
      %{t: Repo.reload!(t)}
    end

    test "gets its round-1 field's Group A, late entrant left out", %{t: t} do
      assert Pairing.baku_group_a_last(t, Pairing.full_roster_players(t.id)) == 4

      {:ok, context} = Pairing.preview_context(t)
      assert context.tournament.baku_group_a_last == 4

      {:ok, text} = TrfExport.export(t)
      assert text |> accelerated_ranks() |> Enum.sort() == [1, 2, 3, 4]
    end

    test "the next pairing stores it", %{t: t} do
      play_round(t)
      assert Repo.reload!(t).baku_group_a_last == 4
    end

    test "the migration's backfill gives it the same", %{t: t} do
      apply(@migration_module, :backfill, [&Repo.query!/2])
      assert Repo.reload!(t).baku_group_a_last == 4
    end
  end

  describe "it travels" do
    setup do
      t = tournament(7, 8)
      play_round(t)
      late_entrant(t, "Late, Entrant")
      play_round(t)
      %{t: Repo.reload!(t)}
    end

    test "through a TRF export and import: the file's 250 records are Group A", %{t: t} do
      {:ok, text} = TrfExport.export(t)
      assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())

      assert imported.acceleration == "baku"
      assert Repo.reload!(imported).baku_group_a_last == 4
      refute Enum.any?(warnings, &(&1[:text] && &1.text =~ "Baku"))

      {:ok, again} = TrfExport.export(Repo.reload!(imported))
      assert records_250(again) == records_250(text)
    end

    test "through a JSON backup and its import", %{t: t} do
      envelope = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      assert hd(envelope["tournaments"])["tournament"]["baku_group_a_last"] == 4

      assert {:ok, [copy]} = TournamentImport.import(envelope, user_scope())
      assert Repo.reload!(copy).baku_group_a_last == 4
    end

    test "through a snapshot restore", %{t: t} do
      scope = user_scope()
      {:ok, snapshot} = Snapshots.capture(t, "manual", scope, summary: "Round 2")

      Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [baku_group_a_last: 7])

      {:ok, restored} = Snapshots.restore(Repo.reload!(t), snapshot.id, scope)
      assert Repo.reload!(restored).baku_group_a_last == 4
    end
  end
end
