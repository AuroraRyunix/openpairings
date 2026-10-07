defmodule PairingsEngine.BoardAnnouncements do
  @moduledoc """
  Boards of the next round announced before it is paired.

  While the last games of a round are still being played, the next-round
  preview (`PairingsEngine.NextRoundPreview`) knows which boards of the
  next round come out the same whatever their results. An arbiter who puts
  out those boards' name cards records it here - by announcing them on the
  Pairings page, or by printing them with "these cards go out now" ticked:
  each board's number, White and Black as announced, when and by whom.

  Three things follow from the record:

    * **Something changed** (`status/2`): a result outside the games the
      preview tried, a forfeit, a player, a setting, a forbidden pairing -
      anything that moves the preview's base
      (`NextRoundPreview.base_state/2`) - and the announced boards may no
      longer hold. "Check again" works the preview out again and marks
      every announced board that is no longer fixed (`check/3`).
    * **The round is paired** (`compare/2`): each announced board is held
      to the real pairing - opponent, colours, board number. A difference
      is information only: the pairing is never changed to match an
      announcement, which would be manipulating the pairing (C.04.2 1.5)
      and, in FIDE mode, a departure. The cards are re-printed instead.
    * **Unpaired and paired again**: compared again; a new round has a new
      id, so an acknowledgement of the old one's differences does not
      carry over.

  The audit trail entries are written by the Pairings page, next to the
  click, like every other.
  """

  import Ecto.Query

  alias PairingsEngine.{NextRoundPreview, PairingDisplay, Repo, Tournaments}
  alias PairingsEngine.BoardAnnouncements.{AnnouncedBoard, Announcement}
  alias PairingsEngine.Pairing, as: Engine

  @doc "The announcement for `round` of `tournament_id`, its boards in board order, or nil."
  def get(tournament_id, round) do
    Announcement
    |> where([a], a.tournament_id == ^tournament_id and a.round == ^round)
    |> preload(boards: ^from(b in AnnouncedBoard, order_by: b.id))
    |> Repo.one()
    |> sort_boards()
  end

  defp sort_boards(nil), do: nil

  defp sort_boards(%Announcement{} = a),
    do: %{a | boards: Enum.sort_by(a.boards, &label_order(&1.label))}

  defp label_order(label) do
    case Integer.parse(label) do
      {n, ""} -> {0, n, label}
      _ -> {1, 0, label}
    end
  end

  @doc """
  Announces the fixed boards of `preview` - a finished
  `NextRoundPreview.run/2` result - for its round, on behalf of `scope`.

  A board already announced with the same number and players is kept as
  it was (its time and author too); a board announced earlier for one of
  the same players, but different, is replaced. The announcement's state
  moves to the preview's. `{:ok, announcement, added, replaced}` - the
  boards newly written and the ones they replaced - or `{:error,
  :nothing_fixed}`.
  """
  def announce(tournament_id, preview, scope) do
    case preview.fixed do
      [] ->
        {:error, :nothing_fixed}

      fixed ->
        now = DateTime.utc_now(:second)
        {user_id, user_name} = author(scope)

        Repo.transaction(fn ->
          announcement = upsert(tournament_id, preview)

          existing =
            Repo.all(from b in AnnouncedBoard, where: b.announcement_id == ^announcement.id)

          {added, replaced} =
            Enum.reduce(fixed, {[], []}, fn row, {added, replaced} ->
              same = Enum.find(existing, &same_board?(&1, row))

              if same do
                if same.uncertain, do: Repo.update!(Ecto.Changeset.change(same, uncertain: false))
                {added, replaced}
              else
                clashing =
                  Enum.filter(existing, fn b ->
                    MapSet.disjoint?(players(b), MapSet.new([row.white, row.black])) == false
                  end)

                Enum.each(clashing, &Repo.delete!/1)

                board =
                  Repo.insert!(%AnnouncedBoard{
                    announcement_id: announcement.id,
                    label: row.label,
                    white_player_id: row.white,
                    black_player_id: row.black,
                    white_name: name(preview, row.white),
                    black_name: name(preview, row.black),
                    announced_at: now,
                    announced_by_id: user_id,
                    announced_by: user_name
                  })

                {[board | added], clashing ++ replaced}
              end
            end)

          {get(tournament_id, preview.next_round), Enum.reverse(added), Enum.uniq(replaced)}
        end)
        |> case do
          {:ok, {announcement, added, replaced}} -> {:ok, announcement, added, replaced}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp upsert(tournament_id, preview) do
    attrs = [base: preview.base, round_results: stringify(preview.round_results)]

    case Repo.one(
           from a in Announcement,
             where: a.tournament_id == ^tournament_id and a.round == ^preview.next_round
         ) do
      nil ->
        Repo.insert!(
          struct(%Announcement{tournament_id: tournament_id, round: preview.next_round}, attrs)
        )

      announcement ->
        announcement |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  defp same_board?(%AnnouncedBoard{} = b, row),
    do: b.label == row.label and b.white_player_id == row.white and b.black_player_id == row.black

  defp players(%AnnouncedBoard{} = b), do: MapSet.new([b.white_player_id, b.black_player_id])

  defp name(preview, id) do
    case Map.get(preview.players, id) do
      %{name: name} -> name
      _ -> ""
    end
  end

  defp author(%{user: %{id: id} = user}),
    do: {id, Map.get(user, :display_name) || Map.get(user, :email) || ""}

  defp author(_scope), do: {nil, ""}

  defp stringify(results), do: Map.new(results, fn {id, r} -> {to_string(id), r} end)

  @doc "Withdraws the announcement for `round`: `{:ok, boards}` (how many it had) or `{:error, :none}`."
  def withdraw(tournament_id, round) do
    case get(tournament_id, round) do
      nil ->
        {:error, :none}

      announcement ->
        Repo.delete!(announcement)
        {:ok, length(announcement.boards)}
    end
  end

  @doc """
  The announcement for the round about to be paired - the one after the
  latest paired round - or nil.
  """
  def pending(tournament_id) do
    get(tournament_id, Engine.paired_rounds_count(tournament_id) + 1)
  end

  @doc """
  Whether `announcement`'s boards can still be trusted as announced:

    * `:holds` - nothing has changed but results the preview tried: a
      result entered (1-0, ½-½ or 0-1) for a game that was open then;
    * `:changed` - anything else: a decided board's result, a result
      cleared, a forfeit, a player, a setting, a forbidden pairing, an
      absence, a round paired or unpaired.
  """
  def status(_tournament_id, %Announcement{base: nil}), do: :changed

  def status(tournament_id, %Announcement{} = announcement) do
    played = announcement.round - 1

    if Engine.paired_rounds_count(tournament_id) != played do
      :changed
    else
      {base, results} = NextRoundPreview.base_state(tournament_id, played)

      if base == announcement.base and only_tried_results?(announcement.round_results, results),
        do: :holds,
        else: :changed
    end
  end

  defp only_tried_results?(then, now) do
    now = stringify(now)

    Map.keys(then) |> Enum.sort() == Map.keys(now) |> Enum.sort() and
      Enum.all?(then, fn {id, was} ->
        is = Map.fetch!(now, id)
        is == was or (was == "" and is in NextRoundPreview.outcomes())
      end)
  end

  @doc """
  Holds the announced boards to `preview` - the next-round preview worked
  out again now - and records the outcome: a board the preview no longer
  has as fixed (same number, same players, same colours) is marked
  uncertain, one it has again is not. The announcement's state moves to
  the preview's, so the "something changed" warning is answered.

  `{:ok, %{announcement:, uncertain:, certain:}}` - the boards no longer
  certain, and how many still are - or `{:error, :none}`.
  """
  def check(tournament_id, round, preview) do
    case get(tournament_id, round) do
      nil ->
        {:error, :none}

      announcement ->
        fixed = MapSet.new(preview.fixed, &{&1.label, &1.white, &1.black})

        {uncertain, certain} =
          Enum.split_with(announcement.boards, fn b ->
            not MapSet.member?(fixed, {b.label, b.white_player_id, b.black_player_id})
          end)

        Repo.transaction(fn ->
          for b <- announcement.boards do
            flag = b in uncertain
            if b.uncertain != flag, do: Repo.update!(Ecto.Changeset.change(b, uncertain: flag))
          end

          announcement
          |> Ecto.Changeset.change(
            base: preview.base,
            round_results: stringify(preview.round_results)
          )
          |> Repo.update!()
        end)

        {:ok,
         %{
           announcement: get(tournament_id, round),
           uncertain: uncertain,
           certain: length(certain)
         }}
    end
  end

  @doc """
  The announced boards of `round` - paired now - held to the real pairing
  (`paired`, the round with its pairings and players preloaded, when the
  caller has it already).
  nil when nothing was announced for it or it is not paired; otherwise

      %{announcement:, round_id:, total:, acknowledged?:,
        changed: [%{board:, actual:, changes:}]}

  `actual` the announced White's board in the pairing (`%{label:, white:,
  black:}`, names; `black` nil for a bye) or nil when they are not paired,
  and `changes` what differs: `:opponent`, `:colours`, `:board`, or
  `:not_paired`.
  """
  def compare(tournament_id, round, paired \\ nil) do
    with %Announcement{} = announcement <- get(tournament_id, round),
         %{} = paired <- paired || Tournaments.get_round(tournament_id, round) do
      seats = seats(paired.pairings)

      changed =
        Enum.flat_map(announcement.boards, fn b ->
          actual = Map.get(seats, b.white_player_id)

          case changes(b, actual) do
            [] -> []
            changes -> [%{board: b, actual: actual && Map.delete(actual, :ids), changes: changes}]
          end
        end)

      %{
        announcement: announcement,
        round_id: paired.id,
        total: length(announcement.boards),
        changed: changed,
        acknowledged?: announcement.acknowledged_round_id == paired.id
      }
    else
      _ -> nil
    end
  end

  # Every player's board in the paired round, by player id.
  defp seats(pairings) do
    Enum.reduce(pairings, %{}, fn p, acc ->
      seat = %{
        label: PairingDisplay.board_label(p),
        white: p.white_player && p.white_player.name,
        black: p.black_player && p.black_player.name,
        ids: {p.white_player_id, p.black_player_id}
      }

      [p.white_player_id, p.black_player_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(acc, &Map.put(&2, &1, seat))
    end)
  end

  defp changes(_board, nil), do: [:not_paired]

  defp changes(%AnnouncedBoard{} = b, %{ids: {white, black}, label: label}) do
    cond do
      MapSet.new([white, black]) != MapSet.new([b.white_player_id, b.black_player_id]) ->
        [:opponent] ++ if(label != b.label, do: [:board], else: [])

      true ->
        if(white != b.white_player_id, do: [:colours], else: []) ++
          if(label != b.label, do: [:board], else: [])
    end
  end

  @doc "Records that the arbiter has seen the differences between the announcement and `round_id`."
  def acknowledge(%Announcement{} = announcement, round_id) do
    announcement |> Ecto.Changeset.change(acknowledged_round_id: round_id) |> Repo.update()
  end

  @doc "A board as the audit trail stores it."
  def audit_board(%AnnouncedBoard{} = b),
    do: %{board: b.label, white: b.white_name, black: b.black_name}
end
