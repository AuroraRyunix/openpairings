defmodule PairingsEngineWeb.MobileEnrollController do
  @moduledoc """
  Enrollment entry points for the no-account mobile result-entry flow:

    * `GET  /m`            - the code-entry page.
    * `POST /m`            - validate a typed numeric code (per-IP rate limited).
    * `GET  /m/e/:token`   - enroll straight from a scanned QR link.
    * `GET  /m/leave`      - drop the enrollment from this browser.

  On success the enrollment is claimed for this phone (`PairingsEngine.Mobile.claim/1`
  - one device per code, either entry path) and stored in the session
  (`PairingsEngineWeb.MobileAuth`), and the browser is sent to
  `PairingsEngineWeb.MobileResultsLive`.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Mobile, RateLimit}
  alias PairingsEngineWeb.{ClientIp, MobileAuth}

  def new(conn, _params), do: render(conn, :new, error: nil, code: "")

  def submit(conn, %{"code" => code}) do
    ip = ClientIp.get(conn)

    cond do
      not RateLimit.allow?(:mobile_enroll, ip) ->
        conn
        |> put_status(429)
        |> render(:new,
          error: gettext("Too many attempts - wait a few minutes, or ask for a fresh code."),
          code: ""
        )

      enrollment = Mobile.get_active_by_code(code) ->
        claim_and_enroll(conn, enrollment, code, fn -> RateLimit.clear(:mobile_enroll, ip) end)

      true ->
        RateLimit.record(:mobile_enroll, ip)
        render(conn, :new, error: gettext("That code is wrong or has expired."), code: code)
    end
  end

  def submit(conn, _params), do: render(conn, :new, error: gettext("Enter your code."), code: "")

  def enroll(conn, %{"token" => token}) do
    case Mobile.get_active_by_token(token) do
      nil ->
        render(conn, :new,
          error: gettext("That enrollment link is invalid or has expired."),
          code: ""
        )

      enrollment ->
        claim_and_enroll(conn, enrollment, "", fn -> :ok end)
    end
  end

  def leave(conn, _params) do
    conn
    |> MobileAuth.clear_enrollment()
    |> redirect(to: ~p"/m")
  end

  # Shared by both entry paths - the QR token and the 6-digit code are the
  # same credential by two routes, so both go through the identical atomic
  # claim (`Mobile.claim/1`) rather than each reimplementing "first phone
  # wins" on its own.
  #
  # `on_success` carries the one thing the two paths do differently once a
  # claim actually succeeds (the code path clears this IP's rate-limit
  # counter; the QR path has none to clear) - everything else, including
  # what happens when the claim LOSES, is identical.
  defp claim_and_enroll(conn, enrollment, code, on_success) do
    case Mobile.claim(enrollment) do
      {:ok, claimed} ->
        on_success.()

        conn
        |> MobileAuth.put_enrollment(claimed)
        |> redirect(to: ~p"/m/results")

      {:error, :already_claimed} ->
        # Not counted as a wrong guess against the rate limit - the code
        # itself was right, it is simply already spoken for, and punishing
        # the honest case (a helper trying the code they were just handed,
        # a moment after someone else already scanned it) is not the
        # problem that limiter exists to stop.
        render(conn, :new,
          error:
            gettext(
              "This code has already been used by another phone - ask your arbiter for a new one."
            ),
          code: code
        )
    end
  end
end
