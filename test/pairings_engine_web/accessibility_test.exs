defmodule PairingsEngineWeb.AccessibilityTest do
  @moduledoc """
  Every page of the arbiter's app, held to the invariants in
  `PairingsEngineWeb.A11y` - the decidable half of the accessibility pass of
  2026-09-13 (`docs/accessibility-2026-09-13.md`).

  The pages are walked from the router, so a LiveView routed later is audited
  the day it lands: a GET route with no entry in `path_for/2` fails "every
  page is walked" and names itself. Each LiveView is audited twice - the
  static render, which is the whole document (`<html lang>`, the skip link,
  the landmarks), and the connected render, which is what an arbiter actually
  has in front of them once the socket is up.

  The states that exist only after a click - the dialogs, the context menu,
  the player card, the confirmation that replaces a result - are opened here
  with the events a click sends, because a label that is only missing inside a
  modal is exactly the one nobody walks past by hand.

  JavaScript does not run, so what the hooks do with focus is the manual
  checklist's; the markup they rely on is asserted.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Pairing, Repo, Tournaments}
  alias PairingsEngineWeb.A11y

  @moduletag :capture_log

  setup %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    conn = log_in_user(conn, admin)
    scope = Accounts.Scope.for_user(admin)

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Accessibility Open",
        "type" => "swiss",
        "rounds_count" => "5",
        "pairing_engine" => "ainalrami",
        "categories_enabled" => true
      })

    for {name, rating, fed, club} <- [
          {"Anna Peeters", 2210, "BEL", "KGSRL"},
          {"Bram Claes", 2105, "BEL", "Brugse SK"},
          {"Chris Maes", 1990, "NED", ""},
          {"Dina Wouters", 1875, "BEL", "KGSRL"},
          {"Eli Jacobs", 1760, "FRA", ""},
          {"Fien Mertens", 1650, "BEL", "Brugse SK"},
          {"Gert Willems", 1540, "GER", ""}
        ] do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => name,
          "fide_rating" => "#{rating}",
          "federation" => fed,
          "club" => club
        })
    end

    {:ok, round1} = Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))

    for p <- Repo.preload(round1, :pairings).pairings, p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    {:ok, round2} = Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))
    [first | _] = Repo.preload(round2, :pairings).pairings |> Enum.filter(& &1.black_player_id)
    {:ok, _} = Tournaments.update_pairing_result(first, "1/2-1/2")

    tournament = Tournaments.get_tournament!(tournament.id)

    {:ok, invite} =
      Tournaments.add_collaborator(
        scope,
        tournament,
        "helper#{System.unique_integer([:positive])}@example.com"
      )

    {:ok,
     conn: conn,
     scope: scope,
     tournament: tournament,
     invite: invite,
     player: tournament.id |> Tournaments.list_players() |> hd()}
  end

  # Every concrete page behind one GET route. `:skip` for a route that cannot
  # render a page in a test (a token that is consumed, a download), with why.
  defp path_for(path, world) do
    t = world.tournament.id

    case path do
      "/" ->
        ["/"]

      "/fide" ->
        ["/fide"]

      "/admin" ->
        ["/admin"]

      "/t/:id/pairings/:round/explain" ->
        ["/t/#{t}/pairings/2/explain", "/t/#{t}/pairings/1/explain"]

      "/t/:id/audit/explain" ->
        ["/t/#{t}/audit/explain"]

      "/t/:id/" <> _ ->
        [String.replace(path, ":id", "#{t}")]

      "/invites/:token" ->
        ["/invites/#{world.invite.invite_token}"]

      "/users/settings" ->
        ["/users/settings"]

      "/users/features" ->
        ["/users/features"]

      "/changelog" ->
        ["/changelog"]

      "/tools/norms" ->
        ["/tools/norms"]

      # Token pages: a real token is single-use and bound to an email flow;
      # a made-up one redirects before rendering anything to audit.
      "/users/settings/confirm-email/:token" ->
        :skip

      "/users/log-in/:token" ->
        :skip

      # Signed-out pages, walked separately below.
      "/users/register" ->
        :signed_out

      "/users/log-in" ->
        :signed_out

      # Enrolment-gated, walked separately below.
      "/m/results" ->
        :mobile

      other ->
        flunk("#{other} is a page nobody walks - add it to path_for/2")
    end
  end

  defp live_routes do
    for %{verb: :get, path: path, metadata: %{phoenix_live_view: _}} <-
          PairingsEngineWeb.Router.__routes__(),
        do: path
  end

  # Not enforced here, and each is a recommendation in the report rather than
  # an oversight: `scope` on the arbiter's ~150 header cells and a name on its
  # ~20 tables. They are simple tables - one header row, no merged cells -
  # which browsers already associate without either. See
  # docs/accessibility-2026-09-13.md.
  @not_enforced [:th_scope, :table_name]

  defp audit_page(html), do: A11y.audit(html, lang: "en", skip: @not_enforced)

  # The connected render is the LiveView's own markup, already inside the
  # layout's <main>; audited as a fragment, so the document-level rules are
  # left to the static render.
  defp audit_fragment(html) do
    A11y.audit(
      ~s(<!DOCTYPE html><html lang="en"><head><title>fragment</title></head><body>#{html}</body></html>),
      skip: [:skip_link, :main, :one_h1, :lang, :title] ++ @not_enforced
    )
  end

  defp report(results) do
    failures = for {where, violations} <- results, violations != [], do: {where, violations}
    Enum.map_join(failures, "\n\n", fn {where, v} -> "#{where}\n#{A11y.explain(v)}" end)
  end

  describe "every LiveView" do
    test "is walked, and passes the audit static and connected", %{conn: conn} = world do
      results =
        for route <- live_routes(),
            paths = path_for(route, world),
            is_list(paths),
            path <- paths,
            reduce: [] do
          acc ->
            case get(conn, path) do
              # A page that only forwards somewhere else (the old settings
              # changelog address) has nothing of its own to audit.
              %{status: status} when status in [301, 302] ->
                acc

              static ->
                {:ok, view, _html} = live(conn, path)

                [
                  {"#{path} (connected)", audit_fragment(render(view))},
                  {"#{path} (static)", audit_page(html_response(static, 200))} | acc
                ]
            end
        end

      if report(results) != "", do: flunk(report(results))
      assert length(results) >= 40
    end
  end

  describe "the pages that are not a signed-in LiveView" do
    test "signing in and registering, signed out" do
      results =
        for path <- ["/users/log-in", "/users/register"] do
          conn = build_conn()
          static = conn |> get(path) |> html_response(200)
          {:ok, view, _html} = live(conn, path)

          [
            {"#{path} (static)", audit_page(static)},
            {"#{path} (connected)", audit_fragment(render(view))}
          ]
        end

      if report(List.flatten(results)) != "", do: flunk(report(List.flatten(results)))
    end

    test "the phone's result entry, enrolled", %{tournament: tournament} do
      {:ok, enrollment} = PairingsEngine.Mobile.create_enrollment(tournament.id)
      conn = init_test_session(build_conn(), %{mobile_enrollment_id: enrollment.id})

      static = conn |> get("/m/results") |> html_response(200)
      {:ok, view, _html} = live(conn, "/m/results")

      results = [
        {"/m/results (static)", audit_page(static)},
        {"/m/results (connected)", audit_fragment(render(view))}
      ]

      if report(results) != "", do: flunk(report(results))
    end

    test "the phone's enrolment page" do
      results =
        for path <- ["/m"] do
          {path, build_conn() |> get(path) |> html_response(200) |> audit_page()}
        end

      if report(results) != "", do: flunk(report(results))
    end
  end

  describe "the states behind a click" do
    # Every overlay is a real dialog: named, modal, and carrying the hook that
    # moves focus in, keeps it there and brings it back.
    defp dialog_problems(html) do
      document = LazyHTML.from_fragment(html)
      overlays = LazyHTML.query(document, ".modal-overlay, .pe-modal")

      for overlay <- overlays,
          dialogs =
            LazyHTML.query(
              overlay,
              ~s([role="dialog"][aria-modal="true"][aria-labelledby][data-dialog][phx-hook="DialogFocus"])
            ),
          Enum.count(dialogs) +
            Enum.count(LazyHTML.filter(overlay, ~s([role="dialog"][data-dialog]))) == 0 do
        {:dialog,
         "an overlay with no named, modal, focus-managed dialog in it: " <>
           (overlay |> LazyHTML.text() |> String.slice(0, 60))}
      end
    end

    defp audit_state(label, html), do: {label, audit_fragment(html) ++ dialog_problems(html)}

    test "the dialogs, the context menu and the clear-result confirmation", %{
      conn: conn,
      tournament: t,
      player: player
    } do
      round2 = Tournaments.get_round(t.id, 2)
      board = Enum.find(round2.pairings, &(&1.result not in [nil, ""]))

      {:ok, players, _} = live(conn, "/t/#{t.id}/players")
      {:ok, pairings, _} = live(conn, "/t/#{t.id}/pairings")
      {:ok, norms, _} = live(conn, "/t/#{t.id}/norms")
      {:ok, home, _} = live(conn, "/")

      results = [
        audit_state(
          "players card",
          render_click(players, "show_card", %{"id" => to_string(player.id)})
        ),
        audit_state(
          "player registration",
          render_click(players, "edit_player", %{"id" => to_string(player.id)})
        ),
        audit_state("refresh ratings", render_click(players, "open_rating_refresh", %{})),
        audit_state(
          "pairing context menu",
          render_click(pairings, "open_menu", %{
            "x" => "10",
            "y" => "10",
            "player-id" => to_string(board.white_player_id),
            "pairing-id" => to_string(board.id),
            "scope" => "seated"
          })
        ),
        audit_state(
          "hand-edit confirmation",
          render_click(pairings, "stage_vacate", %{
            "player-id" => to_string(board.white_player_id)
          })
        ),
        audit_state(
          "norm judgment",
          render_click(norms, "edit_norm", %{"id" => to_string(player.id)})
        ),
        audit_state("hand-off", render_click(home, "handoff_start", %{"id" => to_string(t.id)})),
        audit_state(
          "delete tournament",
          render_click(home, "delete_start", %{"id" => to_string(t.id)})
        )
      ]

      {:ok, fresh, _} = live(conn, "/t/#{t.id}/pairings")

      clear =
        render_change(fresh, "result", %{"pairing-id" => to_string(board.id), "result" => ""})

      results = results ++ [audit_state("clear-result confirmation", clear)]

      if report(results) != "", do: flunk(report(results))

      # The confirmation takes focus as it replaces the select that had it,
      # and says what it is asking on both of its buttons.
      assert has_element?(fresh, ".confirm-clear-result button[phx-mounted][aria-describedby]")

      assert has_element?(
               fresh,
               ".confirm-clear-result button[aria-describedby]:not([phx-mounted])"
             )
    end
  end

  describe "the markup the page scripts rely on" do
    test "the skip link, the announcer, and the dialogs' hook", %{conn: conn, tournament: t} do
      html = conn |> get("/t/#{t.id}/pairings") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert document
             |> LazyHTML.query(~s(body > a.skip-link[href="#main-content"]))
             |> Enum.count() == 1

      assert document |> LazyHTML.query(~s(main#main-content[tabindex="-1"])) |> Enum.count() == 1
      assert document |> LazyHTML.query(~s(#announcer[aria-live="polite"])) |> Enum.count() == 1

      # The banners are seen, and said through #announcer - never live regions
      # of their own while `hidden`.
      for id <- ~w(deploy-banner site-notice version-toast) do
        [banner] = document |> LazyHTML.query("##{id}") |> Enum.to_list()
        assert LazyHTML.attribute(banner, "aria-live") == []
        assert LazyHTML.attribute(banner, "role") == []
      end

      js = File.read!("assets/js/app.js")
      assert js =~ "DialogFocus"

      assert js =~
               "hooks: {...colocatedHooks, ColumnPrefs, PlayerGrid, AddPlayerShortcut, Flash, DialogFocus}"
    end

    test "every result select is named for its board and players", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, "/t/#{t.id}/pairings")
      document = view |> render() |> LazyHTML.from_fragment()

      selects = LazyHTML.query(document, "select[data-board-select]")
      assert Enum.count(selects) > 0

      for label <- LazyHTML.attribute(selects, "aria-label") do
        assert label =~ ~r/^Result, board \d+: .+ against .+$/
      end
    end
  end
end
