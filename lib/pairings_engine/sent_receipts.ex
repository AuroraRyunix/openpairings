defmodule PairingsEngine.SentReceipts do
  @moduledoc """
  The sent receipt: for every send of a round's report and of a
  postponed-games file, a record of exactly what went to the rating officer,
  a short code people can quote ("R5·7F2A", "P·9C01"), and the check that
  tells whether anything rating-relevant changed in the tournament since.

  ## What it is not

  It is not a guard. That a game is never sent twice is decided by the
  sent-games record, its unique index and the locked send
  (`PairingsEngine.PostponedGames`); a receipt is written inside that same
  send transaction, after the record landed, and changes nothing about when
  a send is allowed. It adds proof a person can see, and drift detection.
  Nothing here ever sends anything again: a round that changed since it was
  sent is shown in red, and what to do about it stays the arbiter's call.

  ## The fingerprint and the code

  The fingerprint is a SHA-256 over, in a fixed order:

    * the kind of file and its round (or rating period);
    * every game as sent, ordered by its identity (`game_uid`): its round,
      both players (FIDE ID and name, so colours are in it too) and the
      result as sent (`"?"` for a postponed game still open, which the
      file for rating writes as not played and the postponed-games file
      rates later; it was written as `?` before that);
    * the SHA-256 of the file's bytes (until the file for rating held only
      records, a receipt line was added to it after hashing).

  Board numbers are not in it: a TRF has none. The same games, round and
  file always give the same fingerprint (`fingerprint/4`). The code is the
  round ("R5") or "P" for a postponed-games file, a middle dot, and the
  fingerprint's first four hex digits in capitals; six (then eight) when
  four would repeat a code the tournament already has.

  Inside the TRF the code is written with a hyphen ("R5-7F2A"), because
  every line of a file that leaves the building is ASCII (`file_code/1`).

  ## Drift

  `round_status/2` and `drift/1` compare the latest receipt of each round
  (and every postponed-games receipt) with the tournament as it is now:
  a result corrected, a postponed game sent as `?` and played since but not
  yet in a postponed-games file, a player's FIDE ID or name changed, colours
  swapped, a game removed or added. Each is named (`changes`), never fixed.

  ## Sends made before receipts

  A send made before this feature has a receipt marked `"before_receipts"`:
  no code, because the file it covered was not kept and a code must be the
  file's (see the migration). Its games are the sent-games record's, so a
  change is still detected where the record names the game.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Results}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, SentReceipt, TrfSentGame}

  @version "openpairings-receipt-1"

  ## ---------- the games as sent ----------

  @doc """
  One game as a receipt holds it: a plain map with string keys (stored as
  JSON and carried by backups as it is), `sent_as` the result as written.
  `pairing` has both players preloaded.
  """
  def game_entry(round, %Pairing{} = pairing, sent_as) do
    %{
      "game_uid" => pairing.game_uid,
      "round" => round,
      "board" => pairing.board,
      "white_key" => PairingsEngine.PostponedGames.player_key(pairing.white_player),
      "black_key" => PairingsEngine.PostponedGames.player_key(pairing.black_player),
      "white_name" => name(pairing.white_player),
      "black_name" => name(pairing.black_player),
      "white_fide_id" => fide_id(pairing.white_player),
      "black_fide_id" => fide_id(pairing.black_player),
      "sent_as" => sent_as
    }
  end

  defp name(%Player{name: name}) when is_binary(name), do: String.trim(name)
  defp name(_), do: nil

  defp fide_id(%Player{fide_id: id}) when is_integer(id) and id > 0, do: id
  defp fide_id(_), do: nil

  @doc """
  The sent-games record's `sent_as` for a stored result: `"?"` for a
  postponed game still open - not rated in that send (the file for rating
  writes it as not played, `0000 - Z`), its result going in the
  postponed-games file - the stored code otherwise.
  """
  def as_written(result) do
    if Results.postponed?(result), do: "?", else: result || ""
  end

  @doc "The SHA-256 of `text` in lower-case hex; nil for no file."
  def sha256(nil), do: nil
  def sha256(text) when is_binary(text), do: :crypto.hash(:sha256, text) |> hex()

  defp hex(binary), do: Base.encode16(binary, case: :lower)

  @doc """
  The fingerprint of a send: `kind` (`"report"`/`"postponed"`), `scope` (the
  round number, or the rating period's first day), the games
  (`game_entry/3`) and the hash of the file's bytes (nil for none). See the
  moduledoc for what is in it; the same arguments always give the same
  answer, whatever order the games come in.
  """
  def fingerprint(kind, scope, games, file_sha256) do
    canonical =
      Jason.encode!([
        @version,
        kind,
        scope_text(scope),
        games
        |> Enum.map(fn g ->
          [
            g["game_uid"],
            g["round"],
            g["white_fide_id"],
            g["white_name"],
            g["black_fide_id"],
            g["black_name"],
            g["sent_as"]
          ]
        end)
        |> Enum.sort(),
        file_sha256
      ])

    sha256(canonical)
  end

  defp scope_text(%Date{} = date), do: Date.to_iso8601(date)
  defp scope_text(other), do: other

  @doc """
  The code for a fingerprint: `"R5·7F2A"` for round 5's report, `"P·7F2A"`
  for a postponed-games file. Longer (six, then eight hex digits) when the
  short one is among `taken`.
  """
  def code(kind, round, fingerprint, taken \\ MapSet.new()) do
    prefix = if kind == "postponed", do: "P", else: "R#{round}"

    [4, 6, 8, 64]
    |> Enum.map(&(prefix <> "·" <> String.upcase(binary_part(fingerprint, 0, &1))))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc "A code as the TRF writes it, ASCII: `\"R5-7F2A\"`."
  def file_code(nil), do: nil
  def file_code(code), do: String.replace(code, "·", "-")

  ## ---------- recording a send ----------

  @doc """
  Records the receipts of one send of round reports - one per round in
  `rounds` - for `file` (nil when the send made no file), which is returned
  as it is: no line is added to a file for rating. Run inside the send's write transaction, after the
  sent-games record landed (`PostponedGames.send_rounds/4`): it reads the
  boards as they were sent. Returns `{:ok, receipts, file}`.

  `opts`: `sent_by` (a label: who sent it), `sent_by_id`, `now`.
  """
  def record_rounds(tournament_id, rounds, file, opts \\ []) do
    boards =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and r.number in ^rounds,
          order_by: [r.number, p.board],
          preload: [:white_player, :black_player],
          select: {r.number, p}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    groups =
      for round <- Enum.sort(rounds) do
        games =
          for p <- Map.get(boards, round, []), do: game_entry(round, p, as_written(p.result))

        %{kind: "report", round: round, period: nil, games: games}
      end

    record(tournament_id, groups, file, opts)
  end

  @doc """
  Records the receipt of one postponed-games file: `games` are
  `sendable_late_games/1`'s entries, `period` its rating period. As
  `record_rounds/4`.
  """
  def record_late(tournament_id, games, period, file, opts \\ [])

  def record_late(_tournament_id, [], _period, file, _opts), do: {:ok, [], file}

  def record_late(tournament_id, games, period, file, opts) do
    ids = Enum.map(games, & &1.pairing.id)

    fresh =
      Repo.all(from p in Pairing, where: p.id in ^ids, preload: [:white_player, :black_player])
      |> Map.new(&{&1.id, &1})

    entries =
      for %{round: round, pairing: p} <- games do
        stored = Map.get(fresh, p.id, p)
        game_entry(round, stored, stored.result)
      end

    record(
      tournament_id,
      [%{kind: "postponed", round: nil, period: period, games: entries}],
      file,
      opts
    )
  end

  defp record(tournament_id, groups, file, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
    now = DateTime.truncate(now, :second)
    file_sha = sha256(file)

    taken =
      Repo.all(
        from s in SentReceipt,
          where: s.tournament_id == ^tournament_id and not is_nil(s.code),
          select: s.code
      )
      |> MapSet.new()

    {rows, _taken} =
      Enum.map_reduce(groups, taken, fn group, taken ->
        print = fingerprint(group.kind, group.period || group.round, group.games, file_sha)
        code = code(group.kind, group.round, print, taken)

        row = %{
          tournament_id: tournament_id,
          kind: group.kind,
          round: group.round,
          period: group.period,
          code: code,
          fingerprint: print,
          file_sha256: file_sha,
          games: group.games,
          status: "receipt",
          origin: "sent",
          sent_at: now,
          sent_by: Keyword.get(opts, :sent_by),
          sent_by_id: Keyword.get(opts, :sent_by_id)
        }

        {row, MapSet.put(taken, code)}
      end)

    # The file goes out as built: a file sent for rating holds only TRF
    # records, so the receipt is not written into it (it used to be, as a
    # `###` line). Its code and the file's hash stay here, on the receipt.
    rows = Enum.map(rows, &Map.put(&1, :final_sha256, file_sha))

    receipts = Enum.map(rows, &Repo.insert!(struct(SentReceipt, &1)))
    {:ok, receipts, file}
  end

  defp at_text(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  ## ---------- reading them back ----------

  @doc "Every receipt of `tournament_id`, oldest first."
  def list(tournament_id) do
    Repo.all(
      from s in SentReceipt,
        where: s.tournament_id == ^tournament_id,
        order_by: [s.sent_at, s.id]
    )
  end

  @doc """
  The latest receipt of each round's report, as `%{round => %SentReceipt{}}`
  - the one a round is compared with (a round sent again after a restore
  has more than one; the last is what the rating officer holds last).
  """
  def latest_by_round(tournament_id) do
    tournament_id
    |> list()
    |> Enum.filter(&(&1.kind == "report" and not is_nil(&1.round)))
    |> Enum.group_by(& &1.round)
    |> Map.new(fn {round, receipts} -> {round, List.last(receipts)} end)
  end

  @doc """
  Round `round`'s latest receipt and what changed since it, as
  `%{receipt:, changes:}`; nil for a round with no receipt.
  """
  def round_status(tournament_id, round) do
    case Map.get(latest_by_round(tournament_id), round) do
      nil -> nil
      # Only this round's boards are read: the Pairings page asks on
      # every refresh.
      receipt -> %{receipt: receipt, changes: changes(receipt, context(tournament_id, round))}
    end
  end

  @doc """
  Every receipt that is compared with the tournament - the latest of each
  round's report and every postponed-games receipt - with what changed
  since it: `%{reports: %{round => %{receipt:, changes:}}, postponed:
  [%{receipt:, changes:}]}`.
  """
  def statuses(tournament_id) do
    receipts = list(tournament_id)
    context = context(tournament_id)

    reports =
      receipts
      |> Enum.filter(&(&1.kind == "report" and not is_nil(&1.round)))
      |> Enum.group_by(& &1.round)
      |> Map.new(fn {round, rs} ->
        receipt = List.last(rs)
        {round, %{receipt: receipt, changes: changes(receipt, context)}}
      end)

    postponed =
      for r <- receipts, r.kind == "postponed", do: %{receipt: r, changes: changes(r, context)}

    %{reports: reports, postponed: postponed}
  end

  @doc """
  The receipts that changed since they were sent (`statuses/1`), in round
  order, the postponed-games ones last. Empty when nothing changed.
  """
  def drift(tournament_id) do
    %{reports: reports, postponed: postponed} = statuses(tournament_id)

    sorted = reports |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    Enum.filter(sorted ++ postponed, &(&1.changes != []))
  end

  # The tournament now: every board as a receipt entry, and the games a
  # postponed-games file has carried (by identity).
  defp context(tournament_id, round \\ nil) do
    boards_query =
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id

    boards_query =
      if round, do: where(boards_query, [_p, r], r.number == ^round), else: boards_query

    boards =
      Repo.all(
        from [p, r] in boards_query,
          order_by: [r.number, p.board],
          preload: [:white_player, :black_player],
          select: {r.number, p}
      )
      |> Enum.map(fn {round, p} -> game_entry(round, p, as_written(p.result)) end)

    late_uids =
      Repo.all(
        from s in TrfSentGame,
          where:
            s.tournament_id == ^tournament_id and s.kind == "postponed" and
              not is_nil(s.game_uid),
          select: s.game_uid
      )
      |> MapSet.new()

    %{boards: boards, late_uids: late_uids}
  end

  @doc """
  What changed since `receipt` was sent, against `context` (the tournament
  now). A receipt with no games on record (sent before the sent-games
  record existed) can show none. Each change is a map: `type` (one of
  `:result_changed`, `:postponed_played`, `:player_changed`,
  `:colours_changed`, `:game_removed`, `:game_added`), `round`, `board`,
  `white`, `black` (names as best known), and for the first three `was`
  and `now` (and `side` for a player).
  """
  def changes(%SentReceipt{games: nil}, _context), do: []

  def changes(%SentReceipt{kind: kind} = receipt, %{boards: boards, late_uids: late_uids}) do
    candidates =
      if kind == "report",
        do: Enum.filter(boards, &(&1["round"] == receipt.round)),
        else: boards

    by_uid = for b <- candidates, b["game_uid"], into: %{}, do: {b["game_uid"], b}
    by_key = Enum.group_by(candidates, &{&1["round"], &1["white_key"], &1["black_key"]})

    {found, changes} =
      Enum.map_reduce(receipt.games, [], fn sent, acc ->
        case find(sent, by_uid, by_key) do
          nil ->
            {nil, acc ++ [change(:game_removed, sent, nil)]}

          now ->
            {now["game_uid"], acc ++ compare(kind, sent, now, late_uids)}
        end
      end)

    added =
      if kind == "report" do
        found = MapSet.new(found)

        for b <- candidates,
            not MapSet.member?(found, b["game_uid"]),
            do: change(:game_added, b, b)
      else
        []
      end

    changes ++ added
  end

  defp find(sent, by_uid, by_key) do
    uid = sent["game_uid"]
    round = sent["round"]

    cond do
      is_binary(uid) and Map.has_key?(by_uid, uid) ->
        Map.fetch!(by_uid, uid)

      # Older records name their game only by players: a single board of
      # those players, either way round, is that game.
      match?([_], Map.get(by_key, {round, sent["white_key"], sent["black_key"]}, [])) ->
        hd(Map.fetch!(by_key, {round, sent["white_key"], sent["black_key"]}))

      not is_binary(uid) and
          match?([_], Map.get(by_key, {round, sent["black_key"], sent["white_key"]}, [])) ->
        hd(Map.fetch!(by_key, {round, sent["black_key"], sent["white_key"]}))

      true ->
        nil
    end
  end

  defp compare(kind, sent, now, late_uids) do
    swapped? =
      sent["white_key"] != sent["black_key"] and sent["white_key"] == now["black_key"] and
        sent["black_key"] == now["white_key"]

    players =
      if swapped? do
        [change(:colours_changed, sent, now)]
      else
        player_change(:white, sent, now) ++ player_change(:black, sent, now)
      end

    players ++ result_change(kind, sent, now, late_uids)
  end

  defp player_change(side, sent, now) do
    key = "#{side}_key"
    name = "#{side}_name"
    fide = "#{side}_fide_id"

    # A receipt older than receipts holds the record's key only (the FIDE
    # ID, or the name for a player without one); a name change of a player
    # with a FIDE ID shows only where the name was kept.
    changed? =
      sent[key] != now[key] or
        (not is_nil(sent[name]) and sent[name] != now[name]) or
        (Map.has_key?(sent, fide) and sent[fide] != now[fide])

    if changed? do
      [
        Map.merge(change(:player_changed, sent, now), %{
          side: side,
          was: player_label(sent, side),
          now: player_label(now, side)
        })
      ]
    else
      []
    end
  end

  defp result_change(kind, sent, now, late_uids) do
    was = sent["sent_as"]
    is = now["sent_as"]

    cond do
      was == is ->
        []

      # Sent as unknown, played since: its result goes in a postponed-games
      # file. Once one has carried it, that file's receipt answers for it.
      kind == "report" and was == "?" and is not in ["?", ""] ->
        if MapSet.member?(late_uids, now["game_uid"]),
          do: [],
          else: [Map.merge(change(:postponed_played, sent, now), %{was: was, now: is})]

      true ->
        [Map.merge(change(:result_changed, sent, now), %{was: was, now: is})]
    end
  end

  defp change(type, sent, now) do
    names = now || sent

    %{
      type: type,
      round: sent["round"],
      board: (now && now["board"]) || sent["board"],
      white: player_label(names, :white, false),
      black: player_label(names, :black, false)
    }
  end

  defp player_label(game, side, with_fide? \\ true) do
    name = game["#{side}_name"]
    fide = game["#{side}_fide_id"]
    key = game["#{side}_key"]

    base =
      cond do
        is_binary(name) -> name
        is_binary(key) -> key_name(key)
        true -> nil
      end

    cond do
      with_fide? and is_binary(base) and is_integer(fide) -> "#{base} (FIDE #{fide})"
      true -> base
    end
  end

  defp key_name("fide:" <> id), do: "FIDE " <> id
  defp key_name("name:" <> name), do: name
  defp key_name(other), do: other

  ## ---------- copies ----------

  @doc """
  The `###` lines a copy of `rounds` carries, one per round: whose copy it
  is ("copy of R5-7F2A, not for rating"), a round sent before receipts, or
  one never sent - and, for a round that changed since it was sent, that
  this copy is not what was sent either.
  """
  def copy_lines(tournament_id, rounds) do
    %{reports: reports} = statuses(tournament_id)

    sent =
      PairingsEngine.PostponedGames.sent_rounds(%PairingsEngine.Tournaments.Tournament{
        id: tournament_id
      })

    for round <- Enum.sort(rounds) do
      case Map.get(reports, round) do
        %{receipt: %{code: code} = receipt, changes: changes} when is_binary(code) ->
          "Round #{round}: copy of #{file_code(code)} (sent #{at_text(receipt.sent_at)}), " <>
            "not for rating." <> changed_part(changes)

        %{changes: changes} ->
          "Round #{round}: sent before receipts, not for rating." <> changed_part(changes)

        nil ->
          if round in sent,
            do: "Round #{round}: sent before receipts, not for rating.",
            else: "Round #{round}: never sent."
      end
    end
  end

  defp changed_part([]), do: ""

  defp changed_part(_changes),
    do: " It changed since it was sent: this copy is not what the rating officer has."

  ## ---------- copies of the tournament ----------

  @doc """
  The receipts of `tournament_id` as plain maps, for an export file
  (`PairingsEngine.TournamentExport`), like the sent-games record
  (`PostponedGames.export_records/1`). Who sent it travels as the label it
  was stored with; the account id stays here.
  """
  def export_receipts(tournament_id) do
    for r <- list(tournament_id) do
      %{
        "kind" => r.kind,
        "round" => r.round,
        "period" => r.period && Date.to_iso8601(r.period),
        "code" => r.code,
        "fingerprint" => r.fingerprint,
        "file_sha256" => r.file_sha256,
        "final_sha256" => r.final_sha256,
        "games" => r.games,
        "status" => r.status,
        "origin" => r.origin,
        "sent_at" => DateTime.to_iso8601(r.sent_at),
        "sent_by" => r.sent_by
      }
    end
  end

  @doc """
  Adds the receipts an export file carries (`export_receipts/1`) to
  `tournament_id`'s, as sends another copy made (`origin`, default
  `"import"`). A receipt already held (same kind, round, code and time) is
  not added twice; a malformed entry is skipped; nothing is removed. Then
  every sent round or postponed-games send with no receipt at all gets one
  marked as sent before receipts (`backfill_before_receipts/1`).
  """
  def merge_receipts(tournament_id, entries, origin \\ "import") when is_list(entries) do
    held =
      tournament_id
      |> list()
      |> MapSet.new(&{&1.kind, &1.round, &1.code, &1.sent_at})

    rows =
      for %{} = e <- entries,
          e["kind"] in ~w(report postponed),
          {:ok, at, _} <- [DateTime.from_iso8601(to_string(e["sent_at"]))],
          at <- [DateTime.truncate(at, :second)],
          round <- [integer_or_nil(e["round"])],
          not MapSet.member?(held, {e["kind"], round, string_or_nil(e["code"]), at}),
          uniq: true do
        %{
          tournament_id: tournament_id,
          kind: e["kind"],
          round: round,
          period: date_or_nil(e["period"]),
          code: string_or_nil(e["code"]),
          fingerprint: string_or_nil(e["fingerprint"]),
          file_sha256: string_or_nil(e["file_sha256"]),
          final_sha256: string_or_nil(e["final_sha256"]),
          games: games_or_nil(e["games"]),
          status: if(e["status"] == "before_receipts", do: "before_receipts", else: "receipt"),
          origin: if(e["origin"] in [nil, "sent"], do: origin, else: e["origin"]),
          sent_at: at,
          sent_by: string_or_nil(e["sent_by"])
        }
      end

    if rows != [], do: Repo.insert_all(SentReceipt, rows)
    backfill_before_receipts(tournament_id)
  end

  defp integer_or_nil(n) when is_integer(n), do: n
  defp integer_or_nil(_), do: nil

  defp string_or_nil(s) when is_binary(s) and s != "", do: s
  defp string_or_nil(_), do: nil

  defp date_or_nil(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date_or_nil(_), do: nil

  defp games_or_nil(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp games_or_nil(_), do: nil

  @doc """
  Gives every send of `tournament_id` that has no receipt - a round the
  sent-games record holds as sent, a postponed-games send it holds - a
  receipt marked `"before_receipts"`: no code, the record's games. For a
  copy made from a backup older than receipts. `:ok`.
  """
  def backfill_before_receipts(tournament_id) do
    receipts = list(tournament_id)
    have_rounds = for r <- receipts, r.kind == "report", into: MapSet.new(), do: r.round
    late_receipt? = Enum.any?(receipts, &(&1.kind == "postponed"))

    records =
      Repo.all(
        from s in TrfSentGame,
          where: s.tournament_id == ^tournament_id,
          order_by: [s.sent_at, s.id]
      )

    reports =
      records
      |> Enum.filter(&(&1.kind == "report" and not MapSet.member?(have_rounds, &1.round)))
      |> Enum.group_by(& &1.round)
      |> Enum.map(fn {round, recs} ->
        before_row(
          tournament_id,
          "report",
          round,
          recs,
          Enum.max(Enum.map(recs, & &1.sent_at), DateTime)
        )
      end)

    lates =
      if late_receipt? do
        []
      else
        records
        |> Enum.filter(&(&1.kind == "postponed"))
        |> Enum.group_by(& &1.sent_at)
        |> Enum.map(fn {at, recs} -> before_row(tournament_id, "postponed", nil, recs, at) end)
      end

    if reports ++ lates != [], do: Repo.insert_all(SentReceipt, reports ++ lates)
    :ok
  end

  defp before_row(tournament_id, kind, round, records, at) do
    games =
      records
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

    %{
      tournament_id: tournament_id,
      kind: kind,
      round: round,
      games: games,
      status: "before_receipts",
      origin:
        if(Enum.any?(records, &(&1.origin == "sent")), do: "sent", else: hd(records).origin),
      sent_at: DateTime.truncate(at, :second)
    }
  end
end
