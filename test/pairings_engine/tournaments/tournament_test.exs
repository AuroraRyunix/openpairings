defmodule PairingsEngine.Tournaments.TournamentTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Tournaments.Tournament

  # A tournament that satisfies every `Tournament.required_setup_fields/0`
  # requirement - every individual test below starts from this and knocks
  # out exactly one thing, so a failure clearly points at one requirement.
  defp complete_tournament(overrides \\ %{}) do
    base = %Tournament{
      name: "City Open",
      start_date: "2026-08-01",
      rounds_count: 3,
      round_dates: ["2026-08-01", "2026-08-02", "2026-08-03"],
      tiebreaks: ["BH", "SB"],
      chief_arbiter: "Jane Arbiter",
      federation: "BEL",
      rate_of_play: "90 min + 30 sec/move",
      fide_homologated: false,
      fide_tournament_id: ""
    }

    struct(base, overrides)
  end

  describe "setup_complete?/1 and missing_setup_fields/1 - individually" do
    test "a fully filled-in tournament is complete" do
      t = complete_tournament()
      assert Tournament.setup_complete?(t)
      assert Tournament.missing_setup_fields(t) == []
    end

    test "blank name is reported" do
      t = complete_tournament(%{name: ""})
      refute Tournament.setup_complete?(t)
      assert {:name, _} = find_missing(t, :name)
    end

    test "nil name is reported" do
      t = complete_tournament(%{name: nil})
      refute Tournament.setup_complete?(t)
      assert {:name, _} = find_missing(t, :name)
    end

    # No "blank start_date is reported" test - start_date isn't its own
    # `missing_setup_fields/1` entry any more (it's derived from
    # round_dates, see that field's own doc comment on `Tournament`), so
    # requiring `:round_dates` already covers it. The round_dates-focused
    # tests below (empty / too short / has a blank entry) are what that
    # requirement actually rests on now.

    test "rounds_count of 0 is reported" do
      t = complete_tournament(%{rounds_count: 0, round_dates: []})
      refute Tournament.setup_complete?(t)
      assert {:rounds_count, _} = find_missing(t, :rounds_count)
    end

    test "nil rounds_count is reported" do
      t = complete_tournament(%{rounds_count: nil, round_dates: []})
      refute Tournament.setup_complete?(t)
      assert {:rounds_count, _} = find_missing(t, :rounds_count)
    end

    test "an empty round_dates list is reported (none filled in)" do
      t = complete_tournament(%{round_dates: []})
      refute Tournament.setup_complete?(t)
      assert {:round_dates, _} = find_missing(t, :round_dates)
    end

    test "a round_dates list shorter than rounds_count is reported (not one per round)" do
      t = complete_tournament(%{round_dates: ["2026-08-01"]})
      refute Tournament.setup_complete?(t)
      assert {:round_dates, _} = find_missing(t, :round_dates)
    end

    test "a round_dates list with a blank entry is reported" do
      t = complete_tournament(%{round_dates: ["2026-08-01", "", "2026-08-03"]})
      refute Tournament.setup_complete?(t)
      assert {:round_dates, _} = find_missing(t, :round_dates)
    end

    test "an empty tiebreaks list is reported" do
      t = complete_tournament(%{tiebreaks: []})
      refute Tournament.setup_complete?(t)
      assert {:tiebreaks, _} = find_missing(t, :tiebreaks)
    end

    test "blank chief_arbiter is recommended, not required (doesn't block pairing)" do
      t = complete_tournament(%{chief_arbiter: ""})
      assert Tournament.setup_complete?(t)
      assert find_missing(t, :chief_arbiter) == nil
      assert {:chief_arbiter, _} = find_recommended(t, :chief_arbiter)
    end

    test "blank federation is recommended, not required (doesn't block pairing)" do
      t = complete_tournament(%{federation: ""})
      assert Tournament.setup_complete?(t)
      assert find_missing(t, :federation) == nil
      assert {:federation, _} = find_recommended(t, :federation)
    end

    test "blank rate_of_play is recommended, not required (doesn't block pairing)" do
      t = complete_tournament(%{rate_of_play: ""})
      assert Tournament.setup_complete?(t)
      assert find_missing(t, :rate_of_play) == nil
      assert {:rate_of_play, _} = find_recommended(t, :rate_of_play)
    end

    test "fide_tournament_id is not recommended when the tournament isn't FIDE-homologated" do
      t = complete_tournament(%{fide_homologated: false, fide_tournament_id: ""})
      assert Tournament.setup_complete?(t)
      assert find_recommended(t, :fide_tournament_id) == nil
    end

    test "fide_tournament_id is recommended (not required) once FIDE-homologated" do
      t = complete_tournament(%{fide_homologated: true, fide_tournament_id: ""})
      # A missing FIDE ID never blocks pairing - you file the report later.
      assert Tournament.setup_complete?(t)
      assert find_missing(t, :fide_tournament_id) == nil
      assert {:fide_tournament_id, _} = find_recommended(t, :fide_tournament_id)
    end

    test "a FIDE-homologated tournament with an ID set has nothing recommended for FIDE" do
      t = complete_tournament(%{fide_homologated: true, fide_tournament_id: "BEL2026001"})
      assert Tournament.setup_complete?(t)
      assert find_recommended(t, :fide_tournament_id) == nil
    end
  end

  describe "missing_setup_fields/1 - combined" do
    test "several unmet requirements are all reported together" do
      t =
        complete_tournament(%{
          name: "",
          tiebreaks: [],
          chief_arbiter: "",
          federation: ""
        })

      missing = Tournament.missing_setup_fields(t)
      fields = Enum.map(missing, fn {field, _message} -> field end)

      # Structural fields block pairing...
      assert :name in fields
      assert :tiebreaks in fields
      # ...FIDE-report metadata does not - it's recommended, not required.
      refute :chief_arbiter in fields
      refute :federation in fields
      refute :rate_of_play in fields
      refute :round_dates in fields

      recommended = Enum.map(Tournament.missing_recommended_fields(t), &elem(&1, 0))
      assert :chief_arbiter in recommended
      assert :federation in recommended
    end

    test "every message is a non-blank plain-English string" do
      t = complete_tournament(%{name: "", federation: ""})

      for {_field, message} <- Tournament.missing_setup_fields(t) do
        assert is_binary(message)
        assert String.trim(message) != ""
      end
    end
  end

  describe "abs_jusque/abs_nbfois bounds" do
    # Both are one-byte fields in the `.swar` format, so `SwarExport`'s
    # `w_u8/1` masked anything past 255 - 256 wrote as 0, which SWAR reads
    # as "no round qualifies", the opposite of what was meant. The export
    # clamps and logs as a backstop; the changeset refuses at the door.
    for field <- [:abs_jusque, :abs_nbfois] do
      test "#{field} accepts 0 and 255" do
        for value <- [0, 255] do
          changeset =
            Tournament.changeset(%Tournament{}, %{unquote(field) => value, name: "T"})

          refute Keyword.has_key?(changeset.errors, unquote(field))
        end
      end

      test "#{field} rejects a value past 255" do
        changeset = Tournament.changeset(%Tournament{}, %{unquote(field) => 256, name: "T"})

        assert {_msg, opts} = changeset.errors[unquote(field)]
        assert opts[:validation] == :number
      end

      test "#{field} still rejects a negative value" do
        changeset = Tournament.changeset(%Tournament{}, %{unquote(field) => -1, name: "T"})

        assert changeset.errors[unquote(field)]
      end

      test "#{field} still accepts nil, which means 'no cap'" do
        changeset = Tournament.changeset(%Tournament{}, %{unquote(field) => nil, name: "T"})

        refute Keyword.has_key?(changeset.errors, unquote(field))
      end
    end
  end

  defp find_missing(tournament, field) do
    Enum.find(Tournament.missing_setup_fields(tournament), fn {f, _msg} -> f == field end)
  end

  defp find_recommended(tournament, field) do
    Enum.find(Tournament.missing_recommended_fields(tournament), fn {f, _msg} -> f == field end)
  end
end
