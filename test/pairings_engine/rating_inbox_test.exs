defmodule PairingsEngine.RatingInboxTest do
  @moduledoc """
  Which rating list a report goes to, and how late it is (FIDE B.02
  Art. 9.1, 2024). Pure dates: no database.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.RatingInbox

  describe "list_status/2" do
    test "a tournament ending mid-month goes to that month's list" do
      status = RatingInbox.list_status(~D[2026-09-15], ~D[2026-09-20])

      assert status.target == ~D[2026-09-01]
      assert status.closes == ~D[2026-09-30]
      assert status.last_chance == ~D[2026-11-30]
      assert status.level == :normal
    end

    test "five days or fewer to the end of the month: the next month's list" do
      # 25 September: 5 days remain.
      assert %{target: ~D[2026-10-01], closes: ~D[2026-10-31]} =
               RatingInbox.list_status(~D[2026-09-25], ~D[2026-09-26])

      # 24 September: 6 days remain, still September's.
      assert %{target: ~D[2026-09-01]} = RatingInbox.list_status(~D[2026-09-24], ~D[2026-09-26])

      # The last day itself counts as zero days remaining.
      assert %{target: ~D[2026-10-01]} = RatingInbox.list_status(~D[2026-09-30], ~D[2026-09-30])
    end

    test "the rule carries over a year end" do
      assert %{target: ~D[2027-01-01], closes: ~D[2027-01-31], last_chance: ~D[2027-03-31]} =
               RatingInbox.list_status(~D[2026-12-28], ~D[2026-12-29])
    end

    test "on the closing day it is still normal; the day after it goes to a later list" do
      assert %{level: :normal} = RatingInbox.list_status(~D[2026-09-15], ~D[2026-09-30])

      later = RatingInbox.list_status(~D[2026-09-15], ~D[2026-10-01])
      assert later.level == :later
      assert later.lands_in == ~D[2026-10-01]

      assert %{level: :later, lands_in: ~D[2026-11-01]} =
               RatingInbox.list_status(~D[2026-09-15], ~D[2026-11-30])
    end

    test "past the third list it will not be rated" do
      assert %{level: :late, lands_in: nil} =
               RatingInbox.list_status(~D[2026-09-15], ~D[2026-12-01])
    end
  end
end
