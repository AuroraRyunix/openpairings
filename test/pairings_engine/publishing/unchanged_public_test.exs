defmodule PairingsEngine.Publishing.UnchangedPublicTest do
  @moduledoc """
  The same refusal to send a document twice, for a desktop copy publishing
  under an installation key. The comparison is shared with operator mode;
  what is not shared is everything around it - registration, a minted slug,
  failures kept as data - and this is where a skip could hide in that.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PairingsEngine.{Publishing, Repo, Snapshot, Tournaments}
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Publishing.{Accepted, Installation, QueueEntry}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)
    Application.put_env(:pairings_engine, :local_mode, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end

      Accepted.forget_all()
    end)

    Publishing.put_endpoint(nil)
    Publishing.put_public_base(nil)
    Publishing.put_token(nil)
    Accepted.forget_all()

    Server.install(self())
    {:ok, info} = Installation.server_info()
    :ok = Installation.give_consent(info)
    {:ok, _id} = Installation.register()
    Server.requests()
    :ok
  end

  defp tournament do
    t =
      Repo.insert!(%Tournament{
        name: "Gent Spring Open",
        type: "swiss",
        rounds_count: 3,
        publish_to_openresults: true,
        public_slug: "placeholder#{System.unique_integer([:positive])}"
      })

    Repo.insert!(%Player{tournament_id: t.id, name: "A", fide_rating: 2000, pairing_number: 1})
    Tournaments.get_tournament!(t.id)
  end

  # Minted and accepted once, the queue empty, the requests so far forgotten.
  defp published do
    t = tournament()
    Publishing.enqueue(t)
    assert {1, 0} = Publishing.drain()
    Server.requests()
    Tournaments.get_tournament!(t.id)
  end

  defp rename!(t, name) do
    Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [name: name])
    Tournaments.broadcast_tournament_change(t.id, :settings)
  end

  defp make_due do
    Repo.update_all(QueueEntry,
      set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp snapshot_posts, do: Enum.count(Server.calls(), &(&1 == {"POST", "/api/snapshots"}))

  test "an identical document is not posted, and nothing is left pending" do
    t = published()

    Tournaments.broadcast_tournament_change(t.id, :players)
    assert %QueueEntry{} = Publishing.queued(t.id)

    assert {0, 0} = Publishing.drain()

    # Not a request of any kind: no publish, no mint, no look at the server.
    assert Server.calls() == []
    assert Publishing.pending_count() == 0

    assert %{step: :done, failure: nil} =
             Publishing.public_state(Tournaments.get_tournament!(t.id))
  end

  test "a changed document is posted" do
    t = published()

    rename!(t, "Gent Summer Open")
    assert {1, 0} = Publishing.drain()

    assert [{"POST", "/api/snapshots", _headers, body}] = Server.requests()
    assert Jason.decode!(body)["tournament"]["name"] == "Gent Summer Open"
  end

  test "an identical document is posted after a failure" do
    t = published()

    Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(503, "storage_low")})
    rename!(t, "Gent Summer Open")
    capture_log(fn -> assert {0, 1} = Publishing.drain() end)
    assert snapshot_posts() == 1

    # Back to the name the site accepted, on a site that works again.
    Server.install(self())
    rename!(t, "Gent Spring Open")
    make_due()
    assert {1, 0} = Publishing.drain()
    assert snapshot_posts() == 1
  end

  test "a tournament taken down and published again is posted, to its new address" do
    t = published()
    assert {:ok, _message} = Publishing.take_down(t)
    Server.requests()

    {:ok, _on} =
      Tournaments.set_publish_to_openresults(Tournaments.get_tournament!(t.id), true)

    assert {1, 0} = Publishing.drain()

    again = Tournaments.get_tournament!(t.id)
    refute again.public_slug == t.public_slug
    refute again.openresults_key == t.openresults_key
    assert {"POST", "/api/snapshots"} in Server.calls()
  end

  test "a minted address the site released is minted again and posted" do
    t = tournament()
    {:ok, minted} = Installation.mint(t)
    Server.requests()

    # Remembered as accepted, were that possible for a slug with no publish.
    minted = Publishing.ensure_key(minted)

    Accepted.record(
      minted.id,
      Snapshot.build(minted),
      Publishing.acceptance_binding(minted)
    )

    Accepted.forget(minted.id)
    Publishing.enqueue(minted)
    assert {1, 0} = Publishing.drain()
    assert {"POST", "/api/snapshots"} in Server.calls()
  end

  test "a key taken over from a backup is posted under, whatever was remembered" do
    t = tournament() |> Publishing.ensure_key()
    key = t.openresults_key

    # As though this copy had been accepted somewhere under its own key.
    Accepted.record(t.id, Snapshot.build(t), Publishing.acceptance_binding(t))
    assert Accepted.unchanged?(t.id, Snapshot.build(t), Publishing.acceptance_binding(t))

    claimed =
      t
      |> Ecto.Changeset.change(
        openresults_key: nil,
        openresults_claim: %{"key" => "tk", "slug" => "OtherInstall1", "endpoint" => ""}
      )
      |> Repo.update!()

    assert {:ok, adopted} = Publishing.adopt_claim(claimed)
    refute adopted.openresults_key == key

    assert {1, 0} = Publishing.drain()

    assert [{"POST", "/api/snapshots", headers, body}] = Server.requests()
    assert headers["x-openresults-key"] == "tk"
    assert Jason.decode!(body)["tournament"]["slug"] == "OtherInstall1"
  end

  test "a new installation key is a new credential, and the document goes out under it" do
    t = published()
    payload = Snapshot.build(t)
    binding = Publishing.acceptance_binding(t)
    assert Accepted.unchanged?(t.id, payload, binding)

    {endpoint, key, _credential, mode, version} = binding

    refute Accepted.unchanged?(
             t.id,
             payload,
             {endpoint, key, {:bearer, "orik_new"}, mode, version}
           )
  end
end
