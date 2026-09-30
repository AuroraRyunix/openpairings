defmodule PairingsEngine.HallDisplayTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.HallDisplay

  @defaults %{
    "pairings" => true,
    "names" => true,
    "results" => true,
    "standings" => true,
    "standings_top" => 10,
    "page_seconds" => 15,
    "hold_new_round" => true
  }

  describe "resolve/1" do
    test "nil and an empty map are every default, with no announcement" do
      assert HallDisplay.resolve(nil) == @defaults
      assert HallDisplay.resolve(%{}) == @defaults
    end

    test "stored values win over the defaults" do
      stored = %{
        "names" => false,
        "standings_top" => 25,
        "page_seconds" => 30,
        "hold_new_round" => false,
        "announcement" => "Round 5 starts at 14:00."
      }

      assert HallDisplay.resolve(stored) ==
               Map.merge(@defaults, stored)
    end

    test "junk and out-of-range values fall back to the default" do
      stored = %{
        "pairings" => "false",
        "results" => nil,
        "standings_top" => 51,
        "page_seconds" => 4,
        "hold_new_round" => 1,
        "announcement" => 42,
        "something_from_2027" => true
      }

      assert HallDisplay.resolve(stored) == @defaults
      assert HallDisplay.resolve("not a map") == @defaults
      assert HallDisplay.resolve(%{"page_seconds" => 15.5})["page_seconds"] == 15
    end

    test "the range edges are accepted" do
      assert HallDisplay.resolve(%{"page_seconds" => 5, "standings_top" => 50}) ==
               Map.merge(@defaults, %{"page_seconds" => 5, "standings_top" => 50})

      assert HallDisplay.resolve(%{"page_seconds" => 120, "standings_top" => 3}) ==
               Map.merge(@defaults, %{"page_seconds" => 120, "standings_top" => 3})
    end

    test "a blank announcement is omitted, a long one dropped, CRLF normalised" do
      refute Map.has_key?(HallDisplay.resolve(%{"announcement" => "  \r\n "}), "announcement")

      too_long = String.duplicate("x", 501)
      refute Map.has_key?(HallDisplay.resolve(%{"announcement" => too_long}), "announcement")

      assert HallDisplay.resolve(%{"announcement" => " Line one\r\nLine two \n"})["announcement"] ==
               "Line one\nLine two"
    end
  end

  describe "cast/2" do
    defp form(overrides) do
      Map.merge(
        %{
          "pairings" => "true",
          "names" => "true",
          "results" => "true",
          "standings" => "true",
          "standings_top" => "10",
          "page_seconds" => "15",
          "hold_new_round" => "true",
          "announcement" => ""
        },
        overrides
      )
    end

    test "the defaults store as an empty map" do
      assert HallDisplay.cast(nil, form(%{})) == {:ok, %{}}
    end

    test "only what differs from the defaults is stored" do
      assert {:ok, stored} =
               HallDisplay.cast(
                 nil,
                 form(%{"results" => "false", "page_seconds" => "20", "announcement" => "Hi"})
               )

      assert stored == %{"results" => false, "page_seconds" => 20, "announcement" => "Hi"}
    end

    test "an announcement keeps its newlines, trimmed and with CRLF made LF" do
      assert {:ok, %{"announcement" => "Toilets: first floor.\n\nNo phones."}} =
               HallDisplay.cast(
                 nil,
                 form(%{"announcement" => "  Toilets: first floor.\r\n\r\nNo phones.\r\n"})
               )
    end

    test "clearing the announcement removes it" do
      assert HallDisplay.cast(%{"announcement" => "Old"}, form(%{"announcement" => "   "})) ==
               {:ok, %{}}
    end

    test "out-of-range numbers and a too-long announcement are errors" do
      assert {:error, changeset} =
               HallDisplay.cast(
                 nil,
                 form(%{
                   "page_seconds" => "4",
                   "standings_top" => "51",
                   "announcement" => String.duplicate("é", 501)
                 })
               )

      assert changeset.action == :update
      assert Keyword.has_key?(changeset.errors, :page_seconds)
      assert Keyword.has_key?(changeset.errors, :standings_top)
      assert Keyword.has_key?(changeset.errors, :announcement)
    end

    test "500 characters is allowed, counted as characters" do
      text = String.duplicate("é", 500)

      assert {:ok, %{"announcement" => ^text}} =
               HallDisplay.cast(nil, form(%{"announcement" => text}))
    end

    test "a number that is not a whole number is an error, a blank one too" do
      assert {:error, changeset} = HallDisplay.cast(nil, form(%{"page_seconds" => "abc"}))
      assert Keyword.has_key?(changeset.errors, :page_seconds)

      assert {:error, changeset} = HallDisplay.cast(nil, form(%{"standings_top" => ""}))
      assert Keyword.has_key?(changeset.errors, :standings_top)
    end
  end
end
