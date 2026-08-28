defmodule PairingsEngine.PublishingTest do
  @moduledoc """
  What the arbiter's machine sends to OpenResults, and what happens when it
  cannot.

  The behaviour under test is mostly about failure. A publish that works is
  the easy half; the reason this module exists at all is that an arbiter is
  standing in a school gym with bad wifi when they pair round 5, and the
  interesting question is what the app does then.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.Publishing.QueueEntry
  alias PairingsEngine.Tournaments.{Player, Round, Pairing, Tournament}

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp tournament(opts \\ []) do
    t =
      Repo.insert!(%Tournament{
        name: "Gent Spring Open",
        type: "swiss",
        rounds_count: 3,
        publish_to_openresults: Keyword.get(opts, :publish, true),
        public_slug: Keyword.get(opts, :slug, "gent-#{System.unique_integer([:positive])}")
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

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Tournaments.get_tournament!(t.id)
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp pairings_of(t) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        where: r.tournament_id == ^t.id,
        order_by: p.board
    )
  end

  describe "configuration" do
    test "both halves are required" do
      assert Publishing.configured?()

      Publishing.put_token(nil)
      refute Publishing.configured?()

      Publishing.put_token("s3cret")
      Publishing.put_endpoint(nil)
      refute Publishing.configured?()
    end

    test "a pasted address is normalised rather than rejected" do
      # An arbiter copying an address out of a browser bar or an email is as
      # likely to bring a trailing slash or no scheme as the exact string.
      # Normalising means the error they eventually see is about the server
      # rather than about their typing.
      Publishing.put_endpoint("openresults.zerotwo.cloud/")
      assert Publishing.endpoint() == "https://openresults.zerotwo.cloud"

      Publishing.put_endpoint("http://localhost:4001")
      assert Publishing.endpoint() == "http://localhost:4001"
    end
  end

  describe "publishing" do
    test "posts the snapshot to /api/snapshots with a bearer token" do
      t = tournament()

      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/snapshots"
        assert ["Bearer s3cret"] == Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["schema"] == "openresults/snapshot"
        assert payload["tournament"]["name"] == "Gent Spring Open"
        assert [%{"name" => "A"}, %{"name" => "B"}] = payload["players"]

        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = Publishing.publish(t)
    end

    test "a tournament that has not opted in is refused, not sent" do
      t = tournament(publish: false)

      stub(fn _conn -> flunk("nothing should have been sent") end)

      assert {:error, message} = Publishing.publish(t)
      assert message =~ "not set to publish"
    end

    test "an unconfigured server is refused before anything is built" do
      t = tournament()
      Publishing.put_endpoint(nil)

      stub(fn _conn -> flunk("nothing should have been sent") end)

      assert {:error, message} = Publishing.publish(t)
      assert message =~ "no OpenResults server is configured"
    end
  end

  describe "errors an arbiter has to act on" do
    test "a rejected token says so" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)

      assert {:error, message} = Publishing.publish(t)
      assert message =~ "rejected the token"
    end

    test "a wrong address says so, and names the address" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

      assert {:error, message} = Publishing.publish(t)
      assert message =~ "404"
      assert message =~ "openresults.example"
    end

    test "a dead connection is described in words, not in a tuple" do
      t = tournament()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = Publishing.publish(t)
      # "the connection was refused - is the server running?" beats
      # "%Req.TransportError{reason: :econnrefused}" on a settings page.
      assert message =~ "refused"
      refute message =~ "TransportError"
    end
  end

  describe "the connection check" do
    test "sends the `at` the history route requires" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:query, conn.query_string, conn.request_path})
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      assert {:ok, message} = Publishing.check()
      assert message =~ "Connected"

      # Without `at` the real server answers 400 before it looks the slug up,
      # and the first version of this check reported a correctly configured
      # server as "not an OpenResults server". A stub that answered 404 to
      # anything would have let that ship, so this asserts the request rather
      # than only the reply.
      assert_receive {:query, query, path}
      assert query =~ "at="
      assert path =~ "/history"
    end

    test "never publishes anything" do
      stub(fn conn ->
        # A "test" button that published would be a trap: the arbiter presses
        # it to find out whether the settings work and a tournament goes live
        # as a side effect.
        assert conn.method == "GET"
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      assert {:ok, _} = Publishing.check()
    end

    test "a rejected token is reported as a token problem, not an address one" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)

      assert {:error, message} = Publishing.check()
      assert message =~ "rejected the token"
      refute message =~ "not an OpenResults server"
    end

    test "something that is not an OpenResults server says so" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "<html>hello</html>") end)

      assert {:error, message} = Publishing.check()
      assert message =~ "not an OpenResults server"
    end

    test "missing settings are reported before anything is sent" do
      Publishing.put_token(nil)
      stub(fn _conn -> flunk("nothing should have been sent") end)

      assert {:error, "No token is set."} = Publishing.check()

      Publishing.put_token("s3cret")
      Publishing.put_endpoint(nil)
      assert {:error, "No address is set."} = Publishing.check()
    end
  end

  describe "the queue" do
    test "enqueueing twice leaves one row" do
      t = tournament()

      :ok = Publishing.enqueue(t)
      :ok = Publishing.enqueue(t)
      :ok = Publishing.enqueue(t)

      assert Publishing.pending_count() == 1
    end

    test "a burst of enqueues does not restart the backoff clock" do
      t = tournament()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      :ok = Publishing.enqueue(t)
      assert {0, 1} = Publishing.drain()

      failed = Publishing.queued(t.id)
      assert failed.attempts == 1
      assert DateTime.compare(failed.next_attempt_at, DateTime.utc_now()) == :gt

      # Results keep being entered while the endpoint is down. Each one
      # enqueues, and if that reset `next_attempt_at` the backoff would never
      # take effect and a dead server would be hammered once per keystroke.
      :ok = Publishing.enqueue(t)

      again = Publishing.queued(t.id)
      assert again.next_attempt_at == failed.next_attempt_at
      assert again.attempts == 1
    end

    test "a tournament that has not opted in is never queued" do
      t = tournament(publish: false)

      :ok = Publishing.enqueue(t)

      # Callers are event handlers all over the app; none of them should have
      # to check first, so this is a silent no-op rather than an error.
      assert Publishing.pending_count() == 0
    end

    test "a successful drain removes the row" do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      :ok = Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      assert Publishing.pending_count() == 0
    end

    test "a failed drain keeps the row, with an error the arbiter can read" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)

      :ok = Publishing.enqueue(t)
      assert {0, 1} = Publishing.drain()

      entry = Publishing.queued(t.id)
      assert entry.attempts == 1
      assert entry.last_error =~ "rejected the token"
      assert entry.last_attempt_at
    end

    test "a row is not retried before its backoff expires" do
      t = tournament()

      # Fail once to set a backoff...
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      :ok = Publishing.enqueue(t)
      assert {0, 1} = Publishing.drain()

      # ...then make any further request an outright failure. A second drain
      # must not reach the stub at all.
      stub(fn _conn -> flunk("retried before the backoff expired") end)
      assert {0, 0} = Publishing.drain()
      assert Publishing.pending_count() == 1
    end

    test "the backoff grows and then stops growing" do
      # Bounded on purpose: a publish left overnight has to still go out in
      # the morning without anyone touching it, so the tail is a ceiling
      # rather than a doubling.
      assert Publishing.backoff_for(1) < Publishing.backoff_for(2)
      assert Publishing.backoff_for(2) < Publishing.backoff_for(3)
      assert Publishing.backoff_for(50) == Publishing.backoff_for(500)
      assert Publishing.backoff_for(50) <= 3_600
    end

    test "the queue sends current state, not the state when it was queued" do
      t = tournament()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      :ok = Publishing.enqueue(t)
      assert {0, 1} = Publishing.drain()

      # The connection is down; meanwhile the arbiter adds a player.
      Repo.insert!(%Player{
        tournament_id: t.id,
        name: "C",
        fide_rating: 1600,
        pairing_number: 401
      })

      # Let the backoff expire.
      Publishing.queued(t.id)
      |> Ecto.Changeset.change(%{next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)})
      |> Repo.update!()

      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {1, 0} = Publishing.drain()

      # Three players, not the two that existed when it was queued. The queue
      # holds an intent, not a body: the public page should catch up to the
      # hall, not to a moment twenty minutes ago.
      assert_receive {:payload, payload}
      assert length(payload["players"]) == 3
    end
  end

  describe "the per-tournament opt-in" do
    test "turning it on publishes immediately" do
      t = tournament(publish: false)

      assert {:ok, t} = Tournaments.set_publish_to_openresults(t, true)
      assert t.publish_to_openresults

      # Otherwise the arbiter flips the switch, opens the public link, and
      # gets a 404 until something else happens to touch the tournament.
      assert Publishing.pending_count() == 1
    end

    test "turning it off does not enqueue anything" do
      t = tournament()
      assert {:ok, t} = Tournaments.set_publish_to_openresults(t, false)
      refute t.publish_to_openresults
      assert Publishing.pending_count() == 0
    end

    test "an ordinary settings save cannot turn it on" do
      t = tournament(publish: false)

      {:ok, saved} =
        Tournaments.update_tournament(t, %{
          "name" => "Renamed",
          "publish_to_openresults" => true
        })

      # Same guarantee `public_pages_enabled` and `registration_open` have:
      # sending a copy of an event off this machine is a deliberate act, not
      # something a stray form field can do.
      assert saved.name == "Renamed"
      refute saved.publish_to_openresults
    end
  end

  describe "every write enqueues, through the one funnel" do
    test "entering a result queues a publish" do
      t = tournament()
      [pairing] = pairings_of(t)

      assert Publishing.pending_count() == 0
      {:ok, _} = Tournaments.update_pairing_result(pairing, "0-1")

      # The hook is on broadcast_tournament_change/2, so anything worth
      # telling an open LiveView about queues a publish too, and no call site
      # has to remember.
      assert Publishing.pending_count() == 1
    end

    test "a tournament that has not opted in is untouched by the funnel" do
      t = tournament(publish: false)
      [pairing] = pairings_of(t)

      {:ok, _} = Tournaments.update_pairing_result(pairing, "0-1")
      assert Publishing.pending_count() == 0
      assert t.id
    end

    test "eight results in a burst are one queued publish, not eight" do
      t = tournament()
      [pairing] = pairings_of(t)

      for r <- ["1-0", "0-1", "1/2-1/2", "1-0", "0-1", "1/2-1/2", "1-0", "0-1"] do
        {:ok, _} = Tournaments.update_pairing_result(pairing, r)
      end

      # The snapshot is a whole document, so a burst collapses. This is the
      # property that makes hanging off every write affordable.
      assert Publishing.pending_count() == 1
      assert t.id
    end
  end

  describe "publishing can never break a write" do
    test "a missing publish_queue table does not stop a result being entered" do
      t = tournament()
      [pairing] = pairings_of(t)

      # Exactly the state production was in on 2026-08-28: the code had
      # landed, the migration had not. Every write raised, the site was up,
      # and nothing could be saved.
      Repo.query!("DROP TABLE publish_queue")

      assert {:ok, _} = Tournaments.update_pairing_result(pairing, "0-1")

      assert [%{result: "0-1"}] = pairings_of(t)
    end

    test "a missing COLUMN is a different problem, and this module cannot fix it" do
      t = tournament()
      [pairing] = pairings_of(t)

      Repo.query!("ALTER TABLE tournaments DROP COLUMN publish_to_openresults")

      # Worth pinning because the first version of the rescue above was
      # written believing it covered this too. It does not, and cannot.
      #
      # Ecto selects EVERY field a schema declares. The moment
      # `publish_to_openresults` is on the `Tournament` schema, every query
      # that loads a tournament names that column - `refresh_status!/1`
      # here, but equally the dozens of others. So a deploy that lands code
      # before its migration breaks the whole application, not the one
      # function that reads the new field, and no amount of rescuing inside
      # `Publishing` changes that.
      #
      # The real mitigation is deploy ORDER: migrate, then restart. The
      # deploy script already does them in that order; what it does not do
      # is stop when the migration fails, which is exactly how production
      # spent six minutes in this state on 2026-08-28. See TODO.md.
      assert_raise Exqlite.Error, fn ->
        Tournaments.update_pairing_result(pairing, "1-0")
      end
    end
  end

  describe "deleting a tournament" do
    test "takes its queued publish with it" do
      t = tournament()
      :ok = Publishing.enqueue(t)
      assert Publishing.pending_count() == 1

      Repo.delete!(t)

      # Otherwise the drain would keep trying to build a snapshot for a
      # tournament that no longer exists, forever.
      assert Repo.aggregate(QueueEntry, :count, :id) == 0
    end
  end
end
