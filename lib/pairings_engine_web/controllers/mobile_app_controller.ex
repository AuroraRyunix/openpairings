defmodule PairingsEngineWeb.MobileAppController do
  @moduledoc """
  What keeps `/m` - Manubrium Lite - working through a wifi drop
  (docs/manubrium.md). Lite is a page in the phone's browser, not an app
  to install; that is the full Manubrium's job, so there is no manifest.

    * `GET  /m/sw.js` - the service worker, scope `/m/`.
    * `POST /m/sync`  - the phone's queue of results and incidents, judged
      by `PairingsEngine.Mobile.Sync`.

  The first is the same for everybody and needs no session. The second
  reads the enrolment from the phone's signed session, like
  `/m/results` does, and needs the page's CSRF token like any form post: a
  queued entry is a write, and nothing about being queued makes it a
  cheaper one.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Mobile.Sync

  # Read when this module compiles, so a release carries the worker it was
  # built with and a change to the file recompiles this module.
  @sw_path Path.expand("../../../assets/js/manubrium/sw.js", __DIR__)
  @external_resource @sw_path
  @sw_source File.read!(@sw_path)

  def service_worker(conn, _params) do
    text = %{
      title: gettext("Manubrium Lite is offline"),
      body:
        gettext(
          "This phone has not opened the result page with a connection yet, so there is nothing to show. Connect to the hall wifi once, open the result page, and it keeps working when the wifi drops."
        )
    }

    body =
      @sw_source
      |> String.replace(
        "__MANUBRIUM_VERSION__",
        PairingsEngine.Build.version() <> "-" <> PairingsEngine.Build.ref()
      )
      |> String.replace("__MANUBRIUM_TEXT__", Jason.encode!(text))

    # `no-cache`: the browser revalidates a worker itself, but a proxy in
    # between should not be the reason a phone runs last week's.
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, body)
  end

  def sync(conn, %{"entries" => entries}) when is_list(entries) do
    enrollment_id = get_session(conn, :mobile_enrollment_id)

    case Sync.submit(enrollment_id, entries) do
      {:ok, answers} ->
        json(conn, %{results: Enum.map(answers, &wire/1)})

      {:error, :too_many} ->
        conn
        |> put_status(413)
        |> json(%{error: "too_many", max: Sync.max_batch()})
    end
  end

  def sync(conn, _params) do
    conn |> put_status(400) |> json(%{error: "bad_request"})
  end

  defp wire(answer) do
    %{
      cid: answer.cid,
      status: answer.status,
      reason: answer.reason,
      message: message(answer)
    }
  end

  # The sentence the phone shows beside the board. Always with the board in
  # it: a refusal that does not say which board is a refusal nobody can act
  # on in a hall with forty of them.
  defp message(%{status: :saved, reason: :unchanged, board: board}),
    do: gettext("Board %{board}: already had this result.", board: board || "?")

  defp message(%{status: :saved, kind: "incident", board: board}),
    do: gettext("Board %{board}: incident logged.", board: board || "?")

  defp message(%{status: :saved, board: board}),
    do: gettext("Board %{board}: saved.", board: board || "?")

  defp message(%{status: :retry, board: board}),
    do:
      gettext("Board %{board}: the server is busy - this phone tries again shortly.",
        board: board || "?"
      )

  defp message(%{status: :refused, reason: reason, board: board} = answer),
    do: refusal(reason, board || "?", answer.current)

  defp refusal(:revoked, board, _),
    do:
      gettext(
        "Board %{board}: not saved - this phone's access was ended by the arbiter, or ran out. Tell the arbiter this result.",
        board: board
      )

  defp refusal(:other_code, board, _),
    do:
      gettext(
        "Board %{board}: not saved - it was entered under an earlier code on this phone. Enter it again if it still stands.",
        board: board
      )

  defp refusal(:conflict, board, current),
    do:
      gettext(
        "Board %{board}: not saved - the board now says %{current}, entered elsewhere while this phone was waiting. Check with the arbiter.",
        board: board,
        current: blank_label(current)
      )

  defp refusal(:already_set, board, _),
    do:
      gettext("Board %{board} already has a result - only the arbiter can change it.",
        board: board
      )

  defp refusal(:earlier_round, board, _),
    do:
      gettext(
        "Board %{board}: not saved - that round is no longer the current round, and helpers can only enter the current one.",
        board: board
      )

  defp refusal(:board_out_of_range, board, _),
    do:
      gettext("Board %{board} is outside the boards this phone is allowed to enter.",
        board: board
      )

  defp refusal(:board_changed, board, _),
    do:
      gettext(
        "Not saved: board %{board} changed - the arbiter changed its players. Check who is on it now and enter the result again.",
        board: board
      )

  defp refusal(:board_gone, board, _),
    do:
      gettext(
        "Board %{board}: not saved - that pairing no longer exists (the round was paired again). Check the board and enter it again.",
        board: board
      )

  defp refusal(reason, board, _) when reason in [:archived, :handed_off],
    do:
      gettext(
        "Board %{board}: not saved - the tournament is not taking results at the moment (archived, or handed to another machine).",
        board: board
      )

  defp refusal(:postponed_decisive, board, _),
    do:
      gettext(
        "Board %{board} was postponed and counted provisionally for pairing. A result that is not a draw has to be entered by the arbiter, on the Pairings page.",
        board: board
      )

  defp refusal(:correction_after_pairing, board, _),
    do:
      gettext(
        "A later round was already paired with the result of board %{board}. Correcting it has to be done by the arbiter, on the Pairings page.",
        board: board
      )

  defp refusal(:sent_in_trf, board, _),
    do:
      gettext(
        "Board %{board} was already sent in a TRF finalised for sending. Changing it has to be done by the arbiter, on the Pairings page.",
        board: board
      )

  defp refusal(:kind_not_allowed, board, _),
    do:
      gettext(
        "Board %{board}: not logged - a helper phone can only call the arbiter.",
        board: board
      )

  defp refusal(:incident_cap, board, _),
    do:
      gettext(
        "Board %{board}: not logged - this phone has logged as many incidents as one code may. Ask the arbiter for a new code.",
        board: board
      )

  defp refusal(:photo_too_large, board, _),
    do:
      gettext("Board %{board}: not logged - the photo is too large. Log it again without it.",
        board: board
      )

  defp refusal(:not_a_photo, board, _),
    do:
      gettext(
        "Board %{board}: not logged - the photo could not be read. Log it again without it.",
        board: board
      )

  defp refusal(:note_too_long, board, _),
    do: gettext("Board %{board}: not logged - the note is too long.", board: board)

  defp refusal(_reason, board, _),
    do: gettext("Board %{board}: not saved. Check with the arbiter.", board: board)

  defp blank_label(nil), do: gettext("no result")
  defp blank_label(""), do: gettext("no result")
  defp blank_label(result), do: String.replace(result, "1/2", "½")
end
