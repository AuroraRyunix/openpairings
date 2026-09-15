defmodule PairingsEngine.SafeErrorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PairingsEngine.SafeError

  # A `CaseClauseError` whose term is the exact shape of the 2026-09-14
  # KBSB leak: a downloaded roster, names and birth years included.
  defp roster_case_clause_error do
    term = %{rows: [%{"Name" => "Peeters, Secret", "Birthday" => 1990}]}

    try do
      case dynamic(term) do
        :never_matches -> :ok
      end
    rescue
      e -> e
    end
  end

  # Defeats the type-checker's ability to prove the `case` below can never
  # match `:never_matches` - the point of this helper is to build a REAL
  # `CaseClauseError` the way one actually happens (an unanticipated runtime
  # shape), not a compile-time-provable dead clause.
  defp dynamic(term), do: term

  describe "crash_message/3" do
    test "the returned user-facing text names only the exception's type" do
      exception = roster_case_clause_error()

      message =
        capture_log(fn ->
          text = SafeError.crash_message("FIDE sync", exception, [])
          send(self(), {:text, text})
        end)
        |> then(fn log ->
          assert_received {:text, text}
          {log, text}
        end)

      {log, text} = message

      assert text =~ "FIDE sync failed unexpectedly"
      assert text =~ "CaseClauseError"
      refute text =~ "Peeters"
      refute text =~ "Secret"
      refute text =~ "1990"

      assert log =~ "FIDE sync crashed: CaseClauseError"
      refute log =~ "Peeters"
      refute log =~ "Secret"
    end

    # Mutation guard: `Exception.message/1` on this exact exception DOES
    # quote the term - proof this test would catch the 0.62.5 shape of bug
    # if `crash_message/3` regressed to using it.
    test "Exception.message/1 on the same exception would have leaked the term" do
      exception = roster_case_clause_error()
      assert Exception.message(exception) =~ "Secret"
    end
  end

  describe "log_crash/3" do
    test "logs the type and a short stacktrace, never the exception's own message" do
      exception = roster_case_clause_error()

      log =
        capture_log(fn ->
          kind = SafeError.log_crash("KBSB import", exception, [])
          send(self(), {:kind, kind})
        end)

      assert_received {:kind, "CaseClauseError"}
      assert log =~ "KBSB import crashed: CaseClauseError"
      refute log =~ "Peeters"
      refute log =~ "Secret"
    end
  end

  describe "exit_summary/1" do
    test "an atom reason is shown as-is" do
      assert SafeError.exit_summary(:killed) == ":killed"
      assert SafeError.exit_summary(:noconnection) == ":noconnection"
    end

    test "a non-atom reason (which can carry arbitrary data) is never inspected" do
      reason = {:shutdown, %{last_row: %{"Name" => "Peeters, Secret"}}}

      assert SafeError.exit_summary(reason) == "abnormal exit"
    end
  end
end
