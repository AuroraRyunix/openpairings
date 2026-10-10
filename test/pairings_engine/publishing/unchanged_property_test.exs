defmodule PairingsEngine.Publishing.UnchangedPropertyTest do
  @moduledoc """
  Whatever an arbiter does, in whatever order, the results site ends up
  holding the tournament as it is - with the drain allowed to skip.

  Random sequences of the things that reach the publish queue (results,
  players, settings, the publish switch, an event's sections, a server that
  answers 500, a button that sends regardless), drained at random points.
  After every drain that empties the queue, the document a fake results site
  holds for each publishing tournament must be the one `Snapshot.build/1`
  would build right now, give or take the stamp of when.

  The values are drawn from very small sets on purpose: a result that can
  only be one of three things goes back to what it was all the time, which
  is the case a skip exists for and the case it could get wrong.
  """
  use PairingsEngine.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias PairingsEngine.{Publishing, Repo, Snapshot, TournamentGroups, Tournaments, Tpn}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Publishing.{Accepted, QueueEntry}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    on_exit(&Accepted.forget_all/0)

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Process.put(:posts, Process.get(:posts, 0) + 1)

      case Process.get(:failures_left, 0) do
        0 ->
          payload = Jason.decode!(body)
          site = Process.get(:site, %{})
          Process.put(:site, Map.put(site, payload["tournament"]["slug"], payload))
          Req.Test.json(conn, %{"status" => "ok"})

        n ->
          Process.put(:failures_left, n - 1)
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "broken"})
      end
    end)

    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    %{scope: Scope.for_user(user)}
  end

  defp tournament(scope, name) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "rounds_count" => "5"
      })

    [a, b] =
      for {player, rating, number} <- [{"A", 2000, 1}, {"B", 1800, 2}] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: player,
          fide_rating: rating,
          pairing_number: number
        })
      end

    round =
      Repo.insert!(%Round{
        tournament_id: t.id,
        number: 1,
        status: "finished",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second),
        results_public: true
      })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    t.id
  end

  defp get(id), do: Tournaments.get_tournament!(id)

  defp player(id, index) do
    Repo.all(from p in Player, where: p.tournament_id == ^id, order_by: p.id) |> Enum.at(index)
  end

  ## ---------- what an arbiter can do ----------

  defp op do
    which = member_of([:main, :side])

    frequency([
      {6, tuple({constant(:result), which, member_of(["1-0", "0-1", "1/2-1/2"])})},
      {3, tuple({constant(:rating), which, member_of([0, 1]), member_of([1800, 2000, 2100])})},
      {2, tuple({constant(:player_name), which, member_of([0, 1]), member_of(["A", "B", "C"])})},
      {2, tuple({constant(:name), which, member_of(["Open", "Spring Open"])})},
      {2, tuple({constant(:listed), which, boolean()})},
      {2, tuple({constant(:registration), which, boolean()})},
      {2, tuple({constant(:publish), which, boolean()})},
      {2, tuple({constant(:touch), which})},
      {2, tuple({constant(:regenerate), which})},
      {1, tuple({constant(:direct_publish), which})},
      {1, tuple({constant(:try_again), which})},
      {2, constant(:group)},
      {1, constant(:ungroup)},
      {2, tuple({constant(:label), which, member_of(["Open", "U20", ""])})},
      {1, tuple({constant(:group_name), member_of(["Festival", "Spring Festival"])})},
      {1, tuple({constant(:server_fails), member_of([1, 2])})},
      {8, constant(:drain)}
    ])
  end

  defp run({:result, which, result}, ctx) do
    id = ctx[which]

    Repo.update_all(
      from(p in Pairing, join: r in Round, on: r.id == p.round_id, where: r.tournament_id == ^id),
      set: [result: result]
    )

    Tournaments.broadcast_tournament_change(id, :results)
  end

  defp run({:rating, which, index, rating}, ctx),
    do: Tournaments.update_player(player(ctx[which], index), %{fide_rating: rating})

  defp run({:player_name, which, index, name}, ctx),
    do: Tournaments.update_player(player(ctx[which], index), %{name: name})

  defp run({:name, which, name}, ctx),
    do: Tournaments.update_tournament(get(ctx[which]), %{"name" => name})

  defp run({:listed, which, on?}, ctx), do: Tournaments.set_public_listed(get(ctx[which]), on?)

  defp run({:registration, which, on?}, ctx),
    do: Tournaments.set_registration_open(get(ctx[which]), on?)

  defp run({:publish, which, on?}, ctx),
    do: Tournaments.set_publish_to_openresults(get(ctx[which]), on?)

  defp run({:touch, which}, ctx),
    do: Tournaments.broadcast_tournament_change(ctx[which], :players)

  defp run({:regenerate, which}, ctx), do: Tpn.regenerate(get(ctx[which]))
  defp run({:direct_publish, which}, ctx), do: Publishing.publish(get(ctx[which]))
  defp run({:try_again, which}, ctx), do: Publishing.retry(ctx[which])

  defp run(:group, ctx) do
    case TournamentGroups.membership(ctx.main) do
      nil ->
        with {:ok, group} <- TournamentGroups.create_group(ctx.scope, get(ctx.main), "Festival") do
          TournamentGroups.join_group(ctx.scope, get(ctx.side), group.id)
        end

      member ->
        TournamentGroups.join_group(ctx.scope, get(ctx.side), member.group_id)
    end
  end

  defp run(:ungroup, ctx), do: TournamentGroups.leave_group(ctx.scope, get(ctx.side))

  defp run({:label, which, label}, ctx),
    do: TournamentGroups.set_label(ctx.scope, get(ctx[which]), label)

  defp run({:group_name, name}, ctx),
    do: TournamentGroups.rename_group(ctx.scope, get(ctx.main), name)

  defp run({:server_fails, times}, _ctx), do: Process.put(:failures_left, times)

  defp run(:drain, ctx), do: drain_and_compare(ctx)

  ## ---------- the claim ----------

  # The drain's timer without the waiting: everything in backoff is due,
  # until the queue is empty or the server has had enough chances to fail.
  defp drain_and_compare(ctx) do
    Enum.reduce_while(1..8, nil, fn _pass, _ ->
      Repo.update_all(QueueEntry,
        set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second), stopped_at: nil]
      )

      waiting = Repo.aggregate(QueueEntry, :count, :id)
      {sent, failed} = Publishing.drain()

      # A row that was neither sent nor failed and is gone was judged
      # unchanged. Counted, so the property can prove it tested something.
      left = Repo.aggregate(QueueEntry, :count, :id)
      skipped = max(waiting - sent - failed - max(left - failed, 0), 0)
      Process.put(:skips, Process.get(:skips, 0) + skipped)

      if left == 0, do: {:halt, nil}, else: {:cont, nil}
    end)

    assert Repo.aggregate(QueueEntry, :count, :id) == 0

    for id <- [ctx.main, ctx.side], t = get(id), t.publish_to_openresults do
      held = Process.get(:site, %{})[t.public_slug]
      assert held, "#{t.name} publishes and the results site has never heard of it"

      assert comparable(held) == comparable(Snapshot.build(t)),
             "the results site is not showing #{t.name} as it is"
    end
  end

  # As the server stores it: through JSON, and without the one field that is
  # the clock. Named here rather than taken from `Accepted.volatile_keys/0`
  # on purpose: an oracle that asks the accused what to ignore passes when a
  # key is wrongly listed there, and did, the first time this was tried.
  defp comparable(payload) do
    payload |> Jason.encode!() |> Jason.decode!() |> Map.delete("published_at")
  end

  property "the results site always ends up with the tournament as it is", %{scope: scope} do
    check all(ops <- list_of(op(), max_length: 40), max_runs: 40) do
      Repo.delete_all(QueueEntry)
      Accepted.forget_all()
      Process.put(:site, %{})
      Process.put(:failures_left, 0)

      ctx = %{scope: scope, main: tournament(scope, "Open"), side: tournament(scope, "Side")}

      for which <- [:main, :side],
          do: {:ok, _} = Tournaments.set_publish_to_openresults(get(ctx[which]), true)

      drain_and_compare(ctx)

      Enum.each(ops, &run(&1, ctx))

      Process.put(:failures_left, 0)
      drain_and_compare(ctx)

      # Nothing leaks into the next run: its tournaments are new ones.
      Repo.update_all(from(t in Tournament, where: t.id in ^[ctx.main, ctx.side]),
        set: [publish_to_openresults: false]
      )
    end

    # Forty runs of mostly-reversible operations that never once went back
    # to where they were would be a test of nothing.
    assert Process.get(:skips, 0) > 0
    assert Process.get(:posts, 0) > 0
  end
end
