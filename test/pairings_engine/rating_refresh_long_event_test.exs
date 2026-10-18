defmodule PairingsEngine.RatingRefreshLongEventTest do
  @moduledoc """
  Refresh ratings in a tournament lasting more than 30 days: the starting
  rating (`fide_rating`) stays, a changed rating is added as a later rating
  (`period_ratings`) from a round, and no pairing number moves.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Fide, Meta, Pairing, RatingRefresh, Repo, Tournaments, Tpn}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup do
    Meta.put("fide_list_period", "2026-11")
    :ok
  end

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Long",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 7,
          long_event: true
        },
        attrs
      )
    )
  end

  defp player(t, name, rating, fide_id, attrs \\ %{}) do
    {:ok, p} =
      Tournaments.create_player(
        t.id,
        Map.merge(%{"name" => name, "fide_rating" => rating, "fide_id" => "#{fide_id}"}, attrs)
      )

    p
  end

  defp fide(id, rating),
    do: Repo.insert!(%FidePlayer{fide_id: id, name: "F#{id}", standard_rating: rating, title: ""})

  defp reload(p), do: Repo.get!(Player, p.id)

  test "default round: the first round dated on or after the list's date" do
    t = tournament(%{round_dates: ~w(2026-10-04 2026-10-25 2026-11-08 2026-11-22 2026-12-06)})
    p = player(t, "A", 1800, 1)
    fide(1, 1850)

    summary = RatingRefresh.dry_run(t)
    assert summary.long_event
    assert summary.from_round == 3

    assert [%{field: :period_rating, old: 1800, new: 1850, extra: %{from_round: 3}}] =
             summary.proposals

    {:ok, _} = RatingRefresh.apply(t, summary.proposals)
    p = reload(p)
    assert p.fide_rating == 1800
    assert p.period_ratings == [%{"from_round" => 3, "fide_rating" => 1850}]
  end

  test "undated: the next round to be paired" do
    t = tournament()
    for n <- 1..8, do: player(t, "P#{n}", 2000 - n * 10, n)
    for n <- 1..8, do: fide(n, 2100 - n * 10)
    {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

    assert %{from_round: 2} = RatingRefresh.dry_run(Repo.reload!(t))
  end

  test "the round can be chosen once for the batch" do
    t = tournament()
    player(t, "A", 1800, 1)
    fide(1, 1850)

    summary = RatingRefresh.dry_run(t, Date.utc_today(), from_round: 5)
    assert summary.from_round == 5
    assert [%{extra: %{from_round: 5}}] = summary.proposals
  end

  test "a rating from the same round is replaced, not duplicated; others stay" do
    t = tournament()

    p =
      player(t, "A", 1800, 1, %{
        "period_ratings" => [
          %{"from_round" => 3, "fide_rating" => 1820},
          %{"from_round" => 5, "fide_rating" => 1830}
        ]
      })

    fide(1, 1850)

    summary = RatingRefresh.dry_run(t, Date.utc_today(), from_round: 3)
    {:ok, _} = RatingRefresh.apply(t, summary.proposals)

    assert reload(p).period_ratings == [
             %{"from_round" => 3, "fide_rating" => 1850},
             %{"from_round" => 5, "fide_rating" => 1830}
           ]
  end

  test "a rating equal to what the round already gives is not a change" do
    t = tournament()
    player(t, "A", 1800, 1, %{"period_ratings" => [%{"from_round" => 3, "fide_rating" => 1850}]})
    player(t, "B", 1850, 2)
    fide(1, 1850)
    fide(2, 1850)

    summary = RatingRefresh.dry_run(t, Date.utc_today(), from_round: 4)
    assert summary.proposals == []
    assert summary.changed == 0
  end

  test "nothing is written until Apply, and an empty selection writes nothing" do
    t = tournament()
    p = player(t, "A", 1800, 1)
    fide(1, 1850)

    summary = RatingRefresh.dry_run(t)
    assert reload(p).period_ratings == []

    {:ok, _} = RatingRefresh.apply(t, RatingRefresh.select(summary, []))
    assert reload(p).period_ratings == []
    assert reload(p).fide_rating == 1800
  end

  test "a title still comes along, as a title" do
    t = tournament()
    p = player(t, "A", 1800, 1)
    Repo.insert!(%FidePlayer{fide_id: 1, name: "F1", standard_rating: 1800, title: "FM"})

    summary = RatingRefresh.dry_run(t)
    assert [%{field: :title, new: "FM"}] = summary.proposals
    {:ok, _} = RatingRefresh.apply(t, summary.proposals)
    assert reload(p).title == "FM"
  end

  test "a tournament not lasting more than 30 days is unchanged: fide_rating is overwritten" do
    t = tournament(%{long_event: false})
    Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))
    p = player(t, "A", 1800, 1)
    fide(1, 1850)

    summary = RatingRefresh.dry_run(t)
    refute Map.has_key?(summary, :long_event)
    assert [%{field: :fide_rating, new: 1850}] = summary.proposals
    {:ok, _} = RatingRefresh.apply(t, summary.proposals)
    assert reload(p).fide_rating == 1850
    assert reload(p).period_ratings == []
  end

  test "the automatic notice is quiet in a long event" do
    t = tournament()
    player(t, "A", 1800, 1)
    fide(1, 1850)
    assert RatingRefresh.notice(t) == nil
  end

  describe "pairing numbers" do
    test "later ratings renumber nothing and raise no ordering warning" do
      t = tournament()
      for n <- 1..16, do: player(t, "P#{String.pad_leading("#{n}", 2, "0")}", 2400 - n * 30, n)
      # The lowest-rated player's FIDE rating becomes the highest on the new list.
      for n <- 1..16, do: fide(n, if(n == 16, do: 2800, else: 2400 - n * 30))

      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
      before = Map.new(Tournaments.list_players(t.id), &{&1.name, &1.pairing_number})

      summary = RatingRefresh.dry_run(Repo.reload!(t), Date.utc_today(), from_round: 2)
      assert [%{field: :period_rating, new: 2800}] = summary.proposals
      {:ok, _} = RatingRefresh.apply(t, summary.proposals)

      t = Repo.reload!(t)
      assert Tpn.out_of_order(t) == []
      assert Tpn.regeneration_changes(t) == []

      assert before ==
               Map.new(Tournaments.list_players(t.id), &{&1.name, &1.pairing_number})
    end
  end
end
