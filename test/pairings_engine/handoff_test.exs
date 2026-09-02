defmodule PairingsEngine.HandoffTest do
  @moduledoc """
  The hand-off lock: a tournament is live in exactly one place at a time.

  The property worth guarding is the same negative one archiving's suite
  guards, for a much worse failure. An archived tournament that accepted a
  write loses an arbiter's intent; a handed-off tournament that accepted a
  write produces two divergent copies of a live event, and there is no merge
  that reconciles them afterwards - one machine's board 4 says 1-0 and the
  other says draw, and no rule picks a winner because the disagreement is
  about what happened in a room.

  So: the columns actually round-trip, `ensure_writable/1` refuses, a real
  write path refuses, and the lock cannot be handed off twice or opened with
  the wrong key.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Tournament, Round}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "handoff#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Handoff Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  defp handed_off(scope, label \\ "this laptop") do
    {:ok, t} = Tournaments.hand_off(tournament(scope), label)
    t
  end

  describe "the columns themselves" do
    test "a fresh tournament is live here: all three are nil" do
      t = tournament(user_scope())

      assert t.handed_off_at == nil
      assert t.handed_off_to == nil
      assert t.handoff_token == nil
      refute Tournaments.handed_off?(t)
    end

    test "the migration round-trips: all three survive a write and a reload" do
      # Not a formality. `handed_off_at` is `:utc_datetime`, which SQLite
      # stores as text - a column added with the wrong type reads back as a
      # string, and every comparison against it silently stops working.
      t = tournament(user_scope())
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        t
        |> Ecto.Changeset.change(
          handed_off_at: at,
          handed_off_to: "arbiter's laptop",
          handoff_token: "a-token"
        )
        |> Repo.update()

      reloaded = Repo.reload!(t)

      assert %DateTime{} = reloaded.handed_off_at
      assert DateTime.compare(reloaded.handed_off_at, at) == :eq
      assert reloaded.handed_off_to == "arbiter's laptop"
      assert reloaded.handoff_token == "a-token"
      assert Tournaments.handed_off?(reloaded)
    end
  end

  describe "hand_off/2" do
    test "stamps the time, records the destination, and mints a token" do
      scope = user_scope()
      t = tournament(scope)

      assert {:ok, handed} = Tournaments.hand_off(t, "this laptop")
      assert %DateTime{} = handed.handed_off_at
      assert handed.handed_off_to == "this laptop"
      assert is_binary(handed.handoff_token)
      assert Tournaments.handed_off?(handed)

      # A guessable token is not a lock. 32 bytes url-safe base64 is 43 chars.
      assert String.length(handed.handoff_token) >= 32
    end

    test "trims the label an arbiter typed" do
      scope = user_scope()

      assert {:ok, handed} = Tournaments.hand_off(tournament(scope), "  the club PC \n")
      assert handed.handed_off_to == "the club PC"
    end

    test "every hand-off mints a fresh token" do
      scope = user_scope()

      first = handed_off(scope)
      {:ok, _} = Tournaments.take_back(first, first.handoff_token)
      {:ok, second} = Tournaments.hand_off(Repo.reload!(first), "somewhere else")

      refute second.handoff_token == first.handoff_token
    end

    test "a tournament that is already handed off cannot be handed off again" do
      # The whole lock. A second hand-off would mint a second token and orphan
      # the first, leaving the copy that actually HAS the tournament unable to
      # give it back.
      scope = user_scope()
      t = handed_off(scope, "laptop A")

      assert Tournaments.hand_off(t, "laptop B") == {:error, :already_handed_off}

      reloaded = Repo.reload!(t)
      assert reloaded.handed_off_to == "laptop A"
      assert reloaded.handoff_token == t.handoff_token
    end

    test "a stale struct cannot hand off a tournament that was handed off underneath it" do
      # The `cond` on the struct is a check; the `is_nil(handed_off_at)` in
      # the UPDATE's WHERE is the lock. This is the difference: `stale` still
      # believes the tournament is live.
      scope = user_scope()
      stale = tournament(scope)

      {:ok, _} = Tournaments.hand_off(stale, "laptop A")

      assert Tournaments.hand_off(stale, "laptop B") == {:error, :already_handed_off}
      assert Repo.reload!(stale).handed_off_to == "laptop A"
    end

    test "an archived tournament cannot be handed off" do
      scope = user_scope()
      {:ok, t} = Tournaments.archive_tournament(tournament(scope))

      assert Tournaments.hand_off(t, "this laptop") == {:error, :archived}
      refute Repo.reload!(t).handed_off_at
    end

    test "broadcasts on the tournament topic so open pages flip to read-only live" do
      scope = user_scope()
      t = tournament(scope)
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

      {:ok, _} = Tournaments.hand_off(t, "this laptop")

      tid = t.id
      assert_receive {:tournament_changed, ^tid, :tournament}
    end

    test "broadcasts on the owner's tournament-list topic too" do
      scope = user_scope()
      t = tournament(scope)

      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(scope.user.id)
      )

      {:ok, _} = Tournaments.hand_off(t, "this laptop")

      uid = scope.user.id
      assert_receive {:tournaments_changed, ^uid}
    end
  end

  describe "take_back/2" do
    test "the right token clears all three columns and writes work again" do
      scope = user_scope()
      t = handed_off(scope)

      assert {:ok, back} = Tournaments.take_back(t, t.handoff_token)
      assert back.handed_off_at == nil
      assert back.handed_off_to == nil
      assert back.handoff_token == nil
      refute Tournaments.handed_off?(back)

      assert {:ok, _} = Tournaments.update_tournament(back, %{"name" => "Renamed"})
    end

    test "a wrong token is refused and changes nothing" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.take_back(t, "not-the-token") == {:error, :bad_token}

      reloaded = Repo.reload!(t)
      assert reloaded.handed_off_at
      assert reloaded.handoff_token == t.handoff_token
    end

    test "a token that is a prefix of the real one is refused" do
      # `Plug.Crypto.secure_compare/2` compares lengths first; this is the
      # case a naive `String.starts_with?` would let through.
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.take_back(t, String.slice(t.handoff_token, 0..10)) ==
               {:error, :bad_token}

      assert Repo.reload!(t).handed_off_at
    end

    test "an empty token is refused rather than treated as 'no token needed'" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.take_back(t, "") == {:error, :bad_token}
      assert Repo.reload!(t).handed_off_at
    end

    test "a tournament that is not handed off cannot be 'taken back' by any token" do
      scope = user_scope()
      t = tournament(scope)

      assert Tournaments.take_back(t, "anything") == {:error, :bad_token}
      assert Tournaments.take_back(t, nil) == {:error, :bad_token}
    end

    test "taking back twice fails - the token it compares against is gone" do
      # Documented, not accidental: see `take_back/2`'s doc. A returning
      # payload that is applied twice must not silently succeed the second
      # time, because by then the tournament may have been handed off
      # somewhere else entirely.
      scope = user_scope()
      t = handed_off(scope)

      assert {:ok, _} = Tournaments.take_back(t, t.handoff_token)
      assert Tournaments.take_back(Repo.reload!(t), t.handoff_token) == {:error, :bad_token}
    end

    test "broadcasts the same as hand_off/2" do
      scope = user_scope()
      t = handed_off(scope)
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

      {:ok, _} = Tournaments.take_back(t, t.handoff_token)

      tid = t.id
      assert_receive {:tournament_changed, ^tid, :tournament}
    end
  end

  describe "ensure_writable/1" do
    test "refuses a handed-off tournament, by struct or by id" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.ensure_writable(t) == {:error, :handed_off}
      assert Tournaments.ensure_writable(t.id) == {:error, :handed_off}
    end

    test "reports archiving first when a tournament is somehow both" do
      scope = user_scope()
      t = handed_off(scope)
      {:ok, both} = Tournaments.archive_tournament(t)

      assert Tournaments.ensure_writable(both) == {:error, :archived}
      assert Tournaments.ensure_writable(both.id) == {:error, :archived}
    end

    test "still accepts a live tournament, a live id, nil, and a missing id" do
      # The id clause grew a second column; a live row and a row that does not
      # exist both used to arrive here as a bare `nil`.
      scope = user_scope()
      t = tournament(scope)

      assert Tournaments.ensure_writable(t) == :ok
      assert Tournaments.ensure_writable(t.id) == :ok
      assert Tournaments.ensure_writable(nil) == :ok
      assert Tournaments.ensure_writable(999_999) == :ok
    end
  end

  describe "writes are refused while handed off" do
    test "create_player/2 - a representative write straight through the gate" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, _} = Tournaments.hand_off(live, "this laptop")

      assert Tournaments.create_player(live.id, %{"name" => "Bob"}) == {:error, :handed_off}
      assert length(Tournaments.list_players(live.id)) == 1
    end

    test "update_tournament/2" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.update_tournament(t, %{"name" => "Renamed"}) == {:error, :handed_off}
      assert Repo.reload!(t).name == "Handoff Test"
    end

    test "update_pairing_result/2 - the write that would actually diverge" do
      # The concrete disaster the lock exists to prevent: this copy records a
      # draw on board 1 while the copy holding the tournament records 1-0.
      scope = user_scope()
      live = tournament(scope)
      {:ok, a} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(live.id, %{"name" => "Bob"})

      round = Repo.insert!(%Round{tournament_id: live.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%PairingsEngine.Tournaments.Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: a.id,
          black_player_id: b.id,
          result: ""
        })

      {:ok, _} = Tournaments.hand_off(live, "this laptop")

      assert Tournaments.update_pairing_result(pairing, "1/2-1/2") == {:error, :handed_off}
      assert Repo.reload!(pairing).result == ""
    end

    test "pairing a round - the other way two copies diverge" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Alice", "fide_rating" => "2000"})
      {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Bob", "fide_rating" => "1900"})
      {:ok, handed} = Tournaments.hand_off(live, "this laptop")

      assert {:error, _message} = Pairing.pair_next_round(handed)
      assert Pairing.paired_rounds_count(handed.id) == 0
    end

    test "the sharing controls" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.set_publish_to_openresults(t, true) == {:error, :handed_off}
      assert Tournaments.set_registration_open(t, true) == {:error, :handed_off}
      assert Tournaments.rotate_public_slug(t) == {:error, :handed_off}
    end

    test "writes work again the moment it comes back" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.create_player(t.id, %{"name" => "Alice"}) == {:error, :handed_off}
      {:ok, back} = Tournaments.take_back(t, t.handoff_token)
      assert {:ok, _} = Tournaments.create_player(back.id, %{"name" => "Alice"})
    end
  end

  describe "a handed-off tournament stays readable" do
    test "it is still fetchable, still listed, and still marked to publish" do
      # Handing off freezes writes; it does not hide anything. The copy left
      # behind is the record of an event that is still running elsewhere.
      scope = user_scope()
      t = tournament(scope)
      {:ok, t} = Tournaments.set_publish_to_openresults(t, true)
      {:ok, t} = Tournaments.hand_off(t, "this laptop")

      assert Tournaments.get_authorized_tournament!(scope, t.id)
      assert Enum.any?(Tournaments.list_tournaments(scope), fn {lt, _, _} -> lt.id == t.id end)
      assert Repo.reload!(t).publish_to_openresults
    end
  end

  describe "the hand-off columns are not reachable through the ordinary changeset" do
    test "none of the three is in the cast list" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "handed_off_at" => DateTime.utc_now(),
          "handed_off_to" => "somewhere",
          "handoff_token" => "smuggled"
        })

      refute Map.has_key?(changeset.changes, :handed_off_at)
      refute Map.has_key?(changeset.changes, :handed_off_to)
      refute Map.has_key?(changeset.changes, :handoff_token)
    end

    test "a settings save can neither hand off nor unlock" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, updated} =
        Tournaments.update_tournament(t, %{
          "handed_off_at" => DateTime.utc_now(),
          "handoff_token" => "smuggled",
          "venue" => "Some Hall"
        })

      refute updated.handed_off_at
      assert updated.venue == "Some Hall"
    end

    test "a handed-off tournament cannot be unlocked by a smuggled changeset param" do
      # Refused by the gate before the changeset is even built - but the
      # attempt must not clear the lock even if a future path skipped it.
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.update_tournament(t, %{"handed_off_at" => nil, "handoff_token" => nil}) ==
               {:error, :handed_off}

      reloaded = Repo.reload!(t)
      assert reloaded.handed_off_at
      assert reloaded.handoff_token == t.handoff_token
    end
  end

  describe "lifecycle actions that stay allowed while handed off" do
    test "taking it back is itself never blocked by the gate" do
      scope = user_scope()
      t = handed_off(scope)

      assert {:ok, back} = Tournaments.take_back(t, t.handoff_token)
      refute back.handed_off_at
    end

    test "binning and restoring are a separate lifecycle" do
      scope = user_scope()
      t = handed_off(scope)

      assert {:ok, binned} = Tournaments.soft_delete_tournament(t)
      assert {:ok, restored} = Tournaments.restore_tournament(binned)
      # Still handed off after coming back out of the bin.
      assert restored.handed_off_at
    end
  end
end
