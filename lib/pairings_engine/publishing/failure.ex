defmodule PairingsEngine.Publishing.Failure do
  @moduledoc """
  A public-mode send that did not happen, as data.

  `reason` is a `t:PairingsEngine.Publishing.check_failure/0` - the same
  tagged shape the connection check returns, so the words for it live in one
  place (`PairingsEngineWeb.Components.ConnectionStatus`) whether it came
  from the top bar's check or from a publish. What this adds is what the
  tuple has no room for, and what OpenResults' contract ("Error bodies")
  sends beside a code:

    * `retry_after` - seconds, from `rate_limited`'s body or its
      `Retry-After` header. The queue backs off at least this long.
    * `limit` - `tournament_limit`'s `limit` or `snapshot_too_large`'s
      `limit_bytes`. The arbiter is told the number.
    * `stop` - what the contract's desktop table says the queue does:
      `:tournament` stops that tournament until the arbiter tries again,
      `:installation` stops everything until they act (register again, or
      try again), `nil` keeps retrying on the ordinary backoff.

  ## Why the classification is here and not in the drain

  The table is the contract, and "which code stops what" read in two places
  would come apart. `from_rejection/2` is the one reading of it.

  ## What it never carries

  A key. Neither the installation's nor the tournament's - `to_string/1` is
  what reaches the log and the queue's `last_error`, and `encode/1` is what
  reaches the database; both are built from the code and the status alone.
  The server's `detail` sentence is dropped on encode too: it was for logs,
  and the log line has already been written.
  """

  alias PairingsEngine.Publishing

  @enforce_keys [:reason]
  defstruct [:reason, :retry_after, :limit, stop: nil]

  @type t :: %__MODULE__{
          reason: Publishing.check_failure(),
          retry_after: pos_integer() | nil,
          limit: pos_integer() | nil,
          stop: nil | :tournament | :installation
        }

  # The contract's desktop table, "Queue" column.
  @stop_installation ~w(installation_revoked unauthorized address_blocked)
  @stop_tournament ~w(tournament_limit snapshot_too_large not_owner tournament_hidden)

  # Codes that describe this installation or the whole server rather than
  # one tournament. Remembered installation-wide so the top bar can say them
  # without asking again (`Installation.put_state/1`).
  @installation_wide ~w(installation_suspended installation_revoked unauthorized
                        address_blocked publishing_paused registration_closed)

  @doc "A failure that is not an answer from the server."
  @spec new(Publishing.check_failure()) :: t()
  def new(reason), do: %__MODULE__{reason: reason}

  @doc """
  Classifies an answer from the server.

  `extras` is the decoded body's extra fields and the response headers, as
  `%{"retry_after" => ..., "limit" => ..., "limit_bytes" => ...}`. A bare 401
  with no code is read as `unauthorized`: an installation key that the
  server does not recognise is exactly that, whatever sent the answer.
  """
  @spec from_rejection(Publishing.rejection(), map()) :: t()
  def from_rejection({:rejected, _status, _code, _detail} = rejection, extras \\ %{}) do
    code = effective_code(rejection)

    %__MODULE__{
      reason: {:refused, rejection},
      retry_after: positive(extras["retry_after"]),
      limit: positive(extras["limit"] || extras["limit_bytes"]),
      stop:
        cond do
          code in @stop_installation -> :installation
          code in @stop_tournament -> :tournament
          true -> nil
        end
    }
  end

  @doc "The server's code, reading a bare 401 as `unauthorized`."
  @spec effective_code(Publishing.rejection()) :: String.t() | nil
  def effective_code({:rejected, 401, nil, _detail}), do: "unauthorized"
  def effective_code({:rejected, _status, code, _detail}), do: code

  @doc "Whether `failure` describes the installation or the server rather than one tournament."
  @spec installation_wide?(t()) :: boolean()
  def installation_wide?(%__MODULE__{reason: {:refused, rejection}}),
    do: effective_code(rejection) in @installation_wide

  def installation_wide?(%__MODULE__{}), do: false

  @doc """
  The failure as a string for the `last_reason` column. Code and status,
  never a detail sentence and never a key.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = failure) do
    Jason.encode!(%{
      "reason" => encode_reason(failure.reason),
      "limit" => failure.limit,
      "stop" => failure.stop && Atom.to_string(failure.stop)
    })
  end

  @doc """
  Reads `encode/1`'s output back, or nil for anything else - a row written
  before the column existed, or a hand-edited one. Atoms are only ever
  existing ones: a database value must not be able to grow the atom table.
  """
  @spec decode(String.t() | nil) :: t() | nil
  def decode(encoded) when is_binary(encoded) do
    with {:ok, %{"reason" => raw} = map} <- Jason.decode(encoded),
         {:ok, reason} <- decode_reason(raw) do
      %__MODULE__{
        reason: reason,
        limit: positive(map["limit"]),
        stop:
          case map["stop"] do
            "tournament" -> :tournament
            "installation" -> :installation
            _ -> nil
          end
      }
    else
      _ -> nil
    end
  end

  def decode(_), do: nil

  defp encode_reason({:refused, {:rejected, status, code, _detail}}),
    do: %{"state" => "refused", "status" => status, "code" => code}

  defp encode_reason({:unreachable, reason}) when is_atom(reason),
    do: %{"state" => "unreachable", "reason" => Atom.to_string(reason)}

  defp encode_reason({:unreachable, reason}),
    do: %{"state" => "unreachable", "reason" => inspect(reason)}

  defp encode_reason({:unconfigured, detail}) when is_atom(detail),
    do: %{"state" => "unconfigured", "detail" => Atom.to_string(detail)}

  defp encode_reason(other), do: %{"state" => "other", "reason" => inspect(other)}

  defp decode_reason(%{"state" => "refused", "status" => status} = raw) when is_integer(status),
    do: {:ok, {:refused, {:rejected, status, string_or_nil(raw["code"]), nil}}}

  defp decode_reason(%{"state" => "unreachable", "reason" => reason}) when is_binary(reason),
    do: {:ok, {:unreachable, existing_atom(reason)}}

  defp decode_reason(%{"state" => "unconfigured", "detail" => detail}) when is_binary(detail) do
    case existing_atom(detail) do
      atom when is_atom(atom) -> {:ok, {:unconfigured, atom}}
      _ -> :error
    end
  end

  defp decode_reason(_), do: :error

  defp existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp positive(n) when is_integer(n) and n > 0, do: n

  defp positive(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive(n) when is_float(n) and n > 0, do: ceil(n)
  defp positive(_), do: nil

  defimpl String.Chars do
    # The line a log and `last_error` get. Technical on purpose - it is read
    # by whoever is diagnosing, and the arbiter's sentence is built from
    # `reason` at the display layer.
    def to_string(%{reason: {:refused, {:rejected, status, code, _detail}}}),
      do: "the server answered #{status}#{if code, do: " " <> code, else: ""}"

    def to_string(%{reason: {:unreachable, reason}}) when is_exception(reason),
      do: PairingsEngine.Publishing.describe_transport(reason)

    def to_string(%{reason: {:unreachable, reason}}),
      do: PairingsEngine.Publishing.describe_transport(%Req.TransportError{reason: reason})

    def to_string(%{reason: {:unconfigured, detail}}), do: "not sent (#{detail})"
    def to_string(%{reason: other}), do: inspect(other)
  end
end
