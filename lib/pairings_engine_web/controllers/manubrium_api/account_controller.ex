defmodule PairingsEngineWeb.ManubriumApi.AccountController do
  @moduledoc """
  The Manubrium app and its account: trading a connect code for a device
  token (`connect/2`, the one route without a bearer), who the token is
  (`me/2`), and signing the phone out (`sign_out/2`). The token model is
  `PairingsEngine.Manubrium`'s moduledoc.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Authz, Manubrium}
  alias PairingsEngineWeb.ManubriumApi.Reply

  @doc "POST /connect - `{secret, name?, platform?}` -> `{token, device, user, server}`."
  def connect(conn, %{"secret" => secret} = params) when is_binary(secret) do
    case Manubrium.redeem(secret, params, PairingsEngineWeb.ClientIp.get(conn)) do
      {:ok, device, token} ->
        device = PairingsEngine.Repo.preload(device, :user)

        conn
        |> put_status(201)
        |> json(%{
          token: token,
          device: device_json(device),
          user: user_json(device.user),
          server: server_json()
        })

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "600")
        |> Reply.error(429, "rate_limited", gettext("Too many refused codes. Wait ten minutes."))

      {:error, :invalid} ->
        Reply.error(
          conn,
          401,
          "invalid_code",
          gettext(
            "That code is not valid: it was used already, it ran out, or it was mistyped. Make a new one on the account page."
          )
        )
    end
  end

  def connect(conn, _params),
    do: Reply.error(conn, 400, "bad_request", gettext("A connect code is needed."))

  @doc "GET /me - the account and device behind the token."
  def me(conn, _params) do
    device = conn.assigns.device

    json(conn, %{
      device: device_json(device),
      user: user_json(device.user),
      server: server_json()
    })
  end

  @doc "DELETE /me - signs this phone out: the token stops working, now."
  def sign_out(conn, _params) do
    {:ok, _device} = Manubrium.revoke(conn.assigns.device)
    send_resp(conn, 204, "")
  end

  defp device_json(device),
    do: %{id: device.id, name: device.name, platform: device.platform}

  defp user_json(user),
    do: %{email: user.email, name: Map.get(user, :display_name)}

  defp server_json do
    %{
      name: "OpenPairings",
      version: to_string(Application.spec(:pairings_engine, :vsn)),
      api: 1,
      desktop: Authz.local_mode?()
    }
  end
end
