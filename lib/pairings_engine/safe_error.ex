defmodule PairingsEngine.SafeError do
  @moduledoc """
  Turns an unexpected exception, exit reason, or crash term into text that
  names the KIND of failure without printing the term itself.

  `Exception.message/1` on a `MatchError`, `CaseClauseError`,
  `FunctionClauseError`, etc. quotes whatever value was in scope when the
  match failed - a database row, a parsed file fragment, a name, a whole
  downloaded list. `inspect/1` of a `:DOWN` reason or a generic crash term
  has the same problem. Both are safe for a *known*, bounded error (a
  transport timeout, a status code, a byte count) but never for a
  catch-all `rescue`, `catch`, or `:DOWN` clause, where the term is
  whatever the code happened to be holding.

  Extracted from `PairingsEngine.Federations.BEL.Sync`'s original
  `crashed/4` (written after the 2026-09-14 KBSB roster leak: a `rescue`
  used `Exception.message/1` on a `CaseClauseError` whose term was the
  entire downloaded roster - names and birth years - and it went out in
  the page's error text and the server log) so every sync/import path
  reuses the same fix instead of re-deriving it.
  """

  require Logger

  @doc """
  Logs `context <> " crashed: " <> <exception type> <> <short stacktrace>`
  and returns a safe user-facing sentence naming only the exception's
  type - never `Exception.message/1`, which can quote the term the
  exception failed on.
  """
  @spec crash_message(String.t(), Exception.t(), Exception.stacktrace()) :: String.t()
  def crash_message(context, exception, stacktrace) do
    kind = log_crash(context, exception, stacktrace)
    "#{context} failed unexpectedly (#{kind}). Please try again, or report it."
  end

  @doc """
  Logs a crash the same way `crash_message/3` does, and returns the
  exception's type string, for call sites that only need the log (or want
  to build their own sentence around the type).
  """
  @spec log_crash(String.t(), Exception.t(), Exception.stacktrace()) :: String.t()
  def log_crash(context, exception, stacktrace) do
    kind = inspect(exception.__struct__)

    Logger.error(
      "#{context} crashed: #{kind}\n" <> Exception.format_stacktrace(Enum.take(stacktrace, 5))
    )

    kind
  end

  @doc """
  Safe one-line summary of a process exit/`:DOWN` reason: the atom itself
  when it is one (`:killed`, `:noconnection`, `:normal`, ...) - the shapes
  the OTP kernel itself produces - otherwise the generic "abnormal exit".
  Never `inspect/1` of the raw reason, which for a process that crashed
  mid-computation can be `{%SomeError{}, [stack]}` or a bare term carrying
  whatever data that process was last holding.
  """
  @spec exit_summary(term()) :: String.t()
  def exit_summary(reason) when is_atom(reason), do: inspect(reason)
  def exit_summary(_reason), do: "abnormal exit"
end
