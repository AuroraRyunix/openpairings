defmodule PairingsEngine.RegistrationsTest do
  @moduledoc """
  Pulling entries back from OpenResults, and the arbiter deciding on them.

  The property every test here is really defending is the direction: the
  server holds requests, this machine holds players, and the only thing that
  turns one into the other is a person pressing Accept. So the interesting
  assertions are about what does NOT happen - a discard that stays
  discarded, an email that goes no further than this table, a dead server
  that produces a sentence rather than a struct.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Registrations, Repo, Snapshot, Tournaments}
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp tournament(opts \\ []) do
    Repo.insert!(%Tournament{
      name: "Gent Spring Open",
      type: "swiss",
      rounds_count: Keyword.get(opts, :rounds_count, 5),
      publish_to_openresults: Keyword.get(opts, :publish, true),
      archived_at: Keyword.get(opts, :archived_at),
      public_slug: "gent-#{System.unique_integer([:positive])}"
    })
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  # One entry as the assumed listing route renders it: the stored row's id
  # and server-stamped arrival time, wrapping the registration document.
  defp entry(id, player, opts \\ []) do
    %{
      "id" => id,
      "received_at" => Keyword.get(opts, :received_at, "2026-02-01T09:12:00Z"),
      "payload" => document(player)
    }
  end

  defp document(player) do
    %{
      "schema" => "openresults/registration",
      "version" => 1,
      "received_at" => "2026-02-01T09:12:00Z",
      "tournament_slug" => "gent-spring-open-2026",
      "player" => player
    }
  end

  defp ilse(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "De Vos, Ilse",
        "rating" => 1804,
        "federation" => "BEL",
        "fide_id" => 2_503_014,
        "club" => "KGSRL",
        "email" => "ilse@example.com",
        "requested_byes" => [3, 4]
      },
      overrides
    )
  end

  defp serve(entries) do
    stub(fn conn -> Req.Test.json(conn, %{"registrations" => entries}) end)
  end

  describe "pulling" do
    test "a pull with nothing pending is an answer, not an error" do
      t = tournament()
      serve([])

      # An empty entry list is the ordinary state of a tournament nobody has
      # signed up for yet. Reporting it as a failure would train an arbiter
      # to ignore the error line on this page.
      assert {:ok, %{new: 0, total: 0}} = Registrations.pull(t)
      assert Registrations.pending(t.id) == []
      assert Registrations.pending_count(t.id) == 0
    end

    test "a pull with entries stores them, waiting for a decision" do
      t = tournament()
      serve([entry(1, ilse()), entry(2, ilse(%{"name" => "Peeters, Jan", "email" => nil}))])

      assert {:ok, %{new: 2, total: 2}} = Registrations.pull(t)

      assert [first, second] = Registrations.pending(t.id)
      assert Registration.name(first) == "De Vos, Ilse"
      assert Registration.name(second) == "Peeters, Jan"

      # Pulled is not accepted. Nothing about a pull may create a player.
      assert Repo.aggregate(from(p in Player, where: p.tournament_id == ^t.id), :count, :id) == 0
    end

    test "asks the token-gated registrations route for this tournament's slug" do
      t = tournament()
      test_pid = self()

      stub(fn conn ->
        send(
          test_pid,
          {:request, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization")}
        )

        Req.Test.json(conn, %{"registrations" => []})
      end)

      assert {:ok, _} = Registrations.pull(t)

      assert_receive {:request, method, path, auth}
      assert method == "GET"
      assert path == "/api/tournaments/#{t.public_slug}/registrations"
      # Token-gated for the same reason `/history` is: this listing is the
      # only thing in the system that carries an email address.
      assert auth == ["Bearer s3cret"]
    end

    test "pulling twice does not offer the same entry twice" do
      t = tournament()
      serve([entry(1, ilse())])

      assert {:ok, %{new: 1, total: 1}} = Registrations.pull(t)
      assert {:ok, %{new: 0, total: 1}} = Registrations.pull(t)

      assert length(Registrations.pending(t.id)) == 1
    end

    test "a bare array is read as well as an envelope" do
      # The listing route does not exist on the server yet, so this side
      # accepts both plausible renderings rather than breaking if the other
      # half returns its list unwrapped.
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, [entry(1, ilse())]) end)

      assert {:ok, %{new: 1}} = Registrations.pull(t)
    end

    test "an entry with no id is still recognised on a second pull" do
      # If the server hands back stored payloads verbatim there is no row id
      # to hang a decision on, and without a fingerprint every pull would
      # resurrect everything the arbiter had already dealt with.
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, [document(ilse())]) end)

      assert {:ok, %{new: 1, total: 1}} = Registrations.pull(t)
      assert {:ok, %{new: 0, total: 1}} = Registrations.pull(t)
    end

    test "a tournament with nothing on the results site is refused, and nothing is sent" do
      t = tournament(publish: false)
      stub(fn _conn -> flunk("nothing should have been fetched") end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "nothing to do with the results site"
    end

    test "but one switched off AFTER publishing is still pulled" do
      # The switch says whether more will be SENT. The copy on the server is
      # still there, and its entry form is whatever the last snapshot said -
      # so entries can still be arriving at a tournament this machine has
      # stopped publishing to. Refusing here would leave real people in a
      # queue nobody reads, and a later takedown would delete them unseen.
      t = tournament(publish: false)

      t =
        t
        |> Ecto.Changeset.change(openresults_key: "a-key-from-an-earlier-publish")
        |> Repo.update!()

      stub(fn conn -> Req.Test.json(conn, [document(ilse())]) end)

      assert {:ok, %{new: 1, total: 1}} = Registrations.pull(t)
    end

    test "an archived tournament is refused" do
      t = tournament(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
      stub(fn _conn -> flunk("nothing should have been fetched") end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "archived"
    end

    test "an unconfigured server is refused before anything is sent" do
      t = tournament()
      Publishing.put_endpoint(nil)
      stub(fn _conn -> flunk("nothing should have been fetched") end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "no OpenResults server is configured"
    end
  end

  describe "errors an arbiter has to act on" do
    test "a dead connection is described in words, not in a tuple" do
      t = tournament()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = Registrations.pull(t)

      # Same rule as `Publishing`: an arbiter cannot act on
      # `%Req.TransportError{reason: :econnrefused}`.
      assert message =~ "refused"
      refute message =~ "TransportError"
      assert is_binary(message)
    end

    test "a timeout is described in words too" do
      t = tournament()
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, "connection timed out"} = Registrations.pull(t)
    end

    test "a rejected token says so" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "rejected the token"
    end

    test "a server with no such list says so rather than reporting no entries" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"})) end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "404"
      # "0 entries" and "the server could not tell me" are different facts,
      # and only one of them means everything is fine.
      refute message =~ "Nothing"
    end

    test "an unexpected server error carries what the server said" do
      t = tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, ~s({"error":"boom"})) end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "500"
      assert message =~ "boom"
    end

    test "a reply that is not a list of entries is refused rather than half-read" do
      t = tournament()
      stub(fn conn -> Req.Test.json(conn, %{"hello" => "world"}) end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "not a list of entries"
    end
  end

  describe "accepting" do
    test "accepting creates a real player in the tournament" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, player} = Registrations.accept(registration)

      assert player.tournament_id == t.id
      assert player.name == "De Vos, Ilse"
      assert player.fide_rating == 1804
      assert player.fide_id == 2_503_014
      assert player.federation == "BEL"
      assert player.club == "KGSRL"

      assert [found] = Repo.all(from p in Player, where: p.tournament_id == ^t.id)
      assert found.id == player.id
    end

    test "an accepted entrant lands absent, not in the room" do
      t = tournament()
      serve([entry(1, ilse(%{"requested_byes" => []}))])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, player} = Registrations.accept(registration)

      # Same rule as the form on this machine. Filling in a web page
      # announces an intention to play; getting this backwards pairs a
      # no-show and hands their opponent a forfeit win.
      assert player.absent
    end

    test "requested byes become absent rounds, clamped to the rounds that exist" do
      t = tournament(rounds_count: 5)
      serve([entry(1, ilse(%{"requested_byes" => [4, 3, 9, 0, 3]}))])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, player} = Registrations.accept(registration)

      # Sorted, de-duplicated, and re-derived from the round count rather
      # than trusted - "round 9" of a five-round event is a perfectly
      # well-formed request from a form with no login behind it.
      assert player.absent_rounds == "3,4"

      # The impossible part of the request is still readable on the entry,
      # so the review page can say the person asked for something this
      # tournament cannot give them.
      assert Registrations.requested_rounds(registration) == [0, 3, 4, 9]
    end

    test "a number sent as a string or a float is still accepted" do
      # The columns are integers and Ecto's cast refuses both of these. The
      # sender is a web form, so an entry that could not be accepted at all
      # would leave the arbiter typing the player in by hand.
      t = tournament()

      serve([
        entry(1, ilse(%{"rating" => "1804", "fide_id" => 2_503_014.0, "birth_year" => "1993"}))
      ])

      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, player} = Registrations.accept(registration)
      assert player.fide_rating == 1804
      assert player.fide_id == 2_503_014
      assert player.birth_year == 1993
    end

    test "a rating that is not a number at all is left unset rather than refused" do
      t = tournament()
      serve([entry(1, ilse(%{"rating" => "unrated", "fide_id" => nil}))])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, player} = Registrations.accept(registration)
      assert player.name == "De Vos, Ilse"
      assert player.fide_rating == 0
    end

    test "an entry with no requested byes sits out nothing" do
      t = tournament()
      serve([entry(1, ilse(%{"requested_byes" => nil}))])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, player} = Registrations.accept(registration)
      assert player.absent_rounds == ""
    end

    test "the email stays in this table and reaches neither the player nor a snapshot" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert Registration.email(registration) == "ilse@example.com"

      assert {:ok, player} = Registrations.accept(registration)

      # There is no column on `players` that could hold it, and nothing in
      # the accept path tries.
      refute player
             |> Map.from_struct()
             |> Map.values()
             |> Enum.any?(&(&1 == "ilse@example.com"))

      # The stronger statement: it is not in what would leave the machine.
      {:ok, _} = Tournaments.update_player(player, %{"pairing_number" => 1})

      published = t.id |> Tournaments.get_tournament!() |> Snapshot.build() |> Jason.encode!()

      assert published =~ "De Vos, Ilse"
      refute published =~ "ilse@example.com"
      refute published =~ "email"
    end

    test "a blank name comes back as a sentence rather than a changeset" do
      t = tournament()
      serve([entry(1, ilse(%{"name" => "   "}))])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:error, message} = Registrations.accept(registration)
      assert is_binary(message)
      assert message =~ "name"

      # Still pending: a failed accept must not silently consume the entry.
      assert [_still_here] = Registrations.pending(t.id)
    end

    test "a FIDE ID already in the tournament is reported in words" do
      t = tournament()
      serve([entry(1, ilse()), entry(2, ilse(%{"name" => "Someone Else"}))])
      {:ok, _} = Registrations.pull(t)

      [first, second] = Registrations.pending(t.id)
      assert {:ok, _player} = Registrations.accept(first)

      assert {:error, message} = Registrations.accept(second)
      assert message =~ "FIDE ID"
    end

    test "accepting the same entry twice is refused, FIDE ID or not" do
      t = tournament()
      # No FIDE ID, so `create_player/2`'s duplicate guard cannot catch a
      # second accept - the status has to. This is the double-click on the
      # Accept button, where the page still holds a struct that says
      # "pending" because the click that changed it has not come back yet.
      serve([entry(1, ilse(%{"fide_id" => nil}))])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, _player} = Registrations.accept(registration)

      assert {:error, message} = Registrations.accept(registration)
      assert message =~ "already been accepted"
      assert Repo.aggregate(from(p in Player, where: p.tournament_id == ^t.id), :count, :id) == 1
    end

    test "discarding an entry that has just been accepted is refused" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      {:ok, _player} = Registrations.accept(registration)

      assert {:error, message} = Registrations.discard(registration)
      assert message =~ "already been accepted"
      assert [%{status: "accepted"}] = Registrations.decided(t.id)
    end

    test "an accepted entry remembers which player it became" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      {:ok, player} = Registrations.accept(registration)

      assert [decided] = Registrations.decided(t.id)
      assert decided.status == "accepted"
      assert decided.player_id == player.id
      assert decided.player.name == "De Vos, Ilse"
      assert decided.decided_at
    end
  end

  describe "discarding" do
    test "discarding creates nothing" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      assert {:ok, discarded} = Registrations.discard(registration)
      assert discarded.status == "discarded"

      assert Repo.aggregate(from(p in Player, where: p.tournament_id == ^t.id), :count, :id) == 0
      assert Registrations.pending(t.id) == []
    end

    test "a discarded entry does not come back at the next pull" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      {:ok, _} = Registrations.discard(registration)

      # The server holds everything it was ever sent and has no notion of an
      # entry being handled, so it offers the same row again. "Already
      # decided" is a fact about this machine.
      assert {:ok, %{new: 0, total: 1}} = Registrations.pull(t)
      assert Registrations.pending(t.id) == []
    end

    test "a discarded entry keeps the email, so the person can still be told" do
      t = tournament()
      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(t)

      [registration] = Registrations.pending(t.id)
      {:ok, _} = Registrations.discard(registration)

      assert [decided] = Registrations.decided(t.id)
      assert Registration.email(decided) == "ilse@example.com"
    end

    test "a discarded entry can be put back, an accepted one cannot" do
      t = tournament()
      serve([entry(1, ilse()), entry(2, ilse(%{"name" => "Peeters, Jan", "fide_id" => nil}))])
      {:ok, _} = Registrations.pull(t)

      [first, second] = Registrations.pending(t.id)

      {:ok, discarded} = Registrations.discard(first)
      assert {:ok, restored} = Registrations.restore(discarded)
      assert restored.status == "pending"

      {:ok, _player} = Registrations.accept(second)
      accepted = Registrations.get(t.id, second.id)
      assert {:error, message} = Registrations.restore(accepted)
      assert message =~ "delete the player"
    end
  end

  describe "reaching an entry" do
    test "an entry belongs to its tournament and cannot be fetched through another" do
      mine = tournament()
      theirs = tournament()

      serve([entry(1, ilse())])
      {:ok, _} = Registrations.pull(mine)
      [registration] = Registrations.pending(mine.id)

      assert Registrations.get(mine.id, registration.id)
      # The id arrives in a client event payload long after the mount was
      # authorised, so scoping it is the whole point of the function.
      refute Registrations.get(theirs.id, registration.id)
    end

    test "a non-numeric id is not found rather than a crash" do
      t = tournament()

      refute Registrations.get(t.id, "not-an-id")
      refute Registrations.get(t.id, nil)
    end
  end
end
