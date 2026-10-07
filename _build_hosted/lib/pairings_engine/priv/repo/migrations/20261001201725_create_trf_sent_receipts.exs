defmodule PairingsEngine.Repo.Migrations.CreateTrfSentReceipts do
  @moduledoc """
  The sent receipt: one row per send of a round's report (or of a
  postponed-games file) - human-visible proof of exactly what went to the
  rating officer, and what the tournament is compared with to tell whether
  anything rating-relevant changed since (`PairingsEngine.SentReceipts`).

  It sits beside the sent-games record (`trf_sent_games`) and does not
  replace it: that record, its unique index and the locked send remain the
  guard against sending a game twice. A receipt guards nothing; it shows.
  Like the record it is not tournament content, so a restore or a hand-off
  return never touches it.

    * `kind` - `"report"` (a round's own report) or `"postponed"` (the
      postponed-games file); `round` the round (nil for a postponed-games
      file), `period` the rating period of a postponed-games file.
    * `code` - the short code people quote ("R5·7F2A", "P·9C01"), and
      `fingerprint`, the SHA-256 it is cut from: over the games as sent
      (identity, players, colours, result as written), the round and
      `file_sha256`, the hash of the file's bytes before its own receipt
      line was added. `final_sha256` is the hash of the bytes handed out.
    * `games` - what was sent, game by game, so a later change can be named
      rather than only detected.
    * `status` - `"receipt"`, or `"before_receipts"` for a send made before
      receipts existed (below).
    * `origin` - `"sent"` here, or a copy of the tournament that sent it
      (`"import"`, `"handoff"`), as on the sent-games record.

  ## Rounds sent before this migration

  A fingerprint covers the file's bytes, and no file sent before today was
  kept, so no code can be computed for those sends truthfully - and a code
  that is not the file's would be worse than none. Each one gets a row
  marked `"before_receipts"`, with no code and no fingerprint. Its `games`
  are what the sent-games record says went out (each game's identity,
  players' keys and result as sent), which is true and lets a later change
  still be detected; a round known sent only from the marks on its boards
  (sent before the sent-games record existed) has no `games` at all,
  since the boards as they are now are not evidence of what was sent.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    create table(:trf_sent_receipts) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :round, :integer
      add :period, :date
      add :code, :string
      add :fingerprint, :string
      add :file_sha256, :string
      add :final_sha256, :string
      add :games, {:array, :map}
      add :status, :string, null: false, default: "receipt"
      add :origin, :string, null: false, default: "sent"
      add :sent_at, :utc_datetime, null: false
      add :sent_by, :string
      add :sent_by_id, :integer
    end

    create index(:trf_sent_receipts, [:tournament_id, :kind, :round])

    flush()
    backfill()
  end

  def down do
    drop table(:trf_sent_receipts)
  end

  ## ---------- the sends made before receipts ----------
  #
  # Copied here rather than called from `PairingsEngine.SentReceipts`, so a
  # later change to that module cannot change what this migration did.

  defp backfill do
    repo = repo()

    records =
      repo.all(
        from(s in "trf_sent_games",
          order_by: [s.sent_at, s.id],
          select: %{
            tournament_id: s.tournament_id,
            round: s.round,
            kind: s.kind,
            game_uid: s.game_uid,
            white_key: s.white_key,
            black_key: s.black_key,
            sent_as: s.sent_as,
            sent_at: s.sent_at,
            origin: s.origin
          }
        )
      )

    marks =
      repo.all(
        from(p in "pairings",
          join: r in "rounds",
          on: p.round_id == r.id,
          where: not is_nil(p.finalised_at) or not is_nil(p.postponed_reported_at),
          select: %{
            tournament_id: r.tournament_id,
            round: r.number,
            finalised_at: p.finalised_at,
            postponed_reported_at: p.postponed_reported_at
          }
        )
      )

    rows = report_rows(records, marks) ++ postponed_rows(records, marks)

    rows
    |> Enum.chunk_every(200)
    |> Enum.each(&repo.insert_all("trf_sent_receipts", &1))
  end

  defp report_rows(records, marks) do
    reports = Enum.filter(records, &(&1.kind == "report"))
    by_round = Enum.group_by(reports, &{&1.tournament_id, &1.round})

    from_records =
      for {{tid, round}, recs} <- by_round do
        row(tid, "report", round, recs, Enum.max_by(recs, &to_string(&1.sent_at)).sent_at)
      end

    from_marks =
      marks
      |> Enum.filter(&(not is_nil(&1.finalised_at)))
      |> Enum.reject(&Map.has_key?(by_round, {&1.tournament_id, &1.round}))
      |> Enum.group_by(&{&1.tournament_id, &1.round}, & &1.finalised_at)
      |> Enum.map(fn {{tid, round}, ats} ->
        row(tid, "report", round, nil, Enum.min_by(ats, &to_string/1))
      end)

    from_records ++ from_marks
  end

  defp postponed_rows(records, marks) do
    lates = Enum.filter(records, &(&1.kind == "postponed"))
    tournaments = MapSet.new(lates, & &1.tournament_id)

    from_records =
      for {{tid, at}, recs} <- Enum.group_by(lates, &{&1.tournament_id, to_string(&1.sent_at)}) do
        row(tid, "postponed", nil, recs, at)
      end

    from_marks =
      marks
      |> Enum.filter(&(not is_nil(&1.postponed_reported_at)))
      |> Enum.reject(&MapSet.member?(tournaments, &1.tournament_id))
      |> Enum.map(&{&1.tournament_id, to_string(&1.postponed_reported_at)})
      |> Enum.uniq()
      |> Enum.map(fn {tid, at} -> row(tid, "postponed", nil, nil, at) end)

    from_records ++ from_marks
  end

  defp row(tournament_id, kind, round, records, sent_at) do
    %{
      tournament_id: tournament_id,
      kind: kind,
      round: round,
      games: games(records),
      status: "before_receipts",
      origin: origin(records),
      sent_at: at(sent_at)
    }
  end

  defp games(nil), do: nil

  defp games(records) do
    records
    # A game recorded twice (sent before the one-send guard, or from two
    # copies): the latest record says what the rating officer holds last.
    |> Enum.reverse()
    |> Enum.uniq_by(&(&1.game_uid || {&1.round, &1.white_key, &1.black_key}))
    |> Enum.reverse()
    |> Enum.map(fn s ->
      %{
        "game_uid" => s.game_uid,
        "round" => s.round,
        "white_key" => s.white_key,
        "black_key" => s.black_key,
        "sent_as" => s.sent_as
      }
    end)
    |> Jason.encode!()
  end

  defp origin(nil), do: "sent"

  defp origin(records) do
    if Enum.any?(records, &(&1.origin == "sent")), do: "sent", else: hd(records).origin
  end

  # A schemaless query hands a datetime back as SQLite's text; it is
  # written back as a UTC datetime, the way the schema stores one.
  defp at(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp at(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> at()

  defp at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at(at)
      _ -> text |> NaiveDateTime.from_iso8601!() |> at()
    end
  end
end
