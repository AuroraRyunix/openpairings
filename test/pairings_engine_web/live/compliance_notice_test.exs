defmodule PairingsEngineWeb.ComplianceNoticeTest do
  @moduledoc """
  What the arbiter is actually told, and where.

  The compliance check exists to be read at the moment a setting is changed;
  a check nobody sees is a check that does not exist. These cover the three
  things that can go wrong with that: the notice not appearing when it
  should, appearing when it should not (which is how a warning gets trained
  out of people), and appearing with a code the web layer has no sentence for
  - which renders as a blank line and reads as a bug.
  """
  # async: false: sequential SQLite writes, same as the other settings LiveView
  # tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Compliance, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.SettingsSupport

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Notice Test", "type" => "swiss", "rounds_count" => "6"}, attrs)
      )

    tournament
  end

  describe "every rule the domain can produce has words in the web layer" do
    # `Compliance` returns codes and never sentences, on purpose - the domain
    # layer does not use gettext. The cost of that split is exactly this: a
    # rule added there with no clause added here renders an empty bullet and
    # says nothing at all. This is the wall that stops it.
    test "each departure code, setting label and settings path is defined" do
      # One tournament carrying every departure at once cannot exist (the two
      # Swiss-only booleans are mutually exclusive by an unrelated changeset
      # rule), so the codes are taken from the module rather than from a row.
      codes =
        for system <- ["keizer"], into: MapSet.new() do
          %Tournament{pairing_system: system}
          |> Compliance.check()
          |> Enum.map(& &1.code)
        end
        |> Enum.flat_map(& &1)
        |> MapSet.new()

      swiss_codes =
        [
          %Tournament{pairing_system: "swiss", pair_by_category: true},
          %Tournament{pairing_system: "swiss", swiss_match_format: true}
        ]
        |> Enum.flat_map(&Enum.map(Compliance.check(&1), fn d -> d.code end))
        |> MapSet.new()

      all_codes = MapSet.union(codes, swiss_codes)

      assert MapSet.size(all_codes) == length(Compliance.settings()),
             "every setting in Compliance.settings/0 must be reachable as a departure"

      for code <- all_codes do
        message = SettingsSupport.compliance_message(code)
        assert is_binary(message) and message != "", "no sentence for #{inspect(code)}"
      end

      tournament = %Tournament{id: 1}

      for setting <- Compliance.settings() do
        assert is_binary(SettingsSupport.compliance_setting_label(setting))
        assert SettingsSupport.compliance_setting_path(tournament, setting) =~ "/t/1/"
      end
    end
  end

  describe "the Options page" do
    test "says nothing about compliance for a tournament that has not left the defaults", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      refute html =~ "no longer set up the way the FIDE pairing rules describe"
    end

    test "names the setting, and does not stop the arbiter doing it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "swiss_match_format" => "true"}
        })

      # The change landed. Nothing here refuses, because an arbiter running a
      # club event that is not FIDE-rated has every right to this.
      assert Repo.reload!(tournament).swiss_match_format

      assert html =~ "no longer set up the way the FIDE pairing rules describe"
      assert html =~ "colour-reversed copy of the first"
      assert html =~ "Match format"
      # Round 0 is a real recorded value and gets words, not a number: "in
      # round 0" would read as a bug to the person it is written for.
      assert html =~ "before the first round was paired"
    end

    test "the audit trail records which setting did it and in which round", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "swiss_match_format" => "true"}
      })

      [entry] =
        Audit.list_for_tournament(tournament.id, action: "tournament.fide_compliance_lost")

      assert entry.details["setting"] == "swiss_match_format"
      assert entry.details["code"] == "mirrored_second_leg"
      assert entry.details["round"] == 0
    end

    test "a second save that changes nothing about compliance does not log it again", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"swiss_match_format" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "swiss_match_format" => "true"}
      })

      assert Audit.list_for_tournament(tournament.id, action: "tournament.fide_compliance_lost") ==
               []
    end
  end

  describe "the FIDE settings page" do
    test "says so when the tournament is set up the way the rules describe", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

      assert html =~ "set up the way the FIDE pairing rules describe"
      # And it keeps the two questions apart, which is the whole reason this
      # card sits beside the homologation tickbox rather than replacing it.
      assert html =~ "not the same question as the tickbox below"
    end

    test "and names the departure when there is one", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"pairing_system" => "keizer"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

      assert html =~ "does not define a Keizer ladder"
      assert html =~ "before the first round was paired"
    end
  end

  describe "the Categories page" do
    test "pairing by category shows the notice and audits the round", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => "true"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      refute html =~ "no longer set up the way the FIDE pairing rules describe"

      html = render_click(lv, "toggle_pair_by_category", %{})

      assert Repo.reload!(tournament).pair_by_category
      assert html =~ "no longer set up the way the FIDE pairing rules describe"
      assert html =~ "paired as a separate tournament"

      [entry] =
        Audit.list_for_tournament(tournament.id, action: "tournament.fide_compliance_lost")

      assert entry.details["setting"] == "pair_by_category"
    end
  end
end
