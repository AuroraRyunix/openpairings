defmodule PairingsEngine.TournamentGroups do
  @moduledoc """
  Tournament groups: one event that is really several tournaments - the
  Open, the U20, the U12, a rapid on the side - strung together so an
  arbiter can jump from any of them to a sibling.

  Each member keeps its own players, rounds and pairings. Grouping changes
  nothing about a tournament except where it sits in the switcher and on
  the home list; it is not a FIDE matter and never touches what is paired,
  reported or published.

  ## Who may do what

  The group has no owner. Every right comes from the tournaments in it:

    * creating a group from a tournament, adding a tournament to one, taking
      one out, labelling it - you must be allowed to edit that tournament
      (its owner, or an accepted collaborator, the same rule as
      `Tournaments.get_authorized_tournament/2`), and joining an existing
      group also needs you to be allowed to edit one of its members already,
      or anybody could attach a tournament to a stranger's event by id;
    * renaming the group or reordering it - you must be allowed to edit a
      tournament in it.

  An archived or handed-off tournament is read-only everywhere else, so it
  is read-only here too (`Tournaments.ensure_writable/1`).

  ## What anybody sees

  Only what they could open anyway. `switcher/2` lists the siblings the
  viewer may open and nothing else - not a greyed-out entry, not a count. A
  tournament somebody has no access to does not exist as far as they can
  tell, which is the point of access control and should stay true when two
  arbiters happen to run sections of the same event.

  ## On the results site

  A published member's snapshot carries a `group` block
  (`published_block/1`): the event's name and random public id, this
  tournament's label and place, and its siblings by public slug, label and
  name. OpenResults turns that into a tab strip and an event page.

  The rule that governs it is the switcher's rule pointed outward: **a
  snapshot names only siblings that are themselves on the results site.**
  Publishing the Open must not announce a U12 the arbiter has not published -
  not its name, not its label, not that it exists. So:

    * a sibling is named only while it is set to publish, a copy of it is on
      the site as far as this machine knows (`Publishing.on_site?/1`), and it
      is neither in the recycle bin nor handed off;
    * a sibling that is published but not listed on the site's front page is
      named only in the snapshots of members that are unlisted too. A listed
      page is one anybody browsing can reach, and naming a link-only section
      there would list it by another door;
    * `position` counts among the tournaments named, never the stored order,
      whose gaps would be a count of the ones left out;
    * a tournament with no sibling to name carries no block at all. "Part of
      an event" with nothing beside it is a statement that something else
      exists.

  When any of that changes - a sibling published, withdrawn, renamed,
  relabelled, moved, listed, binned - the other members' pages are out of
  date, and nothing an arbiter did to THEM says so. `sync_published/1` finds
  them: each tournament remembers a fingerprint of the block it last sent
  (`tournaments.openresults_group_sent`, written by `record_published/1`
  after a publish lands), and a member whose block would now read differently
  is queued again. It runs from the same funnel every write goes through, so
  it costs one indexed lookup for a tournament in no group and never sends
  anything that has not changed.

  ## Deleting

  A tournament purged for good takes its membership with it (the foreign
  key cascades), and `prune_empty_groups/0` removes a group that leaves
  empty. A tournament in the recycle bin keeps its place - restore it and it
  is back in its event - but nobody can open it, so nobody sees it in the
  switcher either.
  """

  import Ecto.Query

  alias PairingsEngine.{Audit, Publishing, Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.TournamentGroups.{Group, Member}
  alias PairingsEngine.Tournaments.Tournament

  @type move :: :up | :down

  ## ---------- reading ----------

  @doc """
  The membership row of `tournament_id`, with its group preloaded, or nil
  for a tournament in no group.
  """
  def membership(tournament_id) when is_integer(tournament_id) do
    Repo.one(from m in Member, where: m.tournament_id == ^tournament_id, preload: :group)
  end

  def membership(_), do: nil

  @doc """
  What the switcher on `tournament`'s pages shows to `scope`'s user, or nil
  when the tournament is in no group.

  `members` holds only the tournaments that user may open, in group order,
  each as `%{id, name, type, label, current?}`, where `label` is the short
  label or, when there is none, the tournament's name. See the moduledoc
  for why nothing else is listed.
  """
  def switcher(%Scope{} = scope, %Tournament{id: id}) do
    case membership(id) do
      nil ->
        nil

      %Member{group: group} ->
        %{group: group, members: visible_members(scope, group.id, id)}
    end
  end

  def switcher(_scope, _tournament), do: nil

  defp visible_members(scope, group_id, current_id) do
    Repo.all(
      from m in Member,
        join: t in Tournament,
        on: t.id == m.tournament_id,
        where:
          m.group_id == ^group_id and
            t.id in subquery(Tournaments.authorized_tournament_ids(scope)),
        order_by: [asc: m.position, asc: m.id],
        select: %{id: t.id, name: t.name, type: t.type, label: m.label}
    )
    |> Enum.map(fn m ->
      Map.merge(m, %{label: m.label || m.name, own_label: m.label, current?: m.id == current_id})
    end)
  end

  @doc """
  The groups `tournament` could join: every group with at least one member
  `scope`'s user may edit, other than the one the tournament is already in.
  Each as `%{group, labels}`, `labels` being the members that user can see.
  """
  def joinable_groups(%Scope{} = scope, %Tournament{id: id}) do
    current_group_id =
      case membership(id) do
        nil -> nil
        m -> m.group_id
      end

    Repo.all(
      from m in Member,
        join: t in Tournament,
        on: t.id == m.tournament_id,
        join: g in Group,
        on: g.id == m.group_id,
        where: t.id in subquery(Tournaments.authorized_tournament_ids(scope)),
        order_by: [asc: g.name, asc: g.id, asc: m.position, asc: m.id],
        select: {g, coalesce(m.label, t.name)}
    )
    |> Enum.reject(fn {g, _} -> g.id == current_group_id end)
    |> Enum.chunk_by(fn {g, _} -> g.id end)
    |> Enum.map(fn [{g, _} | _] = rows -> %{group: g, labels: Enum.map(rows, &elem(&1, 1))} end)
  end

  @doc """
  The group facts for a set of tournaments, for the home list:
  `%{tournament_id => %{group_id, group_name, label, position}}`. Tournaments
  in no group are absent. The caller passes only ids the user may open, so
  this never names anything they could not see.
  """
  def memberships_for(tournament_ids) when is_list(tournament_ids) do
    Repo.all(
      from m in Member,
        join: g in Group,
        on: g.id == m.group_id,
        where: m.tournament_id in ^tournament_ids,
        select:
          {m.tournament_id,
           %{group_id: g.id, group_name: g.name, label: m.label, position: m.position}}
    )
    |> Map.new()
  end

  @doc """
  The `"group"` block of a JSON export: the group's name, this tournament's
  label and its position, as information only. Nil for a tournament in no
  group. `PairingsEngine.TournamentImport` reads none of it - an imported
  copy arrives ungrouped, because joining a group on this machine is a
  decision about this machine's tournaments, which the file cannot make.
  """
  def export_block(tournament_id) do
    case membership(tournament_id) do
      nil ->
        nil

      %Member{} = m ->
        %{"name" => m.group.name, "label" => m.label, "position" => m.position}
    end
  end

  ## ---------- on the results site ----------

  @doc """
  The `group` block of `tournament`'s published snapshot, or nil when it is
  in no group or has no sibling that may be named. See the moduledoc, "On
  the results site", for what may be named and why.

      %{"id" => "9f2c...", "name" => "Spring Festival", "label" => "Open",
        "position" => 1,
        "siblings" => [%{"slug" => "...", "label" => "U20", "name" => "Spring U20"}]}

  `siblings` are the OTHER members, in the event's order; `position` is this
  tournament's place among itself and them, from 1.
  """
  @spec published_block(Tournament.t()) :: map() | nil
  def published_block(%Tournament{id: id} = tournament) do
    case membership(id) do
      nil -> nil
      %Member{group: group} -> block_for(tournament, group, group_rows(group.id))
    end
  end

  @doc """
  Whether a copy of `tournament` is public on the results site as far as
  this machine can vouch for: set to publish, a copy there, not binned, not
  in somebody else's custody.
  """
  @spec on_results_site?(Tournament.t()) :: boolean()
  def on_results_site?(%Tournament{} = t) do
    t.publish_to_openresults == true and is_nil(t.deleted_at) and is_nil(t.handed_off_at) and
      Publishing.on_site?(t)
  end

  @doc """
  The event's public id (`/e/<id>` on the results site) when `tournament`'s
  published page shows it as part of an event, else nil.
  """
  @spec published_event_id(Tournament.t()) :: String.t() | nil
  def published_event_id(%Tournament{} = tournament) do
    case on_results_site?(tournament) && published_block(tournament) do
      %{"id" => id} -> id
      _none -> nil
    end
  end

  @doc """
  Queues a publish for every member of `tournament_id`'s group - and the
  tournament itself - whose published `group` block would now read
  differently from the one it last sent. A no-op for a tournament in no
  group whose last snapshot carried no block either.

  Called from `Tournaments.broadcast_tournament_change/2`, so every write
  that could change what a sibling's page says (a rename, the publish
  switch, the listing, the bin) reaches it without knowing it exists.
  """
  @spec sync_published(integer()) :: :ok
  def sync_published(tournament_id) when is_integer(tournament_id) do
    case membership(tournament_id) do
      nil -> sync_tournaments([tournament_id])
      %Member{group_id: group_id} -> sync_tournaments(member_tournament_ids(group_id))
    end
  end

  def sync_published(_other), do: :ok

  @doc """
  Records that `tournament_id`'s snapshot just reached the results site with
  the `group` block it has now, then checks its siblings: a first publish is
  the moment a tournament becomes nameable in theirs.
  """
  @spec record_published(integer()) :: :ok
  def record_published(tournament_id) when is_integer(tournament_id) do
    case Repo.get(Tournament, tournament_id) do
      nil ->
        :ok

      %Tournament{} = tournament ->
        sent = fingerprint(published_block(tournament))

        if sent != tournament.openresults_group_sent do
          Repo.update_all(from(t in Tournament, where: t.id == ^tournament_id),
            set: [openresults_group_sent: sent]
          )
        end

        sync_published(tournament_id)
    end
  end

  @doc false
  # The tournaments among `ids` whose block is out of date on the site, each
  # queued. `Publishing.enqueue/1` ignores the ones that do not publish.
  def sync_tournaments(ids) when is_list(ids) do
    Repo.all(from t in Tournament, where: t.id in ^ids)
    |> Enum.each(fn %Tournament{} = t ->
      if t.publish_to_openresults and
           fingerprint(published_block(t)) != t.openresults_group_sent do
        Publishing.enqueue(t)
      end
    end)

    :ok
  end

  defp group_rows(group_id) do
    Repo.all(
      from m in Member,
        join: t in Tournament,
        on: t.id == m.tournament_id,
        where: m.group_id == ^group_id,
        order_by: [asc: m.position, asc: m.id],
        select: {m, t}
    )
  end

  defp block_for(%Tournament{id: id} = self, %Group{} = group, rows) do
    named = Enum.filter(rows, fn {_m, t} -> t.id == id or nameable?(t, self) end)

    case Enum.find_index(named, fn {_m, t} -> t.id == id end) do
      index when is_integer(index) and length(named) > 1 ->
        {own, _self} = Enum.at(named, index)

        %{
          "id" => ensure_public_slug(group),
          "name" => group.name,
          "label" => own.label || self.name,
          "position" => index + 1,
          "siblings" =>
            for {m, t} <- named, t.id != id do
              %{"slug" => t.public_slug, "label" => m.label || t.name, "name" => t.name}
            end
        }

      _alone_or_not_a_member ->
        nil
    end
  end

  # Whether `sibling` may be named in `self`'s snapshot.
  defp nameable?(%Tournament{} = sibling, %Tournament{} = self) do
    on_results_site?(sibling) and (listed?(sibling) or not listed?(self))
  end

  # The same reading the snapshot's own `listed` key uses.
  defp listed?(%Tournament{public_listed: listed}), do: listed != false

  # Every group has a slug from the migration or its changeset; this is for
  # a row something else wrote without one.
  defp ensure_public_slug(%Group{public_slug: slug}) when is_binary(slug) and slug != "", do: slug

  defp ensure_public_slug(%Group{id: id}) do
    slug = Group.generate_public_slug()

    Repo.update_all(from(g in Group, where: g.id == ^id and is_nil(g.public_slug)),
      set: [public_slug: slug]
    )

    Repo.one(from g in Group, where: g.id == ^id, select: g.public_slug)
  end

  defp fingerprint(nil), do: nil

  defp fingerprint(%{} = block) do
    :crypto.hash(:sha256, :erlang.term_to_binary(block)) |> Base.encode16(case: :lower)
  end

  ## ---------- writing ----------

  @doc """
  Starts a new group named `name` with `tournament` as its only member.
  """
  def create_group(%Scope{} = scope, %Tournament{} = tournament, name) do
    with {:ok, tournament} <- editable(scope, tournament),
         :ok <- ungrouped(tournament) do
      Repo.transaction(fn ->
        with {:ok, group} <- %Group{} |> Group.changeset(%{name: name}) |> Repo.insert(),
             {:ok, _member} <- insert_member(group, tournament, 0) do
          group
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> tap_ok(fn group ->
        Audit.log(tournament.id, scope, "group.created", %{name: group.name})
        broadcast(group.id)
        sync_tournaments([tournament.id])
      end)
    end
  end

  @doc """
  Adds `tournament` to the end of group `group_id`. The user must be allowed
  to edit the tournament AND a tournament already in the group.
  """
  def join_group(%Scope{} = scope, %Tournament{} = tournament, group_id) do
    with {:ok, tournament} <- editable(scope, tournament),
         :ok <- ungrouped(tournament),
         {:ok, group} <- reachable_group(scope, group_id),
         {:ok, _member} <- insert_member(group, tournament, next_position(group.id)) do
      Audit.log(tournament.id, scope, "group.joined", %{name: group.name})
      broadcast(group.id)
      sync_tournaments(member_tournament_ids(group.id))
      {:ok, group}
    end
  end

  @doc """
  Takes `tournament` out of its group. The last member out takes the group
  with it.
  """
  def leave_group(%Scope{} = scope, %Tournament{} = tournament) do
    with {:ok, tournament} <- editable(scope, tournament),
         %Member{} = member <- membership(tournament.id) || {:error, :not_grouped} do
      siblings = member_tournament_ids(member.group_id)

      Repo.transaction(fn ->
        Repo.delete!(member)
        prune_empty_groups()
      end)

      Audit.log(tournament.id, scope, "group.left", %{name: member.group.name})
      broadcast_to(siblings)
      # The leaver too: its page still says it is part of the event.
      sync_tournaments(siblings)
      {:ok, member.group}
    end
  end

  @doc "Renames the group `tournament` is in."
  def rename_group(%Scope{} = scope, %Tournament{} = tournament, name) do
    with {:ok, tournament} <- editable(scope, tournament),
         %Member{group: group} <- membership(tournament.id) || {:error, :not_grouped},
         {:ok, renamed} <- group |> Group.changeset(%{name: name}) |> Repo.update() do
      if renamed.name != group.name do
        Audit.log(tournament.id, scope, "group.renamed", %{from: group.name, to: renamed.name})
        broadcast(renamed.id)
        sync_tournaments(member_tournament_ids(renamed.id))
      end

      {:ok, renamed}
    end
  end

  @doc """
  Sets `tournament`'s short label in the switcher. Blank clears it, and the
  switcher falls back to the tournament's name.
  """
  def set_label(%Scope{} = scope, %Tournament{} = tournament, label) do
    with {:ok, tournament} <- editable(scope, tournament),
         %Member{} = member <- membership(tournament.id) || {:error, :not_grouped},
         {:ok, updated} <- member |> Member.label_changeset(%{label: label}) |> Repo.update() do
      if updated.label != member.label do
        Audit.log(tournament.id, scope, "group.label_set", %{
          name: member.group.name,
          from: member.label,
          to: updated.label
        })

        broadcast(member.group_id)
        sync_tournaments(member_tournament_ids(member.group_id))
      end

      {:ok, updated}
    end
  end

  @doc """
  Moves `member_id` (a tournament id in the same group as `tournament`) one
  place up or down. Places are counted among the members `scope`'s user can
  see: a sibling hidden from them is stepped over, never revealed by a move
  that seems to do nothing.
  """
  @spec move(Scope.t(), Tournament.t(), integer(), move()) :: {:ok, Group.t()} | {:error, term()}
  def move(%Scope{} = scope, %Tournament{} = tournament, member_id, direction)
      when direction in [:up, :down] do
    with {:ok, tournament} <- editable(scope, tournament),
         %Member{group: group} <- membership(tournament.id) || {:error, :not_grouped} do
      normalise_positions(group.id)
      visible = visible_members(scope, group.id, tournament.id) |> Enum.map(& &1.id)

      case Enum.find_index(visible, &(&1 == member_id)) do
        nil ->
          {:error, :not_found}

        index ->
          target = if direction == :up, do: index - 1, else: index + 1

          if target < 0 or target >= length(visible) do
            {:ok, group}
          else
            swap_positions(group.id, member_id, Enum.at(visible, target))
            Audit.log(tournament.id, scope, "group.reordered", %{name: group.name})
            broadcast(group.id)
            sync_tournaments(member_tournament_ids(group.id))
            {:ok, group}
          end
      end
    end
  end

  @doc """
  Deletes every group with no members left. Called after a tournament is
  purged; harmless to call any time.
  """
  def prune_empty_groups do
    {count, _} =
      Repo.delete_all(
        from g in Group, where: g.id not in subquery(from m in Member, select: m.group_id)
      )

    count
  end

  ## ---------- helpers ----------

  # "May edit" is "may open": a collaborator is an editor or nothing (see
  # `Tournaments.Collaborator`). Re-read rather than trusted, because the
  # struct a LiveView holds was authorized when the page mounted, not now.
  defp editable(scope, %Tournament{id: id}) do
    case Tournaments.get_authorized_tournament(scope, id) do
      nil ->
        {:error, :not_authorized}

      tournament ->
        case Tournaments.ensure_writable(tournament) do
          :ok -> {:ok, tournament}
          error -> error
        end
    end
  end

  defp ungrouped(%Tournament{id: id}) do
    if membership(id), do: {:error, :already_grouped}, else: :ok
  end

  # A group the user may edit: one with a member they may open. Anything
  # else is answered exactly like a group that does not exist.
  defp reachable_group(scope, group_id) do
    group_id = to_integer(group_id)

    reachable? =
      group_id &&
        Repo.exists?(
          from m in Member,
            where:
              m.group_id == ^group_id and
                m.tournament_id in subquery(Tournaments.authorized_tournament_ids(scope))
        )

    case reachable? && Repo.get(Group, group_id) do
      %Group{} = group -> {:ok, group}
      _ -> {:error, :not_found}
    end
  end

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_integer(_), do: nil

  defp insert_member(%Group{id: group_id}, %Tournament{id: tournament_id}, position) do
    %Member{group_id: group_id, tournament_id: tournament_id, position: position}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:tournament_id)
    |> Repo.insert()
    |> case do
      {:ok, member} -> {:ok, member}
      # Two tabs racing to group the same tournament: the index answers.
      {:error, %Ecto.Changeset{}} -> {:error, :already_grouped}
    end
  end

  defp next_position(group_id) do
    (Repo.one(from m in Member, where: m.group_id == ^group_id, select: max(m.position)) || -1) +
      1
  end

  defp normalise_positions(group_id) do
    Repo.all(
      from m in Member, where: m.group_id == ^group_id, order_by: [asc: m.position, asc: m.id]
    )
    |> Enum.with_index()
    |> Enum.each(fn
      {%Member{position: index}, index} -> :ok
      {member, index} -> member |> Ecto.Changeset.change(position: index) |> Repo.update!()
    end)
  end

  defp swap_positions(group_id, a_id, b_id) do
    a = Repo.get_by!(Member, group_id: group_id, tournament_id: a_id)
    b = Repo.get_by!(Member, group_id: group_id, tournament_id: b_id)

    Repo.transaction(fn ->
      a |> Ecto.Changeset.change(position: b.position) |> Repo.update!()
      b |> Ecto.Changeset.change(position: a.position) |> Repo.update!()
    end)
  end

  @doc "The other tournaments in `tournament_id`'s group; `[]` when it is in none."
  def sibling_ids(tournament_id) do
    case membership(tournament_id) do
      nil -> []
      %Member{group_id: group_id} -> member_tournament_ids(group_id) -- [tournament_id]
    end
  end

  defp member_tournament_ids(group_id) do
    Repo.all(from m in Member, where: m.group_id == ^group_id, select: m.tournament_id)
  end

  # The home lists of everybody who can see a member, so the grouping there
  # moves when it changes. Not the tournaments' own topics: every page of a
  # tournament reloads on those, and an unrelated settings page would flag
  # itself stale because a sibling was relabelled.
  defp broadcast(group_id), do: group_id |> member_tournament_ids() |> broadcast_to()

  defp broadcast_to(tournament_ids) do
    Repo.all(from t in Tournament, where: t.id in ^tournament_ids)
    |> Enum.each(&Tournaments.broadcast_tournament_list/1)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(error, _fun), do: error
end
