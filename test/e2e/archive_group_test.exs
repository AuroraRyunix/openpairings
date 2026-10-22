defmodule PairingsEngineWeb.E2E.ArchiveGroupTest do
  @moduledoc """
  "Archive group" on the tournament list: one button, the app's own confirm
  dialog in front of it (app.js turns every data-confirm into one, and no
  LiveViewTest ever sees it), and every tournament of the group archived - or
  none of them, when the answer is no.
  """
  use PairingsEngineWeb.E2ECase

  alias PairingsEngine.{Tournaments, TournamentGroups}
  alias PairingsEngine.Accounts.Scope

  setup %{conn: conn} do
    {conn, user} = sign_in(conn)
    scope = Scope.for_user(user)

    [open, u20] =
      for name <- ["Spring Open", "Spring U20"] do
        {:ok, t} =
          Tournaments.create_tournament(scope, %{
            "name" => name,
            "type" => "swiss",
            "rounds_count" => "5"
          })

        t
      end

    {:ok, group} = TournamentGroups.create_group(scope, open, "Spring Festival")
    {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)

    {:ok, conn: conn, open: open, u20: u20, group: group}
  end

  test "asks first, then archives the whole group", %{conn: conn} = ctx do
    conn
    |> visit("/")
    |> assert_has("body .phx-connected")
    |> click("#home-group-archive-#{ctx.group.id}")
    # In two pieces: the driver does not escape a quote inside `text:`.
    |> assert_has("dialog.pe-confirm", text: "Archive all 2 tournaments of")
    |> assert_has("dialog.pe-confirm", text: "Spring Festival")
    |> within("dialog.pe-confirm", &click_button(&1, "OK"))
    |> refute_has("dialog.pe-confirm")
    |> refute_has("#home-group-archive-#{ctx.group.id}")
    |> assert_has("#flash-info")

    assert Tournaments.archived?(Tournaments.get_tournament!(ctx.open.id))
    assert Tournaments.archived?(Tournaments.get_tournament!(ctx.u20.id))
  end

  test "answering no archives nothing", %{conn: conn} = ctx do
    conn
    |> visit("/")
    |> assert_has("body .phx-connected")
    |> click("#home-group-archive-#{ctx.group.id}")
    |> within("dialog.pe-confirm", &click_button(&1, "Cancel"))
    |> refute_has("dialog.pe-confirm")
    # Loaded afresh, so a click that did get through would have had its say.
    |> visit("/")
    |> assert_has("body .phx-connected")
    |> assert_has("#home-group-archive-#{ctx.group.id}")
    |> assert_has("#tournament-row-#{ctx.open.id}")

    refute Tournaments.archived?(Tournaments.get_tournament!(ctx.open.id))
    refute Tournaments.archived?(Tournaments.get_tournament!(ctx.u20.id))
  end
end
