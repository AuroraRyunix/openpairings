defmodule PairingsEngineWeb.PairingsLiveResultOptionsTest do
  @moduledoc """
  The board list's result select is written out as markup
  (`PairingsLive.result_options/1`) so its options are static on the wire.
  `PairingsLive.result_choices/2` - built from the page's `@results`, which
  the compiler already holds to `PairingsEngine.Results.entry_codes/0` - is
  what each select must offer, and these tests hold the markup to it: the
  same codes, labels, order and selection, with postponed games allowed or
  not, and on boards holding a named or an unnamed postponement.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Pairing, Tournament}
  alias PairingsEngineWeb.PairingsLive

  setup :register_and_log_in_user

  for postponed_games <- [false, true] do
    test "every board offers result_choices/2 (postponed games #{postponed_games})", %{
      conn: conn,
      user: user
    } do
      t =
        Repo.insert!(%Tournament{
          name: "Options",
          type: "swiss",
          rounds_count: 3,
          round_dates: ~w(2026-09-01 2026-09-02 2026-09-03),
          tiebreaks: ~w(BH),
          postponed_games: unquote(postponed_games),
          user_id: user.id
        })

      for i <- 1..11, do: insert_player(t, i)
      pair!(t)

      # One board of each kind: no result, a result, the unnamed `*`, a
      # named postponement, and the bye.
      boards =
        Repo.all(
          from p in Pairing,
            join: r in assoc(p, :round),
            where: r.tournament_id == ^t.id and not is_nil(p.black_player_id),
            order_by: p.board
        )

      for {pairing, result} <- Enum.zip(boards, ["1-0", "*", "*W", "1/2-1/2U"]) do
        Repo.update_all(from(p in Pairing, where: p.id == ^pairing.id), set: [result: result])
      end

      {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      document = view |> render() |> LazyHTML.from_document()
      t = reload(t)

      selects = LazyHTML.query(document, "select[id^=result-select-]")
      assert Enum.count(selects) == 5

      for select <- selects do
        "result-select-" <> id = select |> LazyHTML.attribute("id") |> hd()
        pairing = Repo.get!(Pairing, String.to_integer(id))

        shown =
          select
          |> LazyHTML.query("option")
          |> Enum.map(fn o ->
            {o |> LazyHTML.attribute("value") |> hd(),
             o |> LazyHTML.text() |> String.split() |> Enum.join(" "),
             LazyHTML.attribute(o, "selected") != []}
          end)

        expected =
          for {value, label} <- PairingsLive.result_choices(t, pairing),
              do: {value, label, pairing.result == value}

        assert shown == expected
      end
    end
  end
end
