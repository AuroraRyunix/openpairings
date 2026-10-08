defmodule PairingsEngine.RatingInbox do
  @moduledoc """
  The rating period inbox: for each FIDE rating period (a calendar month,
  `PostponedGames.rating_period/1`), every tournament of this installation
  with something to say about it - what was sent for rating (the sent
  receipts, `PairingsEngine.SentReceipts`), what is missing (a finished
  round of a FIDE-rated tournament, dated in the period, with no receipt),
  and which postponed games are still open - and the deadline.

  ## Which period a thing belongs to

    * a round's report: the month of the round's date (the tournament's
      `round_dates`), else the month it was sent;
    * a postponed-games file: its rating period, else the month it was sent;
    * a missing round or an open postponed game: the month of the round's
      date. A round with no date cannot be placed and is left out; the
      Dates page is where that is fixed.

  ## What it does not do

  It reads; it sends nothing and changes nothing. The file of a send is not
  kept (a receipt holds its code and the file's hash), so the TRF it offers
  is a COPY rebuilt from the tournament as it is now, and `check/2` checks
  that copy. A receipt that changed since it was sent is flagged by
  `SentReceipts.statuses/1`.
  """

  import Ecto.Query

  alias PairingsEngine.{PostponedGames, Repo, SentReceipts, TrfExport}
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}

  @doc """
  The periods, newest first, as `%{period:, deadline:, overdue?:,
  tournaments: [bucket]}`; a bucket is `%{tournament:, sent: [%{receipt:,
  changes:}], missing: [round number], open: [%{round:, pairing:}]}`.
  `today` decides `overdue?`: the deadline has passed and something is
  missing or open.
  """
  def periods(today \\ Date.utc_today()) do
    receipts = Repo.all(from s in SentReceipt, select: s) |> Enum.group_by(& &1.tournament_id)

    tournaments =
      Repo.all(from t in Tournament, where: is_nil(t.deleted_at), order_by: [asc: t.name])

    tournaments
    |> Enum.filter(&(Map.has_key?(receipts, &1.id) or &1.fide_homologated))
    |> Enum.flat_map(&facts(&1, Map.get(receipts, &1.id, [])))
    |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
    |> Enum.map(fn {period, items} -> period(period, items, today) end)
    |> Enum.sort_by(&Date.to_gregorian_days(&1.period), :desc)
  end

  # `{period, tournament, kind, data}` for everything a tournament has.
  defp facts(%Tournament{} = t, receipts) do
    sent =
      if receipts == [] do
        []
      else
        %{reports: reports, postponed: postponed} = SentReceipts.statuses(t.id)

        for status <- Map.values(reports) ++ postponed do
          {receipt_period(t, status.receipt), t, :sent, status}
        end
      end

    sent_rounds =
      for %SentReceipt{kind: "report", round: round} <- receipts, into: MapSet.new(), do: round

    missing =
      for %{state: :ready, round: round} <- PostponedGames.trf_round_states(t),
          not MapSet.member?(sent_rounds, round),
          period = round_period(t, round),
          do: {period, t, :missing, round}

    open =
      for %{round: round} = game <- PostponedGames.open_games(t),
          period = round_period(t, round),
          do: {period, t, :open, game}

    sent ++ missing ++ open
  end

  defp period(period, items, today) do
    deadline = PostponedGames.rating_period(period).deadline

    tournaments =
      items
      |> Enum.group_by(fn {t, _kind, _data} -> t end)
      |> Enum.map(fn {t, rows} ->
        %{
          tournament: t,
          sent: for({_t, :sent, s} <- rows, do: s) |> Enum.sort_by(&sort_key/1),
          missing: for({_t, :missing, r} <- rows, do: r) |> Enum.sort(),
          open: for({_t, :open, g} <- rows, do: g)
        }
      end)
      |> Enum.sort_by(&String.downcase(&1.tournament.name || ""))

    pending? = Enum.any?(tournaments, &(&1.missing != [] or &1.open != []))

    %{
      period: period,
      deadline: deadline,
      overdue?: pending? and Date.compare(today, deadline) == :gt,
      tournaments: tournaments
    }
  end

  defp sort_key(%{receipt: %{kind: kind, round: round, sent_at: at}}),
    do: {if(kind == "report", do: 0, else: 1), round || 0, DateTime.to_unix(at)}

  defp receipt_period(t, %SentReceipt{kind: "report", round: round} = receipt),
    do: round_period(t, round) || month(receipt.sent_at)

  defp receipt_period(_t, %SentReceipt{period: %Date{} = period}),
    do: Date.beginning_of_month(period)

  defp receipt_period(_t, %SentReceipt{} = receipt), do: month(receipt.sent_at)

  defp month(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.beginning_of_month()

  defp round_period(%Tournament{round_dates: dates}, round) when is_integer(round) do
    with text when is_binary(text) <- Enum.at(dates || [], round - 1),
         {:ok, date} <- Date.from_iso8601(String.trim(text)) do
      Date.beginning_of_month(date)
    else
      _ -> nil
    end
  end

  defp round_period(_t, _round), do: nil

  ## ---------- the file, and its check ----------

  @doc """
  The TRF copy for `receipt` (a report receipt): `{:ok, text}` with `rounds`
  the round alone (`:round`) or every round up to it (`:through`, what a
  check needs, since a checker replays a round from the history before it).
  Not the file that was sent: that file is not kept. A postponed-games
  receipt has no copy (`{:error, :no_copy}`): its games are marked sent and
  are no longer offered.
  """
  def trf_copy(%Tournament{}, %SentReceipt{kind: "postponed"}, _scope), do: {:error, :no_copy}

  def trf_copy(%Tournament{} = t, %SentReceipt{round: round}, scope) when is_integer(round) do
    spec = if scope == :through, do: "1-#{round}", else: Integer.to_string(round)

    case TrfExport.export(t, spec, copy: true) do
      {:ok, text} -> {:ok, text}
      {:error, %{message: message}} -> {:error, message}
      # FIDE mode, a postponed game open since (VCL4THP Q169): no TRF at all.
      {:error, {:open_postponed, _games}} -> {:error, :open_postponed}
    end
  end

  def trf_copy(_t, _receipt, _scope), do: {:error, :no_copy}

  @doc """
  Checks `text` (a TRF) with Ainalrami's checker, as `ainalrami -c` does:
  every round re-paired from the history before it, and the standings
  recomputed. Returns `%{status:, output:}`, `status` one of `:match`,
  `:differs`, `:not_replayed` (the file's pairing system is one the checker
  does not replay) or `:error`; `output` the checker's own trace.

  Runs in a process of its own with its output captured, since the checker
  keeps its trace level in the process it runs in. What the checker writes
  to the error stream (the detail of a round that differs) goes to the
  server log, not into `output`.
  """
  def check(text) when is_binary(text) do
    path = Path.join(System.tmp_dir!(), "rating-inbox-#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      {:ok, io} = StringIO.open("")

      task =
        Task.async(fn ->
          Process.group_leader(self(), io)
          Ainalrami.CLI.run(["-c", path])
        end)

      code = Task.await(task, :timer.minutes(5))
      {:ok, {_input, output}} = StringIO.close(io)
      %{status: status(code), output: output}
    after
      File.rm(path)
    end
  end

  defp status(0), do: :match
  defp status(1), do: :differs
  defp status(2), do: :not_replayed
  defp status(_), do: :error
end
