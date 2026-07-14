defmodule PairingsEngine.Tournaments.PairingSystemChangesetTest do
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Tournaments.Tournament

  describe "Tournament.changeset/2 - pairing_system field" do
    test "has default value 'swiss'" do
      changeset = Tournament.changeset(%Tournament{}, %{"name" => "Test", "type" => "swiss"})
      assert changeset.valid?
      assert get_field(changeset, :pairing_system) == "swiss"
    end

    test "accepts 'swiss'" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "pairing_system" => "swiss"
        })

      assert changeset.valid?
      assert get_field(changeset, :pairing_system) == "swiss"
    end

    test "accepts 'round_robin'" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "pairing_system" => "round_robin"
        })

      assert changeset.valid?
      assert get_field(changeset, :pairing_system) == "round_robin"
    end

    test "accepts 'keizer'" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "pairing_system" => "keizer"
        })

      assert changeset.valid?
      assert get_change(changeset, :pairing_system) == "keizer"
    end

    test "rejects invalid values like 'dutch'" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "pairing_system" => "dutch"
        })

      refute changeset.valid?
      assert %{pairing_system: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects other invalid pairing systems" do
      for invalid_system <- ["invalid", "rapid", "blitz", "manual"] do
        changeset =
          Tournament.changeset(%Tournament{}, %{
            "name" => "Test",
            "type" => "swiss",
            "pairing_system" => invalid_system
          })

        refute changeset.valid?
        assert %{pairing_system: ["is invalid"]} = errors_on(changeset)
      end
    end
  end

  describe "Tournament.changeset/2 - rr_cycles field" do
    test "has default value 1" do
      changeset = Tournament.changeset(%Tournament{}, %{"name" => "Test", "type" => "swiss"})
      assert changeset.valid?
      assert get_field(changeset, :rr_cycles) == 1
    end

    test "accepts 1" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "rr_cycles" => 1
        })

      assert changeset.valid?
      assert get_field(changeset, :rr_cycles) == 1
    end

    test "accepts 2" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "rr_cycles" => 2
        })

      assert changeset.valid?
      assert get_field(changeset, :rr_cycles) == 2
    end

    test "rejects 0" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "rr_cycles" => 0
        })

      refute changeset.valid?
      assert %{rr_cycles: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects 3" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "rr_cycles" => 3
        })

      refute changeset.valid?
      assert %{rr_cycles: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects negative values" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "rr_cycles" => -1
        })

      refute changeset.valid?
      assert %{rr_cycles: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects large values" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "rr_cycles" => 10
        })

      refute changeset.valid?
      assert %{rr_cycles: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "Tournament.changeset/2 - keizer_top_value field" do
    test "has default value nil" do
      changeset = Tournament.changeset(%Tournament{}, %{"name" => "Test", "type" => "swiss"})
      assert changeset.valid?
      assert get_field(changeset, :keizer_top_value) == nil
    end

    test "accepts nil (automatic mode)" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "keizer_top_value" => nil
        })

      assert changeset.valid?
      assert get_field(changeset, :keizer_top_value) == nil
    end

    test "accepts positive integers" do
      for value <- [1, 10, 50, 100, 1000] do
        changeset =
          Tournament.changeset(%Tournament{}, %{
            "name" => "Test",
            "type" => "swiss",
            "keizer_top_value" => value
          })

        assert changeset.valid?, "Expected #{value} to be valid"
        assert get_field(changeset, :keizer_top_value) == value
      end
    end

    test "rejects 0" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "keizer_top_value" => 0
        })

      refute changeset.valid?
      assert %{keizer_top_value: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "rejects negative integers" do
      for value <- [-1, -10, -100] do
        changeset =
          Tournament.changeset(%Tournament{}, %{
            "name" => "Test",
            "type" => "swiss",
            "keizer_top_value" => value
          })

        refute changeset.valid?, "Expected #{value} to be invalid"
        assert %{keizer_top_value: ["must be greater than 0"]} = errors_on(changeset)
      end
    end

    test "clearing keizer_top_value back to nil is always valid" do
      # Start with a tournament that has a keizer_top_value set
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Test",
          "type" => "swiss",
          "keizer_top_value" => 50
        })

      assert changeset.valid?
      tournament = Ecto.Changeset.apply_changes(changeset)

      # Update it to nil (clearing the field)
      updated =
        Tournament.changeset(tournament, %{
          "keizer_top_value" => nil
        })

      assert updated.valid?
      assert get_change(updated, :keizer_top_value) == nil
    end
  end

  describe "Tournament.changeset/2 - interaction between fields" do
    test "pairing_system, rr_cycles, and keizer_top_value can be set together" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Full Test",
          "type" => "swiss",
          "pairing_system" => "keizer",
          "rr_cycles" => 2,
          "keizer_top_value" => 100
        })

      assert changeset.valid?
      assert get_field(changeset, :pairing_system) == "keizer"
      assert get_field(changeset, :rr_cycles) == 2
      assert get_field(changeset, :keizer_top_value) == 100
    end

    test "round_robin system with rr_cycles=2 is valid" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "RR Test",
          "type" => "swiss",
          "pairing_system" => "round_robin",
          "rr_cycles" => 2
        })

      assert changeset.valid?
    end

    test "all three fields can default without errors" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Defaults Test",
          "type" => "swiss"
        })

      assert changeset.valid?
      assert get_field(changeset, :pairing_system) == "swiss"
      assert get_field(changeset, :rr_cycles) == 1
      assert get_field(changeset, :keizer_top_value) == nil
    end
  end

  describe "Tournament.changeset/2 - public_slug generation" do
    test "generates a public_slug when creating a new tournament" do
      changeset =
        Tournament.changeset(%Tournament{}, %{
          "name" => "Slug Test",
          "type" => "swiss"
        })

      assert changeset.valid?
      slug = get_change(changeset, :public_slug)
      assert is_binary(slug)
      assert byte_size(slug) > 0
    end

    test "does not overwrite an existing public_slug on update" do
      tournament =
        %Tournament{public_slug: "existing-slug"}

      changeset =
        Tournament.changeset(tournament, %{
          "name" => "Update Test",
          "pairing_system" => "round_robin"
        })

      assert changeset.valid?
      # Should not change the existing slug
      refute is_map_key(changeset.changes, :public_slug)
    end
  end
end
