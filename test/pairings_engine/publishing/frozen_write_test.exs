defmodule PairingsEngine.Publishing.FrozenWriteTest do
  @moduledoc """
  Publishing against a tournament that has gone read-only - archived, or
  handed off to another copy of the app.

  ## The partial write

  `rotate_address/1` is "delete the old copy, move to a new address,
  publish again", in that order, and the order is deliberate: the takedown
  is the part the arbiter actually asked for, so it goes first and a failure
  there changes nothing.

  The reasoning holds only while the steps after it cannot fail for reasons
  the first step could have known about. They can. `take_down/1` was
  ungated, `Tournaments.rotate_public_slug/1` is gated - so on a frozen
  tournament the sequence deleted the published copy from the server,
  cleared the key that was the only way to manage it, and THEN refused to
  move. Half the operation, the destructive half, with nothing to roll back
  to: the tournament is gone from the results site, the arbiter is told the
  move failed, and no retry can put it back at the old address because the
  key that authorised it has been thrown away.

  This predates the hand-off lock - archiving alone was enough - which is
  why the tests below run both reasons through the same paths.

  ## And the crash next door

  `writable/1`, the helper `adopt_claim/1` and `discard_claim/1` already
  use, only had a clause for `{:error, :archived}`. A handed-off tournament
  made it raise `CaseClauseError` rather than refuse.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp published_tournament do
    t =
      Repo.insert!(%Tournament{
        name: "Frozen Open",
        type: "swiss",
        rounds_count: 3,
        publish_to_openresults: true,
        public_slug: "frozen-#{System.unique_integer([:positive])}"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: name,
          fide_rating: rating,
          pairing_number: 2001 - rating
        })
      end

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    t = Tournaments.get_tournament!(t.id)
    stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
    assert {:ok, _} = Publishing.publish(t)

    Tournaments.get_tournament!(t.id)
  end

  defp freeze(%Tournament{} = t, :archived) do
    {:ok, frozen} = Tournaments.archive_tournament(t)
    frozen
  end

  defp freeze(%Tournament{} = t, :handed_off) do
    {:ok, frozen} = Tournaments.hand_off(t, "the club PC")
    frozen
  end

  defp watch_requests do
    test_pid = self()

    stub(fn conn ->
      send(test_pid, {:call, conn.method, conn.request_path})
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

  for reason <- [:archived, :handed_off] do
    describe "rotate_address/1 on a #{reason} tournament" do
      test "refuses, and leaves absolutely nothing changed" do
        published = published_tournament()
        frozen = freeze(published, unquote(reason))
        watch_requests()

        assert {:error, message} = Publishing.rotate_address(frozen)
        assert is_binary(message)

        # The half of the operation that cannot be undone. Nothing may have
        # been asked of the server at all: a DELETE that went out has already
        # destroyed the public page, every earlier snapshot in that
        # tournament's history, and any entries its form collected.
        refute_received {:call, "DELETE", _path}

        unchanged = Tournaments.get_tournament!(published.id)
        assert unchanged.public_slug == published.public_slug
        assert unchanged.publish_to_openresults
        assert unchanged.openresults_key == published.openresults_key
      end

      test "and work already queued is not silently dropped" do
        published = published_tournament()
        :ok = Publishing.enqueue(published)
        assert Publishing.queued(published.id)

        frozen = freeze(published, unquote(reason))
        watch_requests()

        assert {:error, _} = Publishing.rotate_address(frozen)

        # `forget_published/1` deletes this tournament's queue entries on its
        # way past. A refusal that had reached it would have thrown away a
        # snapshot the arbiter was already promised.
        assert Publishing.queued(published.id)
      end
    end

    describe "take_down/1 on a #{reason} tournament" do
      test "refuses in words, and sends nothing" do
        published = published_tournament()
        frozen = freeze(published, unquote(reason))
        watch_requests()

        assert {:error, message} = Publishing.take_down(frozen)
        assert is_binary(message)

        refute_received {:call, "DELETE", _path}
        assert Tournaments.get_tournament!(published.id).openresults_key
      end
    end

    describe "the imported-key branch on a #{reason} tournament" do
      test "adopt_claim/1 and discard_claim/1 refuse rather than raise" do
        published = published_tournament()

        {:ok, carrying} =
          published
          |> Ecto.Changeset.change(
            openresults_claim: %{
              "key" => "a-key-from-a-backup",
              "slug" => "somewhere-else",
              "endpoint" => "https://openresults.example"
            }
          )
          |> Repo.update()

        frozen = freeze(carrying, unquote(reason))

        assert {:error, adopt_message} = Publishing.adopt_claim(frozen)
        assert is_binary(adopt_message)

        assert {:error, discard_message} = Publishing.discard_claim(frozen)
        assert is_binary(discard_message)

        assert Tournaments.get_tournament!(published.id).openresults_claim
      end
    end
  end

  describe "an unpublished frozen tournament" do
    test "is refused in words rather than handing back a bare atom" do
      # `rotate_address/1`'s contract is `{:error, String.t()}` - the caller
      # renders it. This branch used to fall through to
      # `rotate_public_slug/1`'s `{:error, :archived}` and put an atom where
      # a sentence was expected.
      t =
        Repo.insert!(%Tournament{
          name: "Never Published",
          type: "swiss",
          rounds_count: 3,
          public_slug: "unpub-#{System.unique_integer([:positive])}"
        })

      {:ok, frozen} = Tournaments.hand_off(Tournaments.get_tournament!(t.id), "the club PC")

      assert {:error, message} = Publishing.rotate_address(frozen)
      assert is_binary(message)
      assert Tournaments.get_tournament!(t.id).public_slug == t.public_slug
    end
  end

  describe "once it is writable again" do
    test "the move goes through as it always did" do
      published = published_tournament()
      {:ok, handed} = Tournaments.hand_off(published, "the club PC")
      {:ok, back} = Tournaments.take_back(handed, handed.handoff_token)
      watch_requests()

      assert {:ok, moved, _message} = Publishing.rotate_address(back)

      assert_received {:call, "DELETE", _}
      refute moved.public_slug == published.public_slug
    end
  end
end
