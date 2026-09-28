defmodule PairingsEngine.AutomaticPublishingMigrationTest do
  @moduledoc """
  The data half of `AutomaticPublishingLadder` (2026-09-28): the old publish
  modes map one to one onto the automation ladder, and nothing public the
  moment before the upgrade is hidden - or shown - the moment after. Run
  against rows built here rather than by rolling the schema back, which the
  SQL sandbox does not allow.
  """
  use PairingsEngine.DataCase, async: true

  import Ecto.Query

  alias PairingsEngine.{Repo, Snapshot, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @migration PairingsEngine.Repo.Migrations.AutomaticPublishingLadder
  @file_path "priv/repo/migrations/20260928082633_automatic_publishing_ladder.exs"

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@file_path)
    :ok
  end

  defp migrate, do: apply(@migration, :backfill, [Repo])

  defp tournament(mode, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          name: mode,
          type: "swiss",
          rounds_count: 5,
          publish_mode: mode,
          public_slug: "mig-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  # Round `number` with one board: `result` "" leaves it unfinished.
  defp round(t, number, published_at, result) do
    round = Repo.insert!(%Round{tournament_id: t.id, number: number, published_at: published_at})
    a = Repo.insert!(%Player{tournament_id: t.id, name: "#{number}A", pairing_number: 2 * number})

    b =
      Repo.insert!(%Player{
        tournament_id: t.id,
        name: "#{number}B",
        pairing_number: 2 * number + 1
      })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: result
    })

    round
  end

  defp fresh(t), do: Tournaments.get_tournament!(t.id)

  describe "the mode mapping" do
    test "manual, timed, scheduled and immediate each land on their step" do
      manual = tournament("manual")
      timed = tournament("timed", %{publish_delay_minutes: 15})
      scheduled = tournament("scheduled")
      immediate = tournament("immediate")
      already = tournament("results")

      migrate()

      assert fresh(manual).publish_mode == "manual"
      assert %{publish_mode: "pairings", publish_delay_minutes: 15} = fresh(timed)
      assert fresh(scheduled).publish_mode == "manual"
      assert fresh(immediate).publish_mode == "standings"
      assert fresh(already).publish_mode == "results"
    end

    test "a retired page switch that was off takes its step away" do
      no_standings = tournament("immediate", %{public_display: %{"standings" => false}})
      no_pairings = tournament("immediate", %{public_display: %{"pairings" => false}})
      timed_no_standings = tournament("timed", %{public_display: %{"standings" => false}})

      migrate()

      assert fresh(no_standings).publish_mode == "results"
      assert fresh(no_pairings).publish_mode == "manual"
      assert fresh(timed_no_standings).publish_mode == "pairings"
      # And the switch itself stays stored - the page stays off.
      assert fresh(no_standings).public_display == %{"standings" => false}
    end

    test "is a pure function, shared with the import" do
      assert Tournament.legacy_publish_mode("immediate", nil) == "standings"
      assert Tournament.legacy_publish_mode("timed", %{}) == "pairings"
      assert Tournament.legacy_publish_mode("scheduled", nil) == "manual"
      assert Tournament.legacy_publish_mode("manual", nil) == "manual"
      assert Tournament.legacy_publish_mode("immediate", %{"standings" => false}) == "results"
      assert Tournament.legacy_publish_mode("immediate", %{"pairings" => false}) == "manual"
    end
  end

  describe "an immediate tournament keeps exactly what it showed" do
    test "every round, every result and the finished standings stay public" do
      t = tournament("immediate", %{standings_through: nil})
      r1 = round(t, 1, nil, "1-0")
      r2 = round(t, 2, nil, "1-0")
      r3 = round(t, 3, nil, "")

      migrate()
      t = fresh(t)

      for r <- [r1, r2, r3] do
        r = Repo.reload!(r)
        assert Tournaments.round_published?(t, r)
        assert r.results_public
      end

      snapshot = Snapshot.build(t)
      assert Enum.map(snapshot["rounds"], & &1["number"]) == [1, 2, 3]
      assert Enum.all?(snapshot["rounds"], & &1["results_public"])
      # Standings through the finished prefix - what immediate mode showed.
      assert snapshot["standings"]["after_round"] == 2
    end

    test "with the Standings page off, the standings reached are stored instead" do
      t =
        tournament("immediate", %{public_display: %{"standings" => false}, standings_through: 0})

      round(t, 1, nil, "1-0")
      round(t, 2, nil, "1-0")

      migrate()
      t = fresh(t)

      assert t.publish_mode == "results"
      assert t.standings_through == 2
      assert Snapshot.build(t)["standings"]["after_round"] == 2
      assert Snapshot.build(t)["tournament"]["display"]["standings"] == false
    end

    test "with the Round pairings page off, the automation is by hand and nothing moves" do
      t = tournament("immediate", %{public_display: %{"pairings" => false}})
      round(t, 1, nil, "1-0")

      migrate()
      t = fresh(t)

      assert t.publish_mode == "manual"
      assert t.standings_through == 1
      assert Snapshot.build(t)["tournament"]["display"]["pairings"] == false
      assert Snapshot.build(t)["standings"]["after_round"] == 1
    end

    test "a round already given a timestamp keeps it" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      t = tournament("immediate")
      r = round(t, 1, past, "")

      migrate()

      assert Repo.reload!(r).published_at == past
    end
  end

  describe "nothing else moves" do
    test "a manual or timed tournament's rounds are left exactly as they were" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      manual = tournament("manual")
      held = round(manual, 1, nil, "1-0")
      timed = tournament("timed")
      waiting = round(timed, 1, future, "")

      migrate()

      assert Repo.reload!(held).published_at == nil
      refute Repo.reload!(held).results_public
      assert Repo.reload!(waiting).published_at == future
      assert fresh(manual).standings_through == manual.standings_through
    end

    test "the starting ranking: published stays on, withheld stays off" do
      on = tournament("manual", %{standings_through: 0})
      off = tournament("manual", %{standings_through: nil})

      migrate()

      assert Tournaments.initial_standings_public?(fresh(on))
      refute Tournaments.initial_standings_public?(fresh(off))
    end
  end

  test "an account's stored default mode is converted too" do
    user = PairingsEngine.AccountsFixtures.user_fixture()
    other = PairingsEngine.AccountsFixtures.user_fixture()

    for {u, defaults} <- [
          {user, %{"publish_mode" => "timed", "publish_delay_minutes" => 5, "city" => "Gent"}},
          {other, %{"publish_mode" => "immediate"}}
        ] do
      Repo.update_all(
        from(x in "users",
          where: x.id == ^u.id,
          update: [set: [tournament_defaults: type(^defaults, :map)]]
        ),
        []
      )
    end

    migrate()

    read = fn u ->
      Repo.one!(
        from(x in "users", where: x.id == ^u.id, select: type(x.tournament_defaults, :map))
      )
    end

    assert read.(user) == %{
             "publish_mode" => "pairings",
             "publish_delay_minutes" => 5,
             "city" => "Gent"
           }

    assert read.(other) == %{"publish_mode" => "standings"}
  end
end
