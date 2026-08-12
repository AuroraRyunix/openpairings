defmodule PairingsEngine.PlayerStatsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.PlayerStats
  alias PairingsEngine.Tournaments.Player

  describe "assign_category/4 (SWAR CATEGORIES threshold rules)" do
    defp player(attrs), do: struct(Player, attrs)

    test "a 1000-rated player picks the tighter of two overlapping elo_below ceilings" do
      rules = %{
        "-1200" => %{"kind" => "elo_below", "value" => 1200},
        "-1100" => %{"kind" => "elo_below", "value" => 1100}
      }

      p = player(fide_rating: 1000, national_rating: 0)
      assert PlayerStats.assign_category(p, ["-1200", "-1100"], rules) == "-1100"
      # Order in the list must not matter — it's the value that's tighter.
      assert PlayerStats.assign_category(p, ["-1100", "-1200"], rules) == "-1100"
    end

    test "elo_above picks the larger (more specific) floor" do
      rules = %{
        "+1800" => %{"kind" => "elo_above", "value" => 1800},
        "+2000" => %{"kind" => "elo_above", "value" => 2000}
      }

      p = player(fide_rating: 2100, national_rating: 0)
      assert PlayerStats.assign_category(p, ["+1800", "+2000"], rules) == "+2000"
    end

    test "age_below/age_above use birth_year against the given current_year" do
      rules = %{"U18" => %{"kind" => "age_below", "value" => 18}}
      p = player(fide_rating: 0, national_rating: 0, birth_year: 2015)
      assert PlayerStats.assign_category(p, ["U18"], rules, 2026) == "U18"
      assert PlayerStats.assign_category(p, ["U18"], rules, 2035) == ""
    end

    test "a plain category with no rule is never auto-matched" do
      rules = %{}
      p = player(fide_rating: 1000, national_rating: 0)
      assert PlayerStats.assign_category(p, ["Open"], rules) == ""
    end

    test "no match at all (unrated, and no age rule) gives blank" do
      rules = %{"+1800" => %{"kind" => "elo_above", "value" => 1800}}
      p = player(fide_rating: 0, national_rating: 0)
      assert PlayerStats.assign_category(p, ["+1800"], rules) == ""
    end

    # Real report: a real tournament's "U1800" (elo_below 1800) bracket
    # wasn't picking up its unrated players at all — 0 (an unrated
    # player's `Player.rating/1`) genuinely IS under any positive
    # ceiling, so excluding them was backwards.
    test "an unrated player (rating 0) still qualifies for an elo_below ceiling" do
      rules = %{"U1800" => %{"kind" => "elo_below", "value" => 1800}}
      p = player(fide_rating: 0, national_rating: 0)
      assert PlayerStats.assign_category(p, ["U1800"], rules) == "U1800"
    end

    # An unrated player has no proven rating to be ABOVE anything —
    # elo_above deliberately keeps excluding them, unlike elo_below.
    test "an unrated player never qualifies for an elo_above floor" do
      rules = %{"+1800" => %{"kind" => "elo_above", "value" => 1800}}
      p = player(fide_rating: 0, national_rating: 0)
      assert PlayerStats.assign_category(p, ["+1800"], rules) == ""
    end

    test "matching more than one KIND at once is broken by list order" do
      rules = %{
        "-1200" => %{"kind" => "elo_below", "value" => 1200},
        "U18" => %{"kind" => "age_below", "value" => 18}
      }

      p = player(fide_rating: 1000, national_rating: 0, birth_year: 2015)
      assert PlayerStats.assign_category(p, ["-1200", "U18"], rules, 2026) == "-1200"
      assert PlayerStats.assign_category(p, ["U18", "-1200"], rules, 2026) == "U18"
    end

    test "falls back to national_rating when there is no FIDE rating" do
      rules = %{"-1500" => %{"kind" => "elo_below", "value" => 1500}}
      p = player(fide_rating: 0, national_rating: 1400)
      assert PlayerStats.assign_category(p, ["-1500"], rules) == "-1500"
    end
  end

  describe "performance/3" do
    test "no games played returns nil" do
      assert PlayerStats.performance([], 0, 0) == nil
    end

    test "averages opponent ratings and adds the win/loss adjustment" do
      # avg(1800, 1700) = 1750, + 400 * (2 - 0) / 2 = +400 => 2150
      assert PlayerStats.performance([1800, 1700], 2, 0) == 2150
    end

    test "losses pull the performance rating down" do
      # avg(2000, 2000) = 2000, + 400 * (0 - 2) / 2 = -400 => 1600
      assert PlayerStats.performance([2000, 2000], 0, 2) == 1600
    end

    test "rounds to the nearest integer" do
      # avg(2001, 2000, 1999) = 2000, + 400 * (1 - 1) / 3 = 0 => 2000
      assert PlayerStats.performance([2001, 2000, 1999], 1, 1) == 2000
    end
  end

  describe "expected_score/1 (FIDE Table 8.1.2, verified against handbook.fide.com)" do
    test "equal ratings (diff 0-3) give 0.50" do
      assert PlayerStats.expected_score(0) == 0.50
      assert PlayerStats.expected_score(3) == 0.50
      assert PlayerStats.expected_score(-3) == 0.50
    end

    test "first bucket boundary above the 0.50 band (diff 4)" do
      assert PlayerStats.expected_score(4) == 0.51
      assert PlayerStats.expected_score(-4) == 0.49
    end

    test "375-391 bucket vs the next one at 392" do
      assert PlayerStats.expected_score(391) == 0.91
      assert PlayerStats.expected_score(392) == 0.92
    end

    test "Article 8.3.1 caps the difference at 400 (0.92 / 0.08)" do
      assert PlayerStats.expected_score(400) == 0.92
      assert PlayerStats.expected_score(-400) == 0.08
      # Beyond 400 the cap still applies — 735 behaves exactly like 400.
      assert PlayerStats.expected_score(735) == 0.92
      assert PlayerStats.expected_score(-735) == 0.08
    end
  end

  describe "we/2" do
    test "unrated player (own_rating <= 0) is blank" do
      assert PlayerStats.we(0, [1800]) == nil
    end

    test "no counted games is blank" do
      assert PlayerStats.we(1800, []) == nil
    end

    test "sums per-game expected scores, unrated opponents already excluded by the caller" do
      # own 1800 vs 1700 (diff +100 => bucket 92-98? no: 99-106 => wait use exact)
      # diff 100 falls in the 99-106 bucket => 0.64; diff -100 (vs 1900) => 0.36
      assert PlayerStats.we(1800, [1700, 1900]) == 1.0
    end
  end

  describe "w_minus_we/2" do
    test "nil We propagates to a blank W-We" do
      assert PlayerStats.w_minus_we(1.0, nil) == nil
    end

    test "signed difference between actual and expected score" do
      assert PlayerStats.w_minus_we(1.5, 1.0) == 0.5
      assert PlayerStats.w_minus_we(0.0, 1.0) == -1.0
    end
  end
end
