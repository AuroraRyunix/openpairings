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
end
