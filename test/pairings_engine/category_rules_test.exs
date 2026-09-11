defmodule PairingsEngine.CategoryRulesTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.CategoryRules
  alias PairingsEngine.PlayerStats
  alias PairingsEngine.Tournaments.Player

  defp player(attrs \\ []), do: struct(Player, attrs)

  describe "rule_owned?/1" do
    test "nil and an empty map are not rule-owned" do
      refute CategoryRules.rule_owned?(nil)
      refute CategoryRules.rule_owned?(%{})
    end

    test "any single recognised key makes it rule-owned" do
      assert CategoryRules.rule_owned?(%{"rating_from" => 1600})
      assert CategoryRules.rule_owned?(%{"rating_below" => 1800})
      assert CategoryRules.rule_owned?(%{"age_from" => 45})
      assert CategoryRules.rule_owned?(%{"age_below" => 16})
      assert CategoryRules.rule_owned?(%{"women" => true})
    end

    test "a map with only unrecognised keys is not rule-owned" do
      refute CategoryRules.rule_owned?(%{"note" => "manual"})
    end
  end

  describe "matches?/4 - rating conditions" do
    test "rating_from alone is >=" do
      p = player()
      assert CategoryRules.matches?(%{"rating_from" => 1600}, p, 1600, nil)
      refute CategoryRules.matches?(%{"rating_from" => 1601}, p, 1600, nil)
    end

    test "rating_below alone is <" do
      p = player()
      assert CategoryRules.matches?(%{"rating_below" => 1601}, p, 1600, nil)
      refute CategoryRules.matches?(%{"rating_below" => 1600}, p, 1600, nil)
    end

    test "both together form a band (bounded on both sides)" do
      rule = %{"rating_from" => 1600, "rating_below" => 1800}
      p = player()
      assert CategoryRules.matches?(rule, p, 1600, nil)
      assert CategoryRules.matches?(rule, p, 1799, nil)
      refute CategoryRules.matches?(rule, p, 1599, nil)
      refute CategoryRules.matches?(rule, p, 1800, nil)
    end

    test "unrated (rating 0) satisfies rating_below but never rating_from" do
      p = player()
      assert CategoryRules.matches?(%{"rating_below" => 1800}, p, 0, nil)
      refute CategoryRules.matches?(%{"rating_from" => 1}, p, 0, nil)
    end
  end

  describe "matches?/4 - age conditions" do
    test "age_from is >=, age_below is <" do
      p = player()
      assert CategoryRules.matches?(%{"age_from" => 45}, p, 0, 45)
      refute CategoryRules.matches?(%{"age_from" => 45}, p, 0, 44)
      assert CategoryRules.matches?(%{"age_below" => 16}, p, 0, 15)
      refute CategoryRules.matches?(%{"age_below" => 16}, p, 0, 16)
    end

    test "both together form a band" do
      rule = %{"age_from" => 45, "age_below" => 55}
      p = player()
      assert CategoryRules.matches?(rule, p, 0, 45)
      assert CategoryRules.matches?(rule, p, 0, 54)
      refute CategoryRules.matches?(rule, p, 0, 44)
      refute CategoryRules.matches?(rule, p, 0, 55)
    end

    test "nil age (no birth data at all) never satisfies an age condition" do
      p = player()
      refute CategoryRules.matches?(%{"age_below" => 99}, p, 0, nil)
      refute CategoryRules.matches?(%{"age_from" => 0}, p, 0, nil)
    end
  end

  describe "matches?/4 - women and combined axes" do
    test "women only matches sex \"w\" - not \"m\", not blank" do
      assert CategoryRules.matches?(%{"women" => true}, player(sex: "w"), 0, nil)
      refute CategoryRules.matches?(%{"women" => true}, player(sex: "m"), 0, nil)
      refute CategoryRules.matches?(%{"women" => true}, player(sex: ""), 0, nil)
    end

    test "a category combining rating, age and women needs every condition at once" do
      rule = %{"rating_below" => 1800, "age_from" => 45, "women" => true}
      w = player(sex: "w")
      m = player(sex: "m")

      assert CategoryRules.matches?(rule, w, 1500, 50)
      refute CategoryRules.matches?(rule, m, 1500, 50)
      refute CategoryRules.matches?(rule, w, 1900, 50)
      refute CategoryRules.matches?(rule, w, 1500, 40)
    end

    test "two nested/overlapping categories both match the same player independently" do
      p = player()
      assert CategoryRules.matches?(%{"rating_below" => 1800}, p, 1500, nil)
      assert CategoryRules.matches?(%{"rating_below" => 1600}, p, 1500, nil)
    end

    test "a category with no conditions set never matches - it is hand-assigned" do
      p = player()
      refute CategoryRules.matches?(%{}, p, 1000, nil)
      refute CategoryRules.matches?(nil, p, 1000, nil)
    end
  end

  describe "tournament_year/1" do
    test "round 1's own date wins when set" do
      t = %{round_dates: ["2019-05-01", "2019-05-02"], start_date: "2026-01-01"}
      assert CategoryRules.tournament_year(t) == 2019
    end

    test "falls back to start_date when round 1's date is blank" do
      t = %{round_dates: ["", "2019-05-02"], start_date: "2020-06-01"}
      assert CategoryRules.tournament_year(t) == 2020
    end

    test "falls back to today when neither is set" do
      t = %{round_dates: [], start_date: ""}
      assert CategoryRules.tournament_year(t) == Date.utc_today().year
    end
  end

  describe "age_at_year_start/2 - FIDE 1 January convention" do
    test "birth year only: year - birth_year - 1" do
      assert CategoryRules.age_at_year_start(player(birth_year: 2010), 2026) == 15
    end

    test "exact birth date after 1 January carries the same -1" do
      assert CategoryRules.age_at_year_start(player(birth_date: ~D[2010-06-15]), 2026) == 15
    end

    test "exact birth date of 1 January itself: the birthday has already happened" do
      assert CategoryRules.age_at_year_start(player(birth_date: ~D[2010-01-01]), 2026) == 16
    end

    test "no birth data at all: nil" do
      assert CategoryRules.age_at_year_start(player(), 2026) == nil
    end
  end

  describe "birth-year hints (editor live preview)" do
    test "birth_year_on_or_after/2, for an age_below threshold" do
      assert CategoryRules.birth_year_on_or_after(2026, 16) == 2010
    end

    test "birth_year_on_or_before/2, for an age_from threshold" do
      assert CategoryRules.birth_year_on_or_before(2026, 45) == 1980
    end
  end

  describe "migrate_legacy_rules/2 - single-rule conversions" do
    test "elo_below keeps its value (< stays <)" do
      rules = %{"U1800" => %{"kind" => "elo_below", "value" => 1800}}

      assert CategoryRules.migrate_legacy_rules(rules, ["U1800"]) ==
               %{"U1800" => %{"rating_below" => 1800}}
    end

    test "elo_above becomes rating_from at value + 1 (> becomes >=)" do
      rules = %{"1800+" => %{"kind" => "elo_above", "value" => 1800}}

      assert CategoryRules.migrate_legacy_rules(rules, ["1800+"]) ==
               %{"1800+" => %{"rating_from" => 1801}}
    end

    test "age_below becomes age_below at value - 1 (the FIDE 1-January shift)" do
      rules = %{"U18" => %{"kind" => "age_below", "value" => 18}}

      assert CategoryRules.migrate_legacy_rules(rules, ["U18"]) ==
               %{"U18" => %{"age_below" => 17}}
    end

    test "age_above becomes age_from at the same value" do
      rules = %{"45+" => %{"kind" => "age_above", "value" => 45}}

      assert CategoryRules.migrate_legacy_rules(rules, ["45+"]) ==
               %{"45+" => %{"age_from" => 45}}
    end
  end

  describe "migrate_legacy_rules/2 - tightest-per-kind collapse, as mutually exclusive bands" do
    test "two elo_below thresholds become bands" do
      rules = %{
        "-1100" => %{"kind" => "elo_below", "value" => 1100},
        "-1200" => %{"kind" => "elo_below", "value" => 1200}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["-1100", "-1200"]) == %{
               "-1100" => %{"rating_below" => 1100},
               "-1200" => %{"rating_from" => 1100, "rating_below" => 1200}
             }
    end

    test "a three-way chain of elo_below thresholds" do
      rules = %{
        "-1100" => %{"kind" => "elo_below", "value" => 1100},
        "-1200" => %{"kind" => "elo_below", "value" => 1200},
        "-1300" => %{"kind" => "elo_below", "value" => 1300}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["-1100", "-1200", "-1300"]) == %{
               "-1100" => %{"rating_below" => 1100},
               "-1200" => %{"rating_from" => 1100, "rating_below" => 1200},
               "-1300" => %{"rating_from" => 1200, "rating_below" => 1300}
             }
    end

    test "two elo_above floors - the larger floor is the tighter one" do
      rules = %{
        "1200+" => %{"kind" => "elo_above", "value" => 1200},
        "1400+" => %{"kind" => "elo_above", "value" => 1400}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["1200+", "1400+"]) == %{
               "1400+" => %{"rating_from" => 1401},
               "1200+" => %{"rating_from" => 1201, "rating_below" => 1401}
             }
    end

    test "two age_below thresholds band on the shifted (FIDE) scale" do
      rules = %{
        "U14" => %{"kind" => "age_below", "value" => 14},
        "U18" => %{"kind" => "age_below", "value" => 18}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["U14", "U18"]) == %{
               "U14" => %{"age_below" => 13},
               "U18" => %{"age_from" => 13, "age_below" => 17}
             }
    end

    test "two age_above floors band on the shifted (FIDE) scale" do
      rules = %{
        "40+" => %{"kind" => "age_above", "value" => 40},
        "50+" => %{"kind" => "age_above", "value" => 50}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["40+", "50+"]) == %{
               "50+" => %{"age_from" => 50},
               "40+" => %{"age_from" => 40, "age_below" => 50}
             }
    end

    test "different literal kinds on the same axis are never banded together" do
      rules = %{
        "-1200" => %{"kind" => "elo_below", "value" => 1200},
        "1200+" => %{"kind" => "elo_above", "value" => 1200}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["-1200", "1200+"]) == %{
               "-1200" => %{"rating_below" => 1200},
               "1200+" => %{"rating_from" => 1201}
             }
    end

    test "a tie (same kind and value) breaks by category_order - the later one matches nobody" do
      rules = %{
        "A" => %{"kind" => "elo_below", "value" => 1200},
        "B" => %{"kind" => "elo_below", "value" => 1200}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["A", "B"]) == %{
               "A" => %{"rating_below" => 1200},
               "B" => %{"rating_from" => 1200, "rating_below" => 1200}
             }
    end
  end

  describe "migrate_legacy_rules/2 - passthrough and defensive cases" do
    test "an already-new-shape entry is left untouched" do
      rules = %{"45+" => %{"age_from" => 45, "women" => true}}
      assert CategoryRules.migrate_legacy_rules(rules, ["45+"]) == rules
    end

    test "a mix of legacy and new-shape entries converts only the legacy ones" do
      rules = %{
        "U18" => %{"kind" => "age_below", "value" => 18},
        "Women" => %{"women" => true}
      }

      assert CategoryRules.migrate_legacy_rules(rules, ["U18", "Women"]) == %{
               "U18" => %{"age_below" => 17},
               "Women" => %{"women" => true}
             }
    end

    test "a hand-assigned category (no rule) does not appear in the result" do
      rules = %{"Open" => %{}}
      assert CategoryRules.migrate_legacy_rules(rules, ["Open"]) == %{}
    end

    test "a category_rules name missing from category_order breaks a tie by sorting last" do
      rules = %{
        "-1100" => %{"kind" => "elo_below", "value" => 1100},
        "Stray" => %{"kind" => "elo_below", "value" => 1100}
      }

      # "Stray" is not in category_order at all (a hand-edited or older
      # backup file could do this) - it must not crash, and an unlisted
      # name is the loosest possible tie-break, same reading
      # `Categories.order/2` already gives an unlisted name elsewhere.
      assert CategoryRules.migrate_legacy_rules(rules, ["-1100"]) == %{
               "-1100" => %{"rating_below" => 1100},
               "Stray" => %{"rating_from" => 1100, "rating_below" => 1100}
             }
    end
  end

  describe "legacy equivalence: the migration reproduces the exact old assignment" do
    # A frozen copy of `PlayerStats`' pre-conversion algorithm, exactly as it
    # read before this feature - removed from lib/ once every tournament's
    # rules are migrated, so it only lives here now, as the yardstick the
    # conversion has to match. `current_year` plays the same role every old
    # caller always passed it: the SAME year the new side's `tournament_year`
    # is given below, so this isolates the conversion arithmetic itself from
    # the real-world year-SOURCE change (today vs the tournament's own
    # derived year) - see `CategoryRules.migrate_legacy_rules/2`'s moduledoc
    # for why that second difference is deliberately out of scope here.
    defp legacy_assign_categories(player, category_order, category_rules, current_year) do
      rating = Player.rating(player)
      age = if player.birth_year, do: current_year - player.birth_year, else: nil
      order_index = category_order |> Enum.with_index() |> Map.new()

      category_order
      |> Enum.map(fn name -> {name, Map.get(category_rules, name)} end)
      |> Enum.filter(fn {_name, rule} ->
        rule != nil and legacy_rule_qualifies?(rule, rating, age)
      end)
      |> Enum.group_by(fn {_name, rule} -> rule["kind"] end)
      |> Enum.map(fn {_kind, matches} ->
        Enum.min_by(matches, fn {_n, r} -> legacy_tightness_key(r) end)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&Map.fetch!(order_index, &1))
    end

    defp legacy_rule_qualifies?(%{"kind" => "elo_below", "value" => v}, rating, _age),
      do: rating < v

    defp legacy_rule_qualifies?(%{"kind" => "elo_above", "value" => v}, rating, _age),
      do: rating > 0 and rating > v

    defp legacy_rule_qualifies?(%{"kind" => "age_below", "value" => v}, _rating, age),
      do: age != nil and age < v

    defp legacy_rule_qualifies?(%{"kind" => "age_above", "value" => v}, _rating, age),
      do: age != nil and age > v

    defp legacy_tightness_key(%{"kind" => "elo_below", "value" => v}), do: v
    defp legacy_tightness_key(%{"kind" => "elo_above", "value" => v}), do: -v
    defp legacy_tightness_key(%{"kind" => "age_below", "value" => v}), do: v
    defp legacy_tightness_key(%{"kind" => "age_above", "value" => v}), do: -v

    test "matrix of ratings x birth years x unrated players x an 8-category, 4-kind tournament" do
      category_order = ["-1100", "-1200", "1800+", "2000+", "U16", "U18", "45+", "55+"]

      legacy_rules = %{
        "-1100" => %{"kind" => "elo_below", "value" => 1100},
        "-1200" => %{"kind" => "elo_below", "value" => 1200},
        "1800+" => %{"kind" => "elo_above", "value" => 1800},
        "2000+" => %{"kind" => "elo_above", "value" => 2000},
        "U16" => %{"kind" => "age_below", "value" => 16},
        "U18" => %{"kind" => "age_below", "value" => 18},
        "45+" => %{"kind" => "age_above", "value" => 45},
        "55+" => %{"kind" => "age_above", "value" => 55}
      }

      year = 2026
      migrated = CategoryRules.migrate_legacy_rules(legacy_rules, category_order)

      ratings = [
        0,
        500,
        1000,
        1099,
        1100,
        1150,
        1199,
        1200,
        1500,
        1800,
        1801,
        1999,
        2000,
        2001,
        2500
      ]

      birth_years = [
        nil,
        1960,
        1965,
        1970,
        1971,
        1975,
        1980,
        1981,
        2005,
        2008,
        2009,
        2010,
        2011,
        2015,
        2026
      ]

      failures =
        for rating <- ratings, birth_year <- birth_years, reduce: [] do
          acc ->
            player =
              struct(Player, fide_rating: rating, national_rating: 0, birth_year: birth_year)

            old_result = legacy_assign_categories(player, category_order, legacy_rules, year)
            new_result = PlayerStats.assign_categories(player, category_order, migrated, year)

            if new_result == old_result do
              acc
            else
              [{rating, birth_year, old_result, new_result} | acc]
            end
        end

      assert failures == [],
             "legacy/new disagreement (rating, birth_year, old, new): #{inspect(Enum.reverse(failures))}"
    end
  end
end
