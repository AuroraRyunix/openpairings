defmodule PairingsEngine.TournamentGroupsPublishingTest do
  @moduledoc """
  A tournament group on the results site: the `group` block a member's
  snapshot carries, who may be named in it, and who is sent again when that
  changes.

  The rule under test is one sentence - a snapshot names only siblings that
  are themselves on the results site - and most of this file is the ways a
  sibling stops being one.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Publishing, Repo, Snapshot, TournamentGroups, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Publishing.QueueEntry
  alias PairingsEngine.TournamentGroups.Group
  alias PairingsEngine.Tournaments.Tournament

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")

    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    scope = Scope.for_user(user)

    open = tournament(scope, "Spring Open")
    u20 = tournament(scope, "Spring U20")
    u12 = tournament(scope, "Spring U12 - working title")

    {:ok, group} = TournamentGroups.create_group(scope, open, "Spring Festival")
    {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
    {:ok, _} = TournamentGroups.join_group(scope, u12, group.id)
    {:ok, _} = TournamentGroups.set_label(scope, open, "Open")
    {:ok, _} = TournamentGroups.set_label(scope, u20, "U20")
    {:ok, _} = TournamentGroups.set_label(scope, u12, "Secret-U12")

    %{scope: scope, open: open, u20: u20, u12: u12, group: Repo.get!(Group, group.id)}
  end

  defp tournament(scope, name) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "rounds_count" => "5"
      })

    t
  end

  defp reload(%Tournament{id: id}), do: Tournaments.get_tournament!(id)

  # Publishing on, and a copy on the results site: what a successful first
  # publish leaves behind, without the network.
  defp on_site!(%Tournament{} = t, opts \\ []) do
    Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
      set: [
        publish_to_openresults: true,
        openresults_key: Publishing.generate_key(),
        public_listed: Keyword.get(opts, :listed, true)
      ]
    )

    reload(t)
  end

  defp block(t), do: Snapshot.build(reload(t))["tournament"]["group"]
  defp sibling_labels(t), do: Enum.map(block(t)["siblings"], & &1["label"])

  defp queued_ids,
    do: Repo.all(from q in QueueEntry, select: q.tournament_id) |> Enum.sort()

  defp clear_queue, do: Repo.delete_all(QueueEntry)

  # Every publish succeeds, and what was sent is kept per slug.
  defp accept_publishes do
    test = self()

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:published, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

  # Sends everything queued, and everything that queues as a result.
  defp drain_all(rounds \\ 6) do
    Repo.update_all(QueueEntry, set: [next_attempt_at: ~U[2020-01-01 00:00:00Z]])
    Publishing.drain()
    if rounds > 0 and queued_ids() != [], do: drain_all(rounds - 1), else: :ok
  end

  defp last_sent(slug) do
    receive_all()
    |> Enum.filter(&(&1["tournament"]["slug"] == slug))
    |> List.last()
  end

  defp receive_all(acc \\ []) do
    receive do
      {:published, payload} -> receive_all([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the block" do
    test "a group gets a random public id, and keeps it", %{
      group: group,
      scope: scope,
      open: open
    } do
      assert group.public_slug =~ ~r/^[0-9a-f]{18}$/
      refute group.public_slug == to_string(group.id)

      {:ok, renamed} = TournamentGroups.rename_group(scope, open, "Spring Festival 2027")
      assert renamed.public_slug == group.public_slug
    end

    test "names the published siblings, in order, with self placed among them", ctx do
      %{open: open, u20: u20, u12: u12, group: group} = ctx
      open = on_site!(open)
      u20 = on_site!(u20)
      u12 = on_site!(u12)

      assert block(u20) == %{
               "id" => group.public_slug,
               "name" => "Spring Festival",
               "label" => "U20",
               "position" => 2,
               "siblings" => [
                 %{"slug" => open.public_slug, "label" => "Open", "name" => "Spring Open"},
                 %{
                   "slug" => u12.public_slug,
                   "label" => "Secret-U12",
                   "name" => "Spring U12 - working title"
                 }
               ]
             }

      assert block(open)["position"] == 1
      assert block(u12)["position"] == 3
      _ = u20
    end

    test "a label left empty is the tournament's name", %{scope: scope, open: open, u20: u20} do
      on_site!(open)
      on_site!(u20)
      {:ok, _} = TournamentGroups.set_label(scope, u20, "")

      assert sibling_labels(open) == ["Spring U20"]
      assert block(u20)["label"] == "Spring U20"
    end

    test "a tournament in no group carries no block", %{scope: scope} do
      alone = scope |> tournament("Alone") |> on_site!()
      refute Map.has_key?(Snapshot.build(alone)["tournament"], "group")
    end
  end

  describe "nobody unpublished is named" do
    test "not its name, not its label, not a gap where it would be", ctx do
      %{open: open, u20: u20, u12: u12} = ctx
      # The U20 sits between the two in the stored order, and is not published.
      open = on_site!(open)
      u12 = on_site!(u12)

      snapshot = Snapshot.build(reload(open))

      assert snapshot["tournament"]["group"]["siblings"] == [
               %{
                 "slug" => u12.public_slug,
                 "label" => "Secret-U12",
                 "name" => "Spring U12 - working title"
               }
             ]

      # Positions count the named, so the hole does not show.
      assert block(open)["position"] == 1
      assert block(u12)["position"] == 2

      json = Jason.encode!(snapshot)
      refute json =~ "U20"
      refute json =~ u20.public_slug
    end

    test "a tournament with no published sibling carries no block at all", ctx do
      %{open: open, u20: u20, u12: u12} = ctx
      open = on_site!(open)

      snapshot = Snapshot.build(open)
      refute Map.has_key?(snapshot["tournament"], "group")

      json = Jason.encode!(snapshot)

      for secret <- [
            "Spring Festival",
            "U20",
            "Secret-U12",
            "working title",
            u20.public_slug,
            u12.public_slug
          ] do
        refute json =~ secret
      end
    end

    test "set to publish but never sent is not on the site yet", %{open: open, u20: u20} do
      on_site!(open)

      Repo.update_all(from(t in Tournament, where: t.id == ^u20.id),
        set: [publish_to_openresults: true]
      )

      assert block(open) == nil
    end

    test "publishing switched off, the recycle bin and a hand-off each take a sibling out", ctx do
      %{open: open, u20: u20} = ctx
      on_site!(open)
      u20 = on_site!(u20)
      assert sibling_labels(open) == ["U20"]

      {:ok, off} = Tournaments.set_publish_to_openresults(u20, false)
      assert block(open) == nil

      {:ok, on} = Tournaments.set_publish_to_openresults(off, true)
      assert sibling_labels(open) == ["U20"]

      {:ok, binned} = Tournaments.soft_delete_tournament(on)
      assert block(open) == nil

      {:ok, restored} = Tournaments.restore_tournament(binned)
      assert sibling_labels(open) == ["U20"]

      Repo.update_all(from(t in Tournament, where: t.id == ^restored.id),
        set: [handed_off_at: ~U[2026-10-10 10:00:00Z]]
      )

      assert block(open) == nil
    end

    test "a link-only sibling is not named on a listed page, only on other link-only ones", ctx do
      %{open: open, u20: u20, u12: u12} = ctx
      on_site!(open, listed: true)
      on_site!(u20, listed: false)
      on_site!(u12, listed: false)

      # The listed Open is alone as far as the world can tell.
      assert block(open) == nil
      # The two link-only sections know each other, and may name the Open.
      assert sibling_labels(u20) == ["Open", "Secret-U12"]
      assert sibling_labels(u12) == ["Open", "U20"]
    end
  end

  describe "who is sent again" do
    test "publish A and B, unpublish B: A's next snapshot no longer lists B", ctx do
      %{open: open, u20: u20} = ctx
      accept_publishes()

      {:ok, open} = Tournaments.set_publish_to_openresults(open, true)
      {:ok, u20} = Tournaments.set_publish_to_openresults(u20, true)
      drain_all()

      # Both landed, and each was sent again once the other was there.
      sent = receive_all()

      last = fn slug ->
        sent |> Enum.filter(&(&1["tournament"]["slug"] == slug)) |> List.last()
      end

      assert [%{"label" => "U20", "slug" => slug}] =
               last.(open.public_slug)["tournament"]["group"]["siblings"]

      assert slug == u20.public_slug
      assert [%{"label" => "Open"}] = last.(u20.public_slug)["tournament"]["group"]["siblings"]
      assert queued_ids() == []

      # B is unpublished: nothing an arbiter did to A, and A is queued.
      {:ok, _} = Tournaments.set_publish_to_openresults(reload(u20), false)
      assert open.id in queued_ids()

      drain_all()
      after_unpublish = last_sent(open.public_slug)

      refute Map.has_key?(after_unpublish["tournament"], "group")
      json = Jason.encode!(after_unpublish)
      refute json =~ "U20"
      refute json =~ u20.public_slug
      refute json =~ "Spring Festival"
    end

    test "a takedown of B re-sends A without it", %{open: open, u20: u20} do
      test = self()

      Req.Test.stub(PairingsEngine.PublishingTest, fn
        %Plug.Conn{method: "DELETE"} = conn ->
          Req.Test.json(conn, %{"ok" => true})

        conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:published, Jason.decode!(body)})
          Req.Test.json(conn, %{"ok" => true})
      end)

      {:ok, open} = Tournaments.set_publish_to_openresults(open, true)
      {:ok, u20} = Tournaments.set_publish_to_openresults(u20, true)
      drain_all()
      receive_all()

      assert {:ok, _} = Publishing.take_down(reload(u20))
      assert open.id in queued_ids()

      drain_all()
      refute Map.has_key?(last_sent(open.public_slug)["tournament"], "group")
      assert reload(u20).openresults_group_sent == nil
    end

    test "a rename, a label, the order and the group's name each queue the siblings", ctx do
      %{scope: scope, open: open, u20: u20} = ctx
      accept_publishes()

      {:ok, open} = Tournaments.set_publish_to_openresults(open, true)
      {:ok, u20} = Tournaments.set_publish_to_openresults(u20, true)
      drain_all()
      assert queued_ids() == []

      {:ok, _} = Tournaments.update_tournament(reload(u20), %{"name" => "Spring Under 20"})
      assert open.id in queued_ids()
      drain_all()

      {:ok, _} = TournamentGroups.set_label(scope, reload(u20), "Juniors")
      assert Enum.sort([open.id, u20.id]) == queued_ids()
      drain_all()

      {:ok, _} = TournamentGroups.move(scope, reload(open), u20.id, :up)
      assert Enum.sort([open.id, u20.id]) == queued_ids()
      drain_all()

      {:ok, _} = TournamentGroups.rename_group(scope, reload(open), "Spring Festival 2026")
      assert Enum.sort([open.id, u20.id]) == queued_ids()
      drain_all()

      block = last_sent(open.public_slug)["tournament"]["group"]
      assert block["name"] == "Spring Festival 2026"
      assert block["position"] == 2

      assert block["siblings"] == [
               %{"slug" => u20.public_slug, "label" => "Juniors", "name" => "Spring Under 20"}
             ]
    end

    test "leaving the group re-sends the leaver and the ones left behind", ctx do
      %{scope: scope, open: open, u20: u20, u12: u12} = ctx
      accept_publishes()

      for t <- [open, u20, u12], do: {:ok, _} = Tournaments.set_publish_to_openresults(t, true)
      drain_all()
      receive_all()
      assert queued_ids() == []

      {:ok, _} = TournamentGroups.leave_group(scope, reload(u12))
      assert queued_ids() == Enum.sort([open.id, u20.id, u12.id])

      drain_all()
      sent = receive_all()

      last = fn slug ->
        sent |> Enum.filter(&(&1["tournament"]["slug"] == slug)) |> List.last()
      end

      refute Map.has_key?(last.(u12.public_slug)["tournament"], "group")
      assert [%{"label" => "U20"}] = last.(open.public_slug)["tournament"]["group"]["siblings"]
    end

    test "a result in one section does not re-send the others", ctx do
      %{open: open, u20: u20} = ctx
      accept_publishes()

      {:ok, open} = Tournaments.set_publish_to_openresults(open, true)
      {:ok, u20} = Tournaments.set_publish_to_openresults(u20, true)
      drain_all()
      clear_queue()

      # The funnel every write goes through, with a hint that changes nothing
      # a sibling's page says.
      Tournaments.broadcast_tournament_change(open.id, :results)

      assert queued_ids() == [open.id]
      _ = u20
    end

    test "a tournament in no group costs nothing and queues nothing extra", %{scope: scope} do
      accept_publishes()
      alone = tournament(scope, "Alone")
      {:ok, alone} = Tournaments.set_publish_to_openresults(alone, true)
      drain_all()

      assert queued_ids() == []
      assert reload(alone).openresults_group_sent == nil
      assert TournamentGroups.sync_published(alone.id) == :ok
      assert queued_ids() == []
    end
  end

  describe "the event link" do
    test "exists only while this tournament's page is part of an event", ctx do
      %{open: open, u20: u20} = ctx
      open = on_site!(open)
      assert PairingsEngineWeb.PublicLink.event_url(open) == nil

      on_site!(u20)
      url = PairingsEngineWeb.PublicLink.event_url(reload(open))
      assert url == "https://openresults.example/e/" <> ctx.group.public_slug
    end
  end
end
