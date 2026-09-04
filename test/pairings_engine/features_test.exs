defmodule PairingsEngine.FeaturesTest do
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Features

  describe "the catalogue" do
    test "every entry names a federation that ships a pack" do
      codes = MapSet.new(Features.federations(), & &1.code)

      for feature <- Features.catalogue() do
        assert feature.federation in codes,
               "#{feature.key} belongs to #{feature.federation}, which is not in federations/0"
      end
    end

    test "keys are unique and match the catalogue's order" do
      keys = Features.keys()

      assert keys == Enum.map(Features.catalogue(), & &1.key)
      assert keys == Enum.uniq(keys)
    end

    test "the six Belgian switches are all there" do
      assert Features.catalogue_for("BEL") |> Enum.map(& &1.key) == [
               "bel_ratings_sync",
               "bel_player_lookup",
               "bel_club_sync",
               "bel_swar_import",
               "bel_swar_export",
               "bel_swar_publish"
             ]
    end

    test "every entry has a label and a description an arbiter can read" do
      for feature <- Features.catalogue() do
        assert is_binary(feature.label) and feature.label != ""
        assert is_binary(feature.description) and feature.description != ""
      end
    end
  end

  describe "enabled?/2" do
    test "a new account has nothing switched on" do
      user = user_fixture()

      for key <- Features.keys() do
        refute Features.enabled?(user, key)
      end

      assert Features.enabled(user) == []
    end

    test "takes a user or a scope" do
      user = user_fixture()
      {:ok, user} = Features.set_enabled(user, ["bel_swar_import"])

      assert Features.enabled?(user, "bel_swar_import")
      assert Features.enabled?(Scope.for_user(user), "bel_swar_import")
      refute Features.enabled?(user, "bel_swar_export")
      refute Features.enabled?(Scope.for_user(user), "bel_swar_export")
    end

    test "no user means no features" do
      refute Features.enabled?(nil, "bel_swar_import")
      refute Features.enabled?(%Scope{user: nil}, "bel_swar_import")
    end

    test "a key this version does not know is off, not an error" do
      user = user_fixture()
      refute Features.enabled?(user, "ned_ratings_sync")
    end
  end

  describe "set_enabled/2" do
    test "replaces the whole set rather than merging" do
      user = user_fixture()

      {:ok, user} = Features.set_enabled(user, ["bel_ratings_sync", "bel_player_lookup"])
      assert Features.enabled(user) == ["bel_ratings_sync", "bel_player_lookup"]

      {:ok, user} = Features.set_enabled(user, ["bel_swar_export"])
      assert Features.enabled(user) == ["bel_swar_export"]

      {:ok, user} = Features.set_enabled(user, [])
      assert Features.enabled(user) == []
    end

    test "stores keys in catalogue order however they arrive, and de-duplicates" do
      user = user_fixture()

      {:ok, user} =
        Features.set_enabled(user, [
          "bel_swar_export",
          "bel_ratings_sync",
          "bel_swar_export"
        ])

      assert user.features == ["bel_ratings_sync", "bel_swar_export"]
    end

    test "drops a key this version does not understand instead of refusing the save" do
      user = user_fixture()

      {:ok, user} = Features.set_enabled(user, ["bel_swar_import", "ned_ratings_sync"])

      assert user.features == ["bel_swar_import"]
    end

    test "switching one key on never switches another on with it" do
      user = user_fixture()

      # The two readers depend on the sync's data, and that dependency is
      # deliberately explained rather than enforced - see the moduledoc.
      {:ok, user} = Features.set_enabled(user, ["bel_player_lookup", "bel_club_sync"])

      refute Features.enabled?(user, "bel_ratings_sync")
      assert Features.enabled?(user, "bel_player_lookup")
      assert Features.enabled?(user, "bel_club_sync")
    end

    test "survives a round trip through the database" do
      user = user_fixture()
      {:ok, _} = Features.set_enabled(user, Features.keys())

      reloaded = PairingsEngine.Accounts.get_user!(user.id)
      assert reloaded.features == Features.keys()
    end
  end
end
