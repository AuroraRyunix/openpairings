defmodule PairingsEngineWeb.AccountPreferences do
  @moduledoc """
  The theme and accent an account stores, as attributes for the root
  layout's `<html>` element - how a stored choice reaches a browser that has
  never seen it (see `PairingsEngine.Accounts.Preferences`).

  The theme switch and the accent picker are client-side: the root layout's
  inline script applies whatever this browser's localStorage says, before
  first paint. It cannot know what the ACCOUNT says, so the server writes it
  onto the page -

      <html lang={...} {PairingsEngineWeb.AccountPreferences.html_attrs(assigns[:current_scope])}>

  - and `assets/js/app.js` ("theme and accent stored on the account")
  applies it when it differs from what this browser had.

  Only real values are written. An account that stores nothing (each device
  decides) and a signed-out visitor get no attributes at all, so for them
  nothing about the page changes.
  """

  alias PairingsEngine.Accounts.{Preferences, User}

  @doc """
  `%{"data-account-theme" => ..., "data-account-accent" => ...}` for the
  signed-in account, each only when stored; `%{}` otherwise.
  """
  def html_attrs(%{user: %User{} = user}) do
    %{}
    |> put_if("data-account-theme", user.theme, &Preferences.theme?/1)
    |> put_if("data-account-accent", user.accent, &Preferences.accent?/1)
  end

  def html_attrs(_scope), do: %{}

  defp put_if(attrs, key, value, valid?) do
    if is_binary(value) and valid?.(value), do: Map.put(attrs, key, value), else: attrs
  end
end
