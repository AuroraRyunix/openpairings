defmodule PairingsEngineWeb.MobileConnectController do
  @moduledoc """
  The arbiter's own way onto Manubrium (docs/manubrium.md): signed in, with
  an account the tournament knows as its owner, an editor or an arbiter
  (`Tournaments.hall_role/2`).

    * `GET  /m/connect`          - the tournaments this account works in.
    * `POST /m/connect/:id`      - "Use this browser": a code bound to the
      account is made and redeemed here and now.
    * `POST /m/connect/:id/code` - "Show a code for my phone": the same kind
      of code, shown as a QR for another device (the arbiter signed in on a
      laptop, or an iPhone's installed app, which has cookies of its own).

  A code made here belongs to the account: what it enters is audited under
  that account, and it stops working the moment the account is taken off
  the tournament. Nobody mints one for somebody else - the desk's codes are
  the no-account kind, so an arbiter's name never ends up on a phone they
  never held.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Mobile, Tournaments}
  alias PairingsEngineWeb.MobileAuth

  def index(conn, _params) do
    render(conn, :index, tournaments: Tournaments.hall_tournaments(conn.assigns.current_scope))
  end

  def here(conn, %{"id" => id}) do
    with {:ok, enrollment} <- mint(conn, id),
         {:ok, claimed} <- Mobile.claim(enrollment) do
      conn
      |> MobileAuth.put_enrollment(claimed)
      |> redirect(to: ~p"/m/results")
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def code(conn, %{"id" => id}) do
    case mint(conn, id) do
      {:ok, enrollment} ->
        enrollment = PairingsEngine.Repo.preload(enrollment, :tournament)
        render(conn, :code, enrollment: enrollment, link: url(~p"/m/e/#{enrollment.token}"))

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  defp mint(conn, id) do
    scope = conn.assigns.current_scope

    with {tid, ""} <- Integer.parse(to_string(id)),
         role when not is_nil(role) <- Tournaments.hall_role(scope.user, tid) do
      Mobile.create_enrollment_for(scope, tid,
        user_id: scope.user.id,
        label: PairingsEngine.Accounts.User.display_label(scope.user) |> String.slice(0, 60)
      )
    else
      _not_theirs -> {:error, :not_authorized}
    end
  end

  defp refuse(conn, reason) do
    message =
      case reason do
        :too_many_codes ->
          gettext(
            "That is enough new phone codes for one hour. The codes already made still work; wait a while before making more."
          )

        reason when reason in [:archived, :handed_off, :local_mode] ->
          Tournaments.refusal_message(reason, gettext("connecting a phone"))

        :not_authorized ->
          gettext("That tournament is not one you work in.")

        _other ->
          gettext("Could not enrol a phone - please retry.")
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/m/connect")
  end
end
