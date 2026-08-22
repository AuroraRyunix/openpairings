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

  alias PairingsEngine.Deploy

  require Logger

  # Ten minutes by default, and capped: this schedules a banner on every
  # connected page, and an accidental `minutes=6000` would leave one up for
  # four days with no way to clear it but a restart.
  @default_minutes 10
  @max_minutes 120

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

  defp seconds(params) do
    case params["minutes"] do
      nil ->
        {:ok, @default_minutes * 60}

      raw ->
        case Integer.parse(to_string(raw)) do
          {m, ""} when m > 0 and m <= @max_minutes -> {:ok, m * 60}
          {_m, ""} -> {:error, "minutes must be 1..#{@max_minutes}"}
          _ -> {:error, "minutes must be an integer"}
        end
    end
  end

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
