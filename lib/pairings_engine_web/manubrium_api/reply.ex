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

  def describe({:needs_acknowledgement, ids, _info}), do: describe({:needs_acknowledgement, ids})

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

  def describe({:vacant, board}),
    do:
      {409, "vacant_seat",
       gettext(
         "Board %{board} has an empty seat. Fill it, give the remaining player a bye, or empty the board before finishing.",
         board: board
       )}

  def describe(:no_boards),
    do: {409, "no_boards", gettext("Pair at least one board before finishing.")}

  def describe(:no_hand_edits),
    do: {409, "no_hand_edits", gettext("This round has no hand edits open.")}

  def describe(:no_way_back),
    do:
      {409, "no_way_back",
       gettext(
         "These hand edits began on a round that already had results, so there is nothing to go back to. Change the boards by hand, or use the restore point at the desk."
       )}

  def describe(:has_results),
    do:
      {409, "has_results",
       gettext(
         "A result was entered in this round since the hand edits began, so they can no longer be discarded. Change the boards by hand."
       )}

  def describe(:stale),
    do:
      {409, "stale",
       gettext(
         "A player the round would go back to is no longer in the tournament. Change the boards by hand."
       )}

  def describe(:not_in_round),
    do: {422, "not_in_round", gettext("That player or board is not in this round.")}

  def describe(:same_player),
    do: {422, "same_player", gettext("Pick two different players.")}

  def describe(:unknown_edit),
    do: {400, "bad_request", gettext("Not an edit this app knows.")}

  def describe(:unknown_bye_type),
    do: {400, "bad_request", gettext("Not a bye type.")}

  def describe(:bye_type_not_asked),
    do:
      {422, "bye_type_not_asked",
       gettext("This tournament does not ask the bye type; a player is marked absent.")}

  def describe(:already_bye),
    do: {422, "already_bye", gettext("That board is already a bye.")}

  def describe(:not_vacant),
    do: {422, "not_vacant", gettext("That board has no empty seat to resolve.")}

  def describe(:seat_taken),
    do: {422, "seat_taken", gettext("Both seats on that board are taken.")}

  def describe(:not_last_board),
    do: {422, "not_last_board", gettext("Only the round's last board can be removed.")}

  def describe(:board_taken),
    do: {422, "board_taken", gettext("That board number was taken in the meantime.")}

  def describe(:already_seated),
    do: {422, "already_seated", gettext("That player was given a board in the meantime.")}

  def describe(:invalid_player),
    do: {422, "not_in_round", gettext("That player is not in this tournament.")}

  def describe(:not_from_phone),
    do:
      {409, "not_from_phone",
       gettext("That result did not come from a phone, or was dealt with already.")}

  def describe(:not_clearable),
    do: {409, "not_clearable", gettext("That result cannot be cleared from here.")}

  def describe(:unknown_tiebreak),
    do:
      {422, "unknown_tiebreak",
       gettext("Pick tie-breaks from the tournament's own list, each once.")}

  def describe(:photo_exists),
    do: {409, "photo_exists", gettext("That incident already has a photo.")}

  def describe(:photo_too_large),
    do: {413, "photo_too_large", gettext("The photo is too large.")}

  def describe(:not_a_photo),
    do: {415, "not_a_photo", gettext("That is not a JPEG photo.")}

  def describe(:tournament_quota),
    do: {409, "tournament_quota", PairingsEngine.Quotas.message(:tournament_quota)}

  def describe(:too_many_codes),
    do:
      {409, "too_many_codes",
       gettext("There are already %{max} codes. Withdraw one you no longer use first.",
         max: PairingsEngine.BoardLink.max_links()
       )}

  def describe(:lan_unusable),
    do: {409, "lan_unusable", gettext("Boxes on the network cannot connect right now.")}

  def describe(:round_paired),
    do:
      {422, "round_paired",
       gettext(
         "That round is already paired. A paired round's byes are changed on the round itself."
       )}

  def describe(:unknown_bye_kind),
    do: {422, "unknown_bye_kind", gettext("Pick a bye kind this tournament offers.")}

  def describe(:duplicate_player),
    do: {422, "duplicate_player", gettext("That player is already in this tournament.")}

  def describe(:not_in_list),
    do: {404, "not_in_list", gettext("That player is not on the list.")}

  def describe(:unknown_kind),
    do: {422, "unknown_kind", gettext("Pick an incident type from the list.")}

  def describe(:kind_not_allowed),
    do:
      {422, "kind_not_allowed",
       gettext("This phone's code can only call the arbiter; that incident is not its to change.")}

  def describe(:note_too_long),
    do:
      {422, "note_too_long",
       gettext("The note is too long: at most %{max} characters.",
         max: PairingsEngine.Incidents.note_max()
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
