defmodule PairingsEngineWeb.AccountController do
  @moduledoc """
  The three things on the account page (`PairingsEngineWeb.UserLive.Settings`)
  that a LiveView cannot do by itself:

    * `appearance/2` - the top-bar theme and accent pickers writing through
      to the account. The pickers are client-side (the root layout's inline
      script); `assets/js/app.js` posts each pick here.
    * `export/2` - "Download everything", a zip. A LiveView cannot hand the
      browser a file.
    * `delete/2` - deleting the account, which has to end the session it is
      running in: clear the cookie, drop the remember-me cookie, redirect.
      A LiveView holds a socket, not a conn, so the page validates and then
      submits here (`phx-trigger-action`, the same shape as changing the
      password), and this checks everything again rather than trusting the
      page it came from.

  ## Recent authentication

  `export/2` and `delete/2` require sudo mode (`Accounts.sudo_mode?/1`, a
  sign-in within the last twenty minutes) on a hosted install, exactly as
  changing the address or the password does: a session left open on a
  club laptop must not be enough to carry off every tournament the account
  can open, or to delete it. A local install has no sign-in to repeat -
  whoever can run the binary is the owner - so the export is not gated
  there, and deletion does not exist there at all.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{AccountExport, Accounts, Authz, RateLimit, Tournaments}
  alias PairingsEngineWeb.UserAuth

  @doc """
  POST /users/preferences/appearance - `theme` or `accent`.

  Writes only a dimension the account already stores. `nil` there means
  "each device decides" (see `PairingsEngine.Accounts.Preferences`), and a
  pick in the top bar of one device must not quietly turn that into "every
  device follows this one" - that choice is made on the account page, on
  purpose.

  Always 204 for a request it will not act on, including a signed-out one:
  this is called in the background by a picker that has already done its
  job on the page, and there is nobody to show an error to. It is outside
  `require_authenticated_user` for the same reason - that plug answers a
  signed-out request with a redirect AND a flash, and a background call
  must not leave "You must log in" waiting on the next page.
  """
  def appearance(conn, params) do
    with %{user: %Accounts.User{} = user} <- conn.assigns[:current_scope],
         {key, value} <- appearance_param(params),
         stored when is_binary(stored) <- Map.get(user, key) do
      Accounts.put_user_preference(user, key, value)
    end

    send_resp(conn, 204, "")
  end

  defp appearance_param(%{"theme" => theme}) when is_binary(theme), do: {:theme, theme}
  defp appearance_param(%{"accent" => accent}) when is_binary(accent), do: {:accent, accent}
  defp appearance_param(_params), do: nil

  @doc "GET /users/settings/export - the zip described in `PairingsEngine.AccountExport`."
  def export(conn, _params) do
    scope = conn.assigns.current_scope
    key = Integer.to_string(scope.user.id)

    cond do
      not recently_authenticated?(scope.user) ->
        conn
        |> put_flash(:error, gettext("Confirm it's you first - then download again."))
        |> redirect(to: ~p"/users/settings" <> "#your-data")

      not RateLimit.allow?(:account_export, key) ->
        conn
        |> put_flash(
          :error,
          gettext("That was downloaded several times just now. Try again in a few minutes.")
        )
        |> redirect(to: ~p"/users/settings" <> "#your-data")

      true ->
        RateLimit.record(:account_export, key)
        {filename, zip} = AccountExport.build(scope)

        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, zip)
    end
  end

  @doc """
  POST /users/settings/delete - deletes the account, then signs out.

  Re-checks all four conditions the page already showed, because the page
  is not a gate: a hosted install, a recent sign-in, the address typed out,
  and nothing owned (`Accounts.account_deletion_blockers/1`).
  """
  def delete(conn, params) do
    user = conn.assigns.current_scope.user
    confirmation = get_in(params, ["account", "confirm"])

    cond do
      Authz.local_mode?() ->
        redirect(conn, to: ~p"/users/settings")

      not Accounts.sudo_mode?(user) ->
        conn
        |> put_flash(:error, gettext("Confirm it's you first - then delete the account again."))
        |> redirect(to: ~p"/users/settings" <> "#delete-account")

      not Accounts.account_deletion_confirmed?(user, confirmation) ->
        conn
        |> put_flash(:error, gettext("Type your email address exactly to delete the account."))
        |> redirect(to: ~p"/users/settings" <> "#delete-account")

      true ->
        case Accounts.delete_user_account(user) do
          {:ok, %{tokens: tokens, tournament_ids: tournament_ids}} ->
            UserAuth.disconnect_sessions(tokens)

            Enum.each(
              tournament_ids,
              &Tournaments.broadcast_tournament_change(&1, :collaborators)
            )

            conn
            |> put_flash(:info, gettext("Your account has been deleted."))
            |> UserAuth.log_out_user()

          {:error, {:blocked, _blockers}} ->
            conn
            |> put_flash(
              :error,
              gettext("The account still owns tournaments, so it was not deleted.")
            )
            |> redirect(to: ~p"/users/settings" <> "#delete-account")

          {:error, _reason} ->
            conn
            |> put_flash(:error, gettext("The account could not be deleted. Nothing changed."))
            |> redirect(to: ~p"/users/settings" <> "#delete-account")
        end
    end
  end

  defp recently_authenticated?(user),
    do: Authz.local_mode?() or Accounts.sudo_mode?(user)
end
