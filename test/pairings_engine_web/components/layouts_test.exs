defmodule PairingsEngineWeb.LayoutsTest do
  use ExUnit.Case, async: true

  alias PairingsEngineWeb.Layouts

  describe "sync_label/1" do
    test "reports 'never synced' when the meta table has no value" do
      assert Layouts.sync_label(nil) == "never synced"
    end

    test "reports 'just now' for a timestamp seconds ago" do
      ts = NaiveDateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

      assert Layouts.sync_label(ts) == "just now"
    end

    test "reports minutes ago" do
      ts =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-5 * 60, :second)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

      assert Layouts.sync_label(ts) == "5 minutes ago"
    end

    test "reports hours ago, singular when exactly one" do
      ts =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-3600, :second)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

      assert Layouts.sync_label(ts) == "1 hour ago"
    end

    test "reports days ago" do
      ts =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-3 * 86_400, :second)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

      assert Layouts.sync_label(ts) == "3 days ago"
    end

    test "reports 'over a month ago' beyond 30 days" do
      ts =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-45 * 86_400, :second)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

      assert Layouts.sync_label(ts) == "over a month ago"
    end

    test "falls back to the raw value if it can't be parsed as a timestamp" do
      assert Layouts.sync_label("not-a-date") == "not-a-date"
    end
  end
end
