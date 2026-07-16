defmodule PairingsEngine.Tournaments.TournamentTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Tournaments.Tournament

  # A tournament that satisfies every `Tournament.required_setup_fields/0`
  # requirement — every individual test below starts from this and knocks
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

  describe "setup_complete?/1 and missing_setup_fields/1 — individually" do
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

    test "blank start_date is reported" do
      t = complete_tournament(%{start_date: ""})
      refute Tournament.setup_complete?(t)
      assert {:start_date, _} = find_missing(t, :start_date)
    end

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

    test "blank chief_arbiter is reported" do
      t = complete_tournament(%{chief_arbiter: ""})
      refute Tournament.setup_complete?(t)
      assert {:chief_arbiter, _} = find_missing(t, :chief_arbiter)
    end

    test "blank federation is reported" do
      t = complete_tournament(%{federation: ""})
      refute Tournament.setup_complete?(t)
      assert {:federation, _} = find_missing(t, :federation)
    end

    test "blank rate_of_play is reported" do
      t = complete_tournament(%{rate_of_play: ""})
      refute Tournament.setup_complete?(t)
      assert {:rate_of_play, _} = find_missing(t, :rate_of_play)
    end

    test "fide_tournament_id is NOT required when the tournament isn't FIDE-homologated" do
      t = complete_tournament(%{fide_homologated: false, fide_tournament_id: ""})
      assert Tournament.setup_complete?(t)
    end

    test "fide_tournament_id IS required once the tournament is FIDE-homologated" do
      t = complete_tournament(%{fide_homologated: true, fide_tournament_id: ""})
      refute Tournament.setup_complete?(t)
      assert {:fide_tournament_id, _} = find_missing(t, :fide_tournament_id)
    end

    test "a FIDE-homologated tournament with an ID set is complete" do
      t = complete_tournament(%{fide_homologated: true, fide_tournament_id: "BEL2026001"})
      assert Tournament.setup_complete?(t)
    end
  end

  describe "missing_setup_fields/1 — combined" do
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

      assert :name in fields
      assert :tiebreaks in fields
      assert :chief_arbiter in fields
      assert :federation in fields
      refute :rate_of_play in fields
      refute :round_dates in fields
    end

    test "every message is a non-blank plain-English string" do
      t = complete_tournament(%{name: "", federation: ""})

      for {_field, message} <- Tournament.missing_setup_fields(t) do
        assert is_binary(message)
        assert String.trim(message) != ""
      end
    end
  end

  defp find_missing(tournament, field) do
    Enum.find(Tournament.missing_setup_fields(tournament), fn {f, _msg} -> f == field end)
  end
end
