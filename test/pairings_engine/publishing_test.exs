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

      # Same guarantee `publish_to_openresults` and `registration_open` have:
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

  describe "the per-tournament key" do
    test "is minted at the first publish, and not before" do
      t = tournament()

      # Not at creation, and not when the switch went on. A key is a claim on
      # a slug the server has never heard of until something is actually
      # sent, so a tournament that never publishes never holds one.
      refute t.openresults_key
      refute Publishing.published?(t)

      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)

      stored = Tournaments.get_tournament!(t.id)
      assert is_binary(stored.openresults_key)
      assert byte_size(stored.openresults_key) >= 32
      assert Publishing.published?(stored)
    end

    test "travels in a header, never in the published document" do
      t = tournament()
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Plug.Conn.get_req_header(conn, "x-openresults-key"), body})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = Publishing.publish(t)
      key = Tournaments.get_tournament!(t.id).openresults_key

      assert_receive {:sent, [^key], body}

      # This is the whole reason it is a header. The server stores the POSTed
      # body verbatim and serves it back on an OPEN route, so a key inside the
      # snapshot would be published to the world by the very request that
      # established it.
      refute body =~ key
    end

    test "the same key is sent on every later publish" do
      t = tournament()
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:key, Plug.Conn.get_req_header(conn, "x-openresults-key")})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = Publishing.publish(t)
      assert_receive {:key, [first]}

      # Publish again from a freshly loaded row, the way the drain does.
      assert {:ok, _} = Publishing.publish(Tournaments.get_tournament!(t.id))
      assert_receive {:key, [second]}

      assert second == first
    end

    test "is never regenerated by anything short of a takedown" do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      assert {:ok, _} = Publishing.publish(t)
      key = Tournaments.get_tournament!(t.id).openresults_key

      # The server binds the slug to the first key it sees. A machine that
      # quietly minted a second one would lock itself out of its own
      # tournament, so every ordinary path has to leave it alone.
      {:ok, _} =
        Tournaments.update_tournament(Tournaments.get_tournament!(t.id), %{
          "name" => "Renamed Mid-Event"
        })

      {:ok, off} =
        Tournaments.set_publish_to_openresults(Tournaments.get_tournament!(t.id), false)

      {:ok, _} = Tournaments.set_publish_to_openresults(off, true)

      {:ok, _} = Tournaments.rotate_public_slug(Tournaments.get_tournament!(t.id))

      assert {:ok, _} = Publishing.publish(Tournaments.get_tournament!(t.id))

      assert Tournaments.get_tournament!(t.id).openresults_key == key
    end

    test "ensure_key/1 does not overwrite a key that is already there" do
      t = tournament()

      first = Publishing.ensure_key(t)
      assert first.openresults_key

      # Called with a STALE struct - the case a race would produce. The row
      # already has a key, so the guarded update matches nothing and the
      # value is read back rather than assumed.
      second = Publishing.ensure_key(%{t | openresults_key: nil})

      assert second.openresults_key == first.openresults_key
      assert Tournaments.get_tournament!(t.id).openresults_key == first.openresults_key
    end

    test "a key the server refuses is reported as a key problem, not a token one" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"wrong_key"})) end)

      assert {:error, message} = Publishing.publish(t)

      # Sending an arbiter to re-check their token when the actual problem is
      # that another machine owns this tournament wastes the only thing they
      # have, which is time between rounds.
      assert message =~ "different machine"
      refute message =~ "rejected the token"
    end
  end

  describe "reconciling a switch that never sent anything" do
    test "queues a tournament that is switched on but has no key" do
      t = tournament()
      refute Publishing.published?(t)
      assert Publishing.pending_count() == 0

      assert Publishing.backfill() == 1
      assert Publishing.queued(t.id)
    end

    test "leaves a tournament that has already published alone" do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)

      # Draining clears the queue; a key means the promise was kept, so there
      # is nothing to reconcile and re-queueing would send a document nobody
      # asked for on every restart.
      Repo.delete_all(QueueEntry)
      assert Publishing.backfill() == 0
    end

    test "leaves a tournament that is switched off alone" do
      _t = tournament(publish: false)

      assert Publishing.backfill() == 0
    end

    test "ignores a deleted tournament" do
      t = tournament()
      {:ok, _} = Tournaments.delete_tournament(t)

      assert Publishing.backfill() == 0
    end

    test "does nothing at all when no results site is configured" do
      _t = tournament()
      Publishing.put_endpoint(nil)

      # A queue entry that can only fail is not a repair - it is an hourly
      # retry of something that was never going to work.
      assert Publishing.backfill() == 0
      assert Publishing.pending_count() == 0
    end

    test "is idempotent - running it twice queues one entry, not two" do
      t = tournament()

      assert Publishing.backfill() == 1
      assert Publishing.backfill() == 1
      assert Publishing.pending_count() == 1
      assert Publishing.queued(t.id)
    end

    test "a tournament taken down is not resurrected by it", %{} do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)
      assert {:ok, _} = Publishing.take_down(Tournaments.get_tournament!(t.id))

      # `take_down/1` clears the key AND switches publishing off. If it only
      # cleared the key, this would look exactly like an unkept promise and
      # the next restart would republish what the arbiter just withdrew.
      assert Publishing.backfill() == 0
      assert Publishing.pending_count() == 0
    end
  end

  describe "moving a published tournament to a new address" do
    setup do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)

      {:ok, published: Tournaments.get_tournament!(t.id)}
    end

    test "deletes the old copy before publishing the new one", %{published: t} do
      test_pid = self()
      old_slug = t.public_slug

      stub(fn conn ->
        send(test_pid, {:call, conn.method, conn.request_path})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, moved, message} = Publishing.rotate_address(t)

      # Order is the whole point. Publishing first would leave a window in
      # which the tournament is live at both addresses, and a takedown that
      # then failed would leave it that way permanently.
      assert_receive {:call, "DELETE", delete_path}
      assert_receive {:call, "POST", "/api/snapshots"}
      assert delete_path == "/api/tournaments/#{old_slug}"

      assert moved.public_slug != old_slug
      assert message =~ "old link is dead"
    end

    test "the old address is genuinely revoked, not just forgotten", %{published: t} do
      old_slug = t.public_slug
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      assert {:ok, moved, _} = Publishing.rotate_address(t)

      # The bug this function exists to prevent: rotating the slug alone
      # leaves the leaked link working, because the copy behind it is on
      # another server and this machine has merely stopped pointing at it.
      # Worse, the key that could have taken it down now names an address
      # that no longer holds anything.
      refute moved.public_slug == old_slug
      assert moved.publish_to_openresults
      assert moved.openresults_key
      refute moved.openresults_key == t.openresults_key
    end

    test "a failed takedown changes nothing at all", %{published: t} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

      assert {:error, _reason} = Publishing.rotate_address(t)

      unchanged = Tournaments.get_tournament!(t.id)

      # A revocation that did not happen must not look like one that did.
      assert unchanged.public_slug == t.public_slug
      assert unchanged.publish_to_openresults
      assert unchanged.openresults_key == t.openresults_key
    end

    test "a failed re-publish still reports the revocation, because it happened", %{published: t} do
      # The takedown succeeds, the publish that follows does not. This is the
      # good way to fail: what the arbiter asked for - kill the old link -
      # is done, and the rest retries by itself.
      stub(fn conn ->
        case conn.method do
          "DELETE" -> Req.Test.json(conn, %{"status" => "deleted"})
          "POST" -> Plug.Conn.send_resp(conn, 503, "later")
        end
      end)

      assert {:ok, moved, message} = Publishing.rotate_address(t)

      assert moved.public_slug != t.public_slug
      assert message =~ "old link is dead"
      assert message =~ "did not go through"

      # Still switched on, so the queue picks it up rather than the arbiter
      # having to notice and re-enable it.
      assert moved.publish_to_openresults
    end

    test "an unpublished tournament just moves" do
      t = tournament(publish: false)
      old_slug = t.public_slug

      # No HTTP at all: there is no copy anywhere to take down, and nothing
      # to send. A stub that raised would prove it, but `Req.Test` with no
      # stub already fails any request that is attempted.
      assert {:ok, moved, message} = Publishing.rotate_address(t)

      assert moved.public_slug != old_slug
      refute moved.publish_to_openresults
      assert message =~ "new address"
    end

    test "a tournament switched off after publishing still revokes properly", %{published: t} do
      # `publish_to_openresults` off but a key still held - a copy IS out
      # there. The old code path keyed off the switch and would have skipped
      # the takedown here, silently orphaning the published copy.
      {:ok, t} = Tournaments.set_publish_to_openresults(t, false)
      t = Tournaments.get_tournament!(t.id)
      assert Publishing.published?(t)

      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:call, conn.method})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _moved, _message} = Publishing.rotate_address(t)
      assert_receive {:call, "DELETE"}
    end
  end

  describe "taking a published tournament down" do
    setup do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)

      {:ok, published: Tournaments.get_tournament!(t.id)}
    end

    test "asks the server to delete it, carrying both secrets", %{published: t} do
      test_pid = self()

      stub(fn conn ->
        send(
          test_pid,
          {:request, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "x-openresults-key")}
        )

        Req.Test.json(conn, %{"status" => "deleted"})
      end)

      assert {:ok, message} = Publishing.take_down(t)
      assert message =~ "Removed from the results site"

      # The token says this machine may talk to the server; the key says it
      # may touch THIS tournament. Both, or the second one is decoration.
      assert_receive {:request, "DELETE", path, ["Bearer s3cret"], [key]}
      assert path == "/api/tournaments/#{t.public_slug}"
      assert key == t.openresults_key
    end

    test "clears the local publishing state", %{published: t} do
      :ok = Publishing.enqueue(t)
      assert Publishing.pending_count() == 1

      stub(fn conn -> Req.Test.json(conn, %{"status" => "deleted"}) end)
      assert {:ok, _} = Publishing.take_down(t)

      after_takedown = Tournaments.get_tournament!(t.id)

      # The switch goes off, so nothing re-publishes what was just deleted.
      refute after_takedown.publish_to_openresults
      # And the queued publish goes with it, for the same reason.
      assert Publishing.pending_count() == 0
      # The key was a claim on something that no longer exists; keeping it
      # would leave a secret behind whose only remaining effect is to leak.
      refute after_takedown.openresults_key
    end

    test "leaves the tournament's own data completely alone", %{published: t} do
      stub(fn conn -> Req.Test.json(conn, %{"status" => "deleted"}) end)
      assert {:ok, _} = Publishing.take_down(t)

      after_takedown = Tournaments.get_tournament!(t.id)
      assert after_takedown.name == t.name
      assert after_takedown.public_slug == t.public_slug
      assert length(Tournaments.list_players(t.id)) == 2
      assert [%{result: "1-0"}] = pairings_of(t)
    end

    test "a refused key is reported in words and changes nothing here", %{published: t} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"wrong_key"})) end)

      assert {:error, message} = Publishing.take_down(t)
      assert message =~ "refused this tournament's key"

      unchanged = Tournaments.get_tournament!(t.id)
      assert unchanged.publish_to_openresults
      assert unchanged.openresults_key == t.openresults_key
    end

    test "a dead connection is reported in words and changes nothing here", %{published: t} do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = Publishing.take_down(t)
      assert message =~ "refused"
      refute message =~ "TransportError"

      unchanged = Tournaments.get_tournament!(t.id)
      assert unchanged.publish_to_openresults
      assert unchanged.openresults_key == t.openresults_key
    end

    test "a 404 is NOT read as 'already gone'", %{published: t} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"})) end)

      # Genuinely ambiguous: the tournament may not be there, or this server
      # may be too old to have a takedown route at all. Guessing the first
      # would tell an arbiter their event was withdrawn while an older server
      # was still serving it.
      assert {:error, message} = Publishing.take_down(t)
      assert message =~ "404"
      assert Tournaments.get_tournament!(t.id).publish_to_openresults
    end

    test "a tournament that never published has nothing to take down" do
      never = tournament()
      stub(fn _conn -> flunk("nothing should have been sent") end)

      # Without a key the server would refuse anyway - and a machine that
      # could delete a tournament it never published is the hole this whole
      # mechanism closes.
      assert {:error, message} = Publishing.take_down(never)
      assert message =~ "nothing has been published from this machine"
    end
  end

  describe "the key in a backup" do
    alias PairingsEngine.Accounts.{Scope, User}
    alias PairingsEngine.{Snapshots, TournamentExport, TournamentImport}

    defp user_scope do
      user =
        Repo.insert!(%User{
          email: "key#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      Scope.for_user(user)
    end

    defp published_tournament do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)
      Tournaments.get_tournament!(t.id)
    end

    test "the envelope carries it, and the address it is authority over" do
      t = published_tournament()

      block =
        t
        |> TournamentExport.export_tournament()
        |> get_in(["tournaments", Access.at(0), "openresults"])

      # Deliberate: rebuilding a laptop from a backup has to recover the
      # ability to manage what that laptop published, and a key left on the
      # dead disk strands a tournament full of player names in public.
      assert block["key"] == t.openresults_key
      assert block["slug"] == t.public_slug
      assert block["endpoint"] == "https://openresults.example"
    end

    test "a tournament that never published carries no block at all" do
      envelope = TournamentExport.export_tournament(tournament())
      assert get_in(envelope, ["tournaments", Access.at(0), "openresults"]) == nil
    end

    test "the key is not smuggled into the tournament map" do
      t = published_tournament()

      t_map =
        t
        |> TournamentExport.export_tournament()
        |> get_in(["tournaments", Access.at(0), "tournament"])

      # `public_slug` and `publish_to_openresults` keep their exclusions: the
      # imported copy still gets its own fresh public link and still has to
      # opt in. Only the key travels, and it travels in its own block.
      refute Map.has_key?(t_map, "openresults_key")
      refute Map.has_key?(t_map, "openresults_claim")
      refute Map.has_key?(t_map, "public_slug")
      refute Map.has_key?(t_map, "publish_to_openresults")
    end

    test "importing does NOT adopt it" do
      source = published_tournament()
      envelope = TournamentExport.export_tournament(source)

      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())
      imported = Tournaments.get_tournament!(imported.id)

      # If it did, two people importing the same file would both believe they
      # own the tournament, both publish to the same slug, and either could
      # delete the other's work.
      refute imported.openresults_key
      refute imported.publish_to_openresults
      refute imported.public_slug == source.public_slug

      # It is held as an offer instead, and taking it up is a separate act.
      assert %{key: key, slug: slug} = Publishing.claim(imported)
      assert key == source.openresults_key
      assert slug == source.public_slug
    end

    test "publishing an imported copy mints a key of its own" do
      source = published_tournament()
      envelope = TournamentExport.export_tournament(source)
      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())

      {:ok, imported} = Tournaments.set_publish_to_openresults(imported, true)
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(imported)

      # Starting fresh is the default in the only sense that matters: not
      # choosing produces a different tournament, not a second owner of the
      # same one.
      assert Tournaments.get_tournament!(imported.id).openresults_key !=
               source.openresults_key
    end

    test "adopting the claim moves both the key and the address across" do
      source = published_tournament()
      envelope = TournamentExport.export_tournament(source)
      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())

      # The original is deleted first - adopting while it still exists here
      # would put two local rows on one address, which the unique index on
      # `public_slug` refuses.
      Repo.delete!(source)

      assert {:ok, adopted} = Publishing.adopt_claim(imported)
      assert adopted.openresults_key == source.openresults_key
      assert adopted.public_slug == source.public_slug
      refute Publishing.claim(adopted)
    end

    test "adopting is refused when this copy already published under its own key" do
      source = published_tournament()
      envelope = TournamentExport.export_tournament(source)
      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())

      {:ok, imported} = Tournaments.set_publish_to_openresults(imported, true)
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(imported)

      # Otherwise it would abandon a published copy this machine is
      # responsible for in order to claim a different one.
      assert {:error, message} =
               Publishing.adopt_claim(Tournaments.get_tournament!(imported.id))

      assert message =~ "already published under a key of its own"
    end

    test "discarding the claim leaves the copy alone and the published one untouched" do
      source = published_tournament()
      envelope = TournamentExport.export_tournament(source)
      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())

      assert {:ok, fresh} = Publishing.discard_claim(imported)
      refute Publishing.claim(fresh)
      refute fresh.openresults_key
      assert Tournaments.get_tournament!(source.id).openresults_key == source.openresults_key
    end

    test "the key survives a restore point taken before it existed" do
      t = tournament()

      # A snapshot from before the tournament ever published, restored after
      # it has. The payload's block is nil, and `openresults_key` is not cast
      # by the changeset, so the restore cannot revoke a live key.
      {:ok, snapshot} = Snapshots.capture(t, "test.before_publishing")

      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Publishing.publish(t)
      key = Tournaments.get_tournament!(t.id).openresults_key

      assert {:ok, _} = Snapshots.restore(Tournaments.get_tournament!(t.id), snapshot.id)

      restored = Tournaments.get_tournament!(t.id)
      assert restored.openresults_key == key
      refute Publishing.claim(restored)
    end

    test "restoring a point taken while published does not resurrect a retired key" do
      t = published_tournament()
      {:ok, snapshot} = Snapshots.capture(t, "test.while_published")

      stub(fn conn -> Req.Test.json(conn, %{"status" => "deleted"}) end)
      assert {:ok, _} = Publishing.take_down(t)

      assert {:ok, _} = Snapshots.restore(Tournaments.get_tournament!(t.id), snapshot.id)

      # A restore point is a copy of the tournament's contents, not of a
      # claim on a server that has since deleted it.
      after_restore = Tournaments.get_tournament!(t.id)
      refute after_restore.openresults_key
      refute after_restore.publish_to_openresults
      refute Publishing.claim(after_restore)
    end
  end
end
