defmodule PairingsEngine.SnapshotFixtures do
  @moduledoc """
  The builders behind the OpenPairings -> OpenResults contract fixtures.

  Shared by two consumers that must never disagree about what a fixture
  looks like:

    * `PairingsEngine.SnapshotTest` ("the cross-repo contract fixtures"),
      which builds each tournament in memory and compares the result with
      the file already committed in `../openresults/test/fixtures` - a
      drift check that writes nothing.
    * `mix pairings.snapshot_fixtures`, which runs the same builders and
      writes their output to disk so a maintainer can commit it there.

  `insert_round/3,4`, `boards/2`, `swiss_fixture/0`, `keizer_fixture/0` and
  `team_snapshot_fixture/0` are also reused directly by the rest of
  `SnapshotTest`'s suite (the withholding, personal-data and team-event
  tests), which is why they live here rather than as private test helpers.
  """

  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, Snapshot, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # Personal data loaded onto the fixtures' players, so the contract's "no
  # personal data travels" test (in SnapshotTest) has something real to
  # check the absence of.
  @email "ilse.de.vos@example.invalid"
  @national_id "BEL-19870142"
  @birth_date_iso "1987-04-02"
  @birth_year 1987

  # A result used on no other board in the swiss fixture, so its absence
  # from a withholding test's JSON is a direct check that the paired-but-
  # unpublished round 4 did not travel.
  @unpublished_round_result "0-1U"

  # Same reasoning, for the hidden board in round 3.
  @hidden_board_result "0-0FF"

  # Well clear of any id the database would hand out on its own, so the
  # swiss fixture's players are the only rows in this range.
  @first_player_id 9000

  # Fixed rather than left to `Tournament.generate_public_slug/0` (which
  # `team_round_robin/2` otherwise leaves the database default for): a
  # random slug in the team fixture rewrote `snapshot_team_roundrobin.json`
  # on every single test run, whether or not the contract had actually
  # changed. `mix pairings.snapshot_fixtures` promises byte-identical output
  # between two runs, which this pins at the source.
  @team_fixture_slug "team-roundrobin-fixture"

  @doc """
  Where the OpenResults contract fixtures live: `OPENRESULTS_FIXTURES` if
  set, otherwise `test/fixtures` in a sibling `../openresults` checkout, or
  `nil` when neither exists. Shared by `mix pairings.snapshot_fixtures`
  (where to write) and `PairingsEngine.SnapshotTest`'s drift check (where to
  compare against) - and by `test/test_helper.exs`, which uses the `nil`
  case to exclude the drift check instead of failing it when the sibling
  repo is not checked out.
  """
  def fixture_dir do
    case System.get_env("OPENRESULTS_FIXTURES") do
      nil ->
        sibling = Path.expand("../openresults", File.cwd!())
        if File.dir?(sibling), do: Path.join([sibling, "test", "fixtures"])

      configured ->
        configured
    end
  end

  @doc """
  name => name of a 0-arity function on this module that builds the
  tournament, in the order the fixtures are written. A `{module, function}`
  pair rather than a closure, so this list stays a plain, literal term - the
  callers that need it (`write_all!/1`, and `SnapshotTest`'s drift check,
  which builds this list at compile time to generate one test per fixture)
  can embed it without capturing an anonymous function across modules.
  """
  def contract_fixtures do
    [
      {"snapshot_swiss.json", :swiss_snapshot_tournament},
      {"snapshot_keizer.json", :keizer_snapshot_tournament},
      {"snapshot_team_roundrobin.json", :team_snapshot_fixture_published}
    ]
  end

  @doc false
  def swiss_snapshot_tournament, do: elem(swiss_fixture(), 0)
  @doc false
  def keizer_snapshot_tournament, do: elem(keizer_fixture(), 0)

  # `published_at` is stamped to a fixed instant before writing.
  #
  # `Snapshot.build/1` sets it to now, which is right in production and wrong
  # in a checked-in fixture: regenerating produced a one-line diff in the
  # sibling repository every single time, whether or not the document had
  # actually changed. That makes the diff worthless - the one thing a
  # committed fixture is for is showing what a contract change did to it.
  #
  # The value is arbitrary and the field is still exercised: SnapshotTest's
  # envelope test asserts the real `build/1` output parses as an ISO-8601
  # instant.
  @fixture_published_at "2026-08-29T00:00:00Z"

  # `source.version` gets the same treatment, for the same reason, and this
  # one was worse in practice: `app_version/0` is `PairingsEngine.Build.id/0`,
  # which carries THIS checkout's own dev version - so every version bump
  # rewrote every fixture whether or not the contract itself had changed.
  # A placeholder nobody could mistake for a real release - it is not, and
  # never has been, a version this app shipped - decouples the two entirely;
  # the real value is still exercised in production and by SnapshotTest's
  # `is_binary/1` assertion, which does not care what the string says.
  @fixture_source_version "0.0.0-fixture"

  @doc """
  The stable, deterministic JSON for `tournament`: `Snapshot.build/1`'s
  output with `published_at` and `source.version` pinned, pretty-printed
  with `Jason`'s stable key order. Calling this twice on fixtures built by
  the same seed produces byte-identical output.
  """
  def stable_json(tournament) do
    stable =
      tournament
      |> Snapshot.build()
      |> Map.put("published_at", @fixture_published_at)
      |> put_in(["source", "version"], @fixture_source_version)

    Jason.encode!(stable, pretty: true) <> "\n"
  end

  @doc """
  Builds every contract fixture and writes each one to `dir` if its content
  differs from what is already there (or nothing is there yet). Returns the
  list of file names that were written, in `contract_fixtures/0`'s order.
  """
  def write_all!(dir) do
    File.mkdir_p!(dir)

    for {name, fun} <- contract_fixtures(), reduce: [] do
      changed ->
        content = apply(__MODULE__, fun, []) |> stable_json()
        path = Path.join(dir, name)
        previous = if File.exists?(path), do: File.read!(path)

        if previous == content do
          changed
        else
          File.write!(path, content)
          [name | changed]
        end
    end
    |> Enum.reverse()
  end

  ## ---------- fixtures ----------

  # A team round robin, four teams of 2-3 boards, round 1 played and
  # published (results switch still off - the withholding test turns it on),
  # round 2 paired but never published (so it must leave no trace at all).
  def team_snapshot_fixture do
    {t, teams} =
      team_round_robin(
        [
          {"Antwerp Knights", [2210, 2105, 1990]},
          {"Brugse SK", [2150, 2000]},
          {"Charleroi", [1900, 1850]},
          {"Deurne", [1800, 1750]}
        ],
        boards: 2,
        tiebreaks: ~w(MP GP DE BB SB),
        start_date: "2026-09-01",
        city: "Gent",
        federation: "BEL",
        public_slug: @team_fixture_slug
      )

    Enum.each(teams, fn team ->
      if team.name == "Antwerp Knights" do
        {:ok, _} = Tournaments.update_team(team, %{"captain" => "Jan Peeters"})
      end
    end)

    t = pair_all!(t)
    enter!(t, 1, "Antwerp Knights", "Deurne", ["1-0", "1/2-1/2"])
    enter!(t, 1, "Brugse SK", "Charleroi", ["0-1", "1-0"])

    t = Tournaments.get_tournament!(t.id)
    round1 = Tournaments.get_round(t.id, 1)
    {:ok, _} = Tournaments.publish_round_now(round1)

    {Tournaments.get_tournament!(t.id), teams}
  end

  # `team_snapshot_fixture/0`, with round 1's results switched on and
  # standings published through it - for the OpenResults fixture, where a
  # page rendering real match points and board statistics is more useful
  # than the withheld state SnapshotTest's own tests already cover directly.
  def team_snapshot_fixture_published do
    {t, _teams} = team_snapshot_fixture()
    {:ok, t} = Tournaments.publish_results(t, 1)
    {:ok, t} = Tournaments.publish_standings_through(t, 1)
    Tournaments.get_tournament!(t.id)
  end

  # Nine rounds' worth of awkwardness in five: byes of three kinds, both
  # legacy forfeit spellings, an unrated result, an unreported game, an
  # unrated player, accented names throughout, a hidden board, a paired but
  # unpublished round, and a published round ABOVE the unpublished one.
  #
  # Deliberately built with plain `Repo.insert!` rather than the pairing
  # engine: this is a shape test, and the point is to hand the builder exactly
  # the awkward state an arbiter's database ends up in, including states the
  # ordinary write paths reach only by a longer route.
  def swiss_fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "Gent Spring Open 2026",
        type: "swiss",
        pairing_system: "swiss",
        city: "Ghent",
        federation: "BEL",
        chief_arbiter: "Jorian Burssens",
        start_date: "2026-03-01",
        end_date: "2026-03-05",
        round_dates: ~w(2026-03-01 2026-03-02 2026-03-03 2026-03-04 2026-03-05),
        rounds_count: 5,
        tiebreaks: ~w(BHC1 BH SB PS),
        categories: ~w(A B),
        categories_enabled: true,
        fide_homologated: true,
        # Manual mode is the only one in which a round can be held back, and
        # therefore the only one in which withholding is testable at all.
        publish_mode: "manual",
        public_slug: "gent-spring-open-2026",
        # The cross-repo fixture built from this tournament is what every
        # OpenResults registration test reads, and since 2026-08-29 that
        # site gates its entry form on this flag. Open here so the fixture
        # exercises the form; OpenResults has its own test for the closed
        # case, which overrides this rather than needing a second fixture.
        registration_open: true,
        # Same reasoning: the fixture is what OpenResults' front-page test
        # reads, and an unlisted tournament is filtered out of that list. The
        # unlisted case has its own test over there.
        public_listed: true
      })

    roster = [
      {1, "Müller, Jörg", "GM", 2601, "GER", 1_503_014, "SF Berlin", "A"},
      {2, "Đurić, Nikola", "IM", 2455, "SRB", 2_503_014, "ŠK Beograd", "A"},
      {3, "Ó Súilleabháin, Séamus", "FM", 2312, "IRL", 3_503_014, "Gonzaga CC", "A"},
      {4, "Łukasiewicz, Paweł", "", 2208, "POL", nil, "KSz Polonia", "A"},
      {5, "Vandenberghe, Françoise", "WFM", 2104, "BEL", 4_503_014, "KGSRL", "A"},
      {6, "Ștefănescu, Ioana", "WIM", 2033, "ROU", 5_503_014, "CS Universitatea", "B"},
      {7, "Ångström, Åsa", "", 1955, "SWE", nil, "Wasa SK", "B"},
      {8, "Björnsson, Sævar", "", 1866, "ISL", 6_503_014, "TR Reykjavík", "B"},
      {9, "De Smet, Jean-Baptiste", "", 1742, "BEL", nil, "Cercle d'Échecs", "B"},
      {10, "Nguyễn, Thị Hà", "", 0, "VIE", nil, "", "B"}
    ]

    # Ids are ASSIGNED here rather than left to the database, so that no
    # player's id is ever their pairing number. Left to autoincrement on a
    # fresh database, player 1 gets id 1 and player 2 gets id 2 - at which
    # point publishing a raw id looks exactly like publishing a pairing
    # number, and the test that exists to catch that leak cannot see it. That
    # is precisely how it passed on a developer's well-used database and
    # failed on CI's empty one.
    players =
      for {no, name, title, rating, fed, fide_id, club, category} <- roster, into: %{} do
        player =
          Repo.insert!(%Player{
            id: @first_player_id + no,
            tournament_id: tournament.id,
            pairing_number: no,
            name: name,
            title: title,
            fide_rating: rating,
            fide_id: fide_id,
            federation: fed,
            club: club,
            # BOTH, because this is a raw insert and `Player.changeset/2` is
            # what normally folds one into the other. Without `categories`
            # the player carries an override for a tag they do not have, so
            # `Categories.pairing_category/2` correctly refuses it and the
            # published `category` is null - a state the migration cannot
            # produce and no changeset will write, but one this fixture was
            # quietly publishing into the contract OpenResults reads.
            category: category,
            categories: if(category in [nil, ""], do: [], else: [category]),
            sex: if(no in [5, 6, 7, 10], do: "w", else: "m"),
            # The personal data the contract keeps out. Loaded onto every
            # player, not just one, so a leak of any single row is caught.
            national_id: @national_id,
            birth_year: @birth_year,
            birth_date: Date.from_iso8601!(@birth_date_iso),
            norm_data: %{"email" => @email, "title_claimed" => "IM"}
          })

        {no, player}
      end

    published = ~U[2026-03-01 14:00:00Z]

    r1 = insert_round(tournament, 1, published)
    r2 = insert_round(tournament, 2, published)
    r3 = insert_round(tournament, 3, published)
    # Paired, never published - the whole point of the withholding tests.
    r4 = insert_round(tournament, 4, nil)
    # Published ABOVE the held-back round, which manual mode allows.
    r5 = insert_round(tournament, 5, published)

    boards(r1, [
      {1, players[1], players[6], "1-0"},
      {2, players[7], players[2], "0-1"},
      {3, players[3], players[8], "1/2-1/2"},
      # Legacy single-sided forfeit spellings, still in SWAR-imported data.
      {4, players[9], players[4], "+--"},
      {5, players[5], players[10], "1-0U"}
    ])

    boards(r2, [
      {1, players[2], players[1], "1/2-1/2"},
      {2, players[6], players[3], "0-1"},
      {3, players[5], players[7], "--+"},
      {4, players[8], players[9], "0-1"}
    ])

    # A pairing-allocated bye: a real pairing row with one empty seat.
    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 5,
      white_player_id: players[4].id,
      black_player_id: nil,
      result: "bye"
    })

    boards(r3, [
      {1, players[1], players[3], "1-0"},
      {2, players[4], players[2], "1/2-0"},
      {3, players[8], players[5], ""}
    ])

    # The hidden board, with BOTH players still seated. `set_pairing_hidden/3`
    # only accepts a fully-vacated row today, so this state is written
    # directly - the builder must not be relying on that narrowness for its
    # guarantee, because the day the flag widens is not the day to discover
    # the payload was leaking seated boards all along.
    Repo.insert!(%Pairing{
      round_id: r3.id,
      board: 4,
      white_player_id: players[7].id,
      black_player_id: players[10].id,
      result: @hidden_board_result,
      hidden: true
    })

    boards(r4, [
      {1, players[1], players[2], "1-0"},
      {2, players[3], players[4], "0-1"},
      {3, players[5], players[6], @unpublished_round_result},
      {4, players[7], players[8], "1/2-1/2"},
      {5, players[9], players[10], "1-0"}
    ])

    boards(r5, [
      {1, players[2], players[1], "0-1"},
      {2, players[3], players[5], "1-0"},
      {3, players[4], players[6], "1/2-1/2"},
      {4, players[8], players[7], "1-0"},
      {5, players[10], players[9], "0-1"}
    ])

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: players[10].id, round: 2, type: "absent"},
      %{tournament_id: tournament.id, player_id: players[6].id, round: 3, type: "requested-half"},
      %{tournament_id: tournament.id, player_id: players[9].id, round: 3, type: "requested-zero"}
    ])

    {tournament, players}
  end

  # A Keizer ladder, whose standings carry value/Keizer points/score instead
  # of FIDE tiebreak columns.
  def keizer_fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cercle d'Échecs Gent - Winteravond 2026",
        type: "swiss",
        pairing_system: "keizer",
        city: "Ghent",
        federation: "BEL",
        chief_arbiter: "Jorian Burssens",
        start_date: "2026-01-08",
        end_date: "2026-01-22",
        round_dates: ~w(2026-01-08 2026-01-15 2026-01-22),
        rounds_count: 3,
        # Configured, and deliberately NOT published: a Keizer ladder does not
        # rank on them, so declaring them would promise columns the rows
        # cannot fill.
        tiebreaks: ~w(BH SB),
        publish_mode: "manual",
        public_slug: "cercle-gent-winteravond-2026"
      })

    roster = [
      {1, "Peeters, Wouter", 2088, "BEL"},
      {2, "Đoković, Milica", 1974, "SRB"},
      {3, "Hernández, José María", 1902, "ESP"},
      {4, "Van der Meché, Anouk", 1855, "NED"},
      {5, "Kowalczyk, Zofia", 1768, "POL"},
      {6, "Ó Braonáin, Cillian", 1690, "IRL"}
    ]

    players =
      for {no, name, rating, fed} <- roster, into: %{} do
        player =
          Repo.insert!(%Player{
            tournament_id: tournament.id,
            pairing_number: no,
            name: name,
            fide_rating: rating,
            federation: fed,
            club: "Cercle d'Échecs Gent",
            national_id: @national_id,
            birth_year: @birth_year,
            norm_data: %{"email" => @email}
          })

        {no, player}
      end

    published = ~U[2026-01-08 20:30:00Z]

    r1 = insert_round(tournament, 1, published)
    r2 = insert_round(tournament, 2, published)
    r3 = insert_round(tournament, 3, nil)

    boards(r1, [
      {1, players[1], players[4], "1-0"},
      {2, players[2], players[5], "1/2-1/2"},
      {3, players[3], players[6], "0-1"}
    ])

    boards(r2, [
      {1, players[6], players[1], "0-1"},
      {2, players[4], players[2], "1/2-1/2"},
      {3, players[5], players[3], "1-0"}
    ])

    boards(r3, [
      {1, players[1], players[5], "1-0"},
      {2, players[2], players[3], "1-0"},
      {3, players[6], players[4], "0-1"}
    ])

    {tournament, players}
  end

  # A published round's results switch is ON unless a test says otherwise:
  # these fixtures describe results that are public, which is what every
  # published round's switch was set to when the switch arrived. The
  # withheld case has its own tests and fixture (in SnapshotTest).
  def insert_round(tournament, number, published_at, results_public \\ nil) do
    Repo.insert!(%Round{
      tournament_id: tournament.id,
      number: number,
      status: "finished",
      published_at: published_at,
      results_public:
        if(is_nil(results_public), do: not is_nil(published_at), else: results_public)
    })
  end

  def boards(round, rows) do
    for {board, white, black, result} <- rows do
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end
  end
end
