defmodule PairingsEngine.RegistrationsFrozenTest do
  @moduledoc """
  What the entries queue says when the tournament has gone read-only.

  `ensure_available/1` asked `ensure_writable/1` whether the tournament was
  writable and then answered "this tournament is archived" whatever it had
  said. That was true while archiving was the only way to lose write access.
  Once hand-off was a second one it became a plain untruth on screen, and a
  costly one: an arbiter told a tournament is archived goes looking for the
  Unarchive button, finds nothing to press, and the real answer - the
  tournament is checked out to a laptop at the venue - is nowhere on the
  page.

  A refusal has two jobs: name the state, and name the way out of it.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Registrations, Repo, Tournaments}
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.Tournament

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp tournament do
    Repo.insert!(%Tournament{
      name: "Gent Spring Open",
      type: "swiss",
      rounds_count: 5,
      publish_to_openresults: true,
      public_slug: "gent-#{System.unique_integer([:positive])}"
    })
  end

  defp pending_entry(tournament) do
    Repo.insert!(%Registration{
      tournament_id: tournament.id,
      external_key: "r-#{System.unique_integer([:positive])}",
      status: "pending",
      received_at: DateTime.utc_now(),
      payload: %{"player" => %{"name" => "De Vos, Ilse"}}
    })
  end

  defp handed_off(t), do: elem(Tournaments.hand_off(t, "the club PC"), 1)

  defp archived(t), do: elem(Tournaments.archive_tournament(t), 1)

  describe "a handed-off tournament" do
    test "pulling names the real state and the way out of it" do
      t = handed_off(tournament())
      stub(fn _conn -> flunk("nothing should have been fetched") end)

      assert {:error, message} = Registrations.pull(t)

      refute message =~ "archived"
      assert message =~ "handed off"
      assert message =~ "take it back"
    end

    test "accepting an entry says the same thing" do
      t = tournament()
      entry = pending_entry(t)
      _ = handed_off(t)

      assert {:error, message} = Registrations.accept(entry)

      refute message =~ "archived"
      assert message =~ "handed off"
      assert message =~ "take it back"

      # And no player was created behind the refusal.
      assert Tournaments.list_players(t.id) == []
    end

    test "discarding one says the same thing" do
      t = tournament()
      entry = pending_entry(t)
      _ = handed_off(t)

      assert {:error, message} = Registrations.discard(entry)
      assert message =~ "handed off"
      assert Repo.reload!(entry).status == "pending"
    end
  end

  describe "an archived tournament" do
    test "still says archived, and now says what to do about it" do
      t = archived(tournament())
      stub(fn _conn -> flunk("nothing should have been fetched") end)

      assert {:error, message} = Registrations.pull(t)

      assert message =~ "archived"
      assert message =~ "unarchive"
    end

    test "accepting an entry says it too" do
      t = tournament()
      entry = pending_entry(t)
      _ = archived(t)

      assert {:error, message} = Registrations.accept(entry)
      assert message =~ "archived"
      assert message =~ "unarchive"
    end
  end
end
