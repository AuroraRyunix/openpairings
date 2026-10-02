defmodule PairingsEngineWeb.PairClickGoldenTest do
  @moduledoc """
  The "Pair round" click was made faster (2026-10-02: batched board inserts,
  the rounds' engine accounts no longer read where nobody looks at them, the
  history walk indexed, the audit reads shared, the result options rendered
  as static markup). None of that may change a single thing the click
  leaves behind.

  `test/fixtures/pair_click/golden.term` was produced by these scenarios on
  the code BEFORE that work (0.71.0, commit 46f375a). Each scenario pairs
  its rounds through the Pairings page's own "pair" event and compares, with
  row ids, random ids and timestamps taken out:

    * everything the pairing wrote (`NextRoundPreviewFixture.snapshot/1`:
      pairing numbers, boards, frozen board labels, bye rows, virtual
      points, the round's account),
    * the standings with their tiebreaks,
    * the TRF export,
    * the full JSON export,
    * every audit row, the click's own among them,
    * the public snapshot OpenResults would be sent,
    * and the board list the page shows: each row's text, and its result
      select's options and selection.

  Run with `WRITE_PAIR_CLICK_GOLDEN=1` only to regenerate it from a version
  known to be right.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{Repo, Standings, TournamentExport, TrfExport, Snapshot}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @golden_path Path.expand("../../fixtures/pair_click/golden.term", __DIR__)

  setup :register_and_log_in_user

  # Complete setup, so the page pairs, and published, so the public
  # snapshot has something in it.
  defp setup_fields(rounds) do
    %{
      round_dates: for(d <- 1..rounds, do: "2026-09-0#{d}"),
      tiebreaks: ~w(BH BHC1 SB DE),
      publish_to_openresults: true,
      publish_mode: "standings"
    }
  end

  test "a single-pool Swiss with most options on", %{conn: conn, user: user} do
    t = options_tournament(Map.put(setup_fields(6), :user_id, user.id))

    click(conn, t)
    finish_latest_round(t)
    click(conn, t)
    finish_latest_round(t)

    # A withdrawal and a late entrant who has no pairing number yet.
    [withdrawn] =
      Repo.all(from p in Player, where: p.tournament_id == ^t.id and p.name == "Player 022")

    set_player(withdrawn, status: "withdrawn")
    insert_player(t, 24, %{start_round: 3})

    click(conn, t)
    finish_latest_round(t, fn board -> default_result(board + 1) end)
    pages = click(conn, t)

    check(:options, capture(t, pages))
  end

  test "a per-category Swiss", %{conn: conn, user: user} do
    t =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Categories",
            type: "swiss",
            rounds_count: 5,
            categories_enabled: true,
            pair_by_category: true,
            categories: ["A", "B", "C"],
            user_id: user.id
          },
          setup_fields(5)
        )
      )

    for i <- 1..15 do
      category = if i == 15, do: "C", else: if(rem(i, 2) == 0, do: "A", else: "B")
      insert_player(t, i, %{category: category, categories: [category]})
    end

    click(conn, t)
    finish_latest_round(t)
    click(conn, t)
    finish_latest_round(t)
    pages = click(conn, t)

    check(:categories, capture(t, pages))
  end

  test "a Swiss in match format, with an odd field", %{conn: conn, user: user} do
    t =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Matches",
            type: "swiss",
            rounds_count: 4,
            swiss_match_format: true,
            user_id: user.id
          },
          setup_fields(4)
        )
      )

    for i <- 1..11, do: insert_player(t, i)

    click(conn, t)
    finish_latest_round(t)
    pages = click(conn, t)

    check(:match_format, capture(t, pages))
  end

  # The arbiter's click, on the page, and the board list it brings back.
  defp click(conn, t) do
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    render_click(view, "pair", %{})
    refute has_element?(view, ".error-note, #pair-error")
    rows(render(view))
  end

  defp rows(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("tr[id^=pairing-row]")
    |> Enum.map(fn row ->
      options =
        row
        |> LazyHTML.query("option")
        |> Enum.map(fn o ->
          {o |> LazyHTML.attribute("value") |> List.first(),
           o |> LazyHTML.attribute("selected") |> List.first() != nil, squish(LazyHTML.text(o))}
        end)

      cells = row |> LazyHTML.query("td") |> Enum.map(&squish(LazyHTML.text(&1)))
      {List.delete_at(cells, 2), options}
    end)
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp capture(t, pages) do
    t = reload(t)
    names = player_names(t)
    {:ok, trf} = TrfExport.export(t)

    %{
      written: snapshot(t),
      standings: normalize(Standings.standings(t), names),
      trf: trf,
      export: t |> TournamentExport.export_tournament() |> normalize(names),
      public:
        t
        |> Snapshot.build()
        |> Map.drop(["published_at", "source", "publisher"])
        |> normalize(names),
      audit: audit_trail(t, names),
      page: pages
    }
  end

  # Every audit row the scenario wrote, in order: the click's own
  # `pairing.round_paired` account with the rest.
  defp audit_trail(t, names) do
    Repo.all(
      from a in PairingsEngine.Audit.AuditLog,
        where: a.tournament_id == ^t.id,
        order_by: a.id,
        select: {a.action, a.details}
    )
    |> Enum.map(fn {action, details} -> {action, normalize(details, names)} end)
  end

  defp player_names(t) do
    Repo.all(from p in Player, where: p.tournament_id == ^t.id, select: {p.id, p.name})
    |> Map.new()
  end

  # Row ids, random ids and timestamps out; player ids become names. What
  # is left is what the tournament says, not where the database put it.
  @dropped ~w(id game_uid data_version head_snapshot_id openresults_key public_slug slug)

  defp normalize(%_{} = struct, names) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Map.new()
    |> normalize(names)
  end

  defp normalize(map, names) when is_map(map) do
    for {k, v} <- map, not dropped?(k), into: %{} do
      {k, normalize_value(to_string(k), v, names)}
    end
  end

  defp normalize(list, names) when is_list(list), do: Enum.map(list, &normalize(&1, names))
  defp normalize(value, _names), do: value

  defp dropped?(key) do
    key = to_string(key)
    key in @dropped or String.ends_with?(key, "_at") or key == "exported" or key == "user_id"
  end

  defp normalize_value(key, value, names) when is_integer(value) do
    cond do
      String.ends_with?(key, "player_id") or key in ~w(player_a_id player_b_id opponent_id) ->
        {:player, Map.get(names, value, :unknown)}

      String.ends_with?(key, "_id") ->
        :id

      true ->
        value
    end
  end

  defp normalize_value(key, values, names) when is_list(values) do
    if String.ends_with?(key, "player_ids"),
      do: Enum.map(values, &{:player, Map.get(names, &1, &1)}),
      else: normalize(values, names)
  end

  defp normalize_value(_key, value, names), do: normalize(value, names)

  defp check(key, captured) do
    if System.get_env("WRITE_PAIR_CLICK_GOLDEN") == "1" do
      golden = if File.exists?(@golden_path), do: read_golden(), else: %{}
      File.mkdir_p!(Path.dirname(@golden_path))

      File.write!(
        @golden_path,
        inspect(Map.put(golden, key, captured), limit: :infinity, printable_limit: :infinity)
      )
    else
      golden = Map.fetch!(read_golden(), key)

      for part <- Map.keys(golden) do
        was = Map.fetch!(golden, part)
        now = Map.fetch!(captured, part)

        assert now == was,
               "#{key}: #{part} differs from before, first at #{inspect(first_difference(now, was, [part]))}"
      end
    end
  end

  # Where two captures first part ways, as a path and the two values there.
  defp first_difference(a, a, _path), do: nil

  defp first_difference(%{} = a, %{} = b, path) do
    keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))

    Enum.find_value(keys, {Enum.reverse(path), :keys, Map.keys(a) -- Map.keys(b)}, fn k ->
      first_difference(Map.get(a, k, :missing), Map.get(b, k, :missing), [k | path])
    end)
  end

  defp first_difference(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.find_value(fn {{x, y}, i} -> first_difference(x, y, [i | path]) end)
  end

  defp first_difference(a, b, path), do: {Enum.reverse(path), a, b}

  defp read_golden do
    {golden, _binding} = Code.eval_file(@golden_path)
    golden
  end
end
