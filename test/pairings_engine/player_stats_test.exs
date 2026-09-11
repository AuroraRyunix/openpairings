defmodule PairingsEngine.PlayerStatsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.PlayerStats
  alias PairingsEngine.Tournaments.Player

  # Condition-set rule matching itself (rating/age/women, nested/overlapping
  # categories, the legacy-shape conversion) is covered exhaustively in
  # `PairingsEngine.CategoryRulesTest` - these tests are about
  # `assign_category/4` and `assign_categories/4` themselves: picking the
  # single winner, preserving `category_order`, and threading
  # `tournament_year` through to the age computation.
  describe "assign_category/4 and assign_categories/4" do
    defp player(attrs), do: struct(Player, attrs)

    test "returns every category whose conditions all match, in category_order" do
      rules = %{"U1800" => %{"rating_below" => 1800}, "U16" => %{"age_below" => 16}}
      p = player(fide_rating: 1000, national_rating: 0, birth_year: 2015)

      assert PlayerStats.assign_categories(p, ["U1800", "U16"], rules, 2026) == ["U1800", "U16"]
      # Order in the list is the tournament's own order, not insertion order.
      assert PlayerStats.assign_categories(p, ["U16", "U1800"], rules, 2026) == ["U16", "U1800"]
    end

    test "assign_category/4 is the first of assign_categories/4's list" do
      rules = %{"U1800" => %{"rating_below" => 1800}}
      p = player(fide_rating: 1000, national_rating: 0)
      assert PlayerStats.assign_category(p, ["U1800"], rules) == "U1800"
    end

    test "assign_category/4 returns blank when nothing matches" do
      rules = %{"1800+" => %{"rating_from" => 1800}}
      p = player(fide_rating: 0, national_rating: 0)
      assert PlayerStats.assign_category(p, ["1800+"], rules) == ""
    end

    test "nested categories (U1800 and U1600) both match a 1500-rated player" do
      rules = %{"U1800" => %{"rating_below" => 1800}, "U1600" => %{"rating_below" => 1600}}
      p = player(fide_rating: 1500, national_rating: 0)
      assert PlayerStats.assign_categories(p, ["U1800", "U1600"], rules) == ["U1800", "U1600"]
    end

    test "a plain category with no rule is never auto-matched" do
      p = player(fide_rating: 1000, national_rating: 0)
      assert PlayerStats.assign_category(p, ["Open"], %{}) == ""
    end

    test "an unrated player (rating 0) qualifies for a rating_below ceiling but not rating_from" do
      p = player(fide_rating: 0, national_rating: 0)

      assert PlayerStats.assign_category(p, ["U1800"], %{"U1800" => %{"rating_below" => 1800}}) ==
               "U1800"

      assert PlayerStats.assign_category(p, ["1+"], %{"1+" => %{"rating_from" => 1}}) == ""
    end

    test "falls back to national_rating when there is no FIDE rating" do
      p = player(fide_rating: 0, national_rating: 1400)
      rules = %{"-1500" => %{"rating_below" => 1500}}
      assert PlayerStats.assign_category(p, ["-1500"], rules) == "-1500"
    end

    test "age uses the FIDE 1-January convention against the given tournament_year" do
      rules = %{"U18" => %{"age_below" => 18}}
      p = player(fide_rating: 0, national_rating: 0, birth_year: 2008)
      # age at 1 Jan 2026 = 2026 - 2008 - 1 = 17, under 18.
      assert PlayerStats.assign_category(p, ["U18"], rules, 2026) == "U18"
      # age at 1 Jan 2027 = 18, no longer under 18.
      assert PlayerStats.assign_category(p, ["U18"], rules, 2027) == ""
    end

    test "no birth data at all never matches an age condition" do
      rules = %{"U18" => %{"age_below" => 18}}
      p = player(fide_rating: 0, national_rating: 0)
      assert PlayerStats.assign_category(p, ["U18"], rules, 2026) == ""
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
      # Beyond 400 the cap still applies - 735 behaves exactly like 400.
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
