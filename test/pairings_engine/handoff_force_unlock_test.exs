defmodule PairingsEngine.HandoffForceUnlockTest do
  @moduledoc """
  The break-glass unlock, and why a lock with no override is not a safety
  feature.

  `take_back/2` needs the token `hand_off/2` minted, and that token lives in
  exactly one place: the copy the tournament was handed to. Which is fine
  right up until that copy is stolen, wiped, or dropped in a canal. Without
  a way in, the server's copy is read-only FOREVER - the round it is holding
  can never be paired, the results can never be entered, and the tournament
  is finished as a working document. A lock whose failure mode is "the event
  cannot continue" trades a recoverable problem for an unrecoverable one.

  `force_take_back/2` is the way in. It is deliberately not a nicer
  `take_back/2`:

    * it is the owner's call, not a collaborator's;
    * it writes its own audit row, distinct from a normal take-back,
      because when two divergent copies surface later the log is the only
      record of which one was forced;
    * it refuses on a tournament that is not handed off, so it cannot be
      used as a "clear the lock just in case" button.

  What it cannot do is make divergence impossible - nothing can, once the
  other copy exists. It makes it DELIBERATE, and it writes down who chose.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "force#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Force Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  defp handed_off(scope, label \\ "the stolen laptop") do
    {:ok, t} = Tournaments.hand_off(tournament(scope), label)
    t
  end

  defp accepted_collaborator(owner, tournament) do
    collaborator = user_scope()

    {:ok, invite} =
      Tournaments.add_collaborator(owner, tournament, collaborator.user.email)

    {:ok, _} = Tournaments.accept_invitation(collaborator, invite.invite_token)

    collaborator
  end

  defp forced_rows(tournament_id) do
    Audit.list_for_tournament(tournament_id, action: "tournament.handoff_forced")
  end

  describe "force_take_back/2" do
    test "clears the lock without the token, and writes work again" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.take_back(t, "the token is in the canal") == {:error, :bad_token}

      assert {:ok, unlocked} = Tournaments.force_take_back(t, scope)
      assert unlocked.handed_off_at == nil
      assert unlocked.handed_off_to == nil
      assert unlocked.handoff_token == nil
      refute Tournaments.handed_off?(unlocked)

      assert {:ok, _} = Tournaments.create_player(unlocked.id, %{"name" => "Alice"})
    end

    test "is refused for a collaborator - this is the owner's call" do
      owner = user_scope()
      t = tournament(owner)
      collaborator = accepted_collaborator(owner, t)

      # The collaborator really does have access to this tournament...
      assert Tournaments.get_authorized_tournament!(collaborator, t.id)

      {:ok, handed} = Tournaments.hand_off(t, "the stolen laptop")

      # ...and still cannot force the lock.
      assert Tournaments.force_take_back(handed, collaborator) == {:error, :not_owner}
      assert Repo.reload!(handed).handoff_token == handed.handoff_token
      assert forced_rows(t.id) == []
    end

    test "is refused for a stranger" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.force_take_back(t, user_scope()) == {:error, :not_owner}
      assert Repo.reload!(t).handed_off_at
    end

    test "is refused on a tournament that is not handed off" do
      # Not a no-op: a button that silently "succeeds" on a live tournament
      # invites pressing it to find out what it does, and this is the one
      # button nobody should learn by pressing.
      scope = user_scope()
      t = tournament(scope)

      assert Tournaments.force_take_back(t, scope) == {:error, :not_handed_off}
      assert forced_rows(t.id) == []
    end

    test "a stale struct cannot force a tournament that was already taken back" do
      scope = user_scope()
      t = handed_off(scope)
      {:ok, _} = Tournaments.take_back(t, t.handoff_token)

      assert Tournaments.force_take_back(Repo.reload!(t), scope) == {:error, :not_handed_off}
    end

    test "broadcasts on both topics, like every other hand-off transition" do
      scope = user_scope()
      t = handed_off(scope)

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(scope.user.id)
      )

      {:ok, _} = Tournaments.force_take_back(t, scope)

      tid = t.id
      uid = scope.user.id
      assert_receive {:tournament_changed, ^tid, :tournament}
      assert_receive {:tournaments_changed, ^uid}
    end
  end

  describe "the audit row" do
    test "is written, under its own action, naming who forced it and where the other copy is" do
      scope = user_scope()
      t = handed_off(scope, "the club PC")

      {:ok, _} = Tournaments.force_take_back(t, scope)

      assert [row] = forced_rows(t.id)
      assert row.user_id == scope.user.id
      assert row.details["name"] == "Force Test"
      assert row.details["was_handed_off_to"] == "the club PC"
      assert is_binary(row.details["was_handed_off_at"])
    end

    test "never carries the token it destroyed" do
      # `Audit`'s "never a secret" rule. The token is dead by the time the
      # row is written, but a dead credential in a log an administrator reads
      # on screen is still a credential in a log.
      scope = user_scope()
      t = handed_off(scope)

      {:ok, _} = Tournaments.force_take_back(t, scope)

      assert [row] = forced_rows(t.id)
      refute row.details |> Map.values() |> Enum.member?(t.handoff_token)
    end

    test "is distinguishable from an ordinary take-back, which writes nothing here" do
      # The whole reason this is a separate action code. Two divergent copies
      # turning up months later is a question about which one was forced, and
      # the answer has to be in the log or it is nowhere.
      scope = user_scope()
      t = handed_off(scope)

      {:ok, _} = Tournaments.take_back(t, t.handoff_token)

      assert forced_rows(t.id) == []
    end

    test "and the unlock together are all-or-nothing" do
      # If the row could fail to be written while the lock still opened, the
      # forced copy would be indistinguishable from a clean take-back, which
      # is the exact question the row exists to answer.
      scope = user_scope()
      t = handed_off(scope)

      {:ok, _} = Tournaments.force_take_back(t, scope)

      assert [_row] = forced_rows(t.id)
      refute Repo.reload!(t).handed_off_at
    end
  end
end
