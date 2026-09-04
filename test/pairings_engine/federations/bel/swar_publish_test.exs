defmodule PairingsEngine.Federations.BEL.SwarPublishTest do
  # async: false - writes to the shared `meta` table (the `Version` setting,
  # the installation pseudo-MAC) and to `tournaments.swar_guid`, same
  # SQLite-single-writer reasoning as every other export test.
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Standings, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarPublish
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  defp fixture(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "SWAR Publish Test",
            "type" => "swiss",
            "rounds_count" => "2",
            "organizer" => "Test Chess Club",
            "organizer_club_number" => "351",
            "chief_arbiter" => "Jane Arbiter",
            "rate_of_play" => "90 min + 30 sec/move",
            "start_date" => "2026-08-01",
            "end_date" => "2026-08-02",
            "round_dates" => ["2026-08-01", "2026-08-02"],
            "tiebreaks" => ["SB", "WIN"],
            "standard" => "standard"
          },
          attrs
        )
      )

    alice =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice, A.",
        sex: "w",
        fide_rating: 2000
      })

    bob =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Bob, B.",
        sex: "m",
        national_rating: 1800
      })

    r1 =
      Repo.insert!(%Round{tournament_id: tournament.id, number: 1, date: "2026-08-01"})

    r2 =
      Repo.insert!(%Round{tournament_id: tournament.id, number: 2, date: "2026-08-02"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    # A pairing-allocated bye on round 2, alongside a real game - exercises
    # `board_row/3`'s bye branch without a second reference file to check
    # its exact shape against (see the moduledoc).
    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: alice.id,
      result: ""
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 2,
      white_player_id: alice.id,
      black_player_id: nil,
      result: "bye"
    })

    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    :ok = Tournaments.freeze_round_display_boards!(r2.id)

    Tournaments.get_tournament!(tournament.id)
  end

  describe "version/0 and put_version/1" do
    test "defaults to v7.00 when nothing has been set" do
      assert SwarPublish.version() == "v7.00"
    end

    test "put_version/1 is honoured by version/0 and by export/1's head" do
      tournament = fixture(user_scope_fixture())

      SwarPublish.put_version("v7.12")
      assert SwarPublish.version() == "v7.12"

      html = SwarPublish.export(tournament)
      assert html =~ "<meta name='Version' content='v7.12'>"
    end

    test "a blank value restores the default rather than storing an empty tag" do
      SwarPublish.put_version("v7.12")
      SwarPublish.put_version("")

      assert SwarPublish.version() == "v7.00"
    end
  end

  describe "ensure_guid!/1" do
    test "a tournament with no swar_guid gets one, in the documented shape, and it persists" do
      tournament = fixture(user_scope_fixture())
      assert tournament.swar_guid in [nil, ""]

      updated = SwarPublish.ensure_guid!(tournament)

      assert updated.swar_guid =~ ~r/^351-\d{6}-[0-9a-f]{8}-\{[0-9a-f-]{36}\}$/

      # Persisted, not just held in memory on the returned struct - a
      # second, independent read of the row must see the same value.
      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.swar_guid == updated.swar_guid
    end

    test "an existing swar_guid is used verbatim and never overwritten" do
      tournament =
        fixture(user_scope_fixture(), %{
          "swar_guid" => "351-250101-deadbeef-{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"
        })

      updated = SwarPublish.ensure_guid!(tournament)

      assert updated.swar_guid == "351-250101-deadbeef-{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"
    end
  end

  describe "export/1 - <head>" do
    test "carries every required meta tag" do
      tournament = fixture(user_scope_fixture())
      html = SwarPublish.export(tournament)

      for name <- ~w(Guid MacGuid MacSend Annee Fede Organisateur Type Round DateStart DateEnd
                     Tournoi DateSend Version Cache-Control Description Author Keywords Robots) do
        assert html =~ "name='#{name}'", "expected a <meta name='#{name}'> tag"
      end

      assert html =~ "<meta charset='utf-8'>"
      assert html =~ "<title>SWAR Publish Test</title>"
    end

    test "<html lang> follows the current Gettext locale" do
      tournament = fixture(user_scope_fixture())
      Gettext.put_locale(PairingsEngineWeb.Gettext, "nl")

      html = SwarPublish.export(tournament)

      assert html =~ "<html lang='nl'>"
    end
  end

  describe "export/1 - tableClassement" do
    test "standings columns follow the tournament's configured tiebreaks" do
      tournament = fixture(user_scope_fixture())
      html = SwarPublish.export(tournament)

      assert html =~ "<table class='tableClassement'>"
      # "SB" and "WIN" (the fixture's configured tiebreaks) show up as
      # SWAR's own Dutch abbreviations - "SB" and "#Win".
      assert html =~ "<td class='tdrib'>SB</td>"
      assert html =~ "<td class='tdrib'>#Win</td>"
      # Nothing this tournament did NOT configure should appear as a column.
      refute html =~ "<td class='tdrib'>Buch</td>"
      refute html =~ "<td class='tdrib'>Koya</td>"

      assert html =~ "Alice, A."
      assert html =~ "Bob, B."
    end

    test "a standings-row name is plain text, never a player-card link" do
      tournament = fixture(user_scope_fixture())
      html = SwarPublish.export(tournament)

      [_before, classement_and_after] =
        String.split(html, "<table class='tableClassement'>", parts: 2)

      [classement, _rest] = String.split(classement_and_after, "<!-- RESULTATS -->", parts: 2)

      refute classement =~ "<a href='#jou_"
    end
  end

  describe "export/1 - tableResultats" do
    test "a round table renders boards, both players and the result" do
      tournament = fixture(user_scope_fixture())
      html = SwarPublish.export(tournament)

      assert html =~ "<tr id='Round1'>"
      assert html =~ "Ronde 1"
      assert html =~ "<table class='tableResultats' style='width:100%;'>"
      assert html =~ "Alice, A."
      assert html =~ "Bob, B."
      assert html =~ "<td class='tdResult'>1-0</td>"
    end

    test "a pairing-allocated bye does not crash generation and carries no dangling link" do
      tournament = fixture(user_scope_fixture())
      html = SwarPublish.export(tournament)

      assert html =~ "<tr id='Round2'>"
      assert html =~ "Vrij"
    end
  end

  describe "export/1 - excluded sections" do
    test "ficheTable, the Berger/American cross table and tableGrille are absent" do
      tournament = fixture(user_scope_fixture())
      html = SwarPublish.export(tournament)

      refute html =~ "ficheTable"
      refute html =~ "tableRondesFermees"
      refute html =~ "id='Americaine'"
      refute html =~ "tableGrille"
      refute html =~ "tableLiens"
    end
  end

  describe "export/1 accepts a tournament id" do
    test "same output as passing the struct" do
      tournament = fixture(user_scope_fixture())

      assert SwarPublish.export(tournament.id) =~ tournament.name
    end
  end

  describe "effective_tiebreaks stay in sync with what the page shows" do
    test "sanity: the fixture's tiebreaks really are what Standings reports" do
      tournament = fixture(user_scope_fixture())
      assert Standings.effective_tiebreaks(tournament) == ["SB", "WIN"]
    end
  end

  describe "the guid's date" do
    test "comes from the tournament's start date, not from today" do
      # SWAR reads it out of `DateDebut`, so a tournament starting 01/08/2026
      # is stamped 260801 whenever the id is minted.
      t =
        fixture(user_scope_fixture(), %{
          "start_date" => "2026-08-01",
          "organizer_club_number" => "351"
        })

      t = SwarPublish.ensure_guid!(t)

      assert t.swar_guid =~ ~r/^351-260801-[0-9a-f]{8}-\{/
    end

    test "survives the start date being changed afterwards" do
      # The reference file proves SWAR does this: its id says 250905 while its
      # DateStart says 01/08/2026. The id is what the results site overwrites
      # in place, so it must not follow an edit - or a second upload would
      # publish a second tournament instead of replacing the first.
      t =
        fixture(user_scope_fixture(), %{
          "start_date" => "2026-08-01",
          "organizer_club_number" => "351"
        })

      t = SwarPublish.ensure_guid!(t)
      minted = t.swar_guid

      {:ok, moved} = Tournaments.update_tournament(t, %{"start_date" => "2027-01-15"})

      assert SwarPublish.ensure_guid!(moved).swar_guid == minted
    end
  end

  describe "attribution" do
    test "the file does not claim SWAR's author wrote it" do
      t = fixture(user_scope_fixture(), %{"organizer_club_number" => "351"})
      html = SwarPublish.export(t)

      refute html =~ "Georges Marchal",
             "copying the Author meta would put another person's name on output he had no hand in"

      assert html =~ "<meta name='Author' content='OpenPairings'>"
    end
  end
end
