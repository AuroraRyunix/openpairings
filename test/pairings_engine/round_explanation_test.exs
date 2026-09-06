defmodule PairingsEngine.RoundExplanationTest do
  @moduledoc """
  `PairingsEngine.RoundExplanation` reads the stored account back with
  players resolved. Pure: the record is a map, the roster is a list, no
  database. What matters here is the version-2 keys (what a bracket was
  paired FROM) and, just as much, that a version-1 record - every round
  paired before 2026-09-06 - still reads, with those keys empty.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.RoundExplanation

  defp player(id, seed), do: %{id: id, name: "P#{id}", pairing_number: seed}

  defp players, do: [player(11, 1), player(12, 2), player(13, 3), player(14, 4)]

  defp record(bracket_extra, version \\ 2) do
    bracket =
      Map.merge(
        %{
          "group" => 1.0,
          "mdps" => [],
          "residents" => [11, 12, 13, 14],
          "floats" => [],
          "pairs" => [[11, 13], [12, 14]],
          "edge_count" => 2,
          "edges" => [],
          "rungs" => []
        },
        bracket_extra
      )

    %{
      explanation: %{
        "engine" => "ainalrami",
        "version" => version,
        "sections" => [%{"category" => nil, "brackets" => [bracket]}]
      }
    }
  end

  test "version 2: subgroups, colour states and exclusions come back resolved" do
    round =
      record(%{
        "heterogeneous" => false,
        "s1" => [11, 12],
        "s2" => [13, 14],
        "states" => [
          %{
            "player" => 11,
            "colours" => ["w", "w"],
            "whites" => 2,
            "blacks" => 0,
            "difference" => 2,
            "preference" => "b",
            "class" => "absolute",
            "repeated" => "w",
            "floated_last_round" => "down",
            "floated_round_before" => nil
          }
        ],
        "exclusions" => [
          %{"players" => [11, 12], "reason" => "rematch", "round" => 1, "colour" => nil},
          %{"players" => [11, 13], "reason" => "colour", "round" => nil, "colour" => "b"},
          %{"players" => [12, 14], "reason" => "forbidden", "round" => nil, "colour" => nil}
        ]
      })

    [%{brackets: [bracket]}] = RoundExplanation.for_round(round, players())

    refute bracket.heterogeneous?
    assert Enum.map(bracket.s1, & &1.id) == [11, 12]
    assert Enum.map(bracket.s2, & &1.id) == [13, 14]

    # Strings in the JSON, atoms for the panel to match on.
    assert [state] = bracket.states
    assert state.player.id == 11
    assert state.colours == ["w", "w"]
    assert state.difference == 2
    assert state.class == :absolute
    assert state.floated_last_round == :down
    assert state.floated_round_before == nil

    assert [rematch, colour, forbidden] = bracket.exclusions
    assert {rematch.a.id, rematch.b.id, rematch.reason, rematch.round} == {11, 12, :rematch, 1}
    assert {colour.reason, colour.colour} == {:colour, "b"}
    assert forbidden.reason == :forbidden
  end

  test "version 3: the bye's and the floats' alternatives come back resolved" do
    candidate = fn id, extra ->
      Map.merge(
        %{
          "player" => id,
          "outcome" => "worse",
          "reason" => nil,
          "at" => nil,
          "fate" => nil,
          "stayed" => true
        },
        extra
      )
    end

    round =
      record(%{
        "float_alternatives" => [
          %{
            "floater" => 14,
            "candidates" => [
              candidate.(11, %{
                "at" => %{
                  "group" => 1.0,
                  "label" => "C14 downfloat repeat r-1",
                  "actual" => 2,
                  "alternative" => 1,
                  "lex" => nil
                },
                "fate" => %{"opponent" => 13, "score" => 0.5}
              }),
              candidate.(12, %{"outcome" => "impossible", "reason" => "no valid pairing"}),
              candidate.(99, %{})
            ]
          }
        ]
      })

    round =
      put_in(round, [:explanation, "sections", Access.at(0), "bye"], %{
        "holder" => 13,
        "group" => 1.0,
        "candidates" => [candidate.(11, %{"outcome" => "ineligible", "reason" => "pairing_bye"})]
      })

    [%{brackets: [bracket], bye: bye}] = RoundExplanation.for_round(round, players())

    assert [%{floater: %{id: 14}, skipped: nil, candidates: [worse, impossible]}] =
             bracket.float_alternatives

    assert worse.player.id == 11
    assert worse.outcome == :worse
    assert worse.at.label == "C14 downfloat repeat r-1"
    assert worse.fate.opponent.id == 13
    assert impossible.outcome == :impossible
    assert impossible.reason == "no valid pairing"

    assert bye.holder.id == 13
    assert [%{outcome: :ineligible, reason: :pairing_bye}] = bye.candidates
  end

  test "a skipped question keeps its count and has no candidates" do
    round =
      record(%{
        "float_alternatives" => [%{"floater" => 14, "skipped" => "too_many", "count" => 40}]
      })

    [%{brackets: [bracket]}] = RoundExplanation.for_round(round, players())

    assert [%{skipped: "too_many", count: 40, candidates: []}] = bracket.float_alternatives
  end

  test "version 1: a record with none of the new keys reads as empty, not as broken" do
    [%{brackets: [bracket]}] = RoundExplanation.for_round(record(%{}, 1), players())

    refute bracket.heterogeneous?
    assert bracket.s1 == []
    assert bracket.s2 == []
    assert bracket.states == []
    assert bracket.exclusions == []
    assert bracket.float_alternatives == []
    # ...while everything version 1 did carry is still there.
    assert length(bracket.pairs) == 2
  end

  test "version 2: a record without the alternatives reads them as absent" do
    [%{brackets: [bracket], bye: bye}] = RoundExplanation.for_round(record(%{}, 2), players())
    assert bracket.float_alternatives == []
    assert bye == nil
  end

  test "a player the roster no longer has is dropped, never rendered as nil" do
    round =
      record(%{
        "s1" => [11, 99],
        "states" => [%{"player" => 99, "colours" => [], "class" => "none"}],
        "exclusions" => [%{"players" => [11, 99], "reason" => "rematch", "round" => 2}]
      })

    [%{brackets: [bracket]}] = RoundExplanation.for_round(round, players())

    assert Enum.map(bracket.s1, & &1.id) == [11]
    assert bracket.states == []
    assert bracket.exclusions == []
  end
end
