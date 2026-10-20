defmodule PairingsEngineWeb.MobileEnrollController do
  @moduledoc """
  Enrollment entry points for the no-account mobile result-entry flow:

    * `GET  /m`            - the code-entry page.
    * `POST /m`            - validate a typed numeric code, or a pasted QR
      link (per-IP rate limited).
    * `GET  /m/e/:token`   - the page a scanned QR opens: one button.
    * `POST /m/e/:token`   - that button: enrol this browser.
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

      enrollment = by_code_or_link(code) ->
        claim_and_enroll(conn, enrollment, code)

      true ->
        RateLimit.record(:mobile_enroll, ip)
        render(conn, :new, error: gettext("That code is wrong or has expired."), code: code)
    end
  end

  def submit(conn, _params), do: render(conn, :new, error: gettext("Enter your code."), code: "")

  # A scanned QR used to enrol the browser on the GET. Two things were wrong
  # with that. A link checker, a chat preview or a QR app that "looks ahead"
  # fetched it first and burnt the one claim, leaving the phone with "already
  # used". And on an iPhone the scan opens Safari, which then held the
  # enrolment the installed app never sees. Now the GET only asks: one tap
  # connects this browser, and the page shows the link to paste into the
  # installed app instead.
  def enroll(conn, %{"token" => token}) do
    case Mobile.get_active_by_token(token) do
      nil ->
        render(conn, :new,
          error: gettext("That enrollment link is invalid or has expired."),
          code: ""
        )

      %{claimed_at: claimed} when not is_nil(claimed) ->
        render(conn, :new,
          error:
            gettext(
              "This code has already been used by another phone - ask your arbiter for a new one."
            ),
          code: ""
        )

      enrollment ->
        enrollment = PairingsEngine.Repo.preload(enrollment, [:tournament, :user])
        render(conn, :confirm, enrollment: enrollment, link: current_url(conn))
    end
  end

  def redeem(conn, %{"token" => token}) do
    case Mobile.get_active_by_token(token) do
      nil ->
        render(conn, :new,
          error: gettext("That enrollment link is invalid or has expired."),
          code: ""
        )

      enrollment ->
        claim_and_enroll(conn, enrollment, "")
    end
  end

  # The code box takes the eight digits, or the whole link from the QR code
  # pasted in - the installed app's way to use a QR its camera never saw.
  @link_token ~r"/m/e/([A-Za-z0-9_-]{16,64})"

  defp by_code_or_link(text) when is_binary(text) do
    case Regex.run(@link_token, text) do
      [_, token] -> Mobile.get_active_by_token(token)
      nil -> Mobile.get_active_by_code(text)
    end
  end

  defp by_code_or_link(_text), do: nil

  def leave(conn, _params) do
    conn
    |> MobileAuth.clear_enrollment()
    |> redirect(to: ~p"/m")
  end

  # Shared by both entry paths - the QR token and the 8-digit code are the
  # same credential by two routes, so both go through the identical atomic
  # claim (`Mobile.claim/1`) rather than each reimplementing "first phone
  # wins" on its own.
  #
  # A success used to wipe this address's count of wrong guesses. Which
  # sounds kind, until an account mints its own codes and redeems one
  # between every seven guesses: the limit then reset itself on demand,
  # and the whole eight-digit space was open to anyone patient with a
  # tournament of their own. Wrong guesses now age out of their window and
  # nothing else; an honest phone that typed one digit wrong has seven
  # more tries, which is plenty for a person and nothing for a script.
  defp claim_and_enroll(conn, enrollment, code) do
    case Mobile.claim(enrollment) do
      {:ok, claimed} ->
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
