defmodule PairingsEngineWeb.RoundChangeNotice do
  @moduledoc """
  Tells a page that is open on a tournament that its rounds were changed by
  somebody else: paired, unpaired, re-paired, published or withdrawn.

  Every open page already reloads silently on a tournament broadcast, so
  nobody looks at stale boards. What nobody learned is THAT it happened, and
  an arbiter staring at round 3 while a colleague pairs round 4 gets no hint
  why the page just moved.

  ## How it avoids notifying the one who did it

  The broadcast carries no author, so this compares instead of asking: a page
  keeps the `marker/1` of the rounds it last showed, and updates it whenever
  it reloads for its own action. By the time the echo of that action arrives
  the marker already matches the database, and `notice/2` finds nothing to
  say. Only a change the page has not seen yet, which by definition came from
  elsewhere (a colleague, another tab), produces a message. Who did it is not
  recorded anywhere, so the message says "elsewhere" rather than guessing.
  """

  use Gettext, backend: PairingsEngineWeb.Gettext

  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Pairing, Round}

  @doc """
  What the tournament's rounds look like, cheaply: for every round that has
  boards, its number, a fingerprint of who plays whom (an aggregate in the
  database, no rows loaded) and when it was published. Results are not part
  of it - a result entered elsewhere is not a round being changed.
  """
  def marker(tournament_id) do
    Repo.all(
      from r in Round,
        join: p in Pairing,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id,
        group_by: [r.id, r.number, r.published_at],
        order_by: r.number,
        select: {
          r.number,
          fragment(
            "sum(coalesce(?, 0) * 7919 + coalesce(?, 0) * 104729 + coalesce(?, 0))",
            p.white_player_id,
            p.black_player_id,
            p.board
          ),
          r.published_at
        }
    )
  end

  @doc """
  The message for what changed between two markers, or nil when nothing did.
  When several rounds changed at once the highest-numbered one is named.
  """
  def notice(old, new) when is_list(old) and is_list(new) do
    old_by = Map.new(old, fn {n, fp, pub} -> {n, {fp, pub}} end)
    new_by = Map.new(new, fn {n, fp, pub} -> {n, {fp, pub}} end)

    changes =
      for n <- Enum.uniq(Map.keys(old_by) ++ Map.keys(new_by)),
          kind = kind(Map.get(old_by, n), Map.get(new_by, n)),
          do: {n, kind}

    case Enum.max_by(changes, &elem(&1, 0), fn -> nil end) do
      nil -> nil
      {n, kind} -> message(kind, n)
    end
  end

  def notice(_old, _new), do: nil

  defp kind(nil, nil), do: nil
  defp kind(nil, _), do: :paired
  defp kind(_, nil), do: :unpaired
  defp kind({fp, _}, {fp2, _}) when fp != fp2, do: :repaired
  defp kind({_, nil}, {_, pub}) when pub != nil, do: :published
  defp kind({_, pub}, {_, nil}) when pub != nil, do: :withdrawn
  defp kind(_, _), do: nil

  defp message(:paired, n), do: gettext("Round %{n} was just paired elsewhere.", n: n)
  defp message(:unpaired, n), do: gettext("Round %{n} was just unpaired elsewhere.", n: n)
  defp message(:repaired, n), do: gettext("Round %{n} was just paired again elsewhere.", n: n)
  defp message(:published, n), do: gettext("Round %{n} was just published elsewhere.", n: n)

  defp message(:withdrawn, n),
    do: gettext("Round %{n} was just withdrawn from publication elsewhere.", n: n)
end
