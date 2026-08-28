defmodule PairingsEngineWeb.DeployController do
  @moduledoc """
  The deploy script's way of telling the running release it is about to be
  restarted, so every open page can warn before the socket drops.

  HTTP rather than `bin/app rpc` on purpose: `rpc` needs a release with a
  known node name and cookie, and this app is also run straight from `mix`
  in some environments. A localhost POST works either way and needs no
  Erlang distribution.

  **Fails closed.** With no `DEPLOY_NOTICE_TOKEN` configured, every request
  is refused rather than allowed - an unset variable in production must not
  silently open an endpoint that can put a banner on every user's screen.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Deploy, Notice}

  require Logger

  # Ten minutes by default, and capped: this schedules a banner on every
  # connected page, and an accidental `minutes=6000` would leave one up for
  # four days with no way to clear it but a restart.
  @default_minutes 10
  @max_minutes 120

  # `seconds` exists for the deploy script's --fast path, where the whole
  # point is a warning shorter than a minute. Floored at 10 rather than 1: a
  # countdown nobody can read before it fires is not a warning, it is a
  # flicker, and the page still has to receive and render the thing.
  @min_seconds 10
  @max_seconds @max_minutes * 60

  def notice(conn, params) do
    with :ok <- authorize(conn),
         {:ok, seconds} <- seconds(params) do
      {:ok, restart_at} = Deploy.announce(seconds)

      Logger.info("Deploy notice: restart announced for #{DateTime.to_iso8601(restart_at)}")
      json(conn, %{ok: true, restart_at: DateTime.to_iso8601(restart_at)})
    else
      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "unauthorized"})

      {:error, message} ->
        conn |> put_status(:bad_request) |> json(%{ok: false, error: message})
    end
  end

  def cancel(conn, _params) do
    case authorize(conn) do
      :ok ->
        Deploy.cancel()
        Logger.info("Deploy notice: withdrawn")
        json(conn, %{ok: true})

      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "unauthorized"})
    end
  end

  # `seconds` wins over `minutes` when both are given, since it is the more
  # specific of the two.
  defp seconds(%{"seconds" => raw}) do
    case Integer.parse(to_string(raw)) do
      {s, ""} when s >= @min_seconds and s <= @max_seconds -> {:ok, s}
      {_s, ""} -> {:error, "seconds must be #{@min_seconds}..#{@max_seconds}"}
      _ -> {:error, "seconds must be an integer"}
    end
  end

  defp seconds(%{"minutes" => raw}) do
    case Integer.parse(to_string(raw)) do
      {m, ""} when m > 0 and m <= @max_minutes -> {:ok, m * 60}
      {_m, ""} -> {:error, "minutes must be 1..#{@max_minutes}"}
      _ -> {:error, "minutes must be an integer"}
    end
  end

  defp seconds(_params), do: {:ok, @default_minutes * 60}

  ## ---------- the plain notice ----------

  # A different thing from the restart countdown above, sharing this
  # controller only because it shares the token: both can put a banner on
  # every screen, so both are the same privilege, and inventing a second
  # secret to configure would be worse than reusing this one.
  #
  # No cap to match `@max_minutes` here. That cap exists because a restart
  # countdown is a promise about a specific imminent event and a typo would
  # leave a false one up for days. This says whatever it is told and stops
  # when it is told to, so a long horizon is the point rather than a
  # mistake - "we are pushing the new system tomorrow morning" is a week's
  # notice at most, and is exactly what it is for.
  def announce(conn, params) do
    with :ok <- authorize(conn),
         {:ok, message} <- message(params),
         {:ok, until} <- until(params),
         {:ok, notice} <- Notice.put(message, until) do
      Logger.info("Site notice set until #{DateTime.to_iso8601(notice.until)}: #{notice.message}")

      json(conn, %{
        ok: true,
        message: notice.message,
        until: DateTime.to_iso8601(notice.until)
      })
    else
      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "unauthorized"})

      {:error, message} ->
        conn |> put_status(:bad_request) |> json(%{ok: false, error: message})
    end
  end

  def withdraw(conn, _params) do
    case authorize(conn) do
      :ok ->
        Notice.clear()
        Logger.info("Site notice withdrawn")
        json(conn, %{ok: true})

      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "unauthorized"})
    end
  end

  defp message(%{"message" => raw}) when is_binary(raw) do
    case String.trim(raw) do
      "" -> {:error, "message is required"}
      # Long enough for two sentences, short enough to stay one banner line
      # on a laptop. A notice that wraps to three lines over a results table
      # is a notice people close.
      trimmed when byte_size(trimmed) > 200 -> {:error, "message must be 200 characters or fewer"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp message(_params), do: {:error, "message is required"}

  # `hours` is the unit an announcement is actually made in. `until` takes an
  # explicit ISO 8601 instant for the case where the deadline is a wall-clock
  # time somebody has already told people about.
  defp until(%{"until" => raw}) do
    case DateTime.from_iso8601(to_string(raw)) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, "until must be an ISO 8601 timestamp"}
    end
  end

  defp until(%{"hours" => raw}) do
    case Float.parse(to_string(raw)) do
      {h, ""} when h > 0 and h <= 336 ->
        {:ok, DateTime.add(DateTime.utc_now(), round(h * 3600), :second)}

      {_h, ""} ->
        {:error, "hours must be between 0 and 336 (two weeks)"}

      _ ->
        {:error, "hours must be a number"}
    end
  end

  defp until(_params), do: {:error, "one of hours or until is required"}

  defp authorize(conn) do
    configured = Application.get_env(:pairings_engine, :deploy_notice_token)

    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> nil
      end

    cond do
      is_nil(configured) or configured == "" ->
        Logger.warning("Deploy notice refused: DEPLOY_NOTICE_TOKEN is not configured")
        :unauthorized

      is_nil(presented) ->
        :unauthorized

      # Constant time, so a wrong token cannot be narrowed down by timing it.
      Plug.Crypto.secure_compare(presented, configured) ->
        :ok

      true ->
        :unauthorized
    end
  end
end
