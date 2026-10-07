defmodule PairingsEngine.ResultCorrections do
  @moduledoc """
  The TEC Manual's Correction PIBE (VCL4THP Q112-Q115, Q217): a result
  changed after a later round has been paired. The pairing of that later
  round was made with the old result, so the correction is a pairing
  integrity breaching event - identified, confirmed, restorable and logged:

    * `correction?/2` says whether a result write is one. The write path
      (`Tournaments.update_pairing_result/3`) then waits for the arbiter's
      explicit confirmation (`:result_correction`, a Level-3 warning), and
      the pairings page takes a restore point (`Snapshots.capture/4`) before
      it writes and logs it as `pibe.correction`, carrying the `###` text.
    * the board keeps the result it had before its first correction
      (`Pairing.corrected_from`, `corrected_from/2`), so the TRF can write
      `### Correction @ Round r: a-b: old => new` from the boards
      themselves (`lines/2`), not from the audit trail.

  A board given a result for the first time (it was blank), and a postponed
  game given its result, are not corrections: the first is a missing
  result, the second the postponed-games feature's own warning (Q163).
  Clearing a result is not one either - it has its own confirmation - but
  it remembers the result cleared, so the result entered next is one.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Results}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  @doc """
  Whether writing `result` to the board `stored` (as it is in the database)
  is a correction: a real result replacing a real result - or one cleared
  since - in a round older than the latest paired round (`closed?/1`).
  """
  def correction?(%Pairing{} = stored, result) do
    real?(result) and result != stored.result and
      (real?(stored.result) or real?(stored.corrected_from)) and
      not restored_after_clear?(stored, result) and closed?(stored)
  end

  # A board cleared and given back the very result it had: nothing changed.
  defp restored_after_clear?(stored, result),
    do: stored.result in ["", nil] and result == stored.corrected_from

  @doc """
  The `corrected_from` the board keeps once `result` is written over
  `stored` in a round that is closed (`closed?/1`): the
  result it had before its FIRST correction, or nil when `result` puts that
  one back. `stored.corrected_from` unchanged when the write is not part of
  a correction.
  """
  def corrected_from(%Pairing{} = stored, result) do
    original = stored.corrected_from || stored.result

    cond do
      not real?(original) -> stored.corrected_from
      result == stored.result -> stored.corrected_from
      not closed?(stored) -> stored.corrected_from
      result == original -> nil
      result in ["", nil] -> original
      real?(result) -> original
      true -> stored.corrected_from
    end
  end

  @doc """
  The text of the `###` line for a correction of the board `pairing` (with
  both players, or their pairing numbers, at hand) from `old` to `new`, in
  round `round_number` - without the `### `. Also what the audit trail
  records for it.
  """
  def line(round_number, white_rank, black_rank, old, new),
    do: "Correction @ Round #{round_number}: #{white_rank}-#{black_rank}: #{old} => #{new}"

  @doc """
  Every Correction PIBE line of `tournament_id` in `rounds`, in round and
  board order: each board whose result differs from the one it had before
  it was corrected.
  """
  def lines(tournament_id, rounds) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        join: w in Player,
        on: w.id == p.white_player_id,
        join: b in Player,
        on: b.id == p.black_player_id,
        where:
          r.tournament_id == ^tournament_id and r.number in ^rounds and
            not is_nil(p.corrected_from) and p.corrected_from != p.result,
        order_by: [r.number, p.board, p.id],
        select: {r.number, w.pairing_number, b.pairing_number, p.corrected_from, p.result}
    )
    |> Enum.map(fn {round, w, b, old, new} ->
      line(round, w, b, old, if(new in [nil, ""], do: "none", else: new))
    end)
  end

  defp real?(code),
    do: is_binary(code) and code not in ["", "bye"] and not Results.postponed?(code)

  @doc """
  Whether the board's round is closed for this purpose: a later round has
  been paired, with the results the board had then.
  """
  def closed?(%Pairing{round_id: round_id}) do
    case Repo.one(
           from r in Round,
             join: o in Round,
             on: o.tournament_id == r.tournament_id,
             where: r.id == ^round_id,
             group_by: r.number,
             select: {r.number, max(o.number)}
         ) do
      {number, latest} when is_integer(number) and is_integer(latest) -> number < latest
      _ -> false
    end
  end
end
