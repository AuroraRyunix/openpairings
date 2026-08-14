defmodule PairingsEngine.ArchiveTest do
  @moduledoc """
  Archiving freezes a tournament read-only. The property worth guarding is
  the negative one: that every write path actually refuses, not just the
  ones whose buttons the UI happens to hide. A stale open tab, a queued
  LiveView event, or a direct context call from a script must all bounce.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Tournament, Round}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "archive#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Archive Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  defp archived(scope, attrs \\ %{}) do
    {:ok, t} = Tournaments.archive_tournament(tournament(scope, attrs))
    t
  end

  describe "archive_tournament/1 and unarchive_tournament/1" do
    test "archiving stamps archived_at; unarchiving clears it" do
      scope = user_scope()
      t = tournament(scope)
      refute Tournaments.archived?(t)

      {:ok, archived} = Tournaments.archive_tournament(t)
      assert archived.archived_at
      assert Tournaments.archived?(archived)

      {:ok, live_again} = Tournaments.unarchive_tournament(archived)
      refute live_again.archived_at
      refute Tournaments.archived?(live_again)
    end

    test "archiving broadcasts on the tournament topic so open pages flip live" do
      scope = user_scope()
      t = tournament(scope)
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

      {:ok, _} = Tournaments.archive_tournament(t)

      tid = t.id
      assert_receive {:tournament_changed, ^tid, :tournament}
    end

    test "an archived tournament drops out of the main list and into the archive list" do
      scope = user_scope()
      t = tournament(scope)

      assert Enum.any?(Tournaments.list_tournaments(scope), fn {lt, _, _} -> lt.id == t.id end)
      assert Tournaments.list_archived_tournaments(scope) == []

      {:ok, _} = Tournaments.archive_tournament(t)

      refute Enum.any?(Tournaments.list_tournaments(scope), fn {lt, _, _} -> lt.id == t.id end)
      assert [listed] = Tournaments.list_archived_tournaments(scope)
      assert listed.id == t.id
    end

    test "an archived tournament that is then binned leaves the archive list too" do
      scope = user_scope()
      t = archived(scope)

      {:ok, _} = Tournaments.soft_delete_tournament(t)

      assert Tournaments.list_archived_tournaments(scope) == []
    end

    test "archiving does NOT hide the tournament from its own pages or public pages" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, t} = Tournaments.set_public_pages(t, true)
      {:ok, _} = Tournaments.archive_tournament(t)

      # Still fetchable — archiving freezes writes, it doesn't hide anything.
      assert Tournaments.get_authorized_tournament!(scope, t.id)
      assert Tournaments.get_tournament_by_public_slug(t.public_slug)
    end
  end

  describe "ensure_writable/1" do
    test "accepts a live tournament, a live id, and nil" do
      scope = user_scope()
      t = tournament(scope)

      assert Tournaments.ensure_writable(t) == :ok
      assert Tournaments.ensure_writable(t.id) == :ok
      assert Tournaments.ensure_writable(nil) == :ok
    end

    test "refuses an archived tournament, by struct or by id" do
      scope = user_scope()
      t = archived(scope)

      assert Tournaments.ensure_writable(t) == {:error, :archived}
      assert Tournaments.ensure_writable(t.id) == {:error, :archived}
    end

    test "treats a non-existent id as writable (nothing to protect)" do
      assert Tournaments.ensure_writable(999_999) == :ok
    end
  end

  describe "writes are refused while archived" do
    test "update_tournament/2" do
      scope = user_scope()
      t = archived(scope)

      assert Tournaments.update_tournament(t, %{"name" => "Renamed"}) == {:error, :archived}
      assert Repo.reload!(t).name == "Archive Test"
    end

    test "create_player/2, update_player/2, delete_player/1" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, player} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, _} = Tournaments.archive_tournament(live)

      assert Tournaments.create_player(live.id, %{"name" => "Bob"}) == {:error, :archived}
      assert Tournaments.update_player(player, %{"name" => "Renamed"}) == {:error, :archived}
      assert Tournaments.delete_player(player) == {:error, :archived}

      assert Repo.reload!(player).name == "Alice"
      assert length(Tournaments.list_players(live.id)) == 1
    end

    test "bulk_update_players/2 (and therefore set_all_players_absent/2)" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, player} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, _} = Tournaments.archive_tournament(live)

      assert Tournaments.set_all_players_absent(live.id, true) == {:error, :archived}
      refute Repo.reload!(player).absent
    end

    test "update_pairing_result/2" do
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

      {:ok, _} = Tournaments.archive_tournament(live)

      assert Tournaments.update_pairing_result(pairing, "1-0") == {:error, :archived}
      assert Repo.reload!(pairing).result == ""
    end

    test "swap_players_in_round/3, vacate_seat/3 and swap_seated_with_pool_player/3" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, a} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(live.id, %{"name" => "Bob"})

      r = Repo.insert!(%Round{tournament_id: live.id, number: 1, status: "playing"})

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: r.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

      {:ok, _} = Tournaments.archive_tournament(live)
      round = Tournaments.get_round(live.id, 1)

      assert Tournaments.swap_players_in_round(round, a.id, b.id) == {:error, :archived}
      assert Tournaments.vacate_seat(round, a.id) == {:error, :archived}
      assert Tournaments.swap_seated_with_pool_player(round, a.id, b.id) == {:error, :archived}
    end

    test "set_pairing_hidden/3 and delete_pairing/2" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, a} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(live.id, %{"name" => "Bob"})

      r = Repo.insert!(%Round{tournament_id: live.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%PairingsEngine.Tournaments.Pairing{
          round_id: r.id,
          board: 1,
          white_player_id: a.id,
          black_player_id: b.id,
          result: ""
        })

      {:ok, _} = Tournaments.vacate_seat(Tournaments.get_round(live.id, 1), a.id)
      {:ok, _} = Tournaments.vacate_seat(Tournaments.get_round(live.id, 1), b.id)

      {:ok, _} = Tournaments.archive_tournament(live)
      round = Tournaments.get_round(live.id, 1)
      pairing = Enum.find(round.pairings, &(&1.id == pairing.id))

      assert Tournaments.set_pairing_hidden(round, pairing, true) == {:error, :archived}
      assert Tournaments.delete_pairing(round, pairing) == {:error, :archived}
      assert Repo.get(PairingsEngine.Tournaments.Pairing, pairing.id)
    end

    test "publish_round_now/1 and unpublish_round/1" do
      scope = user_scope()
      live = tournament(scope, %{"publish_mode" => "manual"})
      round = Repo.insert!(%Round{tournament_id: live.id, number: 1, published_at: nil})
      {:ok, _} = Tournaments.archive_tournament(live)

      assert Tournaments.publish_round_now(round) == {:error, :archived}
      assert Tournaments.unpublish_round(round) == {:error, :archived}
      refute Repo.reload!(round).published_at
    end

    test "the sharing controls (public pages, registration, slug rotation)" do
      scope = user_scope()
      t = archived(scope)
      slug = t.public_slug

      assert Tournaments.set_public_pages(t, true) == {:error, :archived}
      assert Tournaments.set_registration_open(t, true) == {:error, :archived}
      assert Tournaments.rotate_public_slug(t) == {:error, :archived}

      reloaded = Repo.reload!(t)
      refute reloaded.public_pages_enabled
      refute reloaded.registration_open
      assert reloaded.public_slug == slug
    end

    test "the logo setters" do
      scope = user_scope()
      t = archived(scope)
      png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0>>

      assert Tournaments.set_logo(t, png) == {:error, :archived}
      assert Tournaments.clear_logo(t) == {:error, :archived}
    end

    test "manual ranking (enable, disable, reseed, move)" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, player} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, _} = Tournaments.archive_tournament(live)
      t = Repo.reload!(live)

      assert Tournaments.enable_manual_ranking(t) == {:error, :archived}
      assert Tournaments.disable_manual_ranking(t) == {:error, :archived}
      assert Tournaments.reseed_manual_ranking(t) == {:error, :archived}
      assert Tournaments.move_manual_rank(t, player, :up) == {:error, :archived}

      refute Repo.reload!(t).manual_ranking
    end

    test "forbidden pairings (add and remove)" do
      scope = user_scope()
      live = tournament(scope)
      {:ok, a} = Tournaments.create_player(live.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(live.id, %{"name" => "Bob"})
      {:ok, fp} = Tournaments.add_forbidden_pairing(live, a.id, b.id)
      {:ok, _} = Tournaments.archive_tournament(live)
      t = Repo.reload!(live)

      assert Tournaments.add_forbidden_pairing(t, b.id, a.id) == {:error, :archived}
      assert Tournaments.remove_forbidden_pairing(t, fp.id) == {:error, :archived}
      assert length(Tournaments.list_forbidden_pairings(t.id)) == 1
    end

    test "extra-points bands and category auto-assign (via bulk_update_players)" do
      scope = user_scope()
      live = tournament(scope, %{"extra_points_bands" => "1400:1", "categories" => ["Open"]})
      {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Alice", "fide_rating" => "1200"})
      {:ok, _} = Tournaments.archive_tournament(live)
      t = Repo.reload!(live)

      assert Tournaments.apply_extra_points_bands(t) == {:error, :archived}
      assert Tournaments.auto_assign_categories(t) == {:error, :archived}
    end

    test "pairing a round, for every pairing system" do
      scope = user_scope()

      for system <- ~w(swiss round_robin keizer) do
        live = tournament(scope, %{"pairing_system" => system})

        {:ok, _} =
          Tournaments.create_player(live.id, %{"name" => "Alice", "fide_rating" => "2000"})

        {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Bob", "fide_rating" => "1900"})
        {:ok, archived_t} = Tournaments.archive_tournament(live)

        assert {:error, message} = Pairing.pair_next_round(archived_t)
        assert message =~ "archived"
        assert Pairing.paired_rounds_count(archived_t.id) == 0
      end
    end

    test "round robin's pair-the-whole-tournament action" do
      scope = user_scope()
      live = tournament(scope, %{"pairing_system" => "round_robin"})
      {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Alice", "fide_rating" => "2000"})
      {:ok, _} = Tournaments.create_player(live.id, %{"name" => "Bob", "fide_rating" => "1900"})
      {:ok, archived_t} = Tournaments.archive_tournament(live)

      assert {:error, message} = PairingsEngine.RoundRobin.pair_all_rounds(archived_t)
      assert message =~ "archived"
      assert Pairing.paired_rounds_count(archived_t.id) == 0
    end

    test "unpairing a round" do
      scope = user_scope()
      live = tournament(scope)
      Repo.insert!(%Round{tournament_id: live.id, number: 1, status: "playing"})
      {:ok, _} = Tournaments.archive_tournament(live)

      assert {:error, message} = Pairing.delete_round(live.id, 1)
      assert message =~ "archived"
      assert Pairing.paired_rounds_count(live.id) == 1
    end
  end

  describe "lifecycle actions that stay allowed while archived" do
    test "archiving does not block binning or restoring — a separate lifecycle" do
      scope = user_scope()
      t = archived(scope)

      assert {:ok, binned} = Tournaments.soft_delete_tournament(t)
      assert binned.deleted_at
      assert {:ok, restored} = Tournaments.restore_tournament(binned)
      refute restored.deleted_at
      # Still archived after coming back out of the bin.
      assert restored.archived_at
    end

    test "unarchiving is itself never blocked by the archive guard" do
      scope = user_scope()
      t = archived(scope)

      assert {:ok, live_again} = Tournaments.unarchive_tournament(t)
      refute live_again.archived_at

      # ...and writes work again immediately.
      assert {:ok, _} = Tournaments.update_tournament(live_again, %{"name" => "Renamed"})
    end
  end

  describe "archived_at is not reachable through the ordinary changeset" do
    test "a settings save can neither archive nor unarchive" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, updated} =
        Tournaments.update_tournament(t, %{
          "archived_at" => DateTime.utc_now(),
          "venue" => "Some Hall"
        })

      refute updated.archived_at
      assert updated.venue == "Some Hall"
    end

    test "an archived tournament cannot be unarchived by a smuggled changeset param" do
      scope = user_scope()
      t = archived(scope)

      # Refused outright by the guard — but even the attempt must not clear it.
      assert Tournaments.update_tournament(t, %{"archived_at" => nil}) == {:error, :archived}
      assert Repo.reload!(t).archived_at
    end
  end

  describe "Tournament.changeset/2 rejects nothing new" do
    test "archived_at is absent from the cast list, so it is silently ignored" do
      changeset = Tournament.changeset(%Tournament{}, %{"archived_at" => DateTime.utc_now()})
      refute Map.has_key?(changeset.changes, :archived_at)
    end
  end
end
