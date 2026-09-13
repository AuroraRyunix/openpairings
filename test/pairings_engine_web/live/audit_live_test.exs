defmodule PairingsEngineWeb.AuditLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Pairing, Tournaments}
  alias PairingsEngine.AuditActionCodes

  setup :register_and_log_in_user

  @source "lib/pairings_engine_web/live/audit_live.ex"

  # The two recorded, tournament-scoped codes that fit no @categories
  # bucket: a restore point can touch anything a row in ANY other bucket
  # touches (players, pairings, settings, standings), so no single filter
  # names it - see the comment above `@categories` in audit_live.ex, and
  # `HistoryLive`'s own moduledoc, which shows these same rows around their
  # restore points and deliberately has no kind filter either. Reachable
  # only under "All".
  @all_only_codes ~w(snapshot.manual snapshot.restored)

  # Reads `@categories` back out of audit_live.ex by parsing rather than
  # hard-coding a second copy of it here, so this test cannot fall behind a
  # reshuffle of the real list. `~w(...)` sigils and literal tuples need
  # nothing from the module around them, so evaluating the extracted AST
  # on its own is enough to get the real list back.
  defp category_buckets do
    ast = @source |> File.read!() |> Code.string_to_quoted!()

    {_ast, [list_ast]} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:categories, _, [list_ast]}]} = node, acc -> {node, [list_ast | acc]}
        node, acc -> {node, acc}
      end)

    {categories, _binding} = Code.eval_quoted(list_ast)
    for {key, codes} <- categories, key != "all", into: %{}, do: {key, codes}
  end

  defp make_tournament(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Audit T", "type" => "swiss"})
    t
  end

  test "renders audit entries as readable sentences", %{conn: conn, scope: scope} do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_id: 1, player_name: "Alice", rating: 1800})
    Audit.log(t.id, scope, "pairing.round_deleted", %{round: 3})

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Registered player Alice"
    assert html =~ "Unpaired round 3"
    # Acting user shown by email.
    assert html =~ scope.user.email
  end

  test "a locked-field override renders as its own sentence, distinct from an ordinary settings save",
       %{conn: conn, scope: scope} do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "tournament.locked_field_changed", %{
      field: "pairing_engine",
      from: "javafo",
      to: "ainalrami"
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Overrode the round-1 freeze on pairing_engine"
    assert html =~ "javafo"
    assert html =~ "ainalrami"
  end

  test "a machine-wide row (no tournament) never appears on a tournament's own trail", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_name: "Alice"})
    Audit.log_system(scope, "backup.downloaded", %{filename: "whole-db.db"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Registered player Alice"
    refute html =~ "whole-db.db"
    refute html =~ "Downloaded a backup"
    # The page still renders normally - a nil-tournament row elsewhere in the
    # table does not raise inside `describe/1` or anything else on this page.
    assert html =~ "1 event total."
  end

  test "the category filter narrows the list", %{conn: conn, scope: scope} do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_name: "Alice"})

    Audit.log(t.id, scope, "tournament.settings_updated", %{
      changed_fields: %{"name" => ["A", "B"]}
    })

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/audit")

    html = lv |> element("button", "Players") |> render_click()
    assert html =~ "Registered player Alice"
    refute html =~ "Updated tournament settings"

    html = lv |> element("button", "Settings") |> render_click()
    assert html =~ "Updated tournament settings"
    refute html =~ "Registered player Alice"
  end

  test "a Dutch arbiter reads the trail in Dutch - the rows, not just the page around them", %{
    conn: conn,
    scope: scope
  } do
    # The rows were the part that stayed English: `describe/2` built them by
    # interpolation, so the headings, the filter and the table header came
    # out Dutch around a column of English sentences. A phone's result has
    # no account behind it, which is also the one place the "Who" column
    # speaks for itself.
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_name: "Alice"})

    Audit.log(t.id, nil, "pairing.result_entered", %{
      round: 1,
      board: 2,
      white: "Alice",
      black: "Bob",
      from: nil,
      to: "1-0",
      via: "mobile",
      enrollment_id: 1,
      enrollment_label: "Tafel 2",
      enrollment_level: "helper"
    })

    conn = get(conn, ~p"/locale/nl?redirect_to=/")
    {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Speler Alice ingeschreven."

    assert html =~
             "Resultaat 1-0 ingevoerd op bord 2 (ronde 1): Alice tegen Bob. " <>
               "Via de telefoon &quot;Tafel 2&quot; (Helper)."

    assert html =~ "Systeem"
    refute html =~ "Registered player"
    refute html =~ "Entered result"

    html = lv |> element("button", "Spelers") |> render_click()
    assert html =~ "Speler Alice ingeschreven."
    refute html =~ "Resultaat 1-0"
  end

  test "saving the officials does not take the audit page down", %{conn: conn, scope: scope} do
    # `officials` is a map, and the Norms page's save logs it in the ordinary
    # settings diff. The diff formatter called `to_string/1` on each value,
    # which raises for a map - so one officials save made this tournament's
    # audit trail unopenable.
    t = make_tournament(scope)

    Audit.log(t.id, scope, "tournament.settings_updated", %{
      changed_fields: %{
        "officials" => [%{}, %{"chief_arbiter" => %{"name" => "Dirk Jacobs"}}],
        "tiebreaks" => [["BH"], ["BH", "SB"]]
      }
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Updated tournament settings"
    assert html =~ "Dirk Jacobs"
    assert html =~ "tiebreaks BH → BH, SB"
  end

  test "a non-collaborator cannot open another user's audit page", %{conn: conn} do
    other = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(other, %{"name" => "Not Yours", "type" => "swiss"})

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/t/#{t.id}/audit")
    end
  end

  test "the top-bar Advanced menu links to both the audit trail and the explain picker", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Advanced"
    assert html =~ ~s(href="/t/#{t.id}/audit")
    assert html =~ ~s(href="/t/#{t.id}/audit/explain")
  end

  test "the sub-nav highlights the current page and links to the other two", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/audit")
    assert lv |> element("a.filter-picker", "Audit trail") |> render() =~ "active"
    refute lv |> element("a.filter-picker", "Pairing rationale") |> render() =~ "active"
    refute lv |> element("a.filter-picker", "History") |> render() =~ "active"

    {:ok, lv2, _html2} = live(conn, ~p"/t/#{t.id}/audit/explain")
    assert lv2 |> element("a.filter-picker", "Pairing rationale") |> render() =~ "active"
    refute lv2 |> element("a.filter-picker", "Audit trail") |> render() =~ "active"

    {:ok, lv3, _html3} = live(conn, ~p"/t/#{t.id}/history")
    assert lv3 |> element("a.filter-picker", "History") |> render() =~ "active"
    refute lv3 |> element("a.filter-picker", "Audit trail") |> render() =~ "active"
  end

  test "the explain picker lists exactly the paired rounds", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit/explain")

    assert html =~ ~s(href="/t/#{t.id}/pairings/1/explain")
    refute html =~ ~s(href="/t/#{t.id}/pairings/2/explain")
  end

  test "the explain picker shows a message when nothing is paired yet", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit/explain")
    assert html =~ "No rounds have been paired yet"
  end

  describe "the category filters cover every recorded action code" do
    # `@categories` is hand-maintained, so it silently falls behind: 35
    # codes got a describe/2 sentence on 2026-09-13 and NONE of them were
    # added to a filter, so they only ever showed up under "All" - exactly
    # what an arbiter searches for after an incident. These two tests make
    # that a test failure instead of a support ticket, the same way the
    # sentence guard in `audit_describe_test.exs` does for `describe/2`.
    test "every recorded, tournament-scoped code is in exactly one category filter, or documented as all-only" do
      buckets = category_buckets()
      bucket_of = fn code -> for {key, codes} <- buckets, code in codes, do: key end

      recorded = AuditActionCodes.tournament_scoped_codes()

      uncategorized =
        for code <- recorded, code not in @all_only_codes, bucket_of.(code) == [], do: code

      assert uncategorized == [], """
      These tournament-scoped action codes are recorded but appear in no \
      @categories filter in audit_live.ex, and are not in @all_only_codes \
      above - filtering by any category hides them; only "All" shows them. \
      Add each to the filter an arbiter would look under it for (see the \
      comment above @categories), or to @all_only_codes with a reason if it \
      genuinely fits none:

        #{inspect(uncategorized)}
      """

      in_several =
        for code <- recorded, length(bucket_of.(code)) > 1, do: {code, bucket_of.(code)}

      assert in_several == [], """
      These action codes are in more than one @categories filter, so a row \
      would appear under either one - not "exactly one":

        #{inspect(in_several)}
      """

      stale_all_only = Enum.reject(@all_only_codes, &(&1 in recorded))

      assert stale_all_only == [], """
      @all_only_codes (in this test) lists codes nothing currently records - \
      drop them:

        #{inspect(stale_all_only)}
      """

      wrongly_all_only = for code <- @all_only_codes, bucket_of.(code) != [], do: code

      assert wrongly_all_only == [], """
      @all_only_codes lists codes that ARE in a category filter now - drop \
      them from @all_only_codes, they don't need it any more:

        #{inspect(wrongly_all_only)}
      """
    end

    test "machine-wide codes never appear in a category filter - they can never reach this page" do
      # Written by Audit.log_system/3, so tournament_id is always nil - they
      # never match load_entries/1's tournament-scoped query (see the
      # "machine-wide rows" comment in audit_live.ex), on ANY filter, "All"
      # included. A bucket for one would be dead weight, not a fix.
      buckets = category_buckets()
      all_bucketed = buckets |> Map.values() |> List.flatten()

      leaked = for code <- AuditActionCodes.machine_wide_codes(), code in all_bucketed, do: code

      assert leaked == [], """
      These codes are written by Audit.log_system/3 (tournament_id: nil), so \
      they can never reach AuditLive's tournament-scoped queries - remove \
      them from @categories in audit_live.ex:

        #{inspect(leaked)}
      """
    end
  end
end
