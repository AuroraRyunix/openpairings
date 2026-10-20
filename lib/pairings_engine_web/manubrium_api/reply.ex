defmodule PairingsEngineWeb.ManubriumApi.Reply do
  @moduledoc """
  How the Manubrium API answers: JSON, and every refusal as

      {"error": "<code>", "message": "<a sentence for the arbiter>"}

  with an HTTP status that says what kind of refusal it is. The code is the
  contract the app matches on; the message is shown as it is. Where the
  desk would stop to ask something, the code says which question
  (`desk_question`) and the message says to answer it at the desk.

  Also the tournament gate every per-tournament route goes through
  (`tournament/3`): one answer, 404, for "no such tournament" and "not
  yours", so a token cannot be used to find out which ids exist; 403 for an
  arbiter asking for something only the desk's roles may do.
  """
  use Gettext, backend: PairingsEngineWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.SettingsSupport

  @doc "Sends `{error, message}` with `status` and halts."
  def error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => code, "message" => message})
    |> halt()
  end

  @doc """
  Sends a refusal for a context `reason`, choosing status, code and
  sentence (`describe/1`).
  """
  def refuse(conn, reason) do
    {status, code, message} = describe(reason)
    error(conn, status, code, message)
  end

  @doc """
  The tournament `id` names, if `conn`'s account may do `need` there:
  `:hall` (owner, editor or arbiter - results and incidents) or `:desk`
  (owner or editor - everything else, `Tournaments.get_authorized_tournament/2`,
  the very gate every desk page uses). `{:ok, tournament, role}`, or the
  conn already answered.
  """
  def tournament(conn, id, need) when need in [:hall, :desk] do
    scope = conn.assigns.current_scope

    with {:ok, id} <- to_id(id),
         role when not is_nil(role) <- Tournaments.hall_role(scope.user, id) do
      case need do
        :hall ->
          case Tournaments.get_tournament(id) do
            %Tournament{} = t -> {:ok, t, role}
            nil -> {:halt, not_found(conn)}
          end

        :desk ->
          case Tournaments.get_authorized_tournament(scope, id) do
            %Tournament{} = t ->
              {:ok, t, role}

            nil ->
              {:halt,
               error(
                 conn,
                 403,
                 "arbiter_role",
                 gettext(
                   "As an arbiter on this tournament you enter results and log incidents; this needs the organiser or an editor."
                 )
               )}
          end
      end
    else
      _ -> {:halt, not_found(conn)}
    end
  end

  defp not_found(conn),
    do: error(conn, 404, "tournament_not_found", gettext("No such tournament on this account."))

  @doc "A positive whole number from a path or body value, or `:error`."
  def to_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  def to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def to_id(_id), do: :error

  @doc """
  `{status, code, message}` for a refusal from a context function.
  """
  def describe(:setup_incomplete),
    do:
      {409, "setup_incomplete",
       gettext("Finish the tournament setup at the desk first (Settings).")}

  def describe({:hand_edits_open, round}),
    do:
      {409, "desk_question",
       gettext(
         "Round %{n} has hand edits that are not finished. Finish them at the desk: their pairings are checked when you do.",
         n: round
       )}

  def describe(:round_robin),
    do:
      {409, "desk_only",
       gettext("A round robin pairs its whole schedule at once. Do that at the desk.")}

  def describe(:team_event),
    do: {409, "desk_only", gettext("Team events are paired at the desk.")}

  def describe({:tpn_question, _rows}),
    do:
      {409, "desk_question",
       gettext(
         "The pairing numbers do not follow the ratings while they can still be corrected. Answer that question at the desk, then pair."
       )}

  def describe({:fide_departure, _kinds}),
    do:
      {409, "desk_question",
       gettext(
         "Pairing this round would take the tournament out of FIDE mode. That is decided at the desk, not from a phone."
       )}

  def describe({:bye_exclusions, _info}),
    do:
      {409, "desk_question",
       gettext(
         "The bye exclusions leave no legal round. Decide at the desk whose exclusion to lift."
       )}

  def describe({:bye_preference_refused, _info}),
    do:
      {409, "desk_question",
       gettext(
         "A player's bye preference cannot be honoured under FIDE rule C2. Change it at the desk, then pair."
       )}

  def describe({:needs_acknowledgement, ids}),
    do:
      {409, "needs_acknowledgement",
       gettext("This needs confirming first: %{what}.",
         what: Enum.map_join(ids, ", ", &to_string/1)
       )}

  def describe({:no_legal_pairing, text}) when is_binary(text),
    do: {422, "no_legal_pairing", text}

  def describe(:engine_busy),
    do: {503, "engine_busy", SettingsSupport.error_text(:engine_busy)}

  def describe(reason) when reason in [:archived, :handed_off],
    do: {409, Atom.to_string(reason), SettingsSupport.error_text(reason)}

  def describe(:local_mode),
    do:
      {409, "phones_off",
       gettext(
         "This computer does not let phones in. Switch on \"Let phones on this network connect\" at the desk."
       )}

  def describe(:not_found), do: {404, "not_found", gettext("Not found.")}
  def describe(:not_paired), do: {404, "not_paired", gettext("That round is not paired.")}

  def describe(%Ecto.Changeset{} = changeset),
    do: {422, "invalid", SettingsSupport.error_text(changeset)}

  def describe(reason) when is_atom(reason),
    do: {422, Atom.to_string(reason), SettingsSupport.error_text(reason)}

  def describe(reason) when is_binary(reason), do: {422, "refused", reason}

  def describe(_reason), do: {422, "refused", gettext("Not done.")}
end
