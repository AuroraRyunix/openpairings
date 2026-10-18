defmodule PairingsEngine.Norms.TitleNormsBigSwissTest do
  @moduledoc """
  B.01 1.4.3 (d), the big-Swiss clause: a Swiss System tournament "in which
  participants include in every round at least 20 FIDE rated players, not
  from the host federation, from at least 3 different federations, at least
  10 of whom hold GM, IM, WGM or WIM titles" is exempt from the federation
  mix; players "will be counted only if they miss at most one round
  (excluding pairing allocated byes)". Detected from the field, no setting.

  The candidate (BEL, host BEL) beats nine BEL grandmasters rated 2600, so
  every requirement passes except the federation mix, which fails unless
  the clause lifts it. Beside them plays a "field" of other players who
  only meet each other; whether the clause holds is decided by that field.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Norms.TitleNorms
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @rounds 9

  # `field`: one map per field player - `fed`, `title` (nil), `rating`
  # (2300), `skip` (rounds they have no pairing in) and `pab` (rounds they
  # get the pairing-allocated bye).
  defp fixture(field, opts \\ []) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Big Swiss",
        type: Keyword.get(opts, :type, "swiss"),
        pairing_system: Keyword.get(opts, :pairing_system, "swiss"),
        rounds_count: @rounds,
        federation: Keyword.get(opts, :federation, "BEL"),
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0
      })

    candidate = player!(tournament, 1, "Candidate", "BEL", nil, 2450)

    opponents =
      for i <- 1..@rounds, do: player!(tournament, i + 1, "Opponent #{i}", "BEL", "GM", 2600)

    field =
      field
      |> Enum.with_index()
      |> Enum.map(fn {spec, i} ->
        {player!(
           tournament,
           100 + i,
           "Field #{i}",
           spec.fed,
           Map.get(spec, :title),
           Map.get(spec, :rating, 2300)
         ), spec}
      end)

    for r <- 1..@rounds do
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: r, status: "finished"})
      pair!(round, 1, candidate, Enum.at(opponents, r - 1), "1-0")

      {byes, playing} =
        field
        |> Enum.reject(fn {_p, spec} -> r in Map.get(spec, :skip, []) end)
        |> Enum.split_with(fn {_p, spec} -> r in Map.get(spec, :pab, []) end)

      # An odd one out gets the bye, as a pairing would give it.
      {playing, byes} =
        if rem(length(playing), 2) == 1,
          do: {Enum.drop(playing, -1), byes ++ [List.last(playing)]},
          else: {playing, byes}

      playing
      |> Enum.chunk_every(2)
      |> Enum.with_index(2)
      |> Enum.each(fn {[{w, _}, {b, _}], board} -> pair!(round, board, w, b, "1/2-1/2") end)

      byes
      |> Enum.with_index(1000)
      |> Enum.each(fn {{p, _}, board} -> pair!(round, board, p, nil, "bye") end)
    end

    {tournament, candidate}
  end

  defp player!(tournament, number, name, fed, title, rating) do
    Repo.insert!(%Player{
      tournament_id: tournament.id,
      name: name,
      federation: fed,
      title: title,
      fide_rating: rating,
      pairing_number: number
    })
  end

  defp pair!(round, board, white, black, result) do
    Repo.insert!(%Pairing{
      round_id: round.id,
      board: board,
      white_player_id: white.id,
      black_player_id: black && black.id,
      result: result
    })
  end

  # `n` foreign players cycling through `feds`, the first `titled` of them IMs.
  defp field(n, feds, titled, extra \\ %{}) do
    for i <- 0..(n - 1) do
      Map.merge(
        %{fed: Enum.at(feds, rem(i, length(feds))), title: if(i < titled, do: "IM")},
        extra
      )
    end
  end

  defp gm_verdict({tournament, candidate}) do
    tournament
    |> TitleNorms.evaluate()
    |> Map.fetch!(candidate.id)
    |> Map.fetch!(:verdicts)
    |> Enum.find(&(&1.title == "GM"))
  end

  defp check(verdict, name), do: Enum.find(verdict.checks, &(&1.name == name))

  defp big_swiss({tournament, _candidate}), do: TitleNorms.big_swiss(tournament)

  describe "1.4.3 (d): the clause met" do
    test "20 foreign rated players from 3 federations, 10 titled: the federation mix is lifted" do
      fx = fixture(field(20, ~w(FRA NED GER), 10))

      assert %{applies?: true, players: 20, federations: 3, titled: 10} = big_swiss(fx)

      v = gm_verdict(fx)
      assert v.achieved?
      assert check(v, :foreign_federations).ok?
      assert check(v, :foreign_federations).detail =~ "1.4.3 (d)"
      assert check(v, :own_federation_share).ok?
      assert check(v, :single_federation_share).ok?
      # 1.4.3 (e) is still said out loud.
      assert check(v, :foreign_federations).detail =~ "1.4.3 (e)"
    end

    test "WGM and WIM count among the 10 titled, as GM and IM do" do
      field =
        field(20, ~w(FRA NED GER), 0)
        |> Enum.with_index()
        |> Enum.map(fn {spec, i} ->
          if i < 10, do: %{spec | title: Enum.at(~w(GM WGM WIM IM), rem(i, 4))}, else: spec
        end)

      assert %{applies?: true, titled: 10} = big_swiss(fixture(field))
    end
  end

  describe "1.4.3 (d): each threshold, one short" do
    test "19 players are not 20" do
      fx = fixture(field(19, ~w(FRA NED GER), 10))
      assert %{applies?: false, players: 19} = big_swiss(fx)
      refute check(gm_verdict(fx), :foreign_federations).ok?
    end

    test "two federations are not three" do
      fx = fixture(field(20, ~w(FRA NED), 10))
      assert %{applies?: false, federations: 2} = big_swiss(fx)
      refute gm_verdict(fx).achieved?
    end

    test "nine titled are not ten - and FM does not count as a title here" do
      fx = fixture(field(20, ~w(FRA NED GER), 9))
      assert %{applies?: false, titled: 9} = big_swiss(fx)

      fm =
        field(20, ~w(FRA NED GER), 9)
        |> List.update_at(19, &%{&1 | title: "FM"})

      assert %{applies?: false, titled: 9} = big_swiss(fixture(fm))
    end
  end

  describe "1.4.3 (d): who is counted" do
    test "players of the host federation are not counted" do
      field = field(19, ~w(FRA NED GER), 10) ++ [%{fed: "BEL", title: "GM"}]
      assert %{applies?: false, players: 19} = big_swiss(fixture(field))
    end

    test "a player under the FIDE flag is not counted (1.4.2)" do
      field = field(19, ~w(FRA NED GER), 10) ++ [%{fed: "FID", title: "GM"}]
      assert %{applies?: false, players: 19} = big_swiss(fixture(field))
    end

    test "an unrated player is not counted - the clause asks for FIDE rated players" do
      field = field(19, ~w(FRA NED GER), 10) ++ [%{fed: "FRA", rating: nil}]
      assert %{applies?: false, players: 19} = big_swiss(fixture(field))
    end

    test "missing one round still counts, missing two does not" do
      one = field(20, ~w(FRA NED GER), 10) |> List.update_at(19, &Map.put(&1, :skip, [4]))
      assert %{applies?: true, players: 20} = big_swiss(fixture(one))

      two = field(20, ~w(FRA NED GER), 10) |> List.update_at(19, &Map.put(&1, :skip, [4, 7]))
      assert %{applies?: false, players: 19} = big_swiss(fixture(two))
    end

    test "a pairing-allocated bye is not a missed round" do
      field =
        field(20, ~w(FRA NED GER), 10) |> List.update_at(19, &Map.merge(&1, %{pab: [2], skip: [5]}))

      assert %{applies?: true, players: 20} = big_swiss(fixture(field))
    end
  end

  describe "1.4.3 (d): where the clause is never asked" do
    test "no host federation set: not claimed" do
      fx = fixture(field(20, ~w(FRA NED GER), 10), federation: "")
      assert big_swiss(fx) == nil
      refute gm_verdict(fx).achieved?
    end

    test "a round robin is not a Swiss" do
      fx = fixture(field(20, ~w(FRA NED GER), 10), pairing_system: "round_robin")
      assert big_swiss(fx) == nil
      refute check(gm_verdict(fx), :foreign_federations).ok?
    end

    test "no completed round: nothing to count" do
      tournament =
        Repo.insert!(%Tournament{name: "Empty", type: "swiss", rounds_count: 9, federation: "BEL"})

      assert TitleNorms.big_swiss(tournament) == nil
    end

    test "an ordinary small Swiss judges exactly as before" do
      fx = fixture(field(4, ~w(FRA NED GER), 4))
      assert %{applies?: false} = big_swiss(fx)

      v = gm_verdict(fx)
      refute check(v, :foreign_federations).ok?
      refute check(v, :foreign_federations).detail =~ "exempt under"
    end
  end

  test "an event-type exemption is cited in preference to 1.4.3 (d)" do
    {tournament, candidate} = fixture(field(20, ~w(FRA NED GER), 10))
    tournament = Repo.update!(Ecto.Changeset.change(tournament, norm_event_type: "zonal"))

    v =
      tournament
      |> TitleNorms.evaluate()
      |> Map.fetch!(candidate.id)
      |> Map.fetch!(:verdicts)
      |> Enum.find(&(&1.title == "GM"))

    assert check(v, :foreign_federations).detail =~ "1.4.3 (c)"
    refute check(v, :foreign_federations).detail =~ "1.4.3 (d)"
  end
end
