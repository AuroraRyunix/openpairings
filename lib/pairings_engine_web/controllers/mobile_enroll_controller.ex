defmodule PairingsEngineWeb.MobileEnrollController do
  @moduledoc """
  Enrollment entry points for the no-account mobile result-entry flow:

    * `GET  /m`            — the code-entry page.
    * `POST /m`            — validate a typed numeric code (per-IP rate limited).
    * `GET  /m/e/:token`   — enroll straight from a scanned QR link.
    * `GET  /m/leave`      — drop the enrollment from this browser.

  On success the enrollment is stored in the session (`PairingsEngineWeb.MobileAuth`)
  and the browser is sent to `PairingsEngineWeb.MobileResultsLive`.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Mobile
  alias PairingsEngine.Mobile.RateLimit
  alias PairingsEngineWeb.MobileAuth

  def new(conn, _params), do: render(conn, :new, error: nil, code: "")

  def submit(conn, %{"code" => code}) do
    ip = ip_string(conn)

    cond do
      not RateLimit.allow?(ip) ->
        conn
        |> put_status(429)
        |> render(:new,
          error: "Too many attempts — wait a few minutes, or ask for a fresh code.",
          code: ""
        )

      enrollment = Mobile.get_active_by_code(code) ->
        RateLimit.clear(ip)

        conn
        |> MobileAuth.put_enrollment(enrollment)
        |> redirect(to: ~p"/m/results")

      true ->
        RateLimit.record_failure(ip)
        render(conn, :new, error: "That code is wrong or has expired.", code: code)
    end
  end

  def submit(conn, _params), do: render(conn, :new, error: "Enter your code.", code: "")

  def enroll(conn, %{"token" => token}) do
    case Mobile.get_active_by_token(token) do
      nil ->
        render(conn, :new, error: "That enrollment link is invalid or has expired.", code: "")

      enrollment ->
        conn
        |> MobileAuth.put_enrollment(enrollment)
        |> redirect(to: ~p"/m/results")
    end
  end

  def leave(conn, _params) do
    conn
    |> MobileAuth.clear_enrollment()
    |> redirect(to: ~p"/m")
  end

  defp ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
