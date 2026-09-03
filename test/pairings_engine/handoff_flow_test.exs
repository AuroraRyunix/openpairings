defmodule PairingsEngine.HandoffFlowTest do
  @moduledoc """
  The hand-off FLOW: lock, envelope, receive, return, release.

  `PairingsEngine.HandoffTest` covers the lock itself - the three columns,
  the gate, and the fact that a locked tournament refuses writes. This file
  covers the thing built on top of it, and the property it has to keep is the
  one the lock exists for: at no point in a round trip are two copies
  writable at once.

  Both ends of a hand-off live in the same database here, which is not how it
  works in the field but is exactly the harness the property needs - the test
  can assert on the source and the destination at the same instant, which no
  two-machine test could.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Audit, Handoff, Repo, TournamentExport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.Tournament

  defp user_scope(prefix \\ "flow") do
    user =
      Repo.insert!(%User{
        email: "#{prefix}#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Handoff Flow", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  # A tournament with something in it, so "the event travelled" is a claim the
  # assertions can actually check rather than a shape comparison of two empty
  # envelopes.
  defp populated(scope) do
    t = tournament(scope)
    {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Alice", "fide_rating" => "2000"})
    {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Bob", "fide_rating" => "1900"})
    Audit.log(t.id, scope, "tournament.created", %{name: t.name})
    Repo.reload!(t)
  end

  # The wire is JSON, so every test that crosses one goes through an encode
  # and a decode. A payload that only works as an Elixir map is not a payload.
  defp over_the_wire(payload), do: payload |> Jason.encode!() |> Jason.decode!()

  defp actions_for(tournament_id) do
    tournament_id |> Audit.list_for_tournament(limit: 200) |> Enum.map(& &1.action)
  end

  ## -------------------------------------------------------------------------

  describe "hand_off/3" do
    test "locks this copy and hands back an envelope carrying the token" do
      scope = user_scope()
      source = populated(scope)

      assert {:ok, payload} = Handoff.hand_off(source, "the club laptop", scope)

      locked = Repo.reload!(source)
      assert Tournaments.handed_off?(locked)
      assert locked.handed_off_to == "the club laptop"
      assert Tournaments.ensure_writable(locked) == {:error, :handed_off}

      # The token in the file IS the token on the row. Anything else and the
      # returning payload could never unlock it.
      assert payload["handoff"]["token"] == locked.handoff_token
    end

    test "the envelope is an ordinary export envelope, so an importer needs no new format" do
      scope = user_scope()
      source = populated(scope)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", scope)

      assert payload["format"] == TournamentExport.format()
      assert payload["version"] == TournamentExport.version()
      assert [entry] = payload["tournaments"]
      assert entry["tournament"]["name"] == "Handoff Flow"
      assert length(entry["players"]) == 2
    end

    test "it carries the hand-off blocks an ordinary backup does not" do
      scope = user_scope()
      source = populated(scope)
      {:ok, _} = Tournaments.add_collaborator(scope, source, "helper@example.com")

      {:ok, payload} = Handoff.hand_off(Repo.reload!(source), "the club laptop", scope)
      entry = hd(payload["tournaments"])

      assert is_list(entry["audit_log"])
      assert Enum.any?(entry["audit_log"], &(&1["action"] == "tournament.created"))
      assert [%{"email" => "helper@example.com"}] = entry["collaborators"]
    end

    test "the origin block says who sent it, from where, and when it left" do
      scope = user_scope()
      source = populated(scope)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", scope)
      origin = payload["handoff"]["origin"]

      assert is_binary(origin["instance"]) and origin["instance"] != ""
      assert is_binary(origin["address"])
      assert origin["handed_off_to"] == "the club laptop"

      {:ok, left_at, _} = DateTime.from_iso8601(origin["handed_off_at"])
      assert DateTime.compare(left_at, Repo.reload!(source).handed_off_at) == :eq
    end

    test "an already handed-off tournament is refused and nothing is minted twice" do
      scope = user_scope()
      source = populated(scope)
      {:ok, _} = Handoff.hand_off(source, "laptop A", scope)
      first_token = Repo.reload!(source).handoff_token

      assert Handoff.hand_off(Repo.reload!(source), "laptop B", scope) ==
               {:error, :already_handed_off}

      reloaded = Repo.reload!(source)
      assert reloaded.handed_off_to == "laptop A"
      assert reloaded.handoff_token == first_token
    end

    test "an archived tournament is refused" do
      scope = user_scope()
      {:ok, archived} = Tournaments.archive_tournament(tournament(scope))

      assert Handoff.hand_off(archived, "the club laptop", scope) == {:error, :archived}
      refute Repo.reload!(archived).handed_off_at
    end

    test "a blank destination is refused before anything is locked" do
      # `handed_off_to` is the only thing the banner on the copy left behind
      # can say. "Handed off to " is not an answer somebody can act on.
      scope = user_scope()
      source = populated(scope)

      assert Handoff.hand_off(source, "   ", scope) == {:error, :no_destination}
      refute Repo.reload!(source).handed_off_at
    end

    test "it is audited, on the tournament, with the destination but never the token" do
      scope = user_scope()
      source = populated(scope)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", scope)

      row =
        source.id
        |> Audit.list_for_tournament(limit: 50)
        |> Enum.find(&(&1.action == "handoff.handed_off"))

      assert row, "handing off must leave a trail - it is the moment the event left"
      assert row.user_id == scope.user.id
      assert row.details["to"] == "the club laptop"

      refute payload["handoff"]["token"] in Map.values(row.details),
             "the token is a key; the audit trail is a screen an administrator reads"
    end
  end

  describe "receive/2" do
    test "an ordinary backup is refused - it is not a hand-off and unlocks nothing" do
      # The sharpest rejection in the file. An ordinary export has no token, so
      # accepting one as a hand-off would produce a copy that believes it can
      # release a source which is not locked and never was.
      scope = user_scope()
      source = populated(scope)
      backup = over_the_wire(TournamentExport.export_tournament(source))

      assert Handoff.receive(backup, user_scope("other")) == {:error, :not_a_handoff}
    end

    test "a backup exported WITH the hand-off blocks is still not a hand-off" do
      # `include_handoff: true` adds the audit trail and the collaborators. It
      # does not lock anything and mints no token, so a file that carries them
      # is still just a rich backup.
      scope = user_scope()
      source = populated(scope)
      rich = over_the_wire(TournamentExport.export_tournament(source, include_handoff: true))

      assert Handoff.receive(rich, user_scope("other")) == {:error, :not_a_handoff}
    end

    test "junk, and an envelope with a hand-off block that carries no token, are refused" do
      scope = user_scope("other")

      assert Handoff.receive(%{}, scope) == {:error, :not_a_handoff}
      assert Handoff.receive("not even a map", scope) == {:error, :not_a_handoff}

      source = populated(user_scope())
      {:ok, payload} = Handoff.hand_off(source, "the club laptop", user_scope())

      tokenless = put_in(over_the_wire(payload), ["handoff", "token"], "")
      assert Handoff.receive(tokenless, scope) == {:error, :not_a_handoff}
    end

    test "an envelope from a future build is refused by version, not misread" do
      scope = user_scope()
      source = populated(scope)
      {:ok, payload} = Handoff.hand_off(source, "the club laptop", scope)

      future = put_in(over_the_wire(payload), ["handoff", "version"], 99)

      assert Handoff.receive(future, user_scope("other")) ==
               {:error, {:unsupported_version, 99}}
    end

    test "the copy that lands is live, writable, and owned by whoever received it" do
      sender = user_scope()
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      assert {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      refute copy.id == source.id
      assert copy.user_id == receiver.user.id
      refute Tournaments.handed_off?(copy)
      assert Tournaments.ensure_writable(copy) == :ok
      assert {:ok, _} = Tournaments.create_player(copy.id, %{"name" => "Carol"})
    end

    test "it records where it came from and the key that unlocks the original" do
      sender = user_scope()
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      origin = copy.handoff_origin
      assert origin["release_token"] == Repo.reload!(source).handoff_token
      assert origin["label"] == "the club laptop"
      assert origin["instance"] == payload["handoff"]["origin"]["instance"]
      assert is_binary(origin["received_at"])
    end

    test "a received copy is never confused with a copy that was sent away" do
      # The two states the storage decision exists to keep apart. Getting this
      # backwards means a banner telling an arbiter their live tournament is
      # somewhere else, or the reverse - a locked one that looks editable.
      sender = user_scope()
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      locked = Repo.reload!(source)
      assert Handoff.handed_away?(locked)
      refute Handoff.received?(locked)

      refute Handoff.handed_away?(copy)
      assert Handoff.received?(copy)
    end

    test "the same payload cannot be received twice on one machine" do
      # Two live copies of one event, which is the whole thing the lock exists
      # to prevent - and doing it from one file makes it a single mis-click.
      sender = user_scope()
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      wire = over_the_wire(payload)

      assert {:ok, _copy} = Handoff.receive(wire, receiver)
      assert Handoff.receive(wire, receiver) == {:error, :already_received}
    end

    test "not even by a different user on the same machine" do
      # A second account is not a second machine. Both copies would be live in
      # the same database, and either could publish results for the same event.
      sender = user_scope()
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      wire = over_the_wire(payload)

      assert {:ok, _} = Handoff.receive(wire, user_scope("first"))
      assert Handoff.receive(wire, user_scope("second")) == {:error, :already_received}
    end

    test "the audit trail and the collaborators travel with it" do
      sender = user_scope()
      receiver = user_scope("receiver")
      source = populated(sender)
      {:ok, _} = Tournaments.add_collaborator(sender, source, "helper@example.com")

      {:ok, payload} = Handoff.hand_off(Repo.reload!(source), "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      assert "tournament.created" in actions_for(copy.id)
      assert "handoff.received" in actions_for(copy.id)

      assert [collaborator] = Tournaments.list_collaborators(copy)
      assert collaborator.email == "helper@example.com"

      # An import is never a grant - it arrives as an invitation to re-accept.
      assert collaborator.status == "pending"
    end

    test "a payload carrying more than one tournament is refused" do
      # A hand-off is one event moving to one machine. `export_all/1` produces
      # a perfectly valid multi-tournament envelope, and if that were ever
      # given a token the release would be ambiguous - one token, several
      # sources, no way to say which one is being unlocked.
      sender = user_scope()
      source = populated(sender)
      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)

      wire = over_the_wire(payload)
      two = Map.put(wire, "tournaments", wire["tournaments"] ++ wire["tournaments"])

      assert Handoff.receive(two, user_scope("receiver")) == {:error, :not_one_tournament}
    end
  end

  describe "return/2 and release/3" do
    setup do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      %{sender: sender, receiver: receiver, source: Repo.reload!(source), copy: copy}
    end

    test "returning locks this copy and carries the release token back", ctx do
      assert {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)

      assert payload["handoff"]["direction"] == "back"
      assert payload["handoff"]["token"] == ctx.source.handoff_token

      returned = Repo.reload!(ctx.copy)
      assert Tournaments.handed_off?(returned)
      assert Tournaments.ensure_writable(returned) == {:error, :handed_off}
    end

    test "a copy that did not arrive by hand-off has nothing to return", ctx do
      home_grown = populated(ctx.receiver)

      assert Handoff.return(home_grown, ctx.receiver) == {:error, :not_received}
      refute Repo.reload!(home_grown).handed_off_at
    end

    test "returning twice is refused - the copy is already locked", ctx do
      assert {:ok, _} = Handoff.return(ctx.copy, ctx.receiver)

      assert Handoff.return(Repo.reload!(ctx.copy), ctx.receiver) ==
               {:error, :already_handed_off}
    end

    test "the returning file unlocks the original and it is writable again", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)

      assert {:ok, unlocked} = Handoff.release(ctx.source, over_the_wire(payload))
      refute Tournaments.handed_off?(unlocked)
      assert unlocked.handed_off_to == nil
      assert unlocked.handoff_token == nil
      assert {:ok, _} = Tournaments.create_player(unlocked.id, %{"name" => "Dave"})
    end

    test "a wrong token is refused and the original stays locked", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)
      wire = over_the_wire(payload)

      assert Handoff.release(ctx.source, put_in(wire, ["handoff", "token"], "not-the-token")) ==
               {:error, :bad_token}

      # No token at all is not a bad key, it is not a hand-off: an ordinary
      # backup lands here, and must.
      assert Handoff.release(ctx.source, put_in(wire, ["handoff", "token"], "")) ==
               {:error, :not_a_handoff}

      assert Handoff.release(ctx.source, put_in(wire, ["handoff", "token"], nil)) ==
               {:error, :not_a_handoff}

      still = Repo.reload!(ctx.source)
      assert Tournaments.handed_off?(still)
      assert Tournaments.ensure_writable(still) == {:error, :handed_off}
    end

    test "a token that is a prefix of the real one is refused", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)
      token = payload["handoff"]["token"]
      wire = put_in(over_the_wire(payload), ["handoff", "token"], String.slice(token, 0..10))

      assert Handoff.release(ctx.source, wire) == {:error, :bad_token}
      assert Repo.reload!(ctx.source).handed_off_at
    end

    test "a returning payload applied twice is refused the second time", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)
      wire = over_the_wire(payload)

      assert {:ok, _} = Handoff.release(ctx.source, wire)

      # By now the tournament may have been handed off somewhere else
      # entirely; a second release must not silently succeed.
      assert Handoff.release(Repo.reload!(ctx.source), wire) == {:error, :bad_token}
    end

    test "the outbound file is refused as a returning one, though it holds the same token", ctx do
      # The realistic disaster: two similarly-named files in a downloads
      # folder, and the wrong one unlocks the source while the other machine
      # is still running the event on its live copy.
      {:ok, outbound} = Handoff.hand_off(populated(ctx.sender), "elsewhere", ctx.sender)

      assert Handoff.returning_token(over_the_wire(outbound)) == {:error, :not_a_return}
    end

    test "returning_token/1 reads the token back out of a returning file", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)

      assert {:ok, token} = Handoff.returning_token(over_the_wire(payload))
      assert token == ctx.source.handoff_token
      assert {:ok, _} = Handoff.release(ctx.source, over_the_wire(payload))
    end

    test "an ordinary backup is not a returning file either", ctx do
      backup = over_the_wire(TournamentExport.export_tournament(ctx.source))

      assert Handoff.returning_token(backup) == {:error, :not_a_handoff}
      assert Handoff.returning_token("junk") == {:error, :not_a_handoff}
    end

    test "both are audited on their own copy", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)
      {:ok, _} = Handoff.release(ctx.source, over_the_wire(payload))

      assert "handoff.returned" in actions_for(ctx.copy.id)
      assert "handoff.released" in actions_for(ctx.source.id)
    end

    test "the release audit row names the destination but never the token", ctx do
      {:ok, payload} = Handoff.return(ctx.copy, ctx.receiver)
      token = payload["handoff"]["token"]
      {:ok, _} = Handoff.release(ctx.source, over_the_wire(payload))

      row =
        ctx.source.id
        |> Audit.list_for_tournament(limit: 50)
        |> Enum.find(&(&1.action == "handoff.released"))

      assert row.details["from"] == "the club laptop"
      refute token in Map.values(row.details)
    end
  end

  describe "the full round trip" do
    test "exactly one copy is writable at every step" do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      # 1. Live here, nowhere else.
      assert Tournaments.ensure_writable(source) == :ok

      # 2. Handed off: the source is a read-only record.
      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      assert Tournaments.ensure_writable(Repo.reload!(source)) == {:error, :handed_off}

      # 3. Received elsewhere: the copy is the live one now.
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)
      assert Tournaments.ensure_writable(copy) == :ok
      assert Tournaments.ensure_writable(Repo.reload!(source)) == {:error, :handed_off}

      # The event actually moved: a round played on the copy is on the copy.
      {:ok, carol} = Tournaments.create_player(copy.id, %{"name" => "Carol"})
      assert Enum.any?(Tournaments.list_players(copy.id), &(&1.id == carol.id))
      refute Enum.any?(Tournaments.list_players(source.id), &(&1.name == "Carol"))

      # 4. Returned: the copy locks before anything is unlocked, so there is no
      #    instant at which both are writable.
      {:ok, back} = Handoff.return(copy, receiver)
      assert Tournaments.ensure_writable(Repo.reload!(copy)) == {:error, :handed_off}
      assert Tournaments.ensure_writable(Repo.reload!(source)) == {:error, :handed_off}

      # 5. Released: the original is live again, holding what was played over
      #    there, and the copy stays locked.
      {:ok, unlocked} = Handoff.release(Repo.reload!(source), over_the_wire(back))
      assert Tournaments.ensure_writable(unlocked) == :ok
      assert Tournaments.ensure_writable(Repo.reload!(copy)) == {:error, :handed_off}
      assert Enum.any?(Tournaments.list_players(source.id), &(&1.name == "Carol"))

      assert {:ok, _} = Tournaments.update_tournament(unlocked, %{"venue" => "Back home"})
    end

    test "the trail on each copy records its own half of the trip" do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)
      {:ok, back} = Handoff.return(copy, receiver)
      {:ok, _} = Handoff.release(Repo.reload!(source), over_the_wire(back))

      source_actions = actions_for(source.id)
      assert "handoff.handed_off" in source_actions
      assert "handoff.released" in source_actions

      copy_actions = actions_for(copy.id)
      assert "handoff.received" in copy_actions
      assert "handoff.returned" in copy_actions

      # The imported trail carries the source's own history too, which is the
      # point of the hand-off blocks: the copy is the same event, not a new one.
      assert "tournament.created" in copy_actions
    end

    test "a tournament can be handed on again, without losing the first key" do
      # Three machines. The bug this guards is the reason the origin lives in
      # its own column: `Tournaments.hand_off/2` mints a fresh token into
      # `handoff_token`, so a scheme that stored the borrowed key there would
      # destroy it here, silently, and machine A could never be unlocked.
      a = user_scope("a")
      b = user_scope("b")
      c = user_scope("c")

      on_a = populated(a)
      {:ok, to_b} = Handoff.hand_off(on_a, "machine B", a)
      {:ok, on_b} = Handoff.receive(over_the_wire(to_b), b)

      a_key = Repo.reload!(on_a).handoff_token

      {:ok, to_c} = Handoff.hand_off(on_b, "machine C", b)
      {:ok, _on_c} = Handoff.receive(over_the_wire(to_c), c)

      on_b = Repo.reload!(on_b)

      # B is now both: it came from A, and it has been handed to C.
      assert Handoff.received?(on_b)
      assert Handoff.handed_away?(on_b)
      assert on_b.handed_off_to == "machine C"
      assert on_b.handoff_origin["label"] == "machine B"

      # And A's key is still exactly where B put it, which is what keeps A
      # unlockable at all - C's return unlocks B, and B's return then unlocks
      # A. `PairingsEngine.HandoffReturnTest` walks that chain all the way
      # back, contents and all.
      assert on_b.handoff_origin["release_token"] == a_key
      refute on_b.handoff_token == a_key
      assert Tournaments.handed_off?(Repo.reload!(on_a))
    end
  end

  describe "what the file does and does not carry" do
    test "mobile enrolments never travel - the helper's phone stays behind" do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, _enrollment} =
        PairingsEngine.Mobile.create_enrollment(source.id, label: "Helper phone")

      {:ok, payload} = Handoff.hand_off(Repo.reload!(source), "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      assert PairingsEngine.Mobile.list_enrollments(copy.id) == []
      refute Jason.encode!(payload) =~ "Helper phone"
    end

    test "the origin column is not reachable through the ordinary changeset" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "handoff_origin" => %{"release_token" => "smuggled"}
        })

      refute Map.has_key?(changeset.changes, :handoff_origin)
    end

    test "an ordinary backup of a received copy does not carry the borrowed key" do
      # The reason `handoff_origin` is on `@excluded_tournament_fields`. If it
      # were exported, every snapshot and every duplicate of this copy would
      # hold a key that unlocks a machine somewhere else.
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, payload} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(payload), receiver)

      backup = Jason.encode!(TournamentExport.export_tournament(copy))

      refute backup =~ copy.handoff_origin["release_token"]
      refute backup =~ "handoff_origin"
    end
  end
end
