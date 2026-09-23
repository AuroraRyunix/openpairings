defmodule Mix.Tasks.Pairings.VclTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Pairings.Vcl

  @tracker Vcl.load()
  @questions @tracker["questions"]

  test "every question of the checklist is answered exactly once" do
    assert Enum.map(@questions, & &1["q"]) == Enum.to_list(1..225)
  end

  test "answers and statuses use the documented vocabulary" do
    for q <- @questions do
      assert q["answer"] in ["Y", "N"], "Q#{q["q"]}: answer #{inspect(q["answer"])}"
      assert q["status"] in ["met", "gap", "check"], "Q#{q["q"]}: status #{inspect(q["status"])}"

      assert is_binary(q["asks"]) and q["asks"] != "",
             "Q#{q["q"]} says nothing about what it asks"

      for side <- ["yes", "no"] do
        branch = q[side]
        assert branch["outcome"] in ["ok", "penalty", "fail", "next"], "Q#{q["q"]} #{side}"

        if branch["outcome"] == "penalty",
          do:
            assert(is_integer(branch["penalty"]) and branch["penalty"] > 0, "Q#{q["q"]} #{side}")
      end
    end
  end

  # A typo in a "next" would silently cut the walk short and make the summary
  # look better than it is.
  test "every next question exists" do
    for q <- @questions, side <- ["yes", "no"], next = q[side]["next"], next != "end" do
      assert next in 1..225, "Q#{q["q"]} #{side} leads to #{inspect(next)}"
    end
  end

  # A "met" answer that costs a failure or a penalty is a contradiction:
  # either the answer or the status is wrong.
  test "no answer marked met costs anything" do
    walk = Vcl.walk(@tracker)
    costly = MapSet.new(walk.fails ++ Enum.map(walk.penalties, &elem(&1, 0)))

    for q <- @questions, q["status"] == "met", q["q"] in costly do
      flunk("Q#{q["q"]} is marked met but its answer costs a failure or a penalty")
    end
  end

  test "the walk starts at question 1 and ends" do
    walk = Vcl.walk(@tracker)
    assert hd(walk.path) == 1
    assert length(walk.path) == length(Enum.uniq(walk.path))
  end

  test "docs/vcl4thp-tracker.md is up to date with the data" do
    expected = Vcl.document(@tracker, Vcl.walk(@tracker))

    assert File.read!("docs/vcl4thp-tracker.md") == expected,
           "run `mix pairings.vcl --write` after editing docs/vcl4thp/tracker.json"
  end
end
