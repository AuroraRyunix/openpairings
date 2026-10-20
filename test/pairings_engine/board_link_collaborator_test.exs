defmodule PairingsEngine.BoardLinkCollaboratorTest do
  @moduledoc """
  A tournament code borrows its maker's access, and stops working when the
  maker loses it - removed by the owner, or leaving - instead of leaving a
  box in the hall with write access nobody granted any more.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, Repo, Tournaments}
  alias PairingsEngine.BoardLink.Link
  alias PairingsEngine.Tournaments.Collaborator

  setup do
    owner = user_scope_fixture()
    %{tournament: t} = paired_tournament(owner)
    helper = user_scope_fixture()

    {:ok, invite} = Tournaments.add_collaborator(owner, t, helper.user.email)
    {:ok, _} = Tournaments.accept_invitation(helper, invite.invite_token)

    {:ok, link, secret} = BoardLink.create_link(helper, t)
    {:ok, owner: owner, helper: helper, tournament: t, link: link, secret: secret}
  end

  defp reaches?(secret, t) do
    {:ok, link} = BoardLink.authenticate(secret)
    Enum.any?(BoardLink.covered(link), &(&1.tournament.id == t.id))
  end

  test "a collaborator's code reaches the tournament while they are one", ctx do
    assert reaches?(ctx.secret, ctx.tournament)
  end

  test "losing access shuts the code even if the row survives", ctx do
    # The row left behind on purpose, as if the revocation had never run:
    # the per-request check is the lock, not the clean-up.
    Repo.delete_all(Collaborator)
    assert reaches?(ctx.secret, ctx.tournament) == false
    assert :error = BoardLink.fetch_covered(Repo.get!(Link, ctx.link.id), ctx.tournament.id)
  end

  test "removing the collaborator withdraws the codes they made", ctx do
    {:ok, owner_link, owner_secret} = BoardLink.create_link(ctx.owner, ctx.tournament)
    [row] = Tournaments.list_collaborators(ctx.tournament)

    assert {:ok, _} = Tournaments.remove_collaborator(ctx.owner, ctx.tournament, row.id)

    assert :error = BoardLink.authenticate(ctx.secret)
    assert Repo.get(Link, ctx.link.id) == nil

    # The owner's own code is nobody's business but the owner's.
    assert Repo.get(Link, owner_link.id)
    assert reaches?(owner_secret, ctx.tournament)
  end

  test "leaving takes the leaver's codes along", ctx do
    assert {:ok, _} = Tournaments.leave_tournament(ctx.helper, ctx.tournament)
    assert :error = BoardLink.authenticate(ctx.secret)
  end

  test "a code whose maker's account is gone reaches nothing", ctx do
    Repo.update_all(Link, set: [created_by_id: nil])
    assert reaches?(ctx.secret, ctx.tournament) == false
  end
end
