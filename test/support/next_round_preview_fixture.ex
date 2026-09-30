defmodule PairingsEngine.NextRoundPreviewFixture do
  @moduledoc """
  Synthetic tournaments for the next-round preview tests and for the
  "real pairing is unchanged" golden test. Invented names only - no real
  player data.

  `options_tournament/1` switches on as many of the options the Swiss path
  reads as can be combined in one event: a requested bye, a withdrawal, a
  late entrant without a pairing number yet, a hard and a soft forbidden
  pair, clubmates kept apart softly, a club exclusion, a bye exclusion, a
  fixed table, Baku acceleration and a drawn initial colour.
  """

  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{ForbiddenPairing, Player, Tournament}

  @clubs ["Rook", "Knight", "Bishop", "", "Pawn", ""]

  def plain_tournament(size, attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          %Tournament{name: "Preview #{size}", type: "swiss", rounds_count: 7},
          attrs
        )
      )

    for i <- 1..size, do: insert_player(t, i)
    t
  end

  def insert_player(t, i, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Player{
          tournament_id: t.id,
          name: "Player #{String.pad_leading(to_string(i), 3, "0")}",
          fide_rating: 2400 - i * 7,
          club: Enum.at(@clubs, rem(i, length(@clubs)))
        },
        attrs
      )
    )
  end

  @doc "A 23-player event with most pairing options switched on."
  def options_tournament(attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Options",
            type: "swiss",
            rounds_count: 6,
            acceleration: "baku",
            soft_club_rounds: 3,
            club_exclusion: "listed",
            club_exclusion_list: "Pawn",
            initial_colour: "black"
          },
          attrs
        )
      )

    players = for i <- 1..23, do: insert_player(t, i)

    by_i = fn i -> Enum.at(players, i - 1) end

    # A hard and a soft forbidden pair near the top.
    Repo.insert!(%ForbiddenPairing{
      tournament_id: t.id,
      player_a_id: by_i.(1).id,
      player_b_id: by_i.(4).id
    })

    Repo.insert!(%ForbiddenPairing{
      tournament_id: t.id,
      player_a_id: by_i.(2).id,
      player_b_id: by_i.(3).id,
      soft: true
    })

    set_player(by_i.(5), absent_rounds: "3")
    set_player(by_i.(20), no_bye: true)
    set_player(by_i.(21), no_bye: true)
    set_player(by_i.(7), fixed_board: 30)

    t
  end

  def set_player(player, fields) do
    Repo.update_all(from(p in Player, where: p.id == ^player.id), set: fields)
  end

  def reload(t), do: Repo.get!(Tournament, t.id)

  @doc "The latest round's result on every open board, by board number."
  def finish_latest_round(t, fun \\ &default_result/1) do
    round = latest_round(t)

    for p <- round.pairings, p.result == "", p.black_player_id != nil do
      {:ok, _} = Tournaments.update_pairing_result(p, fun.(p.board))
    end

    :ok
  end

  def default_result(board) do
    case rem(board, 3) do
      0 -> "1-0"
      1 -> "1/2-1/2"
      2 -> "0-1"
    end
  end

  def latest_round(t) do
    n = Pairing.paired_rounds_count(t.id)
    t.id |> Tournaments.get_round(n) |> Repo.preload(:pairings)
  end

  def pair!(t, opts \\ []) do
    {:ok, round} = Pairing.pair_next_round(reload(t), opts)
    round
  end

  @doc """
  Everything a pairing writes, with ids replaced by names so two databases
  can be compared: each round's boards (board, frozen label, White, Black,
  result), its bye rows, its recorded virtual points and the parts of its
  account that do not depend on row ids.
  """
  def snapshot(t) do
    names = Repo.all(from p in Player, where: p.tournament_id == ^t.id, select: {p.id, p.name})
    names = Map.new(names)
    name = fn id -> id && Map.get(names, id) end

    rounds =
      Repo.all(
        from r in PairingsEngine.Tournaments.Round,
          where: r.tournament_id == ^t.id,
          order_by: r.number,
          preload: :pairings
      )

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^t.id,
          order_by: [b.round, b.player_id],
          select: {b.round, b.player_id, b.type}
      )

    numbers =
      Repo.all(
        from p in Player,
          where: p.tournament_id == ^t.id,
          order_by: p.name,
          select: {p.name, p.pairing_number}
      )

    %{
      numbers: numbers,
      byes: Enum.map(byes, fn {r, id, type} -> {r, name.(id), type} end),
      rounds:
        Enum.map(rounds, fn r ->
          %{
            number: r.number,
            virtual_points:
              (r.virtual_points || %{})
              |> Enum.map(fn {id, v} -> {name.(String.to_integer(id)), v} end)
              |> Enum.sort(),
            boards:
              r.pairings
              |> Enum.sort_by(& &1.board)
              |> Enum.map(
                &{&1.board, &1.display_board, name.(&1.white_player_id),
                 name.(&1.black_player_id), &1.result}
              ),
            account: account(r.explanation, name)
          }
        end)
    }
  end

  defp account(%{"sections" => sections} = e, name) do
    names = fn ids -> Enum.map(ids || [], name) end

    %{
      engine: e["engine"],
      sections:
        Enum.map(sections, fn s ->
          %{
            category: s["category"],
            pairs: Enum.map(s["pairs"] || [], names),
            field: names.(s["field"]),
            bye_holder: name.(s["bye_holder"]),
            bye_exclusions: names.(s["bye_exclusions"]),
            bye_passed_over: names.(s["bye_passed_over"]),
            soft_pairs_moved: s["soft_pairs_moved"],
            brackets: length(s["brackets"] || [])
          }
        end)
    }
  end

  defp account(_none, _name), do: nil
end
