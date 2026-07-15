defmodule PairingsEngine.TournamentsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}
  alias PairingsEngine.Accounts.{Scope, User}

  # A lightweight stand-in for `PairingsEngine.AccountsFixtures.user_scope_fixture/0`
  # — these tests only need a persisted owner to satisfy the tournament's
  # `user_id` foreign key, not a full register/confirm/magic-link session.
  # Going through the real fixture here (several sequential writes per
  # call) under async/parallel execution was enough to starve SQLite's
  # single writer and intermittently fail with "database busy".
  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  describe "delete_tournament/1" do
    test "removes the tournament and cascades to its players, rounds, pairings and byes" do
      tournament = Repo.insert!(%Tournament{name: "Delete Me", type: "swiss", rounds_count: 3})

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})

      round =
        Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: "1-0"
        })

      Repo.query!(
        "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
        [tournament.id, black.id, 2, "requested-half"]
      )

      assert {:ok, _} = Tournaments.delete_tournament(tournament)

      refute Repo.get(Tournament, tournament.id)
      refute Repo.get(Player, white.id)
      refute Repo.get(Player, black.id)
      refute Repo.get(Round, round.id)
      refute Repo.get(Pairing, pairing.id)

      assert Repo.all(
               from b in "byes", where: b.tournament_id == ^tournament.id, select: b.id
             ) == []
    end
  end

  describe "recycle bin (soft delete, 3-month retention)" do
    test "soft_delete_tournament/1 sets deleted_at and removes it from list_tournaments/1" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:ok, deleted} = Tournaments.soft_delete_tournament(tournament)
      assert %DateTime{} = deleted.deleted_at

      refute Enum.any?(Tournaments.list_tournaments(owner), fn {t, _count, _owner?} -> t.id == tournament.id end)
    end

    test "a binned tournament is not viewable through the normal fetch paths, but shows up in list_deleted_tournaments/1" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, _} = Tournaments.soft_delete_tournament(tournament)

      assert_raise Ecto.NoResultsError, fn -> Tournaments.get_user_tournament!(owner, tournament.id) end
      assert Tournaments.get_user_tournament(owner, tournament.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Tournaments.get_authorized_tournament!(owner, tournament.id) end
      assert Tournaments.get_authorized_tournament(owner, tournament.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Tournaments.get_tournament!(tournament.id) end

      assert [binned] = Tournaments.list_deleted_tournaments(owner)
      assert binned.id == tournament.id
    end

    test "restore_tournament/1 clears deleted_at and brings it back into list_tournaments/1" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, binned} = Tournaments.soft_delete_tournament(tournament)

      assert {:ok, restored} = Tournaments.restore_tournament(binned)
      assert restored.deleted_at == nil

      assert Enum.any?(Tournaments.list_tournaments(owner), fn {t, _count, _owner?} -> t.id == tournament.id end)
      assert Tournaments.list_deleted_tournaments(owner) == []
    end

    test "purge_tournament/1 hard-deletes the row" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, binned} = Tournaments.soft_delete_tournament(tournament)

      assert {:ok, _} = Tournaments.purge_tournament(binned)
      refute Repo.get(Tournament, tournament.id)
    end

    test "purge_expired_tournaments/0 purges rows binned over 90 days ago but keeps recent ones" do
      owner = user_scope()
      {:ok, old} = Tournaments.create_tournament(owner, %{"name" => "Old", "type" => "swiss"})
      {:ok, recent} = Tournaments.create_tournament(owner, %{"name" => "Recent", "type" => "swiss"})

      old
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.add(-100, :day) |> DateTime.truncate(:second))
      |> Repo.update!()

      recent
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second))
      |> Repo.update!()

      assert Tournaments.purge_expired_tournaments() == 1

      refute Repo.get(Tournament, old.id)
      assert Repo.get(Tournament, recent.id)
    end
  end

  describe "update_pairing_result/2" do
    setup do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1})
      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: ""
        })

      %{pairing: pairing}
    end

    test "accepts every canonical result, including the explicit forfeit and played-0-0 codes",
         %{pairing: pairing} do
      for result <- [
            "1-0",
            "0-1",
            "1/2-1/2",
            "1-0FF",
            "0-1FF",
            "0-0FF",
            "0-0",
            "bye",
            ""
          ] do
        assert {:ok, updated} = Tournaments.update_pairing_result(pairing, result)
        assert updated.result == result
      end
    end

    test "rejects a result string that isn't in the recognized set", %{pairing: pairing} do
      assert {:error, changeset} = Tournaments.update_pairing_result(pairing, "3-0")
      assert %{result: ["is invalid"]} = errors_on(changeset)
    end

    test "1-0FF and 0-1FF are distinct from a double forfeit 0-0FF", %{pairing: pairing} do
      assert {:ok, white_forfeit_win} = Tournaments.update_pairing_result(pairing, "1-0FF")
      assert white_forfeit_win.result == "1-0FF"

      assert {:ok, double_forfeit} = Tournaments.update_pairing_result(pairing, "0-0FF")
      assert double_forfeit.result == "0-0FF"

      # A played 0-0 (both lose, game actually contested) is a different,
      # separately-valid result from the double forfeit above.
      assert {:ok, played_zero_zero} = Tournaments.update_pairing_result(pairing, "0-0")
      assert played_zero_zero.result == "0-0"
    end
  end

  describe "refresh_status!/1" do
    test "a tournament with no paired rounds stays \"setup\"" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})

      assert Tournaments.refresh_status!(tournament).status == "setup"
    end

    test "at least one paired round, not fully scored/paired -> \"running\"" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})
      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: ""
      })

      updated = Tournaments.refresh_status!(tournament)
      assert updated.status == "running"
    end

    test "rounds_count rounds paired and every pairing scored -> \"finished\"" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1, status: "setup"})
      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: "1-0"
      })

      updated = Tournaments.refresh_status!(tournament)
      assert updated.status == "finished"
    end

    # A "bye" pairing's result is the literal string "bye" — already
    # non-blank — so a round made up entirely of a pairing-allocated bye
    # still counts as fully scored.
    test "a pairing-allocated bye (result \"bye\") counts as scored, not missing" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1, status: "setup"})
      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{round_id: round.id, board: 1, white_player_id: white.id, black_player_id: nil, result: "bye"})

      updated = Tournaments.refresh_status!(tournament)
      assert updated.status == "finished"
    end

    test "accepts a tournament id as well as a struct, and is a no-op (no error) for a deleted id" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})

      assert Tournaments.refresh_status!(tournament.id).status == "setup"
      assert Tournaments.refresh_status!(-1) == nil
    end

    test "only broadcasts :tournament when the status actually changes" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      Tournaments.refresh_status!(tournament)
      tid = tournament.id
      refute_receive {:tournament_changed, ^tid, :tournament}

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: ""
      })

      Tournaments.refresh_status!(tournament)
      assert_receive {:tournament_changed, ^tid, :tournament}
    end
  end

  describe "PubSub broadcasts" do
    setup do
      %{scope: user_scope()}
    end

    test "create_tournament/2 broadcasts on the owning user's tournament-list topic", %{scope: scope} do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.user_tournaments_topic(scope.user.id))

      assert {:ok, _tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      user_id = scope.user.id
      assert_receive {:tournaments_changed, ^user_id}
    end

    test "update_tournament/2 broadcasts :settings on the tournament topic and on the user's list", %{
      scope: scope
    } do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.user_tournaments_topic(scope.user.id))

      assert {:ok, _updated} = Tournaments.update_tournament(tournament, %{"name" => "T2"})

      tid = tournament.id
      user_id = scope.user.id
      assert_receive {:tournament_changed, ^tid, :settings}
      assert_receive {:tournaments_changed, ^user_id}
    end

    test "update_tournament/2 does not broadcast on an invalid changeset", %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:error, _changeset} = Tournaments.update_tournament(tournament, %{"name" => ""})
      refute_receive {:tournament_changed, _, _}
    end

    test "delete_tournament/1 broadcasts on both the tournament topic and the user's list", %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.user_tournaments_topic(scope.user.id))

      assert {:ok, _} = Tournaments.delete_tournament(tournament)

      tid = tournament.id
      user_id = scope.user.id
      assert_receive {:tournament_changed, ^tid, :tournament}
      assert_receive {:tournaments_changed, ^user_id}
    end

    test "create_player/2, update_player/2 and delete_player/1 each broadcast :players", %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      tid = tournament.id

      assert {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      assert_receive {:tournament_changed, ^tid, :players}

      assert {:ok, player} = Tournaments.update_player(player, %{"name" => "Alice B"})
      assert_receive {:tournament_changed, ^tid, :players}

      assert {:ok, _} = Tournaments.delete_player(player)
      assert_receive {:tournament_changed, ^tid, :players}
    end

    test "create_player/2 does not broadcast on a duplicate FIDE id or an invalid changeset", %{
      scope: scope
    } do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_id" => "123"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:error, :duplicate_fide_id} =
               Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_id" => "123"})

      assert {:error, _changeset} = Tournaments.create_player(tournament.id, %{"name" => ""})

      refute_receive {:tournament_changed, _, _}
    end

    test "update_pairing_result/2 broadcasts :results on the pairing's tournament topic", %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})
      {:ok, white} = Tournaments.create_player(tournament.id, %{"name" => "White"})
      {:ok, black} = Tournaments.create_player(tournament.id, %{"name" => "Black"})

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: ""
        })

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")

      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :results}
    end

    test "with_broadcast_suppressed/1 prevents nested writes from broadcasting", %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      Tournaments.with_broadcast_suppressed(fn ->
        Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      end)

      refute_receive {:tournament_changed, _, _}

      # Suppression only applies inside the function — writes afterwards
      # broadcast normally again.
      assert {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})
      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :players}
    end
  end

  describe "collaborators (tournament sharing by email — invite, must be accepted)" do
    import Swoosh.TestAssertions

    test "add_collaborator/3 creates a pending invite, links user_id as a courtesy when the email belongs to an existing user, and emails an invitation" do
      owner = user_scope()
      collaborator_scope = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:ok, collaborator} =
               Tournaments.add_collaborator(owner, tournament, collaborator_scope.user.email)

      assert collaborator.tournament_id == tournament.id
      assert collaborator.user_id == collaborator_scope.user.id
      assert collaborator.email == String.downcase(collaborator_scope.user.email)
      assert collaborator.status == "pending"
      assert is_binary(collaborator.invite_token)
      assert collaborator.mail_status == :sent

      assert_email_sent(fn email ->
        email.to == [{"", collaborator.email}] and email.text_body =~ collaborator.invite_token
      end)
    end

    test "add_collaborator/3 leaves user_id nil (pending) when no user has that email yet" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:ok, collaborator} =
               Tournaments.add_collaborator(owner, tournament, "Not-Yet-Registered@Example.com")

      assert collaborator.user_id == nil
      assert collaborator.email == "not-yet-registered@example.com"
      assert collaborator.status == "pending"
    end

    test "add_collaborator/3 rejects the owner's own email" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:error, :cannot_add_owner} = Tournaments.add_collaborator(owner, tournament, owner.user.email)
    end

    test "add_collaborator/3 rejects a blank email and a duplicate email gracefully" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:error, :blank_email} = Tournaments.add_collaborator(owner, tournament, "  ")
      assert {:ok, _} = Tournaments.add_collaborator(owner, tournament, "friend@example.com")
      assert {:error, :already_added} = Tournaments.add_collaborator(owner, tournament, "Friend@Example.com")
    end

    test "add_collaborator/3 is owner-only" do
      owner = user_scope()
      not_owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:error, :not_owner} = Tournaments.add_collaborator(not_owner, tournament, "someone@example.com")
    end

    test "remove_collaborator/3 removes a collaborator (pending or accepted) and is owner-only" do
      owner = user_scope()
      not_owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, collaborator} = Tournaments.add_collaborator(owner, tournament, "friend@example.com")

      assert {:error, :not_owner} =
               Tournaments.remove_collaborator(not_owner, tournament, collaborator.id)

      assert {:ok, _} = Tournaments.remove_collaborator(owner, tournament, collaborator.id)
      assert Tournaments.list_collaborators(tournament) == []
    end

    test "a pending invite grants no access — only the owner can reach the tournament until it's accepted" do
      owner = user_scope()
      invited = user_scope()
      pending_email = "pending-#{System.unique_integer([:positive])}@example.com"
      stranger = user_scope()

      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, _} = Tournaments.add_collaborator(owner, tournament, invited.user.email)
      {:ok, _} = Tournaments.add_collaborator(owner, tournament, pending_email)

      assert %Tournament{} = Tournaments.get_authorized_tournament!(owner, tournament.id)

      # Neither the linked-but-pending invitee, nor the not-yet-registered
      # pending invite, nor a stranger have access yet.
      assert Tournaments.get_authorized_tournament(invited, tournament.id) == nil

      pending_scope = %Scope{user: %User{id: -1, email: pending_email}}
      assert Tournaments.get_authorized_tournament(pending_scope, tournament.id) == nil

      assert Tournaments.get_authorized_tournament(stranger, tournament.id) == nil

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_authorized_tournament!(invited, tournament.id)
      end
    end

    test "get_user_tournament!/2 stays owner-only — an (even accepted) collaborator does not satisfy it" do
      owner = user_scope()
      collaborator = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, collaborator.user.email)
      assert {:ok, _} = Tournaments.accept_invitation(collaborator, invite.invite_token)

      assert %Tournament{} = Tournaments.get_user_tournament!(owner, tournament.id)

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_user_tournament!(collaborator, tournament.id)
      end
    end

    test "list_tournaments/1 excludes a shared tournament until the invite is accepted, then includes it (owner? false)" do
      owner = user_scope()
      collaborator = user_scope()
      {:ok, owned} = Tournaments.create_tournament(owner, %{"name" => "Owned", "type" => "swiss"})
      {:ok, shared} = Tournaments.create_tournament(owner, %{"name" => "Shared", "type" => "swiss"})
      {:ok, invite} = Tournaments.add_collaborator(owner, shared, collaborator.user.email)

      refute Enum.any?(Tournaments.list_tournaments(collaborator), fn {t, _count, _owner?} -> t.id == shared.id end)

      assert {:ok, _} = Tournaments.accept_invitation(collaborator, invite.invite_token)

      results = Tournaments.list_tournaments(collaborator)
      ids_and_ownership = Enum.map(results, fn {t, _count, owner?} -> {t.id, owner?} end)

      assert {shared.id, false} in ids_and_ownership
      refute Enum.any?(ids_and_ownership, fn {id, _} -> id == owned.id end)

      owner_results = Tournaments.list_tournaments(owner)
      owner_ids_and_ownership = Enum.map(owner_results, fn {t, _count, owner?} -> {t.id, owner?} end)
      assert {owned.id, true} in owner_ids_and_ownership
      assert {shared.id, true} in owner_ids_and_ownership
    end

    test "link_pending_collaborators/1 links pending rows by email, idempotently, but still does not grant access on its own" do
      owner = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      # Add the collaborator by email *before* any account with that email
      # exists — this is the "pending invite" case add_collaborator/3 itself
      # covers. link_pending_collaborators/1 is the separate, login-time step
      # that backfills user_id once such an account shows up.
      pending_email = "brand-new-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Tournaments.add_collaborator(owner, tournament, pending_email)

      [pending] = Tournaments.list_collaborators(tournament)
      assert pending.user_id == nil

      new_user =
        Repo.insert!(%User{
          email: pending_email,
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      new_scope = Scope.for_user(new_user)

      assert :ok = Tournaments.link_pending_collaborators(new_user)

      [linked] = Tournaments.list_collaborators(tournament)
      assert linked.user_id == new_user.id
      assert linked.status == "pending"

      # Linking backfills user_id for tidiness/lookup purposes only — it does
      # NOT grant access. The invite is still pending.
      refute Enum.any?(Tournaments.list_tournaments(new_scope), fn {t, _count, _owner?} -> t.id == tournament.id end)

      # Idempotent — calling again does nothing further.
      assert :ok = Tournaments.link_pending_collaborators(new_user)
      [still_linked] = Tournaments.list_collaborators(tournament)
      assert still_linked.user_id == new_user.id
    end

    test "accept_invitation/2 grants access, links user_id, clears the token, and requires a matching email" do
      owner = user_scope()
      invitee = user_scope()
      stranger = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:error, :email_mismatch} = Tournaments.accept_invitation(stranger, invite.invite_token)
      assert Tournaments.get_authorized_tournament(stranger, tournament.id) == nil

      assert {:ok, accepted} = Tournaments.accept_invitation(invitee, invite.invite_token)
      assert accepted.status == "accepted"
      assert accepted.user_id == invitee.user.id
      assert accepted.invite_token == nil

      assert %Tournament{} = Tournaments.get_authorized_tournament!(invitee, tournament.id)

      # A bad/already-used token is not found.
      assert {:error, :not_found} = Tournaments.accept_invitation(invitee, invite.invite_token)
      assert {:error, :not_found} = Tournaments.accept_invitation(invitee, "not-a-real-token")
    end

    test "accept_invitation/2 also works by collaborator id" do
      owner = user_scope()
      invitee = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:ok, accepted} = Tournaments.accept_invitation(invitee, invite.id)
      assert accepted.status == "accepted"
    end

    test "decline_invitation/2 deletes the row and requires a matching email" do
      owner = user_scope()
      invitee = user_scope()
      stranger = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:error, :email_mismatch} = Tournaments.decline_invitation(stranger, invite.invite_token)
      assert Tournaments.list_collaborators(tournament) != []

      assert {:ok, _} = Tournaments.decline_invitation(invitee, invite.invite_token)
      assert Tournaments.list_collaborators(tournament) == []

      assert {:error, :not_found} = Tournaments.decline_invitation(invitee, invite.invite_token)
    end

    test "list_pending_invitations/1 returns invites matched by user_id or by email, not accepted ones" do
      owner = user_scope()
      invitee = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, other_tournament} = Tournaments.create_tournament(owner, %{"name" => "T2", "type" => "swiss"})

      {:ok, _} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)
      {:ok, other_invite} = Tournaments.add_collaborator(owner, other_tournament, invitee.user.email)

      assert [_, _] = Tournaments.list_pending_invitations(invitee)

      assert {:ok, _} = Tournaments.accept_invitation(invitee, other_invite.invite_token)

      [remaining] = Tournaments.list_pending_invitations(invitee)
      assert remaining.tournament.id == tournament.id
      assert remaining.owner_email == owner.user.email
    end

    test "the owner can revoke a still-pending invite" do
      owner = user_scope()
      invitee = user_scope()
      {:ok, tournament} = Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})
      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:ok, _} = Tournaments.remove_collaborator(owner, tournament, invite.id)
      assert Tournaments.list_collaborators(tournament) == []

      # Now even the correct person can't accept a revoked invite.
      assert {:error, :not_found} = Tournaments.accept_invitation(invitee, invite.invite_token)
    end
  end

  describe "forbidden pairings (arbiter-configured 'never pair these two')" do
    setup do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob"})
      %{tournament: tournament, a: a, b: b}
    end

    test "add_forbidden_pairing/3 creates a row, and list_forbidden_pairings/1 preloads both players",
         %{tournament: t, a: a, b: b} do
      assert {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert fp.tournament_id == t.id
      assert fp.player_a_id == a.id
      assert fp.player_b_id == b.id

      assert [listed] = Tournaments.list_forbidden_pairings(t.id)
      assert listed.id == fp.id
      assert listed.player_a.name == "Alice"
      assert listed.player_b.name == "Bob"
    end

    test "add_forbidden_pairing/3 rejects the same player twice", %{tournament: t, a: a} do
      assert {:error, :same_player} = Tournaments.add_forbidden_pairing(t, a.id, a.id)
      assert Tournaments.list_forbidden_pairings(t.id) == []
    end

    test "add_forbidden_pairing/3 rejects a player who doesn't belong to this tournament", %{tournament: t, a: a} do
      other = Repo.insert!(%Tournament{name: "Other", type: "swiss", rounds_count: 3})
      stranger = Repo.insert!(%Player{tournament_id: other.id, name: "Stranger"})

      assert {:error, :invalid_player} = Tournaments.add_forbidden_pairing(t, a.id, stranger.id)
      assert {:error, :invalid_player} = Tournaments.add_forbidden_pairing(t, stranger.id, a.id)
      assert Tournaments.list_forbidden_pairings(t.id) == []
    end

    test "add_forbidden_pairing/3 rejects a duplicate pair regardless of order", %{tournament: t, a: a, b: b} do
      assert {:ok, _} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert {:error, :already_forbidden} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert {:error, :already_forbidden} = Tournaments.add_forbidden_pairing(t, b.id, a.id)
      assert length(Tournaments.list_forbidden_pairings(t.id)) == 1
    end

    test "remove_forbidden_pairing/2 removes the row, and 404s (not_found) for another tournament's id",
         %{tournament: t, a: a, b: b} do
      {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      other = Repo.insert!(%Tournament{name: "Other", type: "swiss", rounds_count: 3})

      assert {:error, :not_found} = Tournaments.remove_forbidden_pairing(other, fp.id)
      assert Tournaments.list_forbidden_pairings(t.id) != []

      assert {:ok, removed} = Tournaments.remove_forbidden_pairing(t, fp.id)
      assert removed.id == fp.id
      assert Tournaments.list_forbidden_pairings(t.id) == []
    end

    test "add_forbidden_pairing/3 and remove_forbidden_pairing/2 broadcast :settings on the tournament topic",
         %{tournament: t, a: a, b: b} do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))
      tid = t.id

      assert {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert_receive {:tournament_changed, ^tid, :settings}

      assert {:ok, _} = Tournaments.remove_forbidden_pairing(t, fp.id)
      assert_receive {:tournament_changed, ^tid, :settings}
    end
  end

  describe "extra points (SWAR parity #12 XtPts) — Tournament.changeset/2 normalization" do
    test "count_extra_points defaults false and extra_points_bands defaults blank" do
      tournament = Repo.insert!(%Tournament{name: "Defaults", type: "swiss", rounds_count: 3})
      assert tournament.count_extra_points == false
      assert tournament.extra_points_bands == ""
    end

    test "extra_points_bands is normalized: trimmed, sorted ascending, integer bonuses without a decimal" do
      tournament = Repo.insert!(%Tournament{name: "Norm", type: "swiss", rounds_count: 3})

      {:ok, updated} =
        Tournaments.update_tournament(tournament, %{"extra_points_bands" => " 1600:0.5 , 1400:1 "})

      assert updated.extra_points_bands == "1400:1, 1600:0.5"
    end

    test "rejects a malformed extra_points_bands string with a changeset error" do
      tournament = Repo.insert!(%Tournament{name: "Bad", type: "swiss", rounds_count: 3})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{"extra_points_bands" => "not-a-band"})

      assert %{extra_points_bands: [_msg]} = errors_on(changeset)
    end

    test "rejects a negative threshold or negative bonus" do
      tournament = Repo.insert!(%Tournament{name: "Negative", type: "swiss", rounds_count: 3})

      assert {:error, _} = Tournaments.update_tournament(tournament, %{"extra_points_bands" => "-100:1"})
      assert {:error, _} = Tournaments.update_tournament(tournament, %{"extra_points_bands" => "1400:-1"})
    end

    test "blank extra_points_bands is valid" do
      tournament = Repo.insert!(%Tournament{name: "Blank", type: "swiss", rounds_count: 3})
      assert {:ok, updated} = Tournaments.update_tournament(tournament, %{"extra_points_bands" => "  "})
      assert updated.extra_points_bands == ""
    end

    test "count_extra_points can be toggled on" do
      tournament = Repo.insert!(%Tournament{name: "Toggle", type: "swiss", rounds_count: 3})
      assert {:ok, updated} = Tournaments.update_tournament(tournament, %{"count_extra_points" => true})
      assert updated.count_extra_points == true
    end
  end

  describe "Tournament.parse_extra_points_bands/1 and band_extra_points/2" do
    test "parses a well-formed bands string into sorted-by-input {threshold, bonus} pairs" do
      assert {:ok, [{1600, 0.5}, {1400, 1.0}]} = Tournament.parse_extra_points_bands("1600:0.5, 1400:1")
    end

    test "blank/nil input parses to an empty list" do
      assert {:ok, []} = Tournament.parse_extra_points_bands("")
      assert {:ok, []} = Tournament.parse_extra_points_bands("   ")
      assert {:ok, []} = Tournament.parse_extra_points_bands(nil)
    end

    test "rejects malformed tokens" do
      assert :error = Tournament.parse_extra_points_bands("1400")
      assert :error = Tournament.parse_extra_points_bands("abc:1")
      assert :error = Tournament.parse_extra_points_bands("1400:abc")
      assert :error = Tournament.parse_extra_points_bands("1400:1:2")
    end

    test "a rated player matches the lowest band whose threshold they're below" do
      bands = [{1400, 1.0}, {1600, 0.5}]

      # Below both thresholds -> lowest band wins (bigger bonus).
      assert Tournament.band_extra_points(bands, 1300) == 1.0
      # At the boundary: rating == threshold does NOT count as "below" it.
      assert Tournament.band_extra_points(bands, 1400) == 0.5
      # Below only the higher threshold.
      assert Tournament.band_extra_points(bands, 1550) == 0.5
      # At/above every threshold -> no match.
      assert Tournament.band_extra_points(bands, 1600) == 0.0
      assert Tournament.band_extra_points(bands, 2000) == 0.0
    end

    test "an unrated player (rating 0) only matches an explicit 0:bonus band" do
      assert Tournament.band_extra_points([{1400, 1.0}], 0) == 0.0
      assert Tournament.band_extra_points([{0, 0.75}, {1400, 1.0}], 0) == 0.75
    end

    test "no bands configured -> everyone gets 0.0" do
      assert Tournament.band_extra_points([], 1200) == 0.0
      assert Tournament.band_extra_points([], 0) == 0.0
    end
  end

  describe "apply_extra_points_bands/1" do
    setup do
      tournament =
        Repo.insert!(%Tournament{
          name: "Bands Apply",
          type: "swiss",
          rounds_count: 3,
          extra_points_bands: "1400:1, 1600:0.5"
        })

      low = Repo.insert!(%Player{tournament_id: tournament.id, name: "Low", fide_rating: 1300})
      mid = Repo.insert!(%Player{tournament_id: tournament.id, name: "Mid", fide_rating: 1550})
      high = Repo.insert!(%Player{tournament_id: tournament.id, name: "High", fide_rating: 2000, extra_points: 2.0})
      unrated = Repo.insert!(%Player{tournament_id: tournament.id, name: "Unrated"})

      %{tournament: tournament, low: low, mid: mid, high: high, unrated: unrated}
    end

    test "sets each player's extra_points from the bands, overwriting existing values, matched counts only bonus > 0",
         %{tournament: tournament, low: low, mid: mid, high: high, unrated: unrated} do
      assert {:ok, %{matched: 2, total: 4}} = Tournaments.apply_extra_points_bands(tournament)

      assert Repo.reload!(low).extra_points == 1.0
      assert Repo.reload!(mid).extra_points == 0.5
      # High was previously 2.0 but matches no band -> overwritten to 0.0, not left alone.
      assert Repo.reload!(high).extra_points == 0.0
      # Unrated matches nothing since no "0:bonus" band is configured.
      assert Repo.reload!(unrated).extra_points == 0.0
    end

    test "fires exactly one tournament_changed broadcast", %{tournament: tournament} do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      tid = tournament.id

      assert {:ok, _} = Tournaments.apply_extra_points_bands(tournament)
      assert_receive {:tournament_changed, ^tid, :players}
      refute_receive {:tournament_changed, ^tid, :players}
    end

    test "with no bands configured, applying sets everyone to 0.0" do
      tournament = Repo.insert!(%Tournament{name: "No Bands", type: "swiss", rounds_count: 3})
      p = Repo.insert!(%Player{tournament_id: tournament.id, name: "P", fide_rating: 1000, extra_points: 3.0})

      assert {:ok, %{matched: 0, total: 1}} = Tournaments.apply_extra_points_bands(tournament)
      assert Repo.reload!(p).extra_points == 0.0
    end
  end
end
