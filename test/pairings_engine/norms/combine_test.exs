defmodule PairingsEngine.Norms.CombineTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Norms.{Combine, Forms}
  alias PairingsEngine.Tournaments.{Tournament, Player}

  # ---------------------------------------------------------------------
  # fixtures (plain structs — Combine is pure, no DB needed)
  # ---------------------------------------------------------------------

  defp tournament(overrides) do
    struct(
      %Tournament{
        id: 1,
        name: "Base",
        federation: "BEL",
        venue: "Hall",
        city: "Ghent",
        start_date: "2026-08-01",
        end_date: "2026-08-05",
        rounds_count: 7,
        round_dates: ["2026-08-01", "2026-08-02"],
        rate_of_play: "90+30",
        time_control: "",
        event_code: "EVT1",
        fide_tournament_id: "111",
        officials: %{"chief_arbiter_fide_id" => "999"}
      },
      overrides
    )
  end

  defp player(overrides) do
    struct(
      %Player{
        id: nil,
        name: "Doe, Jane",
        federation: "BEL",
        fide_id: nil,
        national_id: "",
        birth_year: 1990
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------
  # single-tournament passthrough
  # ---------------------------------------------------------------------

  describe "combine/2 with a single tournament" do
    test "passes through unchanged, no renaming, master_index ignored" do
      t = tournament(%{name: "Solo Open"})
      players = [player(%{name: "Doe, Jane"})]

      assert {:ok, {^t, ^players}} = Combine.combine([{t, players}], 0)
      assert {:ok, {^t, ^players}} = Combine.combine([{t, players}], 99)
    end
  end

  # ---------------------------------------------------------------------
  # master field selection + Festival naming
  # ---------------------------------------------------------------------

  describe "combine/2 with 2+ tournaments" do
    test "master (index 0) supplies all header/schedule fields; name gets ' Festival' appended" do
      a =
        tournament(%{
          id: 10,
          name: "Belgian Open",
          venue: "Sports Hall",
          city: "Antwerp",
          rounds_count: 9,
          round_dates: ["2026-09-01", "2026-09-02", "2026-09-02"],
          rate_of_play: "40/90+30",
          event_code: "AOPEN",
          fide_tournament_id: "555",
          officials: %{"chief_arbiter_fide_id" => "12345"}
        })

      b = tournament(%{id: 20, name: "Belgian Youth", venue: "Other Hall", city: "Bruges"})

      a_players = [player(%{name: "Alpha, One", fide_id: 1, birth_year: 2000})]
      b_players = [player(%{name: "Bravo, Two", fide_id: 2, birth_year: 2001})]

      assert {:ok, {virtual, players}} =
               Combine.combine([{a, a_players}, {b, b_players}], 0)

      assert virtual.name == "Belgian Open Festival"
      assert virtual.venue == "Sports Hall"
      assert virtual.city == "Antwerp"
      assert virtual.rounds_count == 9
      assert virtual.round_dates == ["2026-09-01", "2026-09-02", "2026-09-02"]
      assert virtual.rate_of_play == "40/90+30"
      assert virtual.event_code == "AOPEN"
      # fide_tournament_id is the one field NOT taken verbatim from the
      # master — see the "combined FIDE tournament id" describe block below.
      # `a` is "555", `b` (unoverridden) is the fixture default "111".
      assert virtual.fide_tournament_id == "555,111"
      assert virtual.officials == %{"chief_arbiter_fide_id" => "12345"}
      assert virtual.id == nil

      assert players == a_players ++ b_players
    end

    test "master (index 1) supplies the fields instead when picked" do
      a = tournament(%{id: 10, name: "Belgian Open"})
      b = tournament(%{id: 20, name: "Belgian Youth", venue: "Youth Hall", city: "Bruges"})

      assert {:ok, {virtual, _players}} =
               Combine.combine([{a, [player(%{fide_id: 1})]}, {b, [player(%{fide_id: 2})]}], 1)

      assert virtual.name == "Belgian Youth Festival"
      assert virtual.venue == "Youth Hall"
      assert virtual.city == "Bruges"
    end

    test "works with 3+ tournaments, concatenating every player list in order" do
      a = tournament(%{id: 1, name: "A"})
      b = tournament(%{id: 2, name: "B"})
      c = tournament(%{id: 3, name: "C"})

      pa = [player(%{name: "P1", fide_id: 1})]
      pb = [player(%{name: "P2", fide_id: 2})]
      pc = [player(%{name: "P3", fide_id: 3})]

      assert {:ok, {virtual, players}} = Combine.combine([{a, pa}, {b, pb}, {c, pc}], 2)

      assert virtual.name == "C Festival"
      assert players == pa ++ pb ++ pc
    end
  end

  # ---------------------------------------------------------------------
  # combined FIDE tournament id (IT3 B2) — a festival's category groups are
  # often separately homologated with FIDE under different tournament ids
  # ---------------------------------------------------------------------

  describe "combine/2's combined FIDE tournament id" do
    test "every group sharing one id collapses to just that id" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: "555"})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: "555"})

      assert {:ok, {virtual, _players}} =
               Combine.combine([{a, [player(%{fide_id: 1})]}, {b, [player(%{fide_id: 2})]}], 0)

      assert virtual.fide_tournament_id == "555"
    end

    test "consecutive distinct ids compress to a range" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: "12345"})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: "12346"})
      c = tournament(%{id: 3, name: "C", fide_tournament_id: "12347"})

      assert {:ok, {virtual, _players}} =
               Combine.combine(
                 [
                   {a, [player(%{fide_id: 1})]},
                   {b, [player(%{fide_id: 2})]},
                   {c, [player(%{fide_id: 3})]}
                 ],
                 0
               )

      assert virtual.fide_tournament_id == "12345-12347"
    end

    test "consecutive ids given out of order still compress (sorted, not selection order)" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: "12347"})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: "12345"})
      c = tournament(%{id: 3, name: "C", fide_tournament_id: "12346"})

      assert {:ok, {virtual, _players}} =
               Combine.combine(
                 [
                   {a, [player(%{fide_id: 1})]},
                   {b, [player(%{fide_id: 2})]},
                   {c, [player(%{fide_id: 3})]}
                 ],
                 0
               )

      assert virtual.fide_tournament_id == "12345-12347"
    end

    test "a gap in otherwise-numeric ids falls back to a comma list, in selection order" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: "12345"})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: "12350"})

      assert {:ok, {virtual, _players}} =
               Combine.combine([{a, [player(%{fide_id: 1})]}, {b, [player(%{fide_id: 2})]}], 0)

      assert virtual.fide_tournament_id == "12345,12350"
    end

    test "a non-numeric id among the set falls back to a comma list" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: "BEL-2026-A"})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: "12345"})

      assert {:ok, {virtual, _players}} =
               Combine.combine([{a, [player(%{fide_id: 1})]}, {b, [player(%{fide_id: 2})]}], 0)

      assert virtual.fide_tournament_id == "BEL-2026-A,12345"
    end

    test "a group with no id at all is just dropped, not treated as a blank member of the list" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: ""})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: "12345"})

      assert {:ok, {virtual, _players}} =
               Combine.combine([{a, [player(%{fide_id: 1})]}, {b, [player(%{fide_id: 2})]}], 0)

      assert virtual.fide_tournament_id == "12345"
    end

    test "no group has an id -> blank, same as a single tournament with no id" do
      a = tournament(%{id: 1, name: "A", fide_tournament_id: ""})
      b = tournament(%{id: 2, name: "B", fide_tournament_id: ""})

      assert {:ok, {virtual, _players}} =
               Combine.combine([{a, [player(%{fide_id: 1})]}, {b, [player(%{fide_id: 2})]}], 0)

      assert virtual.fide_tournament_id == ""
    end
  end

  # ---------------------------------------------------------------------
  # player-derived aggregates flow through Forms unmodified
  # ---------------------------------------------------------------------

  describe "player-derived aggregates flow naturally through Forms" do
    test "distinct federations across combined tournaments count correctly (BEL,NED,GER + BEL,NED,FR = 4)" do
      a = tournament(%{id: 1, name: "A"})
      b = tournament(%{id: 2, name: "B"})

      a_players = [
        player(%{name: "P1", fide_id: 1, federation: "BEL"}),
        player(%{name: "P2", fide_id: 2, federation: "NED"}),
        player(%{name: "P3", fide_id: 3, federation: "GER"})
      ]

      b_players = [
        player(%{name: "P4", fide_id: 4, federation: "BEL"}),
        player(%{name: "P5", fide_id: 5, federation: "NED"}),
        player(%{name: "P6", fide_id: 6, federation: "FR"})
      ]

      assert {:ok, {virtual, players}} = Combine.combine([{a, a_players}, {b, b_players}], 0)

      candidate = %{
        "last_name" => "X",
        "first_name" => "Y",
        "fide_id" => "1",
        "federation" => "BEL"
      }

      fills = Forms.fa1_fills(virtual, players, candidate)["Invulformulier"]

      # B15 = distinct federations represented among the players.
      assert fills["B15"] == 4
      # B13 = total player count.
      assert fills["B13"] == 6
    end
  end

  # ---------------------------------------------------------------------
  # duplicate detection
  # ---------------------------------------------------------------------

  describe "duplicate player detection" do
    test "flags the same nonzero fide_id appearing in two tournaments" do
      a = tournament(%{id: 1})
      b = tournament(%{id: 2})

      a_players = [player(%{name: "Same Person", fide_id: 12345})]
      b_players = [player(%{name: "Same Person Again", fide_id: 12345})]

      assert {:error, {:duplicate_players, ["Same Person"]}} =
               Combine.combine([{a, a_players}, {b, b_players}], 0)
    end

    test "falls back to national_id when fide_id is absent/zero on both sides" do
      a = tournament(%{id: 1})
      b = tournament(%{id: 2})

      a_players = [player(%{name: "Nat One", fide_id: nil, national_id: "NAT-1"})]
      b_players = [player(%{name: "Nat One", fide_id: 0, national_id: "NAT-1"})]

      assert {:error, {:duplicate_players, ["Nat One"]}} =
               Combine.combine([{a, a_players}, {b, b_players}], 0)
    end

    test "falls back to normalized name + birth_year when fide_id and national_id are both absent" do
      a = tournament(%{id: 1})
      b = tournament(%{id: 2})

      a_players = [
        player(%{name: "  doe, JANE  ", fide_id: nil, national_id: "", birth_year: 1990})
      ]

      b_players = [player(%{name: "Doe, Jane", fide_id: nil, national_id: "", birth_year: 1990})]

      assert {:error, {:duplicate_players, [name]}} =
               Combine.combine([{a, a_players}, {b, b_players}], 0)

      assert name in ["  doe, JANE  ", "Doe, Jane"]
    end

    test "same name but different birth_year is NOT a duplicate" do
      a = tournament(%{id: 1})
      b = tournament(%{id: 2})

      a_players = [player(%{name: "Doe, Jane", fide_id: nil, national_id: "", birth_year: 1990})]
      b_players = [player(%{name: "Doe, Jane", fide_id: nil, national_id: "", birth_year: 2001})]

      assert {:ok, _} = Combine.combine([{a, a_players}, {b, b_players}], 0)
    end

    test "a repeat inside a single tournament's own player list is not flagged (not this check's business)" do
      a = tournament(%{id: 1})
      b = tournament(%{id: 2})

      # Both entries share an identity, but they're both in tournament A —
      # only a duplicate that spans two different *tournaments* matters here.
      a_players = [
        player(%{name: "Data Quality Issue", fide_id: 777}),
        player(%{name: "Data Quality Issue", fide_id: 777})
      ]

      b_players = [player(%{name: "Unrelated", fide_id: 888})]

      assert {:ok, _} = Combine.combine([{a, a_players}, {b, b_players}], 0)
    end

    test "returns every duplicate found, not just the first, sorted" do
      a = tournament(%{id: 1})
      b = tournament(%{id: 2})

      a_players = [
        player(%{name: "Zulu Player", fide_id: 1}),
        player(%{name: "Alpha Player", fide_id: 2})
      ]

      b_players = [
        player(%{name: "Zulu Player Dup", fide_id: 1}),
        player(%{name: "Alpha Player Dup", fide_id: 2})
      ]

      assert {:error, {:duplicate_players, names}} =
               Combine.combine([{a, a_players}, {b, b_players}], 0)

      assert names == Enum.sort(names)
      assert length(names) == 2
    end
  end

  # ---------------------------------------------------------------------
  # error_message/1
  # ---------------------------------------------------------------------

  describe "error_message/1" do
    test "singular duplicate" do
      msg = Combine.error_message({:duplicate_players, ["Doe, Jane"]})
      assert msg =~ "Doe, Jane"
      assert msg =~ "categories of one festival can't share players"
    end

    test "multiple duplicates" do
      msg = Combine.error_message({:duplicate_players, ["Doe, Jane", "Smith, Bob"]})
      assert msg =~ "Doe, Jane"
      assert msg =~ "Smith, Bob"
    end
  end
end
