defmodule PairingsEngineWeb.PrintLiveCategoryTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Round}

  setup :register_and_log_in_user

  defp tournament(scope, categories) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{"name" => "Print Cats", "type" => "swiss"})

    t = t |> Ecto.Changeset.change(categories: categories) |> Repo.update!()
    Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})
    t
  end

  test "no selector without categories", %{conn: conn, scope: scope} do
    t = tournament(scope, [])
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")
    refute has_element?(lv, "#print-category")
  end

  test "choosing a category rewrites the filterable links and the URL", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, ["U1800", "Women & Girls"])
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")

    assert has_element?(lv, "#print-category")
    assert has_element?(lv, "#print-doc-players[href]") == false
    assert has_element?(lv, "#print-doc-players a[href='/t/#{t.id}/print/players']")

    lv |> form("#print-category-form", %{"category" => "Women & Girls"}) |> render_change()

    assert_patch(lv, "/t/#{t.id}/print?category=Women+%26+Girls")

    assert has_element?(
             lv,
             "#print-doc-players a[href='/t/#{t.id}/print/players?category=Women+%26+Girls']"
           )

    assert has_element?(
             lv,
             "#print-doc-pairings a[href='/t/#{t.id}/print/pairings?round=1&category=Women+%26+Girls']"
           )

    # A reload keeps the choice.
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print?#{[category: "U1800"]}")

    assert has_element?(
             lv,
             "#print-doc-standings a[href='/t/#{t.id}/print/standings?category=U1800']"
           )
  end
end
