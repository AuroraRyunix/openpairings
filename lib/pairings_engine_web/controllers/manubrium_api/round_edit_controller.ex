defmodule PairingsEngineWeb.ManubriumApi.RoundEditController do
  @moduledoc """
  Changing a paired round from the Manubrium app: the hand edits the
  Pairings page offers (`PairingsEngineWeb.DeskActions.hand_edit/5`),
  finishing them under the pairing checker (`finish_hand_edits/4`), and the
  arbiter's word on a result a Manubrium Lite phone entered
  (`PairingsEngine.Mobile.PhoneResults`).

  Where the desk's dialog asks a question - a round that is not the latest,
  a round already sent, boards that break the pairing rules, a second
  half-point bye, boards the checker would not pair - the answer is `409
  needs_acknowledgement` with `confirm` (the ids) and what the dialog would
  show; the app asks, and sends the same request again with `acknowledged`.
  Nothing is applied on the arbiter's behalf.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Mobile.PhoneResults
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.DeskActions
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  @edit_acks Map.new(
               DeskActions.edit_acknowledgement_ids() ++ [:mpa_pibe],
               &{Atom.to_string(&1), &1}
             )

  @doc """
  POST /tournaments/:id/rounds/:number/edits - `{edit: {kind, ...},
  acknowledged: [...]}`. `kind` is `swap` (`a`, `b`: player ids), `vacate`
  (`player`, `bye_type?`), `bye` (`pairing`), `fill` (`pairing`, `player`),
  `pool_pair` (`a`, `b`, `board?`), `pool_bye` (`player`) or
  `delete` (`pairing`). Answers the round as it now is.
  """
  def edit(conn, %{"id" => id, "number" => number} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, n} <- round_number(conn, number),
         {:ok, round} <- fetch_round(conn, t, n),
         {:ok, action} <- edit_action(conn, params["edit"]) do
      case DeskActions.hand_edit(
             t,
             conn.assigns.current_scope,
             round,
             action,
             acknowledged(params)
           ) do
        {:ok, _} ->
          json(conn, %{
            round: Json.round(Tournaments.get_tournament!(t.id), Tournaments.get_round(t.id, n))
          })

        {:error, {:needs_acknowledgement, ids, info}} ->
          needs_acknowledgement(conn, ids, %{summary: info.summary, warnings: info.warnings})

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  POST /tournaments/:id/rounds/:number/edits/finish - `{acknowledged: [...]}`:
  the pairing checker's verdict on the round's hand edits. Boards it would
  not pair need `mpa_pibe` acknowledged; the answer then carries the PIBE
  line recorded (`pibe`).
  """
  def finish(conn, %{"id" => id, "number" => number} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, n} <- round_number(conn, number),
         {:ok, round} <- fetch_round(conn, t, n) do
      case DeskActions.finish_hand_edits(
             t,
             conn.assigns.current_scope,
             round,
             acknowledged(params)
           ) do
        {:ok, line} ->
          json(conn, %{
            pibe: line,
            round: Json.round(Tournaments.get_tournament!(t.id), Tournaments.get_round(t.id, n))
          })

        {:error, {:needs_acknowledgement, ids, info}} ->
          needs_acknowledgement(conn, ids, %{checker: info})

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  POST /tournaments/:id/rounds/:number/edits/discard - the desk's "Discard
  hand edits": the round as its hand edits found it, and the session
  closed, while nothing in the round is decided. Answers the round.
  """
  def discard(conn, %{"id" => id, "number" => number}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, n} <- round_number(conn, number),
         {:ok, round} <- fetch_round(conn, t, n),
         :ok <- individual(conn, t) do
      case DeskActions.discard_hand_edits(t, conn.assigns.current_scope, round, %{via: "mobile"}) do
        {:ok, _round} ->
          json(conn, %{
            round: Json.round(Tournaments.get_tournament!(t.id), Tournaments.get_round(t.id, n))
          })

        {:error, :no_session} ->
          Reply.refuse(conn, :no_hand_edits)

        {:error, :no_round} ->
          Reply.refuse(conn, :not_paired)

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  POST /tournaments/:id/rounds/:number/boards/:pairing_id/confirm -
  `{expected}`: the arbiter saw the phone's result and it stands.
  """
  def confirm(conn, %{"id" => id, "number" => number, "pairing_id" => pairing_id} = params) do
    verdict(
      conn,
      id,
      number,
      pairing_id,
      params["expected"],
      &PhoneResults.confirm/5,
      "confirmed"
    )
  end

  @doc """
  POST /tournaments/:id/rounds/:number/boards/:pairing_id/reject -
  `{expected}`: the phone's result is wrong; the board is cleared.
  """
  def reject(conn, %{"id" => id, "number" => number, "pairing_id" => pairing_id} = params) do
    verdict(conn, id, number, pairing_id, params["expected"], &PhoneResults.reject/5, "rejected")
  end

  defp verdict(conn, id, number, pairing_id, expected, fun, status) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :hall),
         {:ok, n} <- round_number(conn, number),
         {:ok, round} <- fetch_round(conn, t, n),
         {:ok, pid} <- id_param(conn, pairing_id),
         {:ok, pairing} <- fetch_pairing(conn, round, pid) do
      case fun.(t, conn.assigns.current_scope, pairing, n, expected) do
        {:ok, _pairing} ->
          json(conn, %{status: status})

        {:conflict, current} ->
          conn
          |> put_status(409)
          |> json(%{
            error: "conflict",
            current: current,
            message:
              gettext("Not done: the board now says %{current}, entered elsewhere.",
                current: if(current == "", do: gettext("no result"), else: current)
              )
          })

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  ## ---------- helpers ----------

  defp needs_acknowledgement(conn, ids, extra) do
    {status, code, message} = Reply.describe({:needs_acknowledgement, ids})

    conn
    |> put_status(status)
    |> json(
      Map.merge(%{error: code, message: message, confirm: Enum.map(ids, &to_string/1)}, extra)
    )
  end

  # The edit, as the context takes it, from the app's JSON - ids as numbers,
  # a kind this controller knows, nothing minted from the body.
  defp edit_action(conn, %{"kind" => kind} = e) do
    with {:ok, action} <- parse_edit(kind, e) do
      {:ok, action}
    else
      :error ->
        {:halt, Reply.error(conn, 400, "bad_request", gettext("Not an edit this app knows."))}
    end
  end

  defp edit_action(conn, _e),
    do: {:halt, Reply.error(conn, 400, "bad_request", gettext("An edit is needed."))}

  defp parse_edit("swap", e) do
    with {:ok, a} <- Reply.to_id(e["a"]),
         {:ok, b} <- Reply.to_id(e["b"]),
         do: {:ok, {:swap, a, b}}
  end

  defp parse_edit("vacate", e) do
    with {:ok, p} <- Reply.to_id(e["player"]), do: {:ok, {:vacate, p, e["bye_type"]}}
  end

  defp parse_edit("bye", e) do
    with {:ok, p} <- Reply.to_id(e["pairing"]), do: {:ok, {:bye, p}}
  end

  defp parse_edit("fill", e) do
    with {:ok, pairing} <- Reply.to_id(e["pairing"]),
         {:ok, player} <- Reply.to_id(e["player"]),
         do: {:ok, {:fill, pairing, player}}
  end

  defp parse_edit("pool_pair", e) do
    with {:ok, a} <- Reply.to_id(e["a"]),
         {:ok, b} <- Reply.to_id(e["b"]),
         {:ok, board} <- optional_id(e["board"]),
         do: {:ok, {:pool_pair, a, b, board}}
  end

  defp parse_edit("pool_bye", e) do
    with {:ok, p} <- Reply.to_id(e["player"]), do: {:ok, {:pool_bye, p}}
  end

  defp parse_edit("delete", e) do
    with {:ok, p} <- Reply.to_id(e["pairing"]), do: {:ok, {:delete_pairing, p}}
  end

  defp parse_edit(_kind, _e), do: :error

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(value), do: Reply.to_id(value)

  # Only the ids the write path knows, so a crafted value cannot mint an atom.
  defp acknowledged(%{"acknowledged" => ids}) when is_list(ids),
    do: for(id <- ids, is_binary(id), ack = Map.get(@edit_acks, id), do: ack)

  defp acknowledged(_params), do: []

  defp fetch_round(conn, t, n) do
    case Tournaments.get_round(t.id, n) do
      nil -> {:halt, Reply.refuse(conn, :not_paired)}
      round -> {:ok, round}
    end
  end

  defp fetch_pairing(conn, round, pid) do
    case Enum.find(round.pairings, &(&1.id == pid)) do
      nil ->
        {:halt, Reply.error(conn, 404, "board_gone", gettext("That board no longer exists."))}

      pairing ->
        {:ok, pairing}
    end
  end

  defp round_number(conn, value), do: id_param(conn, value)

  defp id_param(conn, value) do
    case Reply.to_id(value) do
      {:ok, n} -> {:ok, n}
      :error -> {:halt, Reply.error(conn, 400, "bad_request", gettext("Not a number."))}
    end
  end

  # Team events' hand edits count for matches; they stay at the desk, as
  # every other hand edit does (`DeskActions.hand_edit/5`).
  defp individual(conn, t) do
    if Tournament.team?(t) or Tournament.paired_as_teams?(t),
      do: {:halt, Reply.refuse(conn, :team_event)},
      else: :ok
  end
end
