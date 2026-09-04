defmodule PairingsEngine.BusyWriteTest do
  @moduledoc """
  A locked database must become an answer, never a crash - and never a
  silence. See `PairingsEngine.BusyWrite` for why this exists.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.BusyWrite

  test "passes a successful write straight through" do
    assert BusyWrite.run(fn -> {:ok, :written} end) == {:ok, :written}
  end

  test "a locked database becomes an error the caller can render" do
    for message <- [
          "database is locked",
          "Database Is Locked",
          "database table is locked: pairings",
          "SQLITE_BUSY"
        ] do
      result = BusyWrite.run(fn -> raise RuntimeError, message end)

      assert result == {:error, :database_busy},
             "#{inspect(message)} should have been recognised as a lock"
    end
  end

  test "any other failure is re-raised, not disguised as a busy database" do
    # The dangerous failure mode for this module is over-catching: a genuine
    # bug turned into "the database was busy" is a bug nobody will find.
    assert_raise ArgumentError, "something else entirely", fn ->
      BusyWrite.run(fn -> raise ArgumentError, "something else entirely" end)
    end
  end

  test "the error it returns has a message that says NOT SAVED" do
    text = PairingsEngineWeb.SettingsSupport.error_text(:database_busy)

    assert text =~ "NOT SAVED"
    assert text =~ "Nothing was written"
  end
end
