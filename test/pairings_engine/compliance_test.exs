defmodule PairingsEngine.ComplianceTest do
  @moduledoc """
  FIDE-mode compliance: the derived state, and the one fact about it that is
  stored.

  Two halves, and the second is the dangerous one. `PairingsEngine.Compliance`
  is pure and its mistakes are visible - it says the wrong thing on a page.
  `fide_compliance_lost_round` is a fact about history that VCL4THP wants
  named in a `###` TRF comment, and its mistakes are silent: a restore or a
  hand-off that rewrites it produces a tournament that claims to have been
  handled compliantly throughout, and nothing on any screen would say
  otherwise.

  The restore/hand-off cases below are therefore not "coverage". They are the
  test for the two lines in `TournamentImport` that the whole design turns
  on.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Compliance, Handoff, Repo, Snapshots, TournamentExport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  defp user_scope(prefix \\ "compliance") do
    user =
      Repo.insert!(%User{
        email: "#{prefix}#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Compliance", "type" => "swiss", "rounds_count" => "4"}, attrs)
      )

    t
  end

  # A tournament with `n` rounds on the board, so a loss recorded now has a
  # round number to name that isn't zero.
  defp with_rounds(tournament, n) do
    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice", fide_rating: 2100})
    b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob", fide_rating: 1900})

    for number <- 1..n do
      round =
        Repo.insert!(%Round{tournament_id: tournament.id, number: number, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })
    end

    Repo.reload!(tournament)
  end

  defp codes(tournament), do: tournament |> Compliance.check() |> Enum.map(& &1.code)

  # The wire is JSON, so everything crosses one.
  defp over_the_wire(payload), do: payload |> Jason.encode!() |> Jason.decode!()

  ## -------------------------------------------------------------------------

  describe "the defaults are compliant, which is the whole premise" do
    test "a tournament created with nothing but a name is compliant" do
      t = tournament(user_scope())

      assert Compliance.check(t) == []
      assert Compliance.compliant?(t)
      assert is_nil(t.fide_compliance_lost_round)
    end

    test "so is one whose settings were changed in every way that is NOT a departure" do
      # Every setting deliberately ruled out of the inventory, all at once.
      # If any of them ever starts reporting a departure, this is where it
      # shows up - and the reason it was ruled out is in `Compliance`'s
      # moduledoc, not in a commit message.
      {:ok, t} =
        Tournaments.update_tournament(tournament(user_scope()), %{
          "acceleration" => "baku",
          "points_win" => "3.0",
          "points_draw" => "1.0",
          "points_loss" => "0.0",
          "bye_value" => "0.5",
          "abs_value" => "0.5",
          "absent_counts_as_vur" => "false",
          "count_extra_points" => "true",
          "manual_ranking" => "true",
          "club_exclusion" => "all",
          "fed_exclusion" => "all",
          "soft_club_rounds" => "2",
          "soft_position" => "weak",
          "tiebreaks" => [],
          "pairing_engine" => "javafo"
        })

      assert Compliance.check(t) == []
      assert is_nil(t.fide_compliance_lost_round)
    end
  end

  describe "check/1 names the setting and what would put it back" do
    test "a Keizer ladder is not a FIDE pairing system" do
      t = tournament(user_scope(), %{"pairing_system" => "keizer"})

      assert [departure] = Compliance.check(t)
      assert departure.setting == :pairing_system
      assert departure.code == :non_fide_pairing_system
      assert departure.value == "keizer"
      assert departure.restore_to == ["swiss", "round_robin"]
      refute Compliance.compliant?(t)
    end

    test "round robin is a FIDE system and Swiss is a FIDE system" do
      for system <- ["swiss", "round_robin"] do
        t = tournament(user_scope(), %{"pairing_system" => system})
        assert Compliance.check(t) == [], "#{system} must not be reported as a departure"
      end
    end

    test "pairing each category separately is a departure" do
      t =
        tournament(user_scope(), %{"categories_enabled" => "true", "pair_by_category" => "true"})

      assert [
               %{
                 setting: :pair_by_category,
                 code: :categories_paired_separately,
                 restore_to: [false]
               }
             ] =
               Compliance.check(t)
    end

    test "a mirrored second leg is a departure" do
      t = tournament(user_scope(), %{"swiss_match_format" => "true"})

      assert [%{setting: :swiss_match_format, code: :mirrored_second_leg, restore_to: [false]}] =
               Compliance.check(t)
    end
  end

  describe "it does not cry wolf" do
    # The failure mode this guards is the one that makes a compliance check
    # worthless: an arbiter who learns that one line of it is noise stops
    # reading the other lines. Both booleans are documented on the schema as
    # "never read" off the Swiss path, so reporting them there would be
    # reporting a setting no round will ever act on.
    #
    # The two booleans are set one at a time because `changeset/2` refuses
    # them together ("pairing by category is not yet supported together with
    # match format") - which is a separate rule with nothing to do with FIDE,
    # and setting both at once tests that rule instead of this one.
    test "a Swiss-only setting is not reported on a tournament that never pairs Swiss" do
      mirrored =
        tournament(user_scope(), %{
          "pairing_system" => "round_robin",
          "swiss_match_format" => "true"
        })

      by_category =
        tournament(user_scope(), %{
          "pairing_system" => "round_robin",
          "categories_enabled" => "true",
          "pair_by_category" => "true"
        })

      assert Compliance.check(mirrored) == []
      assert Compliance.check(by_category) == []
    end

    test "a Keizer tournament with a Swiss-only setting reports only the Keizer departure" do
      t =
        tournament(user_scope(), %{
          "pairing_system" => "keizer",
          "swiss_match_format" => "true"
        })

      assert codes(t) == [:non_fide_pairing_system]
    end
  end

  describe "introduced/2 reports what a save just did, not what is true now" do
    test "an existing departure is not re-reported by an unrelated save" do
      scope = user_scope()
      before = tournament(scope, %{"pairing_system" => "keizer"})
      {:ok, after_t} = Tournaments.update_tournament(before, %{"venue" => "Upstairs"})

      assert Compliance.introduced(before, after_t) == []
      refute Compliance.compliant?(after_t)
    end

    test "a save that adds one reports exactly that one" do
      scope = user_scope()
      before = tournament(scope, %{"pairing_system" => "keizer"})
      {:ok, after_t} = Tournaments.update_tournament(before, %{"swiss_match_format" => "true"})

      # Still Keizer, so the mirrored leg is inert and nothing new is
      # introduced - the gating and the diff have to agree.
      assert Compliance.introduced(before, after_t) == []
    end

    test "on a Swiss tournament the same save does introduce one" do
      before = tournament(user_scope())
      {:ok, after_t} = Tournaments.update_tournament(before, %{"swiss_match_format" => "true"})

      assert [%{code: :mirrored_second_leg}] = Compliance.introduced(before, after_t)
    end
  end

  describe "the round is recorded once, at the moment it happens" do
    test "a tournament created non-compliant records round 0, not nil" do
      t = tournament(user_scope(), %{"pairing_system" => "keizer"})

      # 0 is a real value and means "before round 1 was paired". nil would
      # mean it never happened, which is a different and false claim.
      assert t.fide_compliance_lost_round == 0
    end

    test "a save mid-event records the round that exists" do
      t = user_scope() |> tournament() |> with_rounds(2)
      assert is_nil(t.fide_compliance_lost_round)

      {:ok, t} =
        Tournaments.update_tournament(t, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      assert t.fide_compliance_lost_round == 2
    end

    test "a compliant save records nothing" do
      t = user_scope() |> tournament() |> with_rounds(2)
      {:ok, t} = Tournaments.update_tournament(t, %{"venue" => "Upstairs"})

      assert is_nil(t.fide_compliance_lost_round)
    end

    test "a second departure does not move the record" do
      t = user_scope() |> tournament(%{"pairing_system" => "keizer"}) |> with_rounds(2)
      assert t.fide_compliance_lost_round == 0

      {:ok, t} =
        Tournaments.update_tournament(t, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      assert t.fide_compliance_lost_round == 0
    end

    test "putting the setting back makes it compliant again and leaves the record standing" do
      t = user_scope() |> tournament() |> with_rounds(3)

      {:ok, t} =
        Tournaments.update_tournament(t, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      assert t.fide_compliance_lost_round == 3

      {:ok, t} =
        Tournaments.update_tournament(t, %{"swiss_match_format" => "false"},
          unlock: [:swiss_match_format]
        )

      # The two answer different questions, and this is the whole reason the
      # column exists rather than a boolean: there is no way to recompute
      # "round 3" once the setting is back.
      assert Compliance.compliant?(t)
      assert t.fide_compliance_lost_round == 3
    end

    test "an ordinary settings save cannot write it, because it is not cast" do
      t = user_scope() |> tournament() |> with_rounds(2)

      {:ok, saved} = Tournaments.update_tournament(t, %{"fide_compliance_lost_round" => "1"})
      assert is_nil(saved.fide_compliance_lost_round)

      # And a compliant tournament cannot be made to claim a loss by a
      # hand-built changeset either.
      changeset = Tournament.changeset(t, %{"fide_compliance_lost_round" => 1})
      refute Map.has_key?(changeset.changes, :fide_compliance_lost_round)
    end

    test "a save that loses compliance and fails validation records nothing" do
      # The stamp rides in the same changeset as the save that causes it, so
      # a refused save leaves no orphan record of a change that never landed.
      t = user_scope() |> tournament() |> with_rounds(2)

      assert {:error, _} =
               Tournaments.update_tournament(t, %{
                 "pairing_system" => "keizer",
                 "name" => ""
               })

      assert is_nil(Repo.reload!(t).fide_compliance_lost_round)
    end
  end

  describe "the record survives everything that rewrites a tournament wholesale" do
    test "restoring a snapshot taken before the loss does not un-lose it" do
      scope = user_scope()
      t = scope |> tournament() |> with_rounds(2)

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope, summary: "Before")

      {:ok, t} =
        Tournaments.update_tournament(t, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      assert t.fide_compliance_lost_round == 2

      {:ok, restored} = Snapshots.restore(Repo.reload!(t), snapshot.id, scope)

      # The snapshot predates the loss and carries nil. Rolling back past an
      # event that has already been reported must not un-report it - the same
      # argument `openresults_key` makes, and the single highest-risk line in
      # the design.
      assert restored.fide_compliance_lost_round == 2
    end

    test "a hand-off round trip brings home a loss that happened on the other machine" do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = sender |> tournament() |> with_rounds(1)

      assert is_nil(source.fide_compliance_lost_round)

      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)

      {:ok, copy} =
        Tournaments.update_tournament(copy, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      assert copy.fide_compliance_lost_round == 1

      {:ok, back} = Handoff.return(Repo.reload!(copy), receiver)
      {:ok, unlocked} = Handoff.release(Repo.reload!(source), over_the_wire(back), sender)

      # This copy was locked for the whole trip and knows nothing. If the
      # restore path had simply re-asserted the live value, the other
      # machine's record would have been thrown away here and the event would
      # have come home claiming it was handled compliantly throughout.
      assert unlocked.fide_compliance_lost_round == 1
    end

    test "and a hand-off does not un-lose a loss that happened here first" do
      sender = user_scope("sender")
      receiver = user_scope("receiver")
      source = sender |> tournament() |> with_rounds(2)

      {:ok, source} =
        Tournaments.update_tournament(source, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      assert source.fide_compliance_lost_round == 2

      {:ok, out} = Handoff.hand_off(source, "the club laptop", sender)
      {:ok, copy} = Handoff.receive(over_the_wire(out), receiver)
      {:ok, back} = Handoff.return(Repo.reload!(copy), receiver)
      {:ok, unlocked} = Handoff.release(Repo.reload!(source), over_the_wire(back), sender)

      assert unlocked.fide_compliance_lost_round == 2
    end

    test "a JSON backup of a tournament that lost it imports as one that lost it" do
      scope = user_scope()
      t = scope |> tournament() |> with_rounds(3)

      {:ok, t} =
        Tournaments.update_tournament(t, %{"swiss_match_format" => "true"},
          unlock: [:swiss_match_format]
        )

      envelope = t |> TournamentExport.export_tournament() |> over_the_wire()

      assert {:ok, [imported]} = PairingsEngine.TournamentImport.import(envelope, user_scope())
      assert imported.fide_compliance_lost_round == 3
      refute Compliance.compliant?(imported)
    end

    test "the field actually leaves in the envelope" do
      scope = user_scope()
      t = tournament(scope, %{"pairing_system" => "keizer"})

      t_map =
        t
        |> TournamentExport.export_tournament()
        |> get_in(["tournaments", Access.at(0), "tournament"])

      assert t_map["fide_compliance_lost_round"] == 0
    end
  end
end
