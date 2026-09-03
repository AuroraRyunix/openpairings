defmodule PairingsEngine.HandoffReturnTest do
  @moduledoc """
  What comes back with the returning file.

  `PairingsEngine.HandoffFlowTest` covers the flow's shape - lock, envelope,
  receive, return, unlock. This file covers the one thing that used to be
  missing from the end of it: `release/3` applying the payload, so the copy
  left behind ends up holding what was actually played on the other machine
  rather than the state it was frozen in.

  The property under test is that the replacement is total but never blind:
  the source has been read-only for the whole trip, so it cannot have
  diverged and nothing is lost by overwriting it - and every route by which
  that stops being true (a file for another tournament, a source that was
  broken open with the break-glass, a payload that does not survive its own
  import) has to be refused with the source untouched.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Handoff, Repo, Snapshots, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  defp user_scope(prefix) do
    user =
      Repo.insert!(%User{
        email: "#{prefix}#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp populated(scope, name \\ "Return Trip") do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "rounds_count" => "3"
      })

    Repo.insert!(%Player{tournament_id: t.id, name: "Alice", fide_rating: 2100})
    Repo.insert!(%Player{tournament_id: t.id, name: "Bob", fide_rating: 1900})
    Repo.reload!(t)
  end

  # The wire is JSON, so everything crosses one.
  defp over_the_wire(payload), do: payload |> Jason.encode!() |> Jason.decode!()

  # A round actually played on whichever copy is live - the thing the source
  # has never seen and must be holding once the file comes home.
  defp play_round(tournament, number) do
    [white, black] =
      tournament.id |> Tournaments.list_players() |> Enum.sort_by(& &1.name) |> Enum.take(2)

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: number, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: white.id,
      black_player_id: black.id,
      result: "1-0"
    })

    round
  end

  defp player_names(tournament_id) do
    tournament_id |> Tournaments.list_players() |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp round_count(tournament_id) do
    Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament_id), :count)
  end

  defp restore_point(tournament_id) do
    tournament_id
    |> Snapshots.list()
    |> Enum.find(&(&1.trigger == "handoff.released"))
  end

  ## -------------------------------------------------------------------------

  describe "release/3 applies what came back" do
    setup do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)

      %{sender: sender, receiver: receiver, source: Repo.reload!(source), copy: copy}
    end

    test "the rounds played on the other machine are here afterwards", ctx do
      # The event actually ran over there: a round played and a late entry.
      {:ok, _carol} = Tournaments.create_player(ctx.copy.id, %{"name" => "Carol"})
      play_round(ctx.copy, 1)

      # Nothing of that is here yet - the source is frozen where it left.
      assert player_names(ctx.source.id) == ["Alice", "Bob"]
      assert round_count(ctx.source.id) == 0

      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      assert {:ok, unlocked} = Handoff.release(ctx.source, over_the_wire(back), ctx.sender)

      # Unlocked AND up to date, which is the whole point.
      refute Tournaments.handed_off?(unlocked)
      assert Tournaments.ensure_writable(unlocked) == :ok
      assert player_names(ctx.source.id) == ["Alice", "Bob", "Carol"]
      assert round_count(ctx.source.id) == 1

      assert %Round{pairings: [pairing]} = Tournaments.get_round(ctx.source.id, 1)
      assert pairing.result == "1-0"

      # And it takes writes again.
      assert {:ok, _} = Tournaments.create_player(unlocked.id, %{"name" => "Dave"})
    end

    test "settings changed over there come home too", ctx do
      {:ok, _} = Tournaments.update_tournament(ctx.copy, %{"venue" => "The club, upstairs"})

      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      {:ok, unlocked} = Handoff.release(ctx.source, over_the_wire(back), ctx.sender)

      assert unlocked.venue == "The club, upstairs"
    end

    test "the state it replaced is kept as a pinned restore point", ctx do
      {:ok, _carol} = Tournaments.create_player(ctx.copy.id, %{"name" => "Carol"})
      play_round(ctx.copy, 1)

      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      {:ok, _unlocked} = Handoff.release(ctx.source, over_the_wire(back), ctx.sender)

      snapshot = restore_point(ctx.source.id)
      assert snapshot
      assert snapshot.pinned
      assert snapshot.summary =~ "Before the return"

      # An arbiter who applied the wrong file - or simply wants to see what
      # was here - can get the frozen state back.
      assert {:ok, _} = Snapshots.restore(Repo.reload!(ctx.source), snapshot.id, ctx.sender)
      assert player_names(ctx.source.id) == ["Alice", "Bob"]
      assert round_count(ctx.source.id) == 0
    end

    test "it is still audited, and the row still names where it came from", ctx do
      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      {:ok, _} = Handoff.release(ctx.source, over_the_wire(back), ctx.sender)

      row =
        ctx.source.id
        |> PairingsEngine.Audit.list_for_tournament(limit: 50)
        |> Enum.find(&(&1.action == "handoff.released"))

      assert row.details["from"] == "the club laptop"
      refute Repo.reload!(ctx.copy).handoff_origin["release_token"] in Map.values(row.details)
    end

    test "what belongs to this machine is not overwritten by the file", ctx do
      # The counterpart of the export's exclusions: a return replaces the
      # tournament's CONTENT, never who owns it or how this machine shares it.
      before = Repo.reload!(ctx.source)

      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      {:ok, unlocked} = Handoff.release(ctx.source, over_the_wire(back), ctx.sender)

      assert unlocked.user_id == before.user_id
      assert unlocked.public_slug == before.public_slug
      assert unlocked.openresults_key == before.openresults_key
    end

    test "a second application of the same file is refused", ctx do
      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      wire = over_the_wire(back)

      assert {:ok, _} = Handoff.release(ctx.source, wire, ctx.sender)

      # By now this copy may have been handed off somewhere else entirely, and
      # applying the file again would both unlock it and roll it back.
      assert Handoff.release(Repo.reload!(ctx.source), wire, ctx.sender) == {:error, :bad_token}
    end

    test "a struct held from before the lock moved does not unlock the new one", ctx do
      # What a LiveView holds in its assigns while the return panel is open.
      # Between opening it and dropping a file in, the tournament can have
      # come back and gone out again - and the old file's token still matches
      # the OLD struct, which is why the row is re-read before anything is
      # decided.
      stale = ctx.source

      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)
      wire = over_the_wire(back)

      {:ok, _} = Handoff.release(Repo.reload!(ctx.source), wire, ctx.sender)
      {:ok, _} = Handoff.hand_off(Repo.reload!(ctx.source), "a second laptop", ctx.sender)

      assert Handoff.release(stale, wire, ctx.sender) == {:error, :not_this_tournament}

      still = Repo.reload!(ctx.source)
      assert Tournaments.handed_off?(still)
      assert still.handed_off_to == "a second laptop"
    end

    test "the outbound file is still refused as a returning one", ctx do
      {:ok, out} = Handoff.hand_off(populated(ctx.sender, "Elsewhere"), "somewhere", ctx.sender)

      assert Handoff.release(ctx.source, over_the_wire(out), ctx.sender) ==
               {:error, :not_a_return}
    end

    test "an ordinary backup is refused, and nothing is replaced", ctx do
      backup = over_the_wire(PairingsEngine.TournamentExport.export_tournament(ctx.copy))

      assert Handoff.release(ctx.source, backup, ctx.sender) == {:error, :not_a_handoff}
      assert Tournaments.handed_off?(Repo.reload!(ctx.source))
      assert round_count(ctx.source.id) == 0
    end
  end

  describe "a payload that is not this tournament's" do
    test "is refused, and neither the lock nor the contents move" do
      sender = user_scope("sender")
      receiver = user_scope("receiver")

      alpha = populated(sender, "Alpha Open")
      beta = populated(sender, "Beta Open")

      {:ok, alpha_out} = Handoff.hand_off(alpha, "laptop one", sender)
      {:ok, beta_out} = Handoff.hand_off(beta, "laptop two", sender)

      {:ok, _alpha_copy} = Handoff.receive(over_the_wire(alpha_out), receiver)
      {:ok, beta_copy} = Handoff.receive(over_the_wire(beta_out), receiver)

      {:ok, _} = Tournaments.create_player(beta_copy.id, %{"name" => "Beta Only"})
      {:ok, beta_back} = Handoff.return(Repo.reload!(beta_copy), receiver)

      # Beta's return, dropped into Alpha's box. The token would refuse it
      # too, but only after Alpha's contents had been replaced and rolled
      # back; identity refuses it before anything is touched.
      assert Handoff.release(Repo.reload!(alpha), over_the_wire(beta_back), sender) ==
               {:error, :not_this_tournament}

      still = Repo.reload!(alpha)
      assert Tournaments.handed_off?(still)
      assert Tournaments.ensure_writable(still) == {:error, :handed_off}
      assert player_names(alpha.id) == ["Alice", "Bob"]
      refute restore_point(alpha.id)
    end

    test "a file whose body was swapped for another event's is refused" do
      # The token authenticates the envelope, not the body: the two are
      # separate blocks and nothing binds them cryptographically. What binds
      # them here is the trail inside the body, which carries this
      # tournament's own departure row.
      sender = user_scope("sender")
      receiver = user_scope("receiver")

      alpha = populated(sender, "Alpha Open")
      beta = populated(sender, "Beta Open")

      {:ok, alpha_out} = Handoff.hand_off(alpha, "laptop one", sender)
      {:ok, beta_out} = Handoff.hand_off(beta, "laptop two", sender)

      {:ok, alpha_copy} = Handoff.receive(over_the_wire(alpha_out), receiver)
      {:ok, beta_copy} = Handoff.receive(over_the_wire(beta_out), receiver)

      {:ok, alpha_back} = Handoff.return(Repo.reload!(alpha_copy), receiver)
      {:ok, beta_back} = Handoff.return(Repo.reload!(beta_copy), receiver)

      spliced =
        alpha_back
        |> over_the_wire()
        |> Map.put("tournaments", over_the_wire(beta_back)["tournaments"])

      assert Handoff.release(Repo.reload!(alpha), spliced, sender) ==
               {:error, :not_this_tournament}

      assert player_names(alpha.id) == ["Alice", "Bob"]
    end
  end

  describe "a source that was force-unlocked" do
    setup do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)

      %{sender: sender, receiver: receiver, source: Repo.reload!(source), copy: copy}
    end

    test "is refused, because both copies now hold work nobody can merge", ctx do
      # The laptop went missing, so the arbiter broke the glass here and
      # carried on. Then the laptop turned up.
      {:ok, _forced} = Tournaments.force_take_back(ctx.source, ctx.sender)
      {:ok, _} = Tournaments.create_player(ctx.source.id, %{"name" => "Played Here"})
      play_round(Repo.reload!(ctx.source), 1)

      {:ok, _} = Tournaments.create_player(ctx.copy.id, %{"name" => "Played There"})
      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)

      assert Handoff.release(Repo.reload!(ctx.source), over_the_wire(back), ctx.sender) ==
               {:error, :force_unlocked}

      # Nothing done here since the break-glass is touched.
      assert "Played Here" in player_names(ctx.source.id)
      refute "Played There" in player_names(ctx.source.id)
      assert round_count(ctx.source.id) == 1
      refute restore_point(ctx.source.id)
    end

    test "a later, clean hand-off is unaffected by the earlier break-glass", ctx do
      # A forced unlock is not a permanent mark: once this copy has been
      # handed off again it has been read-only for that whole trip, so that
      # trip's returning file is as safe to apply as any other.
      {:ok, _forced} = Tournaments.force_take_back(ctx.source, ctx.sender)
      {:ok, _} = Tournaments.create_player(ctx.source.id, %{"name" => "Played Here"})

      {:ok, out} = Handoff.hand_off(Repo.reload!(ctx.source), "a second laptop", ctx.sender)
      {:ok, second_copy} = Handoff.receive(over_the_wire(out), ctx.receiver)
      {:ok, _} = Tournaments.create_player(second_copy.id, %{"name" => "Played There"})

      {:ok, back} = Handoff.return(Repo.reload!(second_copy), ctx.receiver)

      assert {:ok, unlocked} =
               Handoff.release(Repo.reload!(ctx.source), over_the_wire(back), ctx.sender)

      refute Tournaments.handed_off?(unlocked)
      assert "Played There" in player_names(ctx.source.id)
    end

    test "the file from the abandoned trip is still refused after a second hand-off", ctx do
      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)

      {:ok, _forced} = Tournaments.force_take_back(Repo.reload!(ctx.source), ctx.sender)
      {:ok, _} = Handoff.hand_off(Repo.reload!(ctx.source), "a second laptop", ctx.sender)

      assert Handoff.release(Repo.reload!(ctx.source), over_the_wire(back), ctx.sender) ==
               {:error, :force_unlocked}
    end
  end

  describe "a payload that fails halfway through" do
    setup do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = populated(sender)

      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)

      %{sender: sender, receiver: receiver, source: Repo.reload!(source), copy: copy}
    end

    test "leaves the source untouched and still locked", ctx do
      {:ok, _} = Tournaments.create_player(ctx.copy.id, %{"name" => "Carol"})
      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)

      # A file that gets past every check and then cannot be imported: the
      # entry has lost the settings map `restore_into!/2` reads first.
      wire = over_the_wire(back)
      broken = Map.put(wire, "tournaments", [Map.delete(hd(wire["tournaments"]), "tournament")])

      assert {:error, message} = Handoff.release(ctx.source, broken, ctx.sender)
      assert is_binary(message)

      still = Repo.reload!(ctx.source)
      assert Tournaments.handed_off?(still)
      assert still.handoff_token == ctx.source.handoff_token
      assert Tournaments.ensure_writable(still) == {:error, :handed_off}

      # Contents as they were, and no half-finished restore point on the tree.
      assert player_names(ctx.source.id) == ["Alice", "Bob"]
      assert round_count(ctx.source.id) == 0
      refute restore_point(ctx.source.id)
      assert still.head_snapshot_id == ctx.source.head_snapshot_id
    end

    test "a bad token is refused with the contents left alone", ctx do
      {:ok, back} = Handoff.return(Repo.reload!(ctx.copy), ctx.receiver)

      wire = over_the_wire(back)
      forged = put_in(wire, ["handoff", "token"], "not-the-token")

      assert Handoff.release(ctx.source, forged, ctx.sender) == {:error, :bad_token}

      assert Tournaments.handed_off?(Repo.reload!(ctx.source))
      assert player_names(ctx.source.id) == ["Alice", "Bob"]
      refute restore_point(ctx.source.id)
    end
  end

  describe "the chain, released one link at a time" do
    test "C gives back to B, B gives back to A, and A ends up with everything" do
      a = user_scope("a")
      b = user_scope("b")
      c = user_scope("c")

      on_a = populated(a, "Chain Open")
      {:ok, to_b} = Handoff.hand_off(on_a, "machine B", a)
      {:ok, on_b} = Handoff.receive(over_the_wire(to_b), b)

      {:ok, _} = Tournaments.create_player(on_b.id, %{"name" => "Added on B"})

      {:ok, to_c} = Handoff.hand_off(Repo.reload!(on_b), "machine C", b)
      {:ok, on_c} = Handoff.receive(over_the_wire(to_c), c)

      {:ok, _} = Tournaments.create_player(on_c.id, %{"name" => "Added on C"})

      # C back to B.
      {:ok, c_back} = Handoff.return(Repo.reload!(on_c), c)
      {:ok, b_live} = Handoff.release(Repo.reload!(on_b), over_the_wire(c_back), b)

      assert "Added on C" in player_names(on_b.id)

      # The borrowed key survives having B's contents replaced - without it
      # A could never be unlocked.
      assert b_live.handoff_origin["release_token"] == Repo.reload!(on_a).handoff_token

      # B back to A.
      {:ok, b_back} = Handoff.return(b_live, b)
      {:ok, a_live} = Handoff.release(Repo.reload!(on_a), over_the_wire(b_back), a)

      refute Tournaments.handed_off?(a_live)
      assert player_names(on_a.id) == ["Added on B", "Added on C", "Alice", "Bob"]
    end
  end
end
