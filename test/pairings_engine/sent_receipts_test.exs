defmodule PairingsEngine.SentReceiptsTest do
  @moduledoc """
  The sent receipt (`PairingsEngine.SentReceipts`): a deterministic
  fingerprint and code per send, its `###` line in the file sent (which
  still parses as the same TRF), the copy lines, drift for every kind of
  rating-relevant change and none when nothing changed, and the receipts
  carried by a backup. The receipt never replaces the one-send guard: a
  second send is still refused, and writes no second receipt.

  Generated data only: no .swar fixtures, no real players.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{
    Pairing,
    PostponedGames,
    Repo,
    SentReceipts,
    Snapshots,
    TournamentExport,
    TournamentImport,
    TrfExport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Player, SentReceipt, Tournament}
  alias PairingsEngine.Tournaments.Pairing, as: Board

  import Ecto.Query
  import PairingsEngine.AccountsFixtures, only: [user_scope_fixture: 0]

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Receipt club championship",
              type: "swiss",
              rounds_count: 3,
              tiebreaks: ~w(BH SB),
              postponed_games: true,
              round_dates: ["2026-09-01", "2026-09-08", "2026-09-15"]
            },
            Map.new(attrs)
          )
        )
      )

    players =
      for {name, rating, fide} <- [
            {"Ann", 2000, 99_100_001},
            {"Ben", 1900, 99_100_002},
            {"Cas", 1800, nil},
            {"Dan", 1700, nil}
          ],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{
            tournament_id: t.id,
            name: name,
            fide_rating: rating,
            fide_id: fide
          })

        {name, p}
      end

    {t, players}
  end

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
    Tournaments.get_round(t.id, round.number)
  end

  defp result!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  defp board_of(round, player),
    do: Enum.find(round.pairings, &(player.id in [&1.white_player_id, &1.black_player_id]))

  # Round 1 paired and played (`results` per board, default 1-0), then sent
  # with a file for rating; returns the tournament, its players, the round,
  # the file as built and the send's answer.
  defp sent_round!(results \\ nil) do
    {t, players} = tournament()
    round1 = pair!(t)

    for {p, i} <- Enum.with_index(round1.pairings),
        do: result!(p, (results && Enum.at(results, i)) || "1-0")

    me = self()

    {:ok, sent} =
      PostponedGames.send_rounds(
        Repo.reload!(t),
        [1],
        fn fresh ->
          {:ok, text} = TrfExport.export(fresh, [1], for: :rating)
          send(me, {:built, text})
          {:ok, text}
        end,
        sent_by: "arbiter@example.org"
      )

    assert_received {:built, built}
    {t, players, Tournaments.get_round(t.id, 1), built, sent}
  end

  defp status(t, round), do: SentReceipts.round_status(t.id, round)
  defp types(t, round), do: t |> status(round) |> Map.fetch!(:changes) |> Enum.map(& &1.type)

  defp receipts(t), do: Repo.all(from r in SentReceipt, where: r.tournament_id == ^t.id)

  describe "the fingerprint and the code" do
    test "are deterministic: the same games, round and file give the same fingerprint" do
      games = [
        %{"game_uid" => "b", "round" => 5, "white_name" => "Ann", "sent_as" => "1-0"},
        %{"game_uid" => "a", "round" => 5, "white_name" => "Cas", "sent_as" => "?"}
      ]

      print = SentReceipts.fingerprint("report", 5, games, "abc")

      assert print == SentReceipts.fingerprint("report", 5, Enum.reverse(games), "abc")
      assert print =~ ~r/^[0-9a-f]{64}$/

      # Anything that was sent changes it.
      refute print == SentReceipts.fingerprint("report", 6, games, "abc")
      refute print == SentReceipts.fingerprint("report", 5, games, "abd")

      refute print ==
               SentReceipts.fingerprint(
                 "report",
                 5,
                 [%{hd(games) | "sent_as" => "0-1"} | tl(games)],
                 "abc"
               )

      code = SentReceipts.code("report", 5, print)
      assert code == "R5·" <> String.upcase(binary_part(print, 0, 4))
      assert SentReceipts.file_code(code) == "R5-" <> String.upcase(binary_part(print, 0, 4))
      assert SentReceipts.code("postponed", nil, print) =~ ~r/^P·[0-9A-F]{4}$/

      # A code the tournament already has is lengthened, never repeated.
      assert SentReceipts.code("report", 5, print, MapSet.new([code])) ==
               "R5·" <> String.upcase(binary_part(print, 0, 6))
    end

    test "a send records one receipt per round, whose fingerprint is what was sent" do
      {t, _players, round1, built, %{receipts: [receipt], file: file}} = sent_round!()

      assert receipt.kind == "report" and receipt.round == 1 and receipt.status == "receipt"
      assert receipt.code =~ ~r/^R1·[0-9A-F]{4}$/
      assert receipt.sent_by == "arbiter@example.org"
      assert receipt.file_sha256 == SentReceipts.sha256(built)
      assert receipt.final_sha256 == SentReceipts.sha256(file)
      assert length(receipt.games) == length(round1.pairings)

      # Recomputed from what it holds: the same fingerprint.
      assert SentReceipts.fingerprint("report", 1, receipt.games, receipt.file_sha256) ==
               receipt.fingerprint

      assert [stored] = receipts(t)
      assert stored.code == receipt.code
    end
  end

  describe "the file sent" do
    test "goes out as built: the receipt is not written into it" do
      {_t, _players, _round, built, %{receipts: [receipt], file: file}} = sent_round!()

      # A file for rating holds only records (SWAR's accepted files do too):
      # the receipt's code stays in the app, with the file's hash.
      assert file == built
      refute file =~ "###"
      refute file =~ SentReceipts.file_code(receipt.code)
      assert receipt.final_sha256 == receipt.file_sha256
      assert length(Ainalrami.Trf.parse(file).players) == 4
    end

    test "the postponed-games file carries its own P receipt" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      for p <- round1.pairings, p.id != postponed.id, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      result!(Repo.reload!(postponed), "1/2-1/2", played_on: ~D[2026-09-20])

      {:ok, text, [_game], receipt} =
        PostponedGames.send_late_games(Repo.reload!(t), &TrfExport.postponed_export(&1, []))

      assert receipt.kind == "postponed" and receipt.period == ~D[2026-09-01]
      assert receipt.code =~ ~r/^P·[0-9A-F]{4}$/
      refute text =~ "###"
      refute text =~ "DDD"
      assert receipt.final_sha256 == SentReceipts.sha256(text)
      assert %{players: [_ | _]} = Ainalrami.Trf.parse(text)
    end
  end

  describe "the one-send guard is untouched" do
    test "a second send of a round is refused and writes no second receipt" do
      {t, _players, _round, _built, _sent} = sent_round!()

      assert {:error, {:already_sent, [1]}} =
               PostponedGames.send_rounds(Repo.reload!(t), [1], fn _ -> {:ok, "x"} end)

      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(Repo.reload!(t), [1])
      assert length(receipts(t)) == 1
    end
  end

  describe "drift" do
    test "none when nothing changed" do
      {t, _players, _round, _built, %{receipts: [receipt]}} = sent_round!()

      assert %{receipt: %{id: id}, changes: []} = status(t, 1)
      assert id == receipt.id
      assert SentReceipts.drift(t.id) == []
      assert status(t, 2) == nil
    end

    test "a result corrected after sending" do
      {t, _players, round1, _built, _sent} = sent_round!()
      [board | _] = round1.pairings

      result!(board, "0-1", acknowledged: [:finalised_result_changed])

      assert [%{type: :result_changed, was: "1-0", now: "0-1", round: 1}] =
               status(t, 1).changes

      assert [%{receipt: %{round: 1}}] = SentReceipts.drift(t.id)
    end

    test "a postponed game played since, until a postponed-games file carries it" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      for p <- round1.pairings, p.id != postponed.id, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])
      assert status(t, 1).changes == []

      result!(Repo.reload!(postponed), "1/2-1/2", played_on: ~D[2026-09-20])
      assert [%{type: :postponed_played, was: "?", now: "1/2-1/2"}] = status(t, 1).changes

      {:ok, _text, _games, late} =
        PostponedGames.send_late_games(Repo.reload!(t), &TrfExport.postponed_export(&1, []))

      # Its result went out in the postponed-games file: nothing is missing.
      assert status(t, 1).changes == []
      assert SentReceipts.drift(t.id) == []

      # And a correction after THAT file is the file's drift.
      result!(Repo.reload!(postponed), "1-0",
        acknowledged: [:finalised_result_changed, :adjourned_non_draw_result]
      )

      assert status(t, 1).changes == []

      assert [%{receipt: %{id: late_id}, changes: [%{type: :result_changed, now: "1-0"}]}] =
               SentReceipts.drift(t.id)

      assert late_id == late.id
    end

    test "a player's FIDE ID or name changed" do
      {t, players, _round, _built, _sent} = sent_round!()

      Repo.update_all(from(p in Player, where: p.id == ^players["Ann"].id),
        set: [fide_id: 99_100_099]
      )

      assert [%{type: :player_changed, was: "Ann (FIDE 99100001)", now: "Ann (FIDE 99100099)"}] =
               status(t, 1).changes

      Repo.update_all(from(p in Player, where: p.id == ^players["Ann"].id),
        set: [fide_id: 99_100_001]
      )

      assert status(t, 1).changes == []

      Repo.update_all(from(p in Player, where: p.id == ^players["Cas"].id), set: [name: "Kas"])
      assert [%{type: :player_changed, was: "Cas", now: "Kas"}] = status(t, 1).changes
    end

    test "a game removed, a game added, colours swapped" do
      {t, _players, round1, _built, _sent} = sent_round!()
      [first, second] = round1.pairings

      Repo.update_all(from(p in Board, where: p.id == ^first.id),
        set: [white_player_id: first.black_player_id, black_player_id: first.white_player_id]
      )

      assert :colours_changed in types(t, 1)

      Repo.delete!(Repo.reload!(second))
      assert :game_removed in types(t, 1)

      Repo.insert!(%Board{
        round_id: second.round_id,
        board: 9,
        result: "1-0",
        white_player_id: second.white_player_id,
        black_player_id: second.black_player_id
      })

      # A new board of the same players is the same game to the record (it
      # matches by players when its identity is new): no longer removed.
      refute :game_removed in types(t, 1)

      Repo.insert!(%Board{
        round_id: second.round_id,
        board: 10,
        result: "1-0",
        white_player_id: first.white_player_id,
        black_player_id: second.white_player_id
      })

      assert :game_added in types(t, 1)
    end
  end

  describe "copies" do
    test "say whose copy they are, or that a round was never sent, and still parse" do
      {t, _players, _round, _built, %{receipts: [receipt]}} = sent_round!()
      round2 = pair!(t)
      for p <- round2.pairings, do: result!(p, "1/2-1/2")

      {:ok, copy} = TrfExport.export(Repo.reload!(t), nil, copy: true)

      assert copy =~ "### COPY - NOT FOR RATING"

      assert copy =~
               "### Round 1: copy of #{SentReceipts.file_code(receipt.code)} (sent "

      assert copy =~ "not for rating."
      assert copy =~ "### Round 2: never sent."
      assert %{players: [_ | _]} = Ainalrami.Trf.parse(copy)

      # A round changed since it was sent says so in the copy too.
      [board | _] = Tournaments.get_round(t.id, 1).pairings
      result!(board, "0-1", acknowledged: [:finalised_result_changed, :result_correction])
      {:ok, copy} = TrfExport.export(Repo.reload!(t), "1", copy: true)
      assert copy =~ "It changed since it was sent"
    end
  end

  describe "sends made before receipts" do
    test "get a receipt with no code, and their changes are still detected" do
      {t, _players, round1, _built, _sent} = sent_round!()
      Repo.delete_all(from r in SentReceipt, where: r.tournament_id == ^t.id)

      :ok = SentReceipts.backfill_before_receipts(t.id)

      assert [%{status: "before_receipts", code: nil, fingerprint: nil, games: [_, _]}] =
               receipts(t)

      assert status(t, 1).changes == []
      {:ok, copy} = TrfExport.export(Repo.reload!(t), "1", copy: true)
      assert copy =~ "### Round 1: sent before receipts, not for rating."

      result!(hd(round1.pairings), "0-1", acknowledged: [:finalised_result_changed])
      assert [%{type: :result_changed}] = status(t, 1).changes

      # Run twice, it adds nothing.
      :ok = SentReceipts.backfill_before_receipts(t.id)
      assert length(receipts(t)) == 1
    end
  end

  describe "copies of the tournament" do
    test "a backup carries the receipts, and the copy tells the same drift" do
      {t, _players, _round, _built, %{receipts: [receipt]}} = sent_round!()
      scope = user_scope_fixture()

      backup = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      [entry] = backup["tournaments"]
      assert [%{"code" => code}] = entry["sent_receipts"]
      assert code == receipt.code

      {:ok, [copy]} = TournamentImport.import(backup, scope)

      assert [%{code: ^code, origin: "import", fingerprint: print}] = receipts(copy)
      assert print == receipt.fingerprint
      assert status(copy, 1).changes == []

      [board | _] = Tournaments.get_round(copy.id, 1).pairings
      result!(board, "0-1", acknowledged: [:finalised_result_changed])
      assert [%{type: :result_changed}] = status(copy, 1).changes

      # Imported twice into the same copy's record, nothing is doubled.
      :ok = SentReceipts.merge_receipts(copy.id, entry["sent_receipts"])
      assert length(receipts(copy)) == 1
    end

    test "a backup older than receipts gives the copy a sent-before-receipts receipt" do
      {t, _players, _round, _built, _sent} = sent_round!()
      scope = user_scope_fixture()

      backup =
        t
        |> TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()
        |> update_in(["tournaments", Access.at(0)], &Map.delete(&1, "sent_receipts"))

      {:ok, [copy]} = TournamentImport.import(backup, scope)

      assert [%{status: "before_receipts", code: nil, kind: "report", round: 1}] =
               receipts(copy)
    end

    test "a restore leaves the receipts alone" do
      {t, _players} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, snapshot} = Snapshots.capture(Repo.reload!(t), "manual", nil)
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])
      [receipt] = receipts(t)

      {:ok, _} = Snapshots.restore(Repo.reload!(t), snapshot.id)

      assert [%{id: id}] = receipts(t)
      assert id == receipt.id
      assert status(t, 1).changes == []
    end
  end
end
