defmodule PairingsEngineWeb.ManubriumApi.SettingsController do
  @moduledoc """
  The tournament settings an arbiter changes mid-event, from the Manubrium
  app: `PairingsEngineWeb.DeskActions.update_settings/3`, which takes only
  `DeskActions.phone_settings_fields/0` and writes through the Settings
  pages' own `Tournaments.update_tournament/2`, locks and all. Everything
  structural stays a desk page.

  The organiser and editors only (`:desk`); an arbiter reads the settings
  in the tournament and changes none of them.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Tournaments
  alias PairingsEngineWeb.DeskActions
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  @doc """
  PATCH /tournaments/:id/settings - `{settings: {field: value, ...}}`.
  Fields outside the phone's list are ignored, not refused: an older app
  sending a field a newer server dropped should not lose the rest. A
  locked field is the context's refusal (422 with its sentence). Answers
  the settings as they now are.
  """
  def update(conn, %{"id" => id, "settings" => %{} = settings}) do
    with {:ok, t, role} <- Reply.tournament(conn, id, :desk),
         :ok <- writable(conn, t) do
      case DeskActions.update_settings(t, conn.assigns.current_scope, stringify(settings)) do
        {:ok, updated} ->
          json(conn, %{settings: Json.settings(Tournaments.get_tournament!(updated.id), role)})

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  def update(conn, _params),
    do: Reply.error(conn, 400, "bad_request", gettext("A map of settings is needed."))

  defp writable(conn, t) do
    case Tournaments.ensure_writable(t) do
      :ok -> :ok
      {:error, reason} -> {:halt, Reply.refuse(conn, reason)}
    end
  end

  # JSON booleans and numbers as the Settings form would post them; the
  # tie-break list stays a list.
  defp stringify(settings) do
    Map.new(settings, fn
      {"tiebreaks", v} -> {"tiebreaks", v}
      {k, v} when is_boolean(v) or is_number(v) -> {k, to_string(v)}
      {k, v} -> {k, v}
    end)
  end
end
