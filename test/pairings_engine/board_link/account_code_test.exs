defmodule PairingsEngine.BoardLink.AccountCodeTest do
  @moduledoc """
  Account codes (`PairingsEngine.BoardLink.connect/2`): what one reaches,
  when it stops reaching it, and the grant it is handed over with.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, Repo}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.BoardLink.{Grant, Link}
  alias PairingsEngine.Tournaments.{Collaborator, Tournament}

  defp tournament(scope, attrs \\ %{}), do: paired_tournament(scope, attrs).tournament

  defp collaborate(tournament, user, status \\ "accepted", by \\ :user_id) do
    attrs =
      case by do
        :user_id -> %{tournament_id: tournament.id, user_id: user.id, email: user.email}
        :email -> %{tournament_id: tournament.id, email: user.email}
      end

    Repo.insert!(struct!(Collaborator, Map.put(attrs, :status, status)))
  end

  defp days_ago(n), do: Date.utc_today() |> Date.add(-n) |> Date.to_iso8601()

  defp reached(link), do: link |> BoardLink.covered() |> Enum.map(& &1.tournament.id)

  defp connect!(scope, label \\ "Alnasl - Hall A") do
    {:ok, link, grant} = BoardLink.connect(scope, label: label)
    {link, grant}
  end

  describe "what an account code reaches" do
    test "every current tournament the account owns or collaborates on, and nothing else" do
      me = user_scope_fixture()
      other = user_scope_fixture()

      mine = tournament(me)
      shared = tournament(other)
      shared_by_mail = tournament(other)
      pending = tournament(other)
      foreign = tournament(other)

      collaborate(shared, me.user)
      collaborate(shared_by_mail, me.user, "accepted", :email)
      collaborate(pending, me.user, "pending")

      {link, _grant} = connect!(me)

      assert Enum.sort(reached(link)) == Enum.sort([mine.id, shared.id, shared_by_mail.id])
      refute pending.id in reached(link)
      refute foreign.id in reached(link)
    end

    test "not an archived, handed-off or binned one" do
      me = user_scope_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      archived = tournament(me, %{archived_at: now})
      handed_off = tournament(me, %{handed_off_at: now})
      binned = tournament(me, %{deleted_at: now})
      live = tournament(me)

      {link, _grant} = connect!(me)

      assert reached(link) == [live.id]
      refute archived.id in reached(link)
      refute handed_off.id in reached(link)
      refute binned.id in reached(link)
    end

    test "a finished tournament for #{14} days after its last round, then no more" do
      me = user_scope_fixture()

      recent =
        tournament(me, %{status: "finished", round_dates: [days_ago(5)], end_date: days_ago(5)})

      old =
        tournament(me, %{status: "finished", round_dates: [days_ago(15)], end_date: days_ago(15)})

      # Running with an old date: a postponed game still to be played.
      postponed =
        tournament(me, %{status: "running", round_dates: [days_ago(60)], end_date: days_ago(60)})

      # No round yet: current, whatever its dates say.
      fresh = tournament(me, %{status: "setup", round_dates: [], end_date: ""})

      {link, _grant} = connect!(me)
      ids = reached(link)

      assert recent.id in ids
      assert postponed.id in ids
      assert fresh.id in ids
      refute old.id in ids
    end

    test "a finished tournament without dates goes by when it last changed" do
      me = user_scope_fixture()
      undated = tournament(me, %{status: "finished", round_dates: [], end_date: ""})
      touched = tournament(me, %{status: "finished", round_dates: [], end_date: ""})

      long_ago = DateTime.utc_now() |> DateTime.add(-20 * 86_400) |> DateTime.truncate(:second)

      Repo.update_all(from(t in Tournament, where: t.id == ^undated.id),
        set: [updated_at: long_ago]
      )

      {link, _grant} = connect!(me)

      refute undated.id in reached(link)
      assert touched.id in reached(link)
    end

    test "losing access drops a tournament at the next request" do
      me = user_scope_fixture()
      other = user_scope_fixture()
      shared = tournament(other)
      collaborator = collaborate(shared, me.user)

      {link, _grant} = connect!(me)
      assert shared.id in reached(link)
      assert {:ok, _} = BoardLink.fetch_covered(link, shared.id)

      Repo.delete!(collaborator)

      refute shared.id in reached(link)
      assert :error = BoardLink.fetch_covered(link, shared.id)
    end

    test "says it is an account code, and a tournament it reaches has live boards" do
      me = user_scope_fixture()
      mine = tournament(me)
      other = tournament(user_scope_fixture())

      refute BoardLink.connected?(mine.id)
      {link, _grant} = connect!(me)

      assert %{"kind" => "account", "group" => nil, "tournaments" => [%{"id" => id}]} =
               BoardLink.listing(link)

      assert id == mine.id
      assert BoardLink.connected?(mine.id)
      refute BoardLink.connected?(other.id)
      assert [%Link{id: link_id}] = BoardLink.account_links(mine.id)
      assert link_id == link.id
    end

    test "the account's access and account_links/1 agree, collaborators included" do
      me = user_scope_fixture()
      other = user_scope_fixture()
      shared = tournament(other)
      collaborate(shared, me.user, "accepted", :email)

      {mine, _} = connect!(me, "mine")
      {theirs, _} = connect!(other, "theirs")

      assert Enum.sort(Enum.map(BoardLink.account_links(shared.id), & &1.id)) ==
               Enum.sort([mine.id, theirs.id])
    end
  end

  describe "making and withdrawing" do
    test "eight to an account" do
      me = user_scope_fixture()
      for n <- 1..8, do: connect!(me, "box #{n}")

      assert {:error, :too_many_codes} = BoardLink.connect(me, label: "ninth")
      assert length(BoardLink.list_account_links(me)) == 8
    end

    test "only the account's own code is withdrawn, and the box is refused after" do
      me = user_scope_fixture()
      other = user_scope_fixture()
      {link, grant} = connect!(me)
      {:ok, secret} = BoardLink.redeem_grant(grant)

      assert String.starts_with?(secret, "oplu_")
      assert {:ok, _} = BoardLink.authenticate(secret)

      assert {:error, :not_found} = BoardLink.revoke_account_link(other, link.id)
      assert {:ok, _} = BoardLink.revoke_account_link(me, link.id)
      assert :error = BoardLink.authenticate(secret)
    end

    test "both are on the audit trail as account rows, never with the secret" do
      me = user_scope_fixture()
      {link, grant} = connect!(me, "Alnasl - Hall B")
      {:ok, secret} = BoardLink.redeem_grant(grant)
      {:ok, _} = BoardLink.revoke_account_link(me, link.id)

      rows =
        Repo.all(
          from a in AuditLog,
            where: a.action in ["boards.account_code_created", "boards.account_code_revoked"],
            order_by: a.id
        )

      assert [created, revoked] = rows
      assert created.action == "boards.account_code_created"
      assert revoked.action == "boards.account_code_revoked"
      assert is_nil(created.tournament_id) and is_nil(revoked.tournament_id)
      assert created.user_id == me.user.id
      assert created.details["box"] == "Alnasl - Hall B"
      refute inspect(rows) =~ secret
    end

    test "an account code never works on the network listener" do
      me = user_scope_fixture()
      {_link, grant} = connect!(me)
      {:ok, secret} = BoardLink.redeem_grant(grant)

      assert {:ok, _} = BoardLink.authenticate(secret)
      assert :error = BoardLink.authenticate(secret, lan: true)
    end
  end

  describe "the grant" do
    test "is good once" do
      me = user_scope_fixture()
      {_link, grant} = connect!(me)

      assert {:ok, "oplu_" <> _} = BoardLink.redeem_grant(grant)
      assert :error = BoardLink.redeem_grant(grant)
      assert Repo.aggregate(Grant, :count) == 0
    end

    test "runs out after two minutes" do
      me = user_scope_fixture()
      {_link, grant} = connect!(me)

      past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
      Repo.update_all(Grant, set: [expires_at: past])

      assert :error = BoardLink.redeem_grant(grant)
      assert Repo.aggregate(Grant, :count) == 0
    end

    test "is worth nothing once its code was withdrawn" do
      me = user_scope_fixture()
      {link, grant} = connect!(me)
      {:ok, _} = BoardLink.revoke_account_link(me, link.id)

      assert :error = BoardLink.redeem_grant(grant)
    end

    test "is kept as a hash, with the secret sealed under it" do
      me = user_scope_fixture()
      {_link, grant} = connect!(me)
      [row] = Repo.all(Grant)

      refute row.grant_hash == grant
      refute row.sealed =~ "oplu_"
      assert BoardLink.grant_seconds() == 120
    end

    test "a wrong grant, or something that is not one, is refused" do
      assert :error = BoardLink.redeem_grant(String.duplicate("a", 43))
      assert :error = BoardLink.redeem_grant(nil)
      assert :error = BoardLink.redeem_grant("short")
      assert :error = BoardLink.redeem_grant(%{"grant" => "x"})
    end
  end
end
