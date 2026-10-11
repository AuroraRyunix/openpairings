defmodule PairingsEngine.Publishing.UnchangedTest do
  @moduledoc """
  The drain declines to send a document the results site already holds.

  Half of this file is the saving and the other half is the price it must
  never have: a change that stays on the arbiter's machine. Every test that
  says "POST" is one of the ways out of the skip, and there are meant to be
  more of those than of the other kind.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PairingsEngine.{Publishing, Repo, Snapshot, SnapshotFixtures, Tournaments}
  alias PairingsEngine.Publishing.{Accepted, QueueEntry}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    Accepted.forget_all()
    on_exit(&Accepted.forget_all/0)

    test_pid = self()

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, Jason.decode!(body)})

      case Process.get(:server_answers, :ok) do
        :ok -> Req.Test.json(conn, %{"status" => "ok"})
        status -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "broken"})
      end
    end)

    :ok
  end

  defp tournament do
    t =
      Repo.insert!(%Tournament{
        name: "Gent Spring Open",
        type: "swiss",
        rounds_count: 3,
        publish_to_openresults: true,
        standings_through: 0,
        public_slug: "gent-#{System.unique_integer([:positive])}"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: name,
          fide_rating: rating,
          pairing_number: 2001 - rating
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

    Tournaments.get_tournament!(t.id)
  end

  defp set_result!(t, result) do
    Repo.update_all(
      from(p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        where: r.tournament_id == ^t.id
      ),
      set: [result: result]
    )

    Tournaments.broadcast_tournament_change(t.id, :results)
  end

  # A tournament the results site has accepted once, with an empty queue.
  defp published do
    t = tournament()
    :ok = Publishing.enqueue(t)
    assert {1, 0} = Publishing.drain()
    assert_received {:posted, _first}
    assert Publishing.queued(t.id) == nil
    Tournaments.get_tournament!(t.id)
  end

  defp touch(t), do: Tournaments.broadcast_tournament_change(t.id, :players)

  # The drain's timer, without the wait: whatever is in backoff is due.
  defp make_due do
    Repo.update_all(QueueEntry,
      set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  describe "the drain" do
    test "an identical document is not posted, and the queue is left empty" do
      t = published()
      stamp = Publishing.last_published_at()

      touch(t)
      assert %QueueEntry{} = Publishing.queued(t.id)

      # The test config keeps the logger at warnings; this line is an info.
      Logger.put_module_level(Publishing, :info)
      on_exit(fn -> Logger.delete_module_level(Publishing) end)

      log =
        capture_log([level: :info], fn ->
          assert {0, 0} = Publishing.drain()
        end)

      refute_received {:posted, _}
      assert log =~ "unchanged since the results site last accepted it"

      # What the top bar reads: nothing waiting, nothing failed, and the
      # stamp of the last thing that was actually sent.
      assert Publishing.queued(t.id) == nil
      assert Publishing.pending_count() == 0
      assert Publishing.last_published_at() == stamp
    end

    test "a changed result is posted" do
      t = published()

      set_result!(t, "0-1")
      assert {1, 0} = Publishing.drain()

      assert_received {:posted, payload}
      assert [%{"boards" => [%{"result" => "0-1"}]}] = payload["rounds"]
    end

    test "a change taken back before the drain is not posted" do
      t = published()

      set_result!(t, "0-1")
      set_result!(t, "1-0")

      assert {0, 0} = Publishing.drain()
      refute_received {:posted, _}
      assert Publishing.queued(t.id) == nil
    end

    test "a change taken back AFTER the drain is posted, both times" do
      t = published()

      set_result!(t, "0-1")
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}

      set_result!(t, "1-0")
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, payload}
      assert [%{"boards" => [%{"result" => "1-0"}]}] = payload["rounds"]
    end
  end

  describe "what always sends" do
    test "a first publish" do
      t = tournament()
      :ok = Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "an identical document after the server refused the last one" do
      t = published()

      Process.put(:server_answers, 500)
      set_result!(t, "0-1")
      assert {0, 1} = Publishing.drain()
      assert_received {:posted, _}

      # The arbiter puts the result back. The document is now the one the
      # server accepted before the failure - and nobody knows what a server
      # that answered 500 did with the one in between.
      Process.put(:server_answers, :ok)
      set_result!(t, "1-0")
      make_due()
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "everything, for a while after a failure" do
      t = published()

      Process.put(:server_answers, 500)
      set_result!(t, "0-1")
      assert {0, 1} = Publishing.drain()
      assert_received {:posted, _}

      Process.put(:server_answers, :ok)
      make_due()
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}

      # The retry was accepted, but the request that failed may still be
      # somewhere between here and there. Nothing is trusted yet.
      touch(t)
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "a document built by another version of the app" do
      t = published()
      payload = Snapshot.build(t)

      # What an older build accepted, were it remembered: same document, by
      # the fingerprint's lights, under the older version's binding.
      Accepted.record(t.id, payload, Publishing.acceptance_binding(t, "0.0.1-older"))

      touch(t)
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "a direct publish" do
      t = published()
      assert {:ok, body} = Publishing.publish(t)
      assert body != :unchanged
      assert_received {:posted, _}
    end

    test "Try again" do
      t = published()
      touch(t)

      Publishing.retry(t.id)
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "publishing switched off and on again" do
      t = published()

      {:ok, off} = Tournaments.set_publish_to_openresults(t, false)
      {:ok, _on} = Tournaments.set_publish_to_openresults(off, true)

      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "a new server address, or a new token" do
      t = published()

      Publishing.put_endpoint("https://elsewhere.example/")
      touch(t)
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}

      Publishing.put_token("another")
      touch(t)
      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end

    test "a tournament that came back from a hand-off" do
      t = published()

      {:ok, away} = Tournaments.hand_off(t, "the other laptop")
      {:ok, _back} = Tournaments.take_back(away, away.handoff_token)

      assert {1, 0} = Publishing.drain()
      assert_received {:posted, _}
    end
  end

  describe "Accepted" do
    setup do
      t = tournament()
      %{t: t, payload: Snapshot.build(t), binding: Publishing.acceptance_binding(t)}
    end

    test "nothing is unchanged before something was accepted", ctx do
      refute Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding)
    end

    test "the clock's own stamp is the only thing that may differ", ctx do
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding)

      # Volatile, and safe to ignore: it says when the document was built,
      # and a document not sent keeps the stamp of the send that carried
      # the same content.
      later = Map.put(ctx.payload, "published_at", "2031-01-01T00:00:00Z")
      assert Accepted.unchanged?(ctx.t.id, later, ctx.binding)

      for key <- Map.keys(ctx.payload) -- Accepted.volatile_keys() do
        changed = Map.put(ctx.payload, key, {:changed, ctx.payload[key]})

        refute Accepted.unchanged?(ctx.t.id, changed, ctx.binding),
               "a change to #{inspect(key)} was not noticed"
      end

      # A key nobody has classified is content until somebody says otherwise.
      refute Accepted.unchanged?(ctx.t.id, Map.put(ctx.payload, "new_field", 1), ctx.binding)
    end

    test "a change deep inside the document is a change", ctx do
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding)

      deep = update_in(ctx.payload, ["players", Access.at(0), "name"], &(&1 <> "!"))
      refute Accepted.unchanged?(ctx.t.id, deep, ctx.binding)

      version = put_in(ctx.payload, ["source", "version"], "9.9.9")
      refute Accepted.unchanged?(ctx.t.id, version, ctx.binding)
    end

    test "another key, server, credential or version is another document", ctx do
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding)
      {endpoint, key, credential, mode, version} = ctx.binding

      for other <- [
            {"https://other.example", key, credential, mode, version},
            {endpoint, "another-key", credential, mode, version},
            {endpoint, key, {:bearer, "another"}, mode, version},
            {endpoint, key, credential, :public, version},
            {endpoint, key, credential, mode, "0.0.1"}
          ] do
        refute Accepted.unchanged?(ctx.t.id, ctx.payload, other)
      end

      assert Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding)
    end

    test "an acceptance is believed for an hour, and never from the future", ctx do
      now = 1_000_000
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding, now)

      assert Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, now)
      assert Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, now + 3_599)
      refute Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, now + 3_600)
      refute Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, now - 1)
    end

    test "nothing is remembered until a failure has had time to finish arriving", ctx do
      now = 1_000_000
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding, now)
      Accepted.failed(ctx.t.id, now + 10)
      refute Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, now + 11)

      Accepted.record(ctx.t.id, ctx.payload, ctx.binding, now + 40)
      refute Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, now + 41)

      settled = now + 10 + Accepted.settle_seconds()
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding, settled)
      assert Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding, settled + 1)
    end

    test "forgetting", ctx do
      Accepted.record(ctx.t.id, ctx.payload, ctx.binding)
      Accepted.forget(ctx.t.id)
      refute Accepted.unchanged?(ctx.t.id, ctx.payload, ctx.binding)
    end
  end

  describe "the fingerprint's list of keys" do
    # The test the brief for this feature asked for by name. A new top-level
    # key in the snapshot fails here until somebody puts it in `@stable` or
    # argues, in `Accepted`, for `@volatile`. Unclassified keys are hashed
    # anyway, so forgetting costs nothing but this failure.
    test "every top-level key a snapshot can carry is classified" do
      classified = Accepted.stable_keys() ++ Accepted.volatile_keys()

      {swiss, _} = SnapshotFixtures.swiss_fixture()
      {team, _} = SnapshotFixtures.team_snapshot_fixture()
      team = %{team | type: "team-swiss", pairing_system: "swiss", team_pairing_mode: "teams"}

      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "owner#{System.unique_integer([:positive])}@example.invalid",
          hashed_password: "x"
        })

      hosted = Repo.update!(Ecto.Changeset.change(swiss, user_id: user.id))

      seen =
        [swiss, team, hosted]
        |> Enum.flat_map(&Map.keys(Snapshot.build(&1)))
        |> Enum.uniq()

      assert seen -- classified == []

      # One key, and adding a second means coming here to say so.
      assert Accepted.volatile_keys() == ["published_at"]
      # And the list is not padded with keys that no longer exist.
      assert classified -- seen == []
      assert Accepted.stable_keys() -- Accepted.volatile_keys() == Accepted.stable_keys()
    end
  end
end
