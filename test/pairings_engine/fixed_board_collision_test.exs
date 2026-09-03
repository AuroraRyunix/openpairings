defmodule PairingsEngine.FixedBoardCollisionTest do
  @moduledoc """
  `Player.fixed_board` is SWAR's handicap/accessible-table concept: a player
  who must sit at one specific physical table. SWAR numbers those tables from
  1001 (`TABLE_HANDICAP`) precisely so they can never collide with an ordinary
  board number. OpenPairings kept the concept but accepts any integer, so an
  arbiter can pin a player to table **1** - a number the ordinary board
  sequence already uses.

  Doing that produces a round whose printed sheet carries the SAME LABEL
  twice:

      label 1     real board 1   P1 v P2
      label 2     real board 2   P3 v P4
      label 3     real board 3   P5 v P6
      label 4     real board 4   P7 v P8
      label 1     real board 5   P9 v P10   <- the accessible table, sorts last

  **This is a decision, not a bug.** The maintainer looked at that output and
  accepted it: a hall really can have one physical table 1 that is also the
  accessible table, renumbering the ordinary boards around the pin was
  explicitly rejected, and so was refusing the value outright. These tests
  exist so that decision cannot be quietly reversed - if someone later "fixes"
  the duplicate, or adds a validation that rejects a colliding value, this
  file fails loudly and the reversal has to be argued rather than slipped in.

  What makes the duplicate SAFE is a single architectural property, stated in
  `PairingsEngine.PairingDisplay`'s moduledoc and pinned test-by-test below:

      `display_board` is a LABEL and nothing else. Every consumer that can
      act on a pairing - the pairing engine, result writes, the audit trail,
      TRF, SWAR, the OpenResults snapshot, the JSON export - keys on the
      real, engine-assigned `pairing.board` integer, which stays unique.

  So the file is in three parts, matching the three things that must hold:

    1. **Allowed** - a colliding `fixed_board` is accepted by the real
       player-edit changeset and freezes without raising.
    2. **The duplicate is the expected output** - asserted explicitly, in
       display order (a list, never a map: a map would silently collapse the
       very duplicate this pins).
    3. **Nothing downstream keys on the label** - the engine input is
       byte-identical with and without the pin, results land on the pairing
       they were written for, and every export carries the real board.

  ## Defects the same sweep found next door

  The adversarial sweep that preceded this file found real problems adjacent
  to the collision, and each was written here first as a `@tag :skip`ped
  test asserting the CORRECT behaviour. All four were fixed on 2026-08-28
  and the tags are gone; each one's comment now records what was wrong and
  what the fix chose, because these are the tests that stop it coming back.
  Nothing in this file is skipped any more.
  """

  # async: false - the export/import round-trips below perform full
  # transactional imports (many sequential inserts on one connection), the
  # same reason `TournamentImportTest` and `ResultsImportTest` are serial.
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts.Scope

  # `PairingsEngine.Pairing` (the pairing context) and
  # `PairingsEngine.Tournaments.Pairing` (the schema) share a name - the rest
  # of the suite disambiguates the context as `PairingCtx`, so do the same.
  alias PairingsEngine.Pairing, as: PairingCtx

  alias PairingsEngine.{
    PairingDisplay,
    PgnExport,
    Repo,
    ResultsImport,
    Snapshot,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}

  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # The colliding value the maintainer accepted, and SWAR's own out-of-range
  # value, used as a control throughout: several assertions below are only
  # meaningful next to the 1001 case, because they show what does and does not
  # change when the pin stops being out of range.
  @colliding 1
  @swar_handicap 1001

  @results %{1 => "1-0", 2 => "0-1", 3 => "1/2-1/2", 4 => "1-0", 5 => "0-1"}

  ## ---------- fixture ----------

  # Ten players, five boards, one optional pin. `pin` is `{player_number,
  # fixed_board}` (1-based, so `{9, 1}` is the maintainer's own reported
  # layout: the pinned player sits on real board 5, the last one).
  #
  # The pin is applied through `Player.changeset/2` with STRING params - the
  # exact path the Players page form takes - so `special_table` is synced by
  # `sync_special_table/1` the way it is in production, not bypassed by a
  # bare `Ecto.Changeset.change/2`.
  defp fixture(opts \\ []) do
    pin = Keyword.get(opts, :pin)
    results = Keyword.get(opts, :results, %{})
    pin_after_pairing? = Keyword.get(opts, :pin_after_pairing, false)

    t =
      Repo.insert!(%Tournament{
        name: "Fixed Board Collision",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 3,
        public_slug: "collision-#{System.unique_integer([:positive])}"
      })

    players =
      for n <- 1..10 do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: "Player#{n}, X.",
          fide_rating: 2000 - n,
          pairing_number: n
        })
      end

    unless pin_after_pairing?, do: apply_pin(players, pin)

    round =
      Repo.insert!(%Round{
        tournament_id: t.id,
        number: 1,
        status: "playing",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    players
    |> Enum.map(&Repo.reload!/1)
    |> Enum.chunk_every(2)
    |> Enum.with_index(1)
    |> Enum.each(fn {[w, b], board} ->
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b.id,
        result: Map.get(results, board, "")
      })
    end)

    # Every production pairing path freezes immediately after inserting a
    # round's pairings - see `Tournaments.freeze_round_display_boards!/1`'s
    # callers. Do the same, or the fixture is a round no arbiter could ever
    # produce.
    :ok = Tournaments.freeze_round_display_boards!(round.id)

    if pin_after_pairing?, do: apply_pin(players, pin)

    {Repo.reload!(t), round, Enum.map(players, &Repo.reload!/1)}
  end

  defp apply_pin(_players, nil), do: :ok

  defp apply_pin(players, {player_number, value}) do
    {:ok, _} =
      players
      |> Enum.at(player_number - 1)
      |> Player.changeset(%{"fixed_board" => to_string(value)})
      |> Repo.update()

    :ok
  end

  defp pairings(round_id) do
    Repo.all(
      from p in Pairing,
        where: p.round_id == ^round_id,
        preload: [:white_player, :black_player]
    )
  end

  # The printed sheet, in display order, as a LIST of
  # `{label, real board, special?}`. A list, not a map, on purpose: keying
  # this by label would collapse the duplicate that is the whole subject of
  # this file, and keying it by real board would hide whether the label is
  # duplicated at all.
  defp sheet(round_id) do
    round_id
    |> pairings()
    |> PairingDisplay.with_display_boards()
    |> Enum.map(fn %{pairing: p, board: label} -> {label, p.board, p.display_special} end)
  end

  defp labels(round_id), do: round_id |> sheet() |> Enum.map(&elem(&1, 0))

  defp result_by_real_board(round_id) do
    Repo.all(from p in Pairing, where: p.round_id == ^round_id, order_by: p.board)
    |> Map.new(&{&1.board, &1.result})
  end

  defp scope, do: Scope.for_user(user_fixture())

  ## ---------- 1. the collision is allowed ----------

  describe "a colliding fixed_board is allowed, not rejected" do
    test "the player-edit changeset accepts 1 and syncs special_table" do
      {_t, _round, players} = fixture()

      changeset = Player.changeset(hd(players), %{"fixed_board" => to_string(@colliding)})

      assert changeset.valid?,
             "fixed_board=#{@colliding} was rejected by Player.changeset/2 - the maintainer " <>
               "explicitly chose to ALLOW a colliding pin rather than error on it"

      assert {:ok, player} = Repo.update(changeset)
      assert player.fixed_board == @colliding
      # SWAR round-trip compat: the boolean must follow the number.
      assert player.special_table
    end

    test "freezing a round that contains a colliding pin does not raise" do
      {_t, round, _players} = fixture(pin: {9, @colliding})

      assert :ok = Tournaments.freeze_round_display_boards!(round.id)
    end

    test "a colliding pin is stored and read back verbatim - it is not coerced into SWAR's range" do
      {_t, _round, players} = fixture(pin: {9, @colliding})

      assert Enum.find(players, & &1.fixed_board).fixed_board == @colliding
    end
  end

  ## ---------- 2. the duplicate label IS the expected output ----------

  describe "the duplicate label is the accepted output, asserted explicitly" do
    test "the maintainer's reported layout: two rows labelled 1, the special one last" do
      {_t, round, _players} = fixture(pin: {9, @colliding})

      # This exact list is the decision. Changing it - renumbering the
      # ordinary boards around the pin, relabelling the special row, or
      # refusing the value - is a product decision, not a refactor.
      assert sheet(round.id) == [
               {"1", 1, false},
               {"2", 2, false},
               {"3", 3, false},
               {"4", 4, false},
               {"1", 5, true}
             ]
    end

    test "the duplicate is in the LABEL only - the real board column stays unique" do
      {_t, round, _players} = fixture(pin: {9, @colliding})

      real_boards = round.id |> sheet() |> Enum.map(&elem(&1, 1))

      assert Enum.sort(real_boards) == [1, 2, 3, 4, 5]
      assert length(Enum.uniq(real_boards)) == 5

      # ...while the labels deliberately are not unique.
      assert labels(round.id) == ["1", "2", "3", "4", "1"]
      assert length(Enum.uniq(labels(round.id))) == 4
    end

    test "control: the same layout pinned to SWAR's 1001 produces no duplicate" do
      {_t, round, _players} = fixture(pin: {9, @swar_handicap})

      assert sheet(round.id) == [
               {"1", 1, false},
               {"2", 2, false},
               {"3", 3, false},
               {"4", 4, false},
               {"1001", 5, true}
             ]
    end

    test "a pin that is NOT on the last board still renumbers the ordinary boards around it" do
      # Player 5 sits on real board 3. The special row leaves the ordinary
      # sequence with no hole (real 4 becomes label 3, real 5 becomes 4) and
      # sorts to the bottom - the documented renumbering, here producing the
      # duplicate "1" in the middle of the real-board order.
      {_t, round, _players} = fixture(pin: {5, @colliding})

      assert sheet(round.id) == [
               {"1", 1, false},
               {"2", 2, false},
               {"3", 4, false},
               {"4", 5, false},
               {"1", 3, true}
             ]
    end

    test "two players both pinned to 1 produce three rows labelled 1" do
      # Nothing dedupes across pairings, and nothing should: each pinned
      # player is a separate physical-table instruction. Pinned players 1 and
      # 5 sit on real boards 1 and 3, so the ordinary boards left over (2, 4,
      # 5) are numbered "1", "2", "3" and both special rows sort to the end
      # carrying "1" - three rows labelled 1 in one round.
      {_t, round, _players} = fixture(pin: {1, @colliding})
      {:ok, _} = apply_extra_pin(round, 5, @colliding)

      assert :ok = Tournaments.freeze_round_display_boards!(round.id)

      assert sheet(round.id) == [
               {"1", 2, false},
               {"2", 4, false},
               {"3", 5, false},
               {"1", 1, true},
               {"1", 3, true}
             ]
    end

    test "one pairing with two DIFFERENT pinned players is slash-joined, not duplicated" do
      # Players 9 and 10 face each other on real board 5.
      {_t, round, _players} = fixture(pin: {9, @colliding})
      {:ok, _} = apply_extra_pin(round, 10, 7)

      assert :ok = Tournaments.freeze_round_display_boards!(round.id)

      assert sheet(round.id) == [
               {"1", 1, false},
               {"2", 2, false},
               {"3", 3, false},
               {"4", 4, false},
               {"1/7", 5, true}
             ]
    end
  end

  defp apply_extra_pin(round, player_number, value) do
    round.tournament_id
    |> Tournaments.list_players()
    |> Enum.find(&(&1.pairing_number == player_number))
    |> Player.changeset(%{"fixed_board" => to_string(value)})
    |> Repo.update()
  end

  ## ---------- 3a. results land on the right game ----------

  describe "results land on the pairing they were written for, never on a label" do
    test "writing to each of the two rows labelled 1 hits a different game" do
      {_t, round, _players} = fixture(pin: {9, @colliding})

      [first, last] =
        round.id
        |> pairings()
        |> Enum.filter(&(&1.display_board == "1"))
        |> Enum.sort_by(& &1.board)

      # This is the write path the Pairings page's inline <select> uses: the
      # pairing STRUCT, resolved by id, never by a number the page rendered.
      assert {:ok, _} = Tournaments.update_pairing_result(first, "1-0")
      assert {:ok, _} = Tournaments.update_pairing_result(last, "0-1")

      assert result_by_real_board(round.id) == %{
               1 => "1-0",
               2 => "",
               3 => "",
               4 => "",
               5 => "0-1"
             }
    end

    test "CSV results import resolves by the DISPLAYED label, not the real board" do
      {t, round, _players} = fixture(pin: {9, @colliding})

      # Real board 5 is the pinned one and the sheet labels it "1"; the four
      # ordinary rows are labelled 1..4 for real boards 1..4. So the real
      # board number 5 appears on no document the arbiter can read, and
      # naming it is now an error rather than a silent write.
      #
      # This test asserted the opposite until 2026-08-28. It was a
      # characterisation of the defect, not a specification: keying on the
      # real column is exactly what made transcribing a sheet land results
      # on the wrong games.
      assert {:error, ["board 5: no such board in round 1"]} =
               ResultsImport.apply_import(t, 1, [{5, "0-1"}])

      assert result_by_real_board(round.id)[5] == ""

      # "4" is the last ordinary row, which is real board 4.
      assert {:ok, 1} = ResultsImport.apply_import(t, 1, [{4, "0-1"}])
      assert result_by_real_board(round.id)[4] == "0-1"
    end

    test "an out-of-range fixed table is addressable by its own number" do
      {t, round, _players} = fixture(pin: {9, 1001})

      # SWAR's own range does not collide, so the label is unique and names
      # exactly one game. Before the importer resolved by label this was not
      # reachable from a CSV at all - 1001 is never a real board number, so
      # it failed with "no such board".
      assert {:ok, 1} = ResultsImport.apply_import(t, 1, [{1001, "0-1"}])
      assert result_by_real_board(round.id)[5] == "0-1"
    end

    test "a CSV naming the same number twice is refused before anything is written" do
      {t, round, _players} = fixture(pin: {9, @colliding})

      # The arbiter's most faithful transcription of a sheet showing two rows
      # numbered 1 is two lines starting "1," - and it is rejected at parse
      # time, so no half-applied round can result.
      assert {:error, [reason]} = ResultsImport.parse_text("1,1-0\n1,0-1\n")
      assert reason =~ "board 1"
      assert reason =~ "more than once"

      assert result_by_real_board(round.id) == %{1 => "", 2 => "", 3 => "", 4 => "", 5 => ""}
      assert {:ok, 0} = ResultsImport.apply_import(t, 1, [])
    end

    # FIXED in ea960ff - was lib/pairings_engine/results_import.ex:178.
    #
    # `apply_import/3` resolved each CSV line against `pairing.board` (the
    # real column) while every document the arbiter reads - the printed sheet
    # (print_controller.ex:653), the Pairings page (pairings_live.ex:2156),
    # the public page and the projector - prints the frozen LABEL. Whenever
    # the pinned board was not the last real board, those were two different
    # numbering spaces, so typing the sheet's own numbers silently wrote
    # results onto the wrong games and reported success.
    #
    # It was PRE-EXISTING and not caused by the accepted collision: the
    # adversarial pass reproduced identical damage with fixed_board=1001.
    # Allowing 1 only removed the accidental protection an out-of-range label
    # used to give (an "unknown board" error instead of a wrong write).
    test "CSV import addresses the boards the arbiter can actually see" do
      # Player 5 => real board 3. Sheet: real1->"1" real2->"2" real4->"3"
      # real5->"4", special real3->"1".
      {t, round, _players} = fixture(pin: {5, @colliding})

      assert labels(round.id) == ["1", "2", "3", "4", "1"]

      # The arbiter reads the sheet top to bottom and types its four ordinary
      # rows. Those name real boards 1, 2, 4 and 5.
      rows = [{1, "1-0"}, {2, "1-0"}, {3, "1-0"}, {4, "1-0"}]
      assert {:ok, 4} = ResultsImport.apply_import(t, 1, rows)

      assert result_by_real_board(round.id) == %{
               1 => "1-0",
               2 => "1-0",
               # the accessible board - never named by the arbiter
               3 => "",
               4 => "1-0",
               5 => "1-0"
             }
    end
  end

  ## ---------- 3b. the pairing engine never sees fixed_board ----------

  describe "the pairing engine is blind to fixed_board" do
    test "the TRF handed to the engine is byte-identical before and after a pin" do
      {t, _round, players} = fixture()

      before_input = PairingCtx.javafo_input(t)
      :ok = apply_pin(players, {9, @colliding})
      after_input = PairingCtx.javafo_input(Repo.reload!(t))

      assert after_input == before_input,
             "a fixed_board pin changed the engine's input file - a seating " <>
               "accommodation must never be able to change WHO plays WHOM"
    end

    test "the rows handed to the engine carry no board of any kind" do
      {t, _round, _players} = fixture(pin: {9, @colliding})

      rows = PairingCtx.trf_player_rows(t, Tournaments.list_players(t.id))

      assert rows != []

      for row <- rows do
        refute Map.has_key?(row, :board)
        refute Map.has_key?(row, :display_board)
        refute Map.has_key?(row, :fixed_board)
        refute Map.has_key?(row, :special_table)

        for game <- row.games do
          refute Map.has_key?(game, :board)
        end
      end
    end
  end

  ## ---------- 3c. every export carries the real board ----------

  describe "TRF16 export/import" do
    test "the TRF text is byte-identical before and after a pin" do
      {t, _round, players} = fixture(results: @results)

      assert {:ok, before_text} = TrfExport.export(t)
      :ok = apply_pin(players, {9, @colliding})
      assert {:ok, after_text} = TrfExport.export(Repo.reload!(t))

      # TRF16's 001 record has no board column at all - only starting rank,
      # opponent rank, colour and result - so the pin contributes zero bytes
      # and the duplicate label has no channel to travel through.
      assert after_text == before_text
    end

    test "re-importing gives a clean 1..N sequence with every result intact" do
      {t, _round, _players} = fixture(pin: {9, @colliding}, results: @results)

      assert {:ok, text} = TrfExport.export(t)
      assert {:ok, imported, _warnings} = TrfImport.import_text(text, scope())

      round = Tournaments.get_round(imported.id, 1)

      # No fixed_board survives (TRF16 cannot express one), so the copy shows
      # an ordinary, duplicate-free sequence...
      assert labels(round.id) == ["1", "2", "3", "4", "5"]
      refute Enum.any?(Tournaments.list_players(imported.id), & &1.fixed_board)

      # ...and every game is still the game it was.
      assert Map.values(result_by_real_board(round.id)) |> Enum.sort() ==
               @results |> Map.values() |> Enum.sort()
    end
  end

  describe "SWAR export/import" do
    test "the per-round Table field carries the REAL board, not the label and not 1001" do
      {t, _round, _players} = fixture(pin: {9, @colliding}, results: @results)

      assert {:ok, parsed} = t |> SwarExport.export() |> SwarImport.parse()

      tables =
        parsed.players
        |> Enum.flat_map(&(&1.rounds || []))
        |> Enum.map(& &1[:table])
        |> Enum.uniq()
        |> Enum.sort()

      assert tables == [1, 2, 3, 4, 5]
    end

    test "the handicap table travels, and results/boards survive the round-trip" do
      {t, _round, _players} = fixture(pin: {9, @colliding}, results: @results)

      bin = SwarExport.export(t)
      assert {:ok, parsed} = SwarImport.parse(bin)

      # HandyTable carries the pinned table number (0 = no fixed table), so
      # exactly one player is marked.
      assert Enum.count(parsed.players, &(&1.handy_table != 0)) == 1
      assert Enum.find(parsed.players, &(&1.handy_table != 0)).handy_table == @colliding

      path =
        Path.join(
          System.tmp_dir!(),
          "fixed_board_collision_#{System.unique_integer([:positive])}.swar"
        )

      File.write!(path, bin)

      try do
        assert {:ok, imported, _warnings} = SwarImport.import_file(path, scope())

        round = Tournaments.get_round(imported.id, 1)

        assert Map.keys(result_by_real_board(round.id)) == [1, 2, 3, 4, 5]

        assert Map.values(result_by_real_board(round.id)) |> Enum.sort() ==
                 @results |> Map.values() |> Enum.sort()
      after
        File.rm(path)
      end
    end

    # FIXED 2026-08-28 - was lib/pairings_engine/swar_import.ex:1554 with
    # lib/pairings_engine/swar_export.ex:512.
    #
    # `SwarImport` set `special_table: p.handy_table != 0` and never set
    # `fixed_board` at all, while `PairingDisplay.special?/1` decides
    # specialness solely on `fixed_board != nil`. So a SWAR-imported handicap
    # player was not special anywhere: ordinary label, ordinary sort
    # position, and no "(table N)" note on their card. The export side
    # compounded it - `w_i16(if p.special_table, do: 1, else: 0)` degraded
    # the table NUMBER to a boolean, so even a correct importer could not
    # have recovered it. A .swar backup/restore, an ordinary arbiter
    # workflow, silently stopped honouring the pin.
    #
    # HandyTable is a signed 16-bit table NUMBER - SWAR's own 1001+ handicap
    # numbering lives in it (`SwarImport`'s `@table_handicap`) - so the fix
    # was to write and read the number. It is the whole number that travels,
    # not a re-derived one: pinned to 1, this comes back as 1.
    test "a SWAR round-trip keeps the accessible table" do
      {t, _round, _players} = fixture(pin: {9, @colliding}, results: @results)

      path =
        Path.join(
          System.tmp_dir!(),
          "fixed_board_collision_#{System.unique_integer([:positive])}.swar"
        )

      File.write!(path, SwarExport.export(t))

      try do
        assert {:ok, imported, _warnings} = SwarImport.import_file(path, scope())

        pinned = Enum.filter(Tournaments.list_players(imported.id), & &1.fixed_board)
        assert [player] = pinned
        assert player.fixed_board == @colliding
        assert player.special_table

        round = Tournaments.get_round(imported.id, 1)
        assert {"1", _real, true} = round.id |> sheet() |> List.last()
      after
        File.rm(path)
      end
    end

    # The control that tells a NUMBER from a FLAG. Pinned to SWAR's own
    # 1001, a boolean HandyTable would come back as fixed_board 1 (or as
    # nothing at all, which is what it did); only a round-trip that carries
    # the number can return 1001.
    test "the table NUMBER survives, not a boolean re-derived from it" do
      {t, _round, _players} = fixture(pin: {9, @swar_handicap}, results: @results)

      path =
        Path.join(
          System.tmp_dir!(),
          "fixed_board_collision_#{System.unique_integer([:positive])}.swar"
        )

      File.write!(path, SwarExport.export(t))

      try do
        assert {:ok, imported, _warnings} = SwarImport.import_file(path, scope())

        assert [player] = Enum.filter(Tournaments.list_players(imported.id), & &1.fixed_board)
        assert player.fixed_board == @swar_handicap
        assert player.special_table

        round = Tournaments.get_round(imported.id, 1)
        assert {"1001", _real, true} = round.id |> sheet() |> List.last()
      after
        File.rm(path)
      end
    end

    # The two fields are read in different places - `PairingDisplay` looks
    # only at `fixed_board`, `SwarExport` looks at both - so a row with one
    # set and not the other is special in exactly one of them. That was the
    # SWAR importer's own output for as long as it wrote the boolean alone.
    test "an imported handicap player carries BOTH fields, never just one" do
      {t, _round, _players} = fixture(pin: {9, @colliding})

      path =
        Path.join(
          System.tmp_dir!(),
          "fixed_board_collision_#{System.unique_integer([:positive])}.swar"
        )

      File.write!(path, SwarExport.export(t))

      try do
        assert {:ok, imported, _warnings} = SwarImport.import_file(path, scope())

        for player <- Tournaments.list_players(imported.id) do
          assert player.special_table == not is_nil(player.fixed_board),
                 "#{player.name} came back with special_table=#{player.special_table} and " <>
                   "fixed_board=#{inspect(player.fixed_board)} - a player who is a special " <>
                   "board in one half of the app and an ordinary one in the other"
        end
      after
        File.rm(path)
      end
    end

    # Databases the OLD importer wrote still hold rows marked `special_table`
    # with no `fixed_board` - the flag is genuinely all those rows ever knew.
    # The export still carries their marking rather than dropping it on the
    # floor because the number it would prefer is missing.
    test "a legacy special_table row with no fixed_board still exports its marking" do
      {t, _round, players} = fixture()

      players
      |> Enum.at(8)
      |> Ecto.Changeset.change(special_table: true, fixed_board: nil)
      |> Repo.update!()

      assert {:ok, parsed} = t |> SwarExport.export() |> SwarImport.parse()

      assert Enum.count(parsed.players, &(&1.handy_table != 0)) == 1
    end
  end

  describe "OpenResults snapshot" do
    test "boards[].board is the real integer board - five distinct numbers, no duplicate" do
      {t, _round, _players} = fixture(pin: {9, @colliding}, results: @results)

      snapshot = Snapshot.build(t)
      [round] = snapshot["rounds"]
      boards = Enum.map(round["boards"], & &1["board"])

      assert boards == [1, 2, 3, 4, 5]
      assert boards == Enum.uniq(boards)
    end

    test "the snapshot is byte-identical with and without the pin" do
      {t, _round, players} = fixture(results: @results)

      strip_timestamps = fn snapshot ->
        snapshot |> Map.delete("published_at") |> Map.delete("source")
      end

      before_snapshot = t |> Snapshot.build() |> strip_timestamps.()
      :ok = apply_pin(players, {9, @colliding})
      after_snapshot = Repo.reload!(t) |> Snapshot.build() |> strip_timestamps.()

      # The snapshot publishes no fixed-table information at all - it is the
      # real board or nothing - so a pin cannot change a published document.
      assert after_snapshot == before_snapshot
    end
  end

  describe "full-fidelity JSON export/import" do
    test "a pin set BEFORE pairing round-trips exactly, duplicate label and all" do
      {t, round, _players} = fixture(pin: {9, @colliding}, results: @results)

      envelope = TournamentExport.export_tournament(t)
      assert {:ok, [copy]} = TournamentImport.import(envelope, scope())

      copy_round = Tournaments.get_round(copy.id, 1)

      # `display_board`/`display_special` are deliberately NOT exported - they
      # are recomputed on import from the round-tripped `fixed_board`, so this
      # asserts the recompute lands on exactly the same answer.
      assert sheet(copy_round.id) == sheet(round.id)
      assert result_by_real_board(copy_round.id) == result_by_real_board(round.id)

      assert [pinned] = Enum.filter(Tournaments.list_players(copy.id), & &1.fixed_board)
      assert pinned.fixed_board == @colliding
      assert pinned.special_table
    end

    # FIXED 2026-08-28 - was lib/pairings_engine/tournament_import.ex:230
    # (reached from lib/pairings_engine/snapshots.ex:374 on a restore).
    #
    # `PairingDisplay`'s moduledoc promises labels are "computed exactly ONCE
    # per round ... never live again". That held live - the test in
    # board_stability_test.exs proves pinning a player mid-round changes
    # nothing - but NOT across an export/import or a snapshot restore:
    # `@pairing_excluded` dropped the frozen columns and the importer
    # re-froze every round from the payload's CURRENT `fixed_board`.
    #
    # So a round that was played, printed and handed out as 1..5 came back
    # from a restore relabelled - here acquiring two rows numbered "1" that
    # the sheets on the tables never showed. Real boards and results were
    # untouched, so it was a display/print-record defect, not corruption; it
    # was pre-existing for any fixed_board value and the collision only made
    # its symptom louder.
    #
    # The export now carries `display_board`/`display_special` and the
    # importer restores them verbatim, recomputing only for a payload old
    # enough to have neither.
    test "a round already played keeps its labels across an export/import" do
      {t, round, _players} =
        fixture(pin: {5, @colliding}, results: @results, pin_after_pairing: true)

      # The live round is correctly untouched by the later pin.
      assert labels(round.id) == ["1", "2", "3", "4", "5"]

      envelope = TournamentExport.export_tournament(Repo.reload!(t))
      assert {:ok, [copy]} = TournamentImport.import(envelope, scope())

      copy_round = Tournaments.get_round(copy.id, 1)
      assert labels(copy_round.id) == labels(round.id)
    end
  end

  describe "PGN export" do
    test "the [Board] tag carries the REAL board, so the accepted duplicate stops here" do
      {t, _round, _players} = fixture(pin: {9, @colliding}, results: @results)

      pgn = PgnExport.export(t, 1, board: true)

      tags = Regex.scan(~r/\[Board "([^"]+)"\]/, pgn) |> Enum.map(&Enum.at(&1, 1))

      # THE TRIPWIRE FIRED, AND THE DECISION WAS TAKEN - 2026-08-28.
      #
      # This used to assert the opposite, and said so: the tag carried the
      # display label, so a pin colliding with an ordinary board exported two
      # games in one round both tagged Board 1. It was asserted "so that
      # changing it is a decision rather than a silent drift". This is that
      # decision, argued rather than slipped in.
      #
      # A PGN tag is never read by somebody standing at a board. It is how a
      # reader or a database tells one game of a round apart from the others,
      # keyed on (Event, Round, Board) - a job that REQUIRES uniqueness within
      # the round, which the label does not have once a fixed table collides.
      # `pairing.board` is engine-assigned and unique by construction.
      #
      # This pulls the OPPOSITE way from the printed documents in this same
      # file, and that is deliberate: a place card is read by a person who has
      # to find a physical table, so it must agree with the pairing sheet; a
      # PGN is read by software that has to tell two games apart, so it must
      # be unique. Same number, two documents, two different right answers.
      # Full reasoning in `PgnExport.board_tag/1`.
      #
      # The duplicate label is still the accepted output on every human-facing
      # surface - the sheet assertions above are unchanged. It simply no
      # longer reaches a machine-readable export.
      assert Enum.sort(tags) == ["1", "2", "3", "4", "5"]
      assert tags == Enum.uniq(tags)
    end

    test "control: pinned to 1001 the tags are the same real boards, pin or no pin" do
      {t, _round, _players} = fixture(pin: {9, @swar_handicap}, results: @results)

      pgn = PgnExport.export(t, 1, board: true)

      tags = Regex.scan(~r/\[Board "([^"]+)"\]/, pgn) |> Enum.map(&Enum.at(&1, 1))

      # 1001 is a seating instruction, not a board number, and no longer
      # travels into the export at all. Pinned or not, the tags are the
      # engine's own numbering - which is the point: an export should not
      # change shape because an arbiter accommodated a player.
      assert Enum.sort(tags) == ["1", "2", "3", "4", "5"]
      assert tags == Enum.uniq(tags)
    end
  end

  ## ---------- adjacent defects found by the same sweep ----------

  describe "known defects adjacent to the collision" do
    # FIXED 2026-08-28 - was lib/pairings_engine/tournaments.ex:2528.
    #
    # `do_pair_from_pool/4` was the ONE pairing-creating path that never
    # froze what it inserted (every other one does: pairing.ex:658, :1426,
    # :1497, round_robin.ex:456, keizer.ex:428, and all three importers).
    # The new row's `display_board` stayed nil and fell through to
    # `PairingDisplay.fallback_label/1`, i.e. its REAL board - a different
    # numbering space from the round's frozen labels, so the printed
    # sequence gained a visible gap (1, 2, 3, 4, 6, and the special 1). The
    # modal accepts any free board the arbiter types, so a hole in the low
    # real boards would have put that fallback back inside the frozen range
    # and produced a second kind of duplicate nobody signed off on.
    #
    # It freezes ONLY the row it inserts (`freeze_new_pairing_display_board!/1`),
    # never the whole round: this round is already printed and sat down at,
    # and a full re-freeze recomputes every label from each player's
    # fixed_board as it stands now - the retroactive renumbering the freeze
    # exists to prevent. The next test pins that distinction.
    test "pair_from_pool freezes the row it inserts" do
      {t, _round, _players} = fixture(pin: {9, @colliding})

      a = Repo.insert!(%Player{tournament_id: t.id, name: "Late One", pairing_number: 11})
      b = Repo.insert!(%Player{tournament_id: t.id, name: "Late Two", pairing_number: 12})

      round = Tournaments.get_round(t.id, 1)
      assert {:ok, _} = Tournaments.pair_from_pool(round, a.id, b.id, 6)

      new_pairing = Enum.find(pairings(round.id), &(&1.board == 6))
      refute is_nil(new_pairing.display_board)

      assert labels(round.id) == ["1", "2", "3", "4", "5", "1"]
    end

    # A round already printed keeps its numbering when a late pairing is
    # added to it - the invariant that makes the fix above narrow rather
    # than a call to `freeze_round_display_boards!/1`.
    test "pair_from_pool does not renumber the round it is inserting into" do
      # Paired and frozen with no pin at all: a plain 1..5.
      {t, round, players} = fixture()
      assert labels(round.id) == ["1", "2", "3", "4", "5"]

      # The arbiter pins player 9 - who is sitting on real board 5 right now
      # - and only then pairs two latecomers in. The pin correctly does
      # nothing to this round (board_stability_test.exs pins that on its
      # own); the question here is whether pairing someone in re-opens it.
      :ok = apply_pin(players, {9, @colliding})

      a = Repo.insert!(%Player{tournament_id: t.id, name: "Late One", pairing_number: 11})
      b = Repo.insert!(%Player{tournament_id: t.id, name: "Late Two", pairing_number: 12})

      assert {:ok, _} = Tournaments.pair_from_pool(Tournaments.get_round(t.id, 1), a.id, b.id, 6)

      # A whole-round re-freeze would answer ["1", "2", "3", "4", "5", "1"]:
      # real board 5 moved to the bottom as a special board and everything
      # after it renumbered, under players already seated. Nothing moves -
      # the new row just continues the printed sequence.
      assert labels(round.id) == ["1", "2", "3", "4", "5", "6"]
    end

    # FIXED 2026-08-28 - was lib/pairings_engine/tournaments/player.ex:104.
    #
    # `fixed_board` was cast with no `validate_number/3`, so 0 and negative
    # values were accepted and reached the label, the PGN [Board] tag and
    # every printed document. The only guard was the `min="1"` attribute on
    # the Players page input, which is client-side and is bypassed by a
    # crafted form post or by a JSON import (fixed_board travels in
    # @player_fields).
    #
    # This is NOT a rejection of the accepted colliding value 1 - it is the
    # opposite end: a board number that cannot exist at all.
    test "fixed_board must be a positive board number" do
      {_t, _round, players} = fixture()
      player = hd(players)

      refute Player.changeset(player, %{"fixed_board" => "0"}).valid?
      refute Player.changeset(player, %{"fixed_board" => "-3"}).valid?

      # ...while the accepted collision stays valid.
      assert Player.changeset(player, %{"fixed_board" => "1"}).valid?
    end
  end
end
