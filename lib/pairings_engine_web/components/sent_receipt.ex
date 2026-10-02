defmodule PairingsEngineWeb.SentReceipt do
  @moduledoc """
  The words and the two marks for the sent receipt
  (`PairingsEngine.SentReceipts`): the stamp a sent round carries ("Sent
  03-10-2026 14:02 UTC · R5·7F2A") and the red warning when the tournament
  changed since ("Changed since sent (R5·7F2A) — the rating body has the
  old version"), naming each change. Used by the Pairings page and
  Settings, Export, so both say it the same way.
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  @doc "The code, or what stands for it on a send older than receipts."
  def code_text(%{code: code}) when is_binary(code), do: code
  def code_text(_receipt), do: gettext("sent before receipts")

  @doc "When a receipt's send happened, as this app prints a time: 03-10-2026 14:02 UTC."
  def at_text(%DateTime{} = at), do: Calendar.strftime(at, "%d-%m-%Y %H:%M UTC")

  @doc "The stamp: \"Sent 03-10-2026 14:02 UTC · R5·7F2A\"."
  def stamp_text(receipt) do
    gettext("Sent %{at} · %{code}", at: at_text(receipt.sent_at), code: code_text(receipt))
  end

  @doc """
  The stamp's tooltip: who sent it, and the fingerprint and file hash a
  file can be checked against.
  """
  def stamp_title(receipt) do
    [
      receipt.sent_by && gettext("Sent by %{who}", who: receipt.sent_by),
      receipt.origin not in [nil, "sent"] &&
        gettext("Sent from another copy of this tournament"),
      receipt.fingerprint && gettext("Fingerprint %{hash}", hash: receipt.fingerprint),
      receipt.final_sha256 && gettext("File SHA-256 %{hash}", hash: receipt.final_sha256),
      receipt.status == "before_receipts" &&
        gettext(
          "Sent before receipts existed: the file was not kept, so there is no code. A change to a game the record of sent games names is still detected."
        )
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  @doc "The warning's heading."
  def drift_title(receipt) do
    gettext("Changed since sent (%{code}) — the rating body has the old version",
      code: code_text(receipt)
    )
  end

  @doc "One change (`SentReceipts.changes/2`) as a sentence."
  def change_text(%{type: :result_changed} = c) do
    gettext("%{where} (%{game}): sent as %{was}, now %{now}.",
      where: where(c),
      game: game(c),
      was: result(c.was),
      now: result(c.now)
    )
  end

  def change_text(%{type: :postponed_played} = c) do
    gettext(
      "%{where} (%{game}): sent as ? (postponed), played since: %{now}. Not yet sent in a postponed-games file.",
      where: where(c),
      game: game(c),
      now: result(c.now)
    )
  end

  def change_text(%{type: :player_changed} = c) do
    gettext("%{where} (%{game}): %{side} was %{was}, now %{now}.",
      where: where(c),
      game: game(c),
      side: if(c.side == :white, do: gettext("White"), else: gettext("Black")),
      was: c.was || "?",
      now: c.now || "?"
    )
  end

  def change_text(%{type: :colours_changed} = c) do
    gettext("%{where} (%{game}): colours swapped since it was sent.",
      where: where(c),
      game: game(c)
    )
  end

  def change_text(%{type: :game_removed} = c) do
    gettext("%{where}: the game %{game} that was sent is no longer in the tournament.",
      where: where(c),
      game: game(c)
    )
  end

  def change_text(%{type: :game_added} = c) do
    gettext("%{where}: the game %{game} was not in what was sent.",
      where: where(c),
      game: game(c)
    )
  end

  defp where(%{round: round, board: board}) when is_integer(board),
    do: gettext("Round %{round}, board %{board}", round: round, board: board)

  defp where(%{round: round}), do: gettext("Round %{round}", round: round)

  defp game(c), do: "#{c.white || "?"} - #{c.black || gettext("bye")}"

  defp result(""), do: gettext("no result")
  defp result(nil), do: gettext("no result")
  defp result(code), do: code

  @doc "The stamp beside a sent round. Renders nothing without a receipt."
  attr :receipt, :map, default: nil
  attr :id, :string, required: true

  def stamp(assigns) do
    ~H"""
    <span
      :if={@receipt}
      id={@id}
      class={["receipt-stamp", @receipt.status == "before_receipts" && "is-before"]}
      title={stamp_title(@receipt)}
    >
      {stamp_text(@receipt)}
    </span>
    """
  end

  @doc """
  The red warning for a receipt whose round (or postponed-games file)
  changed since it was sent: `status` is `%{receipt:, changes:}`. Renders
  nothing when nothing changed. It never offers to send again: what the
  rating officer holds is corrected with them.
  """
  attr :status, :map, default: nil
  attr :id, :string, required: true

  def drift_warning(assigns) do
    ~H"""
    <div
      :if={@status && @status.changes != []}
      id={@id}
      class="receipt-drift"
      role="alert"
    >
      <strong class="receipt-drift-title">{drift_title(@status.receipt)}</strong>
      <ul class="receipt-drift-list">
        <li :for={{change, i} <- Enum.with_index(@status.changes)} id={"#{@id}-change-#{i}"}>
          {change_text(change)}
        </li>
      </ul>
      <p class="receipt-drift-note">
        {gettext(
          "Nothing is sent again on its own. If the change is right, tell the rating officer; the round stays marked as sent."
        )}
      </p>
    </div>
    """
  end
end
