defmodule PairingsEngine.RatingInboxTest do
  @moduledoc """
  Which rating list a report is for, and how late it is (FIDE B.02
  Art. 9.1, 2024; Art. 4.1 for a tournament of more than 30 days), and
  which tournaments the inbox lists at all. Pure dates and structs: no
  database.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.RatingInbox
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}

  describe "list_status/3" do
    test "a tournament ending mid-month is for the list of the first of next month" do
      status = RatingInbox.list_status(~D[2026-09-15], ~D[2026-09-20])

      assert status.basis == :final
      assert status.list == ~D[2026-10-01]
      assert status.closes == ~D[2026-09-30]
      # The third list after it ended: 1 October, 1 November, 1 December.
      assert status.last_list == ~D[2026-12-01]
      assert status.last_chance == ~D[2026-11-30]
      assert status.level == :normal
    end

    test "five days or fewer to the end of the month: the list after that" do
      # 25 September: 5 days remain.
      assert %{list: ~D[2026-11-01], closes: ~D[2026-10-31]} =
               RatingInbox.list_status(~D[2026-09-25], ~D[2026-09-26])

      # 24 September: 6 days remain, still the list of 1 October.
      assert %{list: ~D[2026-10-01]} = RatingInbox.list_status(~D[2026-09-24], ~D[2026-09-26])

      # The last day itself counts as zero days remaining.
      assert %{list: ~D[2026-11-01]} = RatingInbox.list_status(~D[2026-09-30], ~D[2026-09-30])
    end

    test "the third list is counted from the day it ended, not from the list it was due in" do
      # Ends on the 28th: due a list later than one ending on the 20th, and
      # lost on the same day.
      assert %{last_chance: ~D[2026-11-30]} =
               RatingInbox.list_status(~D[2026-09-28], ~D[2026-09-29])
    end

    test "the rule carries over a year end" do
      assert %{list: ~D[2027-02-01], closes: ~D[2027-01-31], last_chance: ~D[2027-02-28]} =
               RatingInbox.list_status(~D[2026-12-28], ~D[2026-12-29])
    end

    test "on the closing day it is still normal; the day after it goes to a later list" do
      assert %{level: :normal} = RatingInbox.list_status(~D[2026-09-15], ~D[2026-09-30])

      later = RatingInbox.list_status(~D[2026-09-15], ~D[2026-10-01])
      assert later.level == :later
      assert later.lands_in == ~D[2026-11-01]

      assert %{level: :later, lands_in: ~D[2026-12-01]} =
               RatingInbox.list_status(~D[2026-09-15], ~D[2026-11-30])
    end

    test "past the third list it will not be rated" do
      assert %{level: :late, lands_in: nil} =
               RatingInbox.list_status(~D[2026-09-15], ~D[2026-12-01])
    end

    test "an interim report is overdue, never unrated" do
      status = RatingInbox.list_status(~D[2026-10-02], ~D[2027-03-01], :interim)

      assert status.basis == :interim
      assert status.list == ~D[2026-11-01]
      assert status.last_chance == nil
      assert status.level == :later
      assert status.lands_in == ~D[2027-04-01]
    end
  end

  describe "report_day/2" do
    @championship %Tournament{
      start_date: "2026-10-02",
      round_dates: ["2026-10-02", "2026-10-16", "2026-11-06", "2027-03-05", "2027-04-02"]
    }

    test "a tournament of 30 days or fewer is counted from its last day, whatever the month" do
      t = %Tournament{start_date: "2026-09-20", round_dates: ["2026-09-20", "2026-10-04"]}

      assert RatingInbox.report_day(t, ~D[2026-09-01]) == {:final, ~D[2026-10-04]}
      assert RatingInbox.report_day(t, ~D[2026-10-01]) == {:final, ~D[2026-10-04]}
    end

    test "a longer one reports each month's rounds from the last of them" do
      assert RatingInbox.report_day(@championship, ~D[2026-10-01]) == {:interim, ~D[2026-10-16]}
      assert RatingInbox.report_day(@championship, ~D[2026-11-01]) == {:interim, ~D[2026-11-06]}
    end

    test "the month it ends in is the final report" do
      assert RatingInbox.report_day(@championship, ~D[2027-04-01]) == {:final, ~D[2027-04-02]}
    end

    test "an October round of a championship ending in April is not given until April" do
      {basis, day} = RatingInbox.report_day(@championship, ~D[2026-10-01])

      assert %{list: ~D[2026-11-01], closes: ~D[2026-10-31]} =
               RatingInbox.list_status(day, ~D[2026-10-20], basis)
    end

    test "no date at all: nothing to count from" do
      assert RatingInbox.report_day(%Tournament{round_dates: []}, ~D[2026-10-01]) == nil
    end
  end

  describe "listed?/2 and rated?/1" do
    test "a tournament that is not marked FIDE-rated and sent nothing is not listed" do
      refute RatingInbox.listed?(%Tournament{fide_homologated: false}, [])
      refute RatingInbox.rated?(%Tournament{fide_homologated: false})
    end

    test "marked FIDE-rated: listed, receipt or not" do
      assert RatingInbox.listed?(%Tournament{fide_homologated: true}, [])
      assert RatingInbox.rated?(%Tournament{fide_homologated: true})
    end

    test "a sent receipt lists it, and does not make it rated" do
      t = %Tournament{fide_homologated: false}

      assert RatingInbox.listed?(t, [%SentReceipt{kind: "report", round: 1}])
      refute RatingInbox.rated?(t)
    end
  end
end
