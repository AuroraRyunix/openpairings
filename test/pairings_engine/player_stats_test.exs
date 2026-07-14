defmodule PairingsEngine.PlayerStatsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.PlayerStats

  describe "category/2" do
    test "nil birth_year gives an empty category" do
      assert PlayerStats.category(nil, 2026) == ""
    end

    test "youth brackets step every two years, exclusive upper bound" do
      assert PlayerStats.category(2019, 2026) == "-8"
      assert PlayerStats.category(2017, 2026) == "-10"
      assert PlayerStats.category(2015, 2026) == "-12"
      assert PlayerStats.category(2013, 2026) == "-14"
      assert PlayerStats.category(2011, 2026) == "-16"
      assert PlayerStats.category(2009, 2026) == "-18"
      assert PlayerStats.category(2007, 2026) == "-20"
    end

    test "adults between -20 and S50 fall into SEN" do
      assert PlayerStats.category(1996, 2026) == "SEN"
      assert PlayerStats.category(1977, 2026) == "SEN"
    end

    test "50-64 is S50, 65+ is S65" do
      assert PlayerStats.category(1976, 2026) == "S50"
      assert PlayerStats.category(1962, 2026) == "S50"
      assert PlayerStats.category(1961, 2026) == "S65"
      assert PlayerStats.category(1940, 2026) == "S65"
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
