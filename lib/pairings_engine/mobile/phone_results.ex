defmodule PairingsEngine.Mobile.PhoneResults do
  @moduledoc """
  Which boards of a round hold a result a Manubrium Lite phone entered, and
  the arbiter's word on each: confirmed, or rejected (cleared).

  The desk has had exactly one notion of a phone's result since phones
  could enter one: the audit row `Mobile.log_result/6` writes, `via:
  "mobile"`, with the code's label. There is no column on the board for it
  and there is no second notion here. A board is "from a phone" when the
  LAST write to its result in the audit trail came from a no-account code
  or an arbiter on the `/m` pages (not from a connected Manubrium app,
  whose rows carry the device - those are the arbiter's own taps), and the
  board still holds what that write put there. It stays unconfirmed until
  an arbiter confirms it (`confirm/5`, one more audit row) or rejects it
  (`reject/5`: the hall's clear, audited as a rejection). A result the desk
  changes afterwards is simply no longer a phone's.

  Reading the audit trail for this is deliberate: it is the record the
  arbiter is asked to confirm, so it cannot disagree with itself.
  """
  import Ecto.Query

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.{Pairing, Tournament}

  @writes ~w(pairing.result_entered pairing.result_changed pairing.result_cleared)
  @verdicts ~w(pairing.result_confirmed pairing.result_rejected)

  @doc """
  The boards of round `round_number` whose result came from a phone, as
  `%{pairing_id => %{label, state, at, to}}` - `state` `"unconfirmed"` or
  `"confirmed"`, `label` the phone as the desk names it, `to` the result
  the phone put there. Boards with a desk result, or none, are absent.
  """
  def by_pairing(tournament_id, round_number) do
    actions = @writes ++ @verdicts

    rows =
      Repo.all(
        from a in AuditLog,
          where:
            a.tournament_id == ^tournament_id and a.action in ^actions and
              fragment("json_extract(?, '$.round')", a.details) == ^round_number,
          order_by: [desc: a.inserted_at, desc: a.id],
          select: {a.action, a.details, a.inserted_at}
      )

    rows
    |> Enum.reduce(%{}, fn {action, details, at}, acc ->
      case details["pairing_id"] do
        id when is_integer(id) and not is_map_key(acc, id) ->
          Map.put(acc, id, verdict(action, details, at))

        _ ->
          acc
      end
    end)
    |> Enum.reject(fn {_id, v} -> is_nil(v) end)
    |> Map.new()
  end

  # The latest row about the board decides: a Lite phone's write is
  # unconfirmed, a confirmation is confirmed, anything else (the desk, an
  # app's own tap, a clear, a rejection) is not a phone's result.
  defp verdict("pairing.result_confirmed", d, at),
    do: %{label: d["phone"], state: "confirmed", at: at, to: d["to"]}

  defp verdict(action, %{"via" => "mobile"} = d, at)
       when action in ["pairing.result_entered", "pairing.result_changed"] do
    if is_nil(d["device_id"]) and (d["to"] || "") != "" do
      %{label: label(d), state: "unconfirmed", at: at, to: d["to"]}
    end
  end

  defp verdict(_action, _details, _at), do: nil

  defp label(%{"enrollment_label" => label}) when is_binary(label) and label != "", do: label
  defp label(%{"enrollment_code" => code}) when is_binary(code), do: "#{code}"
  defp label(_d), do: "phone"

  @doc """
  Confirms the phone's result on `pairing` (round `round_number`) as what
  the arbiter saw: `expected` is the result the phone showed, so a result
  changed meanwhile is `{:conflict, current}`. Writes one audit row and
  nothing else. `{:error, :not_from_phone}` for a board no phone entered.
  """
  def confirm(%Tournament{} = t, scope, %Pairing{} = pairing, round_number, expected) do
    with :ok <- Tournaments.ensure_writable(t),
         :ok <- same_result(pairing, expected),
         {:ok, phone} <- phone_result(t, pairing, round_number) do
      Audit.log(t.id, scope, "pairing.result_confirmed", %{
        pairing_id: pairing.id,
        round: round_number,
        board: pairing.board,
        white: player_name(pairing.white_player),
        black: player_name(pairing.black_player),
        to: pairing.result,
        phone: phone.label,
        via: "mobile"
      })

      {:ok, pairing}
    end
  end

  @doc """
  Rejects the phone's result on `pairing`: the board is cleared
  (`Tournaments.update_pairing_result/3`, where it allows a clear) and the
  audit row says it was a rejection, naming the phone.
  `{:ok, cleared}`, `{:conflict, current}` or `{:error, reason}`.
  """
  def reject(%Tournament{} = t, scope, %Pairing{} = pairing, round_number, expected) do
    with :ok <- Tournaments.ensure_writable(t),
         :ok <- same_result(pairing, expected),
         {:ok, phone} <- phone_result(t, pairing, round_number),
         true <- Tournaments.result_clearable?(pairing) || {:error, :not_clearable},
         {:ok, cleared} <- Tournaments.update_pairing_result(pairing, "") do
      Audit.log(t.id, scope, "pairing.result_rejected", %{
        pairing_id: pairing.id,
        round: round_number,
        board: pairing.board,
        white: player_name(pairing.white_player),
        black: player_name(pairing.black_player),
        from: pairing.result,
        to: "",
        phone: phone.label,
        via: "mobile"
      })

      {:ok, cleared}
    end
  end

  defp phone_result(t, pairing, round_number) do
    case Map.get(by_pairing(t.id, round_number), pairing.id) do
      %{state: "unconfirmed"} = phone -> {:ok, phone}
      _ -> {:error, :not_from_phone}
    end
  end

  defp same_result(%Pairing{result: stored}, expected) do
    if (stored || "") == (expected || ""), do: :ok, else: {:conflict, stored || ""}
  end

  defp player_name(%PairingsEngine.Tournaments.Player{name: name}), do: name
  defp player_name(_), do: nil
end
