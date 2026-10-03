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

  describe "round 1 fixes it" do
    test "over every numbered player, a round-1 absentee included" do
      t = tournament(5, 9)
      absentee = t.id |> Tournaments.list_players() |> Enum.at(8)
      {:ok, _} = Tournaments.update_player(absentee, %{"absent_rounds" => "1"})

      play_round(t)

      # Nine on the starting list: 2 * ceil(9/4) = 6.
      assert Repo.reload!(t).baku_group_a_last == 6
    end

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
