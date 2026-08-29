defmodule PairingsEngine.RegistrationPollTest do
  @moduledoc """
  Fetching entries without being asked.

  Pulling was a button, which was fine while this app also served the form -
  the arbiter was in the app and the entries were on the same machine. The
  form moved to the results site, and a queue nobody is told about is a queue
  discovered on the morning of the tournament.

  The line this must not cross is accepting. Nothing here adds a player to
  anything: entries land in the review list and wait for a person.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Registrations, Repo, Tournaments}
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp tournament(attrs \\ []) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Poll Test",
          type: "swiss",
          rounds_count: 3,
          public_slug: "poll-#{System.unique_integer([:positive])}",
          publish_to_openresults: true,
          registration_open: true,
          openresults_key: "key-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  defp entries(names) do
    for {name, i} <- Enum.with_index(names) do
      %{
        "id" => "entry-#{name}-#{i}",
        "received_at" => "2026-08-29T09:00:00Z",
        "player" => %{"name" => name, "federation" => "BEL"}
      }
    end
  end

  defp serving(entries) do
    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      Req.Test.json(conn, %{"registrations" => entries})
    end)
  end

  describe "which tournaments get polled" do
    test "one that has published and is taking entries" do
      t = tournament()
      serving(entries(["De Vos, Ilse"]))

      assert {1, 1} = Registrations.poll()
      assert [%Registration{}] = Registrations.pending(t.id)
    end

    test "one switched off, because a copy is still out there taking entries" do
      # The switch says whether more will be SENT. The form on the server is
      # whatever the last snapshot said, so entries can still be arriving at
      # a tournament this machine has stopped publishing.
      t = tournament(publish_to_openresults: false)
      serving(entries(["Late, Entry"]))

      assert {1, 1} = Registrations.poll()
      assert length(Registrations.pending(t.id)) == 1
    end

    test "one whose form is closed, because the last few arrive before it shuts" do
      t = tournament(registration_open: false)
      serving(entries(["Just, Intime"]))

      assert {1, 1} = Registrations.poll()
      assert length(Registrations.pending(t.id)) == 1
    end

    test "not one that was never published" do
      _t = tournament(openresults_key: nil)

      # No key means nothing is out there under this tournament's name. There
      # is no queue to ask about, and asking would be this machine querying a
      # slug it does not own.
      assert {0, 0} = Registrations.poll()
    end

    test "not an archived one - that is the arbiter saying the event is done" do
      _t = tournament(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))

      # And it is what stops this polling every tournament ever run, forever.
      assert {0, 0} = Registrations.poll()
    end

    test "not a deleted one" do
      _t = tournament(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))

      assert {0, 0} = Registrations.poll()
    end
  end

  describe "what a poll does and does not do" do
    test "the same entry twice is stored once" do
      t = tournament()
      serving(entries(["De Vos, Ilse"]))

      assert {1, 1} = Registrations.poll()
      assert {1, 0} = Registrations.poll()

      assert length(Registrations.pending(t.id)) == 1
    end

    test "nobody is added to the tournament" do
      t = tournament()
      serving(entries(["De Vos, Ilse", "Peeters, Wouter"]))

      assert {1, 2} = Registrations.poll()

      # The line this feature must not cross. A web form is a paper form left
      # on a table: filling one in announces an intention, it does not enter
      # a tournament.
      assert Repo.all(from p in Player, where: p.tournament_id == ^t.id) == []
      assert Enum.all?(Registrations.pending(t.id), &(&1.status == "pending"))
    end

    test "a server that is down is skipped, not crashed over" do
      t = tournament()

      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      # A timer with nobody watching. There is nothing here worth taking a
      # supervision tree down for, and nothing an arbiter could do with the
      # news at 02:00 - it is tried again next tick.
      assert {0, 0} = Registrations.poll()
      assert Registrations.pending(t.id) == []
    end

    test "one unreachable tournament does not stop the others" do
      good = tournament()
      _other = tournament()

      # Both are asked; the stub answers every request the same way, so this
      # asserts the loop completes rather than short-circuiting on the first
      # result.
      serving(entries(["Shared, Entry"]))

      assert {2, 2} = Registrations.poll()
      assert length(Registrations.pending(good.id)) == 1
    end
  end

  describe "the timer process" do
    test "does nothing when no results site is configured" do
      _t = tournament()
      Publishing.put_endpoint(nil)

      # The common case - a laptop that has never been told about a results
      # site - must cost nothing at all, not even the query that would find
      # no tournaments.
      assert {0, 0} = PairingsEngine.Registrations.Poll.poll_now()
    end

    test "is in the supervision tree and started" do
      assert is_pid(Process.whereis(PairingsEngine.Registrations.Poll))
    end
  end
end
