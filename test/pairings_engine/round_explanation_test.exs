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

  describe "equal_alternatives/3 - one item per alternative pairing" do
    # Eight players, two brackets. The 2.0 bracket is five strong - S1 is
    # 1 and 2, S2 is 3, 4 and 5 - and 5 floats down to meet 6.
    defp field, do: for(n <- 1..8, do: player(n, n))

    defp tie(id, opponent, extra \\ %{}) do
      Map.merge(
        %{
          "player" => id,
          "outcome" => "tie",
          "reason" => nil,
          "at" => %{"group" => 2.0, "label" => nil, "lex" => "actual"},
          "fate" => %{"opponent" => opponent, "score" => 1.0},
          "stayed" => true
        },
        extra
      )
    end

    defp two_brackets(top_extra, section_extra \\ %{}) do
      top =
        Map.merge(
          %{
            "group" => 2.0,
            "mdps" => [],
            "residents" => [1, 2, 3, 4, 5],
            "floats" => [5],
            "pairs" => [[1, 3], [2, 4]],
            "heterogeneous" => false,
            "s1" => [1, 2],
            "s2" => [3, 4, 5]
          },
          top_extra
        )

      bottom = %{
        "group" => 1.0,
        "mdps" => [5],
        "residents" => [6, 7, 8],
        "floats" => [],
        "pairs" => [[5, 6], [7, 8]]
      }

      section = Map.merge(%{"category" => nil, "brackets" => [top, bottom]}, section_extra)
      round = %{explanation: %{"engine" => "ainalrami", "version" => 3, "sections" => [section]}}

      [%{brackets: [bracket | _]} = resolved] = RoundExplanation.for_round(round, field())
      {resolved, bracket}
    end

    defp ids(players), do: Enum.map(players, & &1.id)
    defp board_ids(boards), do: Enum.map(boards, fn {a, b} -> {a && a.id, b && b.id} end)

    test "an alternative that touches two boards is one item, and so is one that touches three" do
      {section, bracket} =
        two_brackets(%{
          "float_alternatives" => [
            %{
              "floater" => 5,
              "candidates" => [
                # 4 goes down to meet 6: boards 2-4 and 5-6 are gone.
                tie(4, 6),
                # 1 goes down to meet 7: boards 1-3, 5-6 and 7-8 are gone.
                tie(1, 7),
                # Not a tie, so not an item.
                tie(3, 6, %{"outcome" => "worse"})
              ]
            }
          ]
        })

      assert [two, three] =
               RoundExplanation.equal_alternatives(section, bracket, bracket.float_alternatives)

      assert two.candidate.id == 4
      assert two.kind == :float
      assert ids(two.instead_of) == [5]
      assert ids(two.stayed) == [5]
      assert two.pick == :actual
      assert board_ids([two.proposed]) == [{4, 6}]
      assert board_ids(two.played) == [{2, 4}, {5, 6}]

      assert three.candidate.id == 1
      assert board_ids(three.played) == [{1, 3}, {5, 6}, {7, 8}]
    end

    test "what separates the two is named only where the record shows it" do
      {section, bracket} =
        two_brackets(%{
          "float_alternatives" => [
            %{"floater" => 5, "candidates" => [tie(4, 6), tie(1, 7)]}
          ]
        })

      # 4 is in the bottom half like the floater: which of S2 is left over.
      # 1 is in the top half: it can only leave by an exchange.
      assert [%{step: :bottom_half}, %{step: :exchange}] =
               RoundExplanation.equal_alternatives(section, bracket, bracket.float_alternatives)

      # A played pairing that is not top half against bottom half may have
      # needed an exchange itself, so nothing is claimed about it.
      {section, bracket} =
        two_brackets(%{
          "pairs" => [[1, 2], [3, 4]],
          "float_alternatives" => [%{"floater" => 5, "candidates" => [tie(4, 6)]}]
        })

      assert [%{step: nil, pick: :actual}] =
               RoundExplanation.equal_alternatives(section, bracket, bracket.float_alternatives)
    end

    test "the same candidate under two floaters' questions is the same alternative" do
      # Six in the bracket, 5 and 6 both float; forcing 4 out is one search
      # whichever floater the question was about.
      {section, bracket} =
        two_brackets(%{
          "residents" => [1, 2, 3, 4, 5, 6],
          "floats" => [5, 6],
          "s1" => [1, 2, 3],
          "s2" => [4, 5, 6],
          "float_alternatives" => [
            %{"floater" => 5, "candidates" => [tie(4, 7)]},
            %{"floater" => 6, "candidates" => [tie(4, 7, %{"stayed" => false})]}
          ]
        })

      assert [item] =
               RoundExplanation.equal_alternatives(section, bracket, bracket.float_alternatives)

      assert item.candidate.id == 4
      assert ids(item.instead_of) == [5, 6]
      assert ids(item.stayed) == [5]
      # Two floaters: S1 and S2 are no longer the regulation's, so no step.
      assert item.step == nil
    end

    test "a record from before the subgroups were kept still groups" do
      {section, bracket} =
        two_brackets(%{
          "float_alternatives" => [%{"floater" => 5, "candidates" => [tie(4, 6), tie(1, 7)]}]
        })

      old = %{bracket | s1: [], s2: []}

      assert [%{step: nil, played: [_, _]}, %{step: nil, played: [_, _, _]}] =
               RoundExplanation.equal_alternatives(section, old, old.float_alternatives)
    end

    test "the bye's ties are items too, and which way the order falls is kept" do
      {section, _bracket} =
        two_brackets(%{}, %{
          "bye" => %{
            "holder" => 8,
            "group" => 1.0,
            "candidates" => [
              tie(7, nil, %{
                "fate" => %{"opponent" => nil, "score" => nil},
                "at" => %{"group" => 1.0, "label" => nil, "lex" => "alternative"}
              }),
              tie(6, nil, %{"outcome" => "ineligible", "reason" => "pairing_bye"})
            ]
          }
        })

      # The fixture's 7-8 stands in for the holder's board.
      assert [item] = RoundExplanation.equal_alternatives(section, nil, [section.bye])
      assert item.kind == :bye
      assert item.candidate.id == 7
      assert ids(item.instead_of) == [8]
      assert item.pick == :alternative
      assert board_ids([item.proposed]) == [{7, nil}]
      assert board_ids(item.played) == [{7, 8}]
    end

    test "no ties, no items - and no entries, no crash" do
      {section, bracket} = two_brackets(%{})
      assert RoundExplanation.equal_alternatives(section, bracket, []) == []
      assert RoundExplanation.equal_alternatives(section, nil, [nil]) == []
    end
  end
end
