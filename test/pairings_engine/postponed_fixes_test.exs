defmodule PairingsEngine.PostponedFixesTest do
  @moduledoc """
  The fixes for the postponed-games audit of 2026-10-01, beyond the F1-F7
  tests in `postponed_audit_test.exs`: the variants the audit described but
  did not test, the record carried by copies of a tournament, and the
  postponed-games file as a tournament of its own. The rule above all: no
  game is ever sent for rating twice.

  Generated data only: no .swar fixtures, no real players.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{
    Pairing,
    PostponedGames,
    Repo,
    Snapshots,
    TournamentExport,
    TournamentImport,
    TrfExport,
    TrfImport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Tournament, TrfSentGame}

  import Ecto.Query
  import PairingsEngine.AccountsFixtures, only: [user_scope_fixture: 0]

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Fixes club championship",
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
      for {name, rating} <- [{"Ann", 2000}, {"Ben", 1900}, {"Cas", 1800}, {"Dan", 1700}],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{tournament_id: t.id, name: name, fide_rating: rating})

        {name, p}
      end

    {t, players}
  end

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
    Tournaments.get_round(t.id, round.number)
  end

  defp board_of(round, player),
    do: Enum.find(round.pairings, &(player.id in [&1.white_player_id, &1.black_player_id]))

  defp result!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  defp snapshot!(t) do
    {:ok, snapshot} = Snapshots.capture(Repo.reload!(t), "manual", nil)
    snapshot
  end

  defp records(t, kind),
    do: Repo.all(from s in TrfSentGame, where: s.tournament_id == ^t.id and s.kind == ^kind)

  defp over_the_wire(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  describe "a game's identity" do
    test "every board gets one from the database, and a send records it" do
      {t, _players} = tournament()
      round1 = pair!(t)

      uids = Enum.map(round1.pairings, &Repo.reload!(&1).game_uid)
      assert Enum.all?(uids, &(is_binary(&1) and byte_size(&1) == 32))
      assert uids == Enum.uniq(uids)

      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, 2} = PostponedGames.finalise(Repo.reload!(t), [1])

      assert t |> records("report") |> Enum.map(& &1.game_uid) |> Enum.sort() == Enum.sort(uids)
      assert Enum.all?(records(t, "report"), &(&1.origin == "sent"))
    end

    test "the database refuses a second record of one game sent, whatever the code checked" do
      {t, _players} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      [%TrfSentGame{} = row | _] = records(t, "report")

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%TrfSentGame{row | id: nil})
      end

      # A send another copy made is a fact to keep, not a race to refuse.
      assert {:ok, _} = Repo.insert(%TrfSentGame{row | id: nil, origin: "copy"})
    end
  end

  describe "the `?` mark across a restore (the variant F4 described)" do
    test "a FIDE ID filled in after a snapshot does not lose the game's ? on a restore" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      for p <- round1.pairings, p.id != postponed.id, do: result!(p, "1-0")
      open = snapshot!(t)

      {:ok, _} = Tournaments.update_player(Repo.reload!(players["Ann"]), %{fide_id: 99_000_002})
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      # Back to before the ID was known: the game is still the one sent as ?.
      assert Snapshots.sent_conflicts(Repo.reload!(t), open.id) == []
      {:ok, _} = Snapshots.restore(Repo.reload!(t), open.id)

      # A restore recreates the players: Ann's board, found by her name.
      board =
        t.id
        |> Tournaments.get_round(1)
        |> Map.fetch!(:pairings)
        |> Repo.preload([:white_player, :black_player])
        |> Enum.find(
          &("Ann" in [
              &1.white_player && &1.white_player.name,
              &1.black_player && &1.black_player.name
            ])
        )

      assert %{finalised_open: true} = board

      result!(board, "1-0", acknowledged: [:adjourned_non_draw_result], played_on: ~D[2026-09-21])

      assert [%{pairing: %{id: id}}] = PostponedGames.sendable_late_games(Repo.reload!(t))
      assert id == board.id
    end
  end

  describe "the third send (F3): a game sent as ? here and with its result elsewhere" do
    test "is never offered for the postponed-games file" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      for p <- round1.pairings, p.id != postponed.id, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      # The contents a hand-off brings back: the other machine played the
      # game and sent round 1 with its result (its copy knew nothing of this
      # one's send). What `Handoff.release/3` writes, then reapplies.
      Repo.update_all(from(p in PairingsEngine.Tournaments.Pairing, where: p.id == ^postponed.id),
        set: [result: "1-0", finalised_open: false, played_on: ~D[2026-09-22]]
      )

      :ok = PostponedGames.reapply_sent_marks(t.id)

      assert %{finalised_open: false} = Repo.reload!(postponed)
      assert PostponedGames.sendable_late_games(Repo.reload!(t)) == []

      # Both sends are on record, the other copy's as a copy's.
      assert [%{sent_as: "?", origin: "sent"}, %{sent_as: "1-0", origin: "copy"}] =
               t
               |> records("report")
               |> Enum.filter(&(&1.game_uid == Repo.reload!(postponed).game_uid))
               |> Enum.sort_by(& &1.origin, :desc)
    end
  end

  describe "copies of a tournament (F5)" do
    test "a JSON backup carries what was sent, and the copy keeps it" do
      {t, _players} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      backup = t |> Repo.reload!() |> TournamentExport.export_tournament() |> over_the_wire()
      [entry] = backup["tournaments"]
      assert length(entry["sent_games"]) == 2

      {:ok, [copy]} = TournamentImport.import(backup, user_scope_fixture())

      assert [%{origin: "import"}, %{origin: "import"}] = records(copy, "report")
      # Its boards keep their identity, so the record knows them.
      assert copy |> records("report") |> Enum.map(& &1.game_uid) |> Enum.sort() ==
               entry["rounds"]
               |> hd()
               |> Map.fetch!("pairings")
               |> Enum.map(& &1["game_uid"])
               |> Enum.sort()

      # Something was sent: the copy asks first, and even confirmed it
      # refuses the round.
      assert copy.send_confirmation_needed == "json"
      {:ok, copy} = Tournaments.confirm_sending(copy)
      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(copy, [1])
    end

    test "an unconfirmed copy sends nothing until confirmed, and the confirmation is on record" do
      {t, _players} = tournament(fide_tournament_id: "515151")
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")

      backup = t |> Repo.reload!() |> TournamentExport.export_tournament() |> over_the_wire()
      scope = user_scope_fixture()
      {:ok, [copy]} = TournamentImport.import(backup, scope)

      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(copy, [1])
      assert records(copy, "report") == []

      {:ok, copy} = Tournaments.confirm_sending(copy, scope)
      assert is_nil(copy.send_confirmation_needed)

      assert [%{details: %{"source" => "json"}}] =
               Repo.all(
                 from a in PairingsEngine.Audit.AuditLog,
                   where: a.tournament_id == ^copy.id and a.action == "trf.copy_confirmed"
               )

      assert {:ok, 2} = PostponedGames.finalise(copy, [1])
    end

    test "a hand-off copy carries on sending, and knows what the other machine sent" do
      {t, _players} = tournament(fide_tournament_id: "616161")
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      file = t |> Repo.reload!() |> TournamentExport.export_tournament() |> over_the_wire()
      {:ok, [copy]} = TournamentImport.import(file, user_scope_fixture(), handoff: true)

      assert is_nil(copy.send_confirmation_needed)
      assert Enum.all?(records(copy, "report"), &(&1.origin == "handoff"))
      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(copy, [1])
    end

    test "a TRF of a played event asks before anything is sent" do
      {t, _players} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, text} = TrfExport.export(Repo.reload!(t), "1")

      {:ok, copy, _warnings} = TrfImport.import_text(text, user_scope_fixture())

      assert copy.send_confirmation_needed == "trf"
      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(copy, [1])
    end

    test "a JSON backup of a club event with nothing sent and no FIDE ID asks nothing" do
      {t, _players} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")

      backup = t |> Repo.reload!() |> TournamentExport.export_tournament() |> over_the_wire()
      {:ok, [copy]} = TournamentImport.import(backup, user_scope_fixture())

      assert is_nil(copy.send_confirmation_needed)
      assert {:ok, 2} = PostponedGames.finalise(copy, [1])
    end
  end

  describe "a locked copy (F3)" do
    test "cannot send a postponed-games file either" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      for p <- round1.pairings, p.id != postponed.id, do: result!(p, "1-0")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])
      result!(Repo.reload!(postponed), "1/2-1/2")

      {:ok, locked} = Tournaments.hand_off(Repo.reload!(t), "Arbiter laptop")

      assert {:error, :handed_off} =
               PostponedGames.send_late_games(locked, &TrfExport.postponed_export(&1, []))

      assert records(t, "postponed") == []
    end
  end

  describe "the postponed-games file is a tournament of its own" do
    # Round 1 sent with both games postponed; both played since, on `dates`.
    defp two_late_games!(dates, attrs \\ []) do
      {t, _players} = tournament(attrs)
      round1 = pair!(t)
      boards = for p <- round1.pairings, do: result!(p, "*W")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      for {p, date} <- Enum.zip(boards, dates) do
        result!(Repo.reload!(p), "1/2-1/2", played_on: date)
      end

      t
    end

    test "under its own name, dated by its games, with only them" do
      t = two_late_games!([~D[2026-09-20], ~D[2026-09-27]])

      {:ok, text, games} = TrfExport.postponed_export(Repo.reload!(t))
      assert length(games) == 2

      assert text =~ "012 Fixes club championship postponed games"
      assert text =~ "042 2026/09/20"
      assert text =~ "052 2026/09/27"
      refute text =~ "COPY"

      {:ok, _} =
        Tournaments.update_postponed_report(Repo.reload!(t), %{
          "postponed_report_name" => "Clubkampioenschap 26-27 uitgestelde partijen",
          "postponed_fide_tournament_id" => "777001"
        })

      t = Repo.reload!(t)
      assert t.postponed_fide_tournament_id == "777001"
      {:ok, text, _games} = TrfExport.postponed_export(t)
      assert text =~ "012 Clubkampioenschap 26-27 uitgestelde partijen"

      # A copy says it is one.
      {:ok, copy, _games} = TrfExport.postponed_export(t, copy: true)
      assert copy =~ "### COPY - NOT FOR RATING"
      assert Ainalrami.Trf.parse(copy).players |> length() == 4
    end

    test "the default name is in the page's language" do
      {t, _players} = tournament(name: "Clubkampioenschap 25-26")

      assert Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
               PostponedGames.report_name(t)
             end) == "Clubkampioenschap 25-26 uitgestelde partijen"

      assert PostponedGames.report_name(t) == "Clubkampioenschap 25-26 postponed games"
    end

    test "one rating period per file: games of two months are never mixed" do
      t = two_late_games!([~D[2026-09-28], ~D[2026-10-03]])

      assert {:error, {:mixed_periods, [~D[2026-09-01], ~D[2026-10-01]]}} =
               TrfExport.postponed_export(Repo.reload!(t))

      {:ok, text, [september]} =
        TrfExport.postponed_export(Repo.reload!(t), period: ~D[2026-09-01])

      assert september.pairing.played_on == ~D[2026-09-28]
      assert text =~ "052 2026/09/28"

      {:ok, _text, [_], _receipt} =
        PostponedGames.send_late_games(
          Repo.reload!(t),
          &TrfExport.postponed_export(&1, period: ~D[2026-09-01])
        )

      # The October game waits for its own file.
      assert {:ok, _text, [october]} = TrfExport.postponed_export(Repo.reload!(t))
      assert october.pairing.played_on == ~D[2026-10-03]
    end

    test "a game with no date played has no period, and is not sent until it has one" do
      t = two_late_games!([~D[2026-09-28], ~D[2026-09-29]])

      [game | _] = PostponedGames.sendable_late_games(Repo.reload!(t))

      Repo.update_all(
        from(p in PairingsEngine.Tournaments.Pairing, where: p.id == ^game.pairing.id),
        set: [played_on: nil]
      )

      assert {:error, :played_on_missing} = TrfExport.postponed_export(Repo.reload!(t))

      assert {:ok, _text, [_]} =
               TrfExport.postponed_export(Repo.reload!(t), period: ~D[2026-09-01])
    end
  end

  describe "the played date of a late game (F6)" do
    test "is kept by a correction, and changed only when asked" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      for p <- round1.pairings, p.id != postponed.id, do: result!(p, "1-0")

      played = result!(Repo.reload!(postponed), "1/2-1/2", played_on: ~D[2026-09-19])

      assert result!(played, "0-1", acknowledged: [:adjourned_non_draw_result]).played_on ==
               ~D[2026-09-19]

      assert result!(Repo.reload!(played), "1-0", played_on: ~D[2026-09-18]).played_on ==
               ~D[2026-09-18]

      # Re-postponed and played again: a new date, as it is a new game day.
      reopened = result!(Repo.reload!(played), "*W")
      assert is_nil(reopened.played_on)
      assert result!(reopened, "1/2-1/2").played_on == Date.utc_today()
    end
  end

  describe "a copy of a sent round (F7)" do
    test "parses as the same TRF, with the comment line skipped" do
      {t, _players} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, do: result!(p, "1-0")
      {:ok, sent} = TrfExport.export(Repo.reload!(t), "1")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])
      {:ok, copy} = TrfExport.export(Repo.reload!(t), "1")

      assert copy =~ "### COPY - NOT FOR RATING. Round 1 of this file"
      assert Ainalrami.Trf.parse(copy).players == Ainalrami.Trf.parse(sent).players

      # Downloaded as a copy before anything was sent: still marked.
      {t2, _players} = tournament()
      round = pair!(t2)
      for p <- round.pairings, do: result!(p, "1-0")
      {:ok, plain} = TrfExport.export(Repo.reload!(t2), "1")
      {:ok, copy} = TrfExport.export(Repo.reload!(t2), "1", copy: true)
      refute plain =~ "###"
      assert copy =~ "### COPY - NOT FOR RATING. Downloaded as a copy"

      # The older spelling, for pairing programs, carries no comment line.
      {:ok, engine} = TrfExport.export(Repo.reload!(t), "1", dialect: :engine, copy: true)
      refute engine =~ "###"
    end
  end
end
