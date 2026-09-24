defmodule PairingsEngine.Badges do
  @moduledoc """
  Accreditation badges: A6 cards, front and back, printed two to an A4 sheet.
  See docs/badges.md.

  Everything is owned by one user and every function takes the caller's
  `%Scope{}` first. An event or badge that belongs to somebody else is
  indistinguishable from one that does not exist: the `!` getters raise
  `Ecto.NoResultsError` (a 404) and the others return nil.

  ## Linking to a tournament

  An event may stand alone or link to one tournament. Linking goes through
  `Tournaments.get_authorized_tournament/2` - the rule every tournament page
  uses, owner or accepted collaborator - and is checked again on every
  import, so losing access to a tournament also stops its data flowing in.

  ## Importing

  `import_players/2` and `import_officials/2` are explicit actions. Each
  badge remembers what it was made from (`source_player_id`, or
  `source_official_slot` for `chief`, `deputy1`, `deputy2`, `arbiterN`), and
  running an import again updates those badges in place instead of adding
  new ones. Manual badges are never touched.

  "Edited" is recorded rather than guessed: when the organiser saves a change
  to one of `Badge.imported_fields/0` on an imported badge, the field's name
  goes into `edited_fields`, and imports skip those fields for that badge from
  then on. `revert_to_source/2` forgets them again.

  Room access, the photo and the badge's existence are never taken away by an
  import: a player who has left the tournament keeps their badge until the
  organiser deletes it.
  """

  import Ecto.Query

  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Badges.{Badge, Defaults, Event, FideProfile, Image}
  alias PairingsEngine.{Fide, RateLimit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # Every column except the image blobs. Lists and LiveViews never need the
  # bytes - the pages load images by URL (`PairingsEngineWeb.BadgeController`)
  # - and a 400-photo event would otherwise sit in the LiveView's memory.
  @event_fields Event.__schema__(:fields) --
                  [:emblem_data, :logo_left_data, :logo_right_data, :badge_count]
  @badge_fields Badge.__schema__(:fields) -- [:photo_data]

  ## ---------- Events ----------

  @doc "The user's badge events, newest first, each with its `badge_count`."
  def list_events(%Scope{user: user}) do
    counts =
      from b in Badge,
        group_by: b.event_id,
        select: %{event_id: b.event_id, n: count(b.id)}

    Repo.all(
      from e in Event,
        left_join: c in subquery(counts),
        on: c.event_id == e.id,
        where: e.user_id == ^user.id,
        order_by: [desc: e.inserted_at, desc: e.id],
        preload: [:tournament],
        select: %{struct(e, ^@event_fields) | badge_count: coalesce(c.n, 0)}
    )
  end

  @doc "The user's event `id`. Raises `Ecto.NoResultsError` for anyone else's."
  def get_event!(%Scope{user: user}, id) do
    Repo.one!(event_query(user, id))
  end

  @doc "Like `get_event!/2`, nil instead of raising."
  def get_event(%Scope{user: user}, id) do
    Repo.one(event_query(user, id))
  rescue
    Ecto.Query.CastError -> nil
  end

  defp event_query(user, id) do
    from e in Event,
      where: e.id == ^id and e.user_id == ^user.id,
      preload: [:tournament],
      select: struct(e, ^@event_fields)
  end

  @doc """
  The user's badge event linked to `tournament_id`, or nil. When there are
  several, the most recently created.
  """
  def event_for_tournament(%Scope{user: user}, tournament_id) do
    Repo.one(
      from e in Event,
        where: e.user_id == ^user.id and e.tournament_id == ^tournament_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  @doc """
  Creates an event owned by `scope.user`. `attrs["tournament_id"]`, when
  present, links it (see `link_tournament/3`), and blank fields are filled in
  from that tournament: its name, city and year.
  """
  def create_event(%Scope{user: user} = scope, attrs) do
    attrs = stringify(attrs)

    with {:ok, tournament} <- authorized_link(scope, attrs["tournament_id"]) do
      attrs =
        attrs
        |> fill_from_tournament(tournament)
        |> Map.put_new("usage_conditions", Defaults.conditions())

      %Event{user_id: user.id, tournament_id: tournament && tournament.id}
      |> Event.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, event} -> {:ok, Repo.preload(event, :tournament)}
        error -> error
      end
    end
  end

  defp fill_from_tournament(attrs, nil), do: attrs

  defp fill_from_tournament(attrs, %Tournament{} = t) do
    year =
      case t.start_date do
        <<y::binary-size(4), _::binary>> -> y
        _ -> Integer.to_string(Date.utc_today().year)
      end

    attrs
    |> put_if_blank("name", t.name)
    |> put_if_blank("city", t.city)
    |> put_if_blank("organiser", t.organizer)
    |> put_if_blank("year", year)
  end

  defp put_if_blank(attrs, key, value) do
    if attrs[key] in [nil, ""], do: Map.put(attrs, key, value || ""), else: attrs
  end

  @doc "Updates the event's printed settings (not its owner, link or logos)."
  def update_event(%Scope{} = scope, %Event{} = event, attrs) do
    event = owned!(scope, event)
    old_count = event.room_count

    with {:ok, updated} <- event |> Event.changeset(stringify(attrs)) |> Repo.update() do
      if updated.room_count < old_count, do: trim_room_access(updated)
      {:ok, Repo.preload(updated, :tournament, force: true)}
    end
  end

  # Fewer rooms: a badge must not keep a tick for a room that is gone, or it
  # would reappear ticked when the count goes back up.
  defp trim_room_access(%Event{id: id, room_count: count}) do
    from(b in Badge, where: b.event_id == ^id, select: struct(b, ^@badge_fields))
    |> Repo.all()
    |> Enum.each(fn badge ->
      if Enum.any?(badge.room_access, &(&1 > count)) do
        badge |> Badge.room_access_changeset(badge.room_access, count) |> Repo.update!()
      end
    end)
  end

  @doc "A changeset for the event settings form."
  def change_event(%Event{} = event, attrs \\ %{}), do: Event.changeset(event, stringify(attrs))

  @doc "Deletes the event and all its badges."
  def delete_event(%Scope{} = scope, %Event{} = event) do
    scope |> owned!(event) |> Repo.delete()
  end

  @doc """
  Links the event to tournament `tournament_id` (nil or "" unlinks). Refused
  with `{:error, :unauthorized}` unless the user may access that tournament.
  Badges already imported keep their source; an import from the new
  tournament simply won't match them.
  """
  def link_tournament(%Scope{} = scope, %Event{} = event, tournament_id) do
    event = owned!(scope, event)

    with {:ok, tournament} <- authorized_link(scope, tournament_id) do
      event
      |> Ecto.Changeset.change(tournament_id: tournament && tournament.id)
      |> Repo.update()
      |> case do
        {:ok, event} -> {:ok, Repo.preload(event, :tournament, force: true)}
        error -> error
      end
    end
  end

  @doc "The tournaments the user may link an event to: the same list their Tournaments page shows."
  def linkable_tournaments(%Scope{} = scope) do
    scope |> Tournaments.list_tournaments() |> Enum.map(fn {t, _count, _owner?} -> t end)
  end

  defp authorized_link(_scope, id) when id in [nil, ""], do: {:ok, nil}

  defp authorized_link(scope, id) do
    case Tournaments.get_authorized_tournament(scope, id) do
      nil -> {:error, :unauthorized}
      tournament -> {:ok, tournament}
    end
  rescue
    # A non-numeric id from a crafted payload.
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  @doc """
  Stores an event logo. `slot` is `:emblem` (the header, both sides),
  `:logo_left` or `:logo_right` (the footer). Returns
  `{:error, :invalid_image | :too_large | :too_many_pixels}` for bytes that
  are not an acceptable image - see `PairingsEngine.Badges.Image`.
  """
  def set_logo(%Scope{} = scope, %Event{} = event, slot, binary)
      when slot in [:emblem, :logo_left, :logo_right] do
    event = owned!(scope, event)

    with {:ok, type} <- Image.validate(binary, :logo),
         {:ok, updated} <-
           event
           |> Ecto.Changeset.change([{:"#{slot}_data", binary}, {:"#{slot}_content_type", type}])
           |> Repo.update() do
      {:ok, Map.put(updated, :"#{slot}_data", nil)}
    end
  end

  @doc "Removes an event logo, so the badge falls back to its default."
  def clear_logo(%Scope{} = scope, %Event{} = event, slot)
      when slot in [:emblem, :logo_left, :logo_right] do
    # Forced: the struct in hand never carries the blob (see @event_fields),
    # so a plain change to nil would look like no change at all.
    scope
    |> owned!(event)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:"#{slot}_data", nil)
    |> Ecto.Changeset.force_change(:"#{slot}_content_type", nil)
    |> Repo.update()
  end

  @doc "The event's logo in `slot` as `{binary, content_type}`, or nil."
  def logo(%Event{} = event, slot) when slot in [:emblem, :logo_left, :logo_right] do
    data_field = :"#{slot}_data"
    type_field = :"#{slot}_content_type"

    case Repo.one(
           from e in Event,
             where: e.id == ^event.id,
             select: {field(e, ^data_field), field(e, ^type_field)}
         ) do
      {data, type} when is_binary(data) and is_binary(type) -> {data, type}
      _ -> nil
    end
  end

  @doc "Resets the usage conditions to the default text."
  def reset_conditions(%Scope{} = scope, %Event{} = event) do
    update_event(scope, event, %{"usage_conditions" => Defaults.conditions()})
  end

  ## ---------- Badges ----------

  @doc "The event's badges in the order they print: officials, then everyone else by creation."
  def list_badges(%Scope{} = scope, %Event{} = event) do
    event = owned!(scope, event)

    Repo.all(
      from b in Badge,
        where: b.event_id == ^event.id,
        order_by: [
          asc: fragment("CASE ? WHEN 'official' THEN 0 ELSE 1 END", b.source),
          asc: b.inserted_at,
          asc: b.id
        ],
        select: struct(b, ^@badge_fields)
    )
  end

  @doc "How many badges the event has."
  def count_badges(%Event{id: id}),
    do: Repo.aggregate(from(b in Badge, where: b.event_id == ^id), :count)

  @doc "The user's badge `id` in `event`. Raises `Ecto.NoResultsError` otherwise."
  def get_badge!(%Scope{} = scope, %Event{} = event, id) do
    event = owned!(scope, event)

    Repo.one!(
      from b in Badge,
        where: b.id == ^id and b.event_id == ^event.id,
        select: struct(b, ^@badge_fields)
    )
  end

  @doc "Like `get_badge!/3`, nil instead of raising (including for a malformed id)."
  def get_badge(%Scope{} = scope, %Event{} = event, id) do
    event = owned!(scope, event)

    Repo.one(
      from b in Badge,
        where: b.id == ^id and b.event_id == ^event.id,
        select: struct(b, ^@badge_fields)
    )
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Adds a badge by hand. With no role given it takes the event's "staff"
  role (or its first role), and it opens the first two rooms.
  """
  def create_badge(%Scope{} = scope, %Event{} = event, attrs \\ %{}) do
    event = owned!(scope, event)
    attrs = stringify(attrs)
    role = Event.role(event, attrs["role_key"] || "staff") || List.first(event.roles) || %{}

    attrs =
      attrs
      |> Map.put_new("role", role["label"] || "")
      |> Map.put_new("role_color", role["color"] || "#374151")

    %Badge{
      event_id: event.id,
      source: "manual",
      room_access: Enum.to_list(1..min(2, event.room_count))
    }
    |> Badge.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Saves the editor's fields. On an imported badge, every imported field whose
  value changes is added to `edited_fields`, so later imports leave it alone.
  """
  def update_badge(%Scope{} = scope, %Badge{} = badge, attrs) do
    badge = owned_badge!(scope, badge)
    changeset = Badge.changeset(badge, stringify(attrs))

    changeset =
      if Badge.imported?(badge) do
        edited =
          Badge.imported_fields()
          |> Enum.filter(&Map.has_key?(changeset.changes, &1))
          |> Enum.map(&Atom.to_string/1)

        Ecto.Changeset.put_change(
          changeset,
          :edited_fields,
          Enum.uniq(badge.edited_fields ++ edited)
        )
      else
        changeset
      end

    Repo.update(changeset)
  end

  @doc "A changeset for the badge editor form."
  def change_badge(%Badge{} = badge, attrs \\ %{}), do: Badge.changeset(badge, stringify(attrs))

  @doc "Gives the badge a role from the event's list, by key."
  def set_role(%Scope{} = scope, %Event{} = event, %Badge{} = badge, role_key) do
    case Event.role(event, role_key) do
      nil ->
        {:error, :unknown_role}

      role ->
        update_badge(scope, badge, %{"role" => role["label"], "role_color" => role["color"]})
    end
  end

  @doc "Sets the badge's room access to `rooms`, dropping any the event does not have."
  def set_room_access(%Scope{} = scope, %Event{} = event, %Badge{} = badge, rooms) do
    event = owned!(scope, event)
    badge = owned_badge!(scope, badge)

    badge
    |> Badge.room_access_changeset(rooms, event.room_count)
    |> Repo.update()
  end

  @doc "Ticks room `num` on or off."
  def toggle_room(%Scope{} = scope, %Event{} = event, %Badge{} = badge, num) do
    rooms =
      if num in badge.room_access,
        do: List.delete(badge.room_access, num),
        else: [num | badge.room_access]

    set_room_access(scope, event, badge, rooms)
  end

  @doc """
  Copies a badge as a new manual badge, photo included. The copy has no
  import source: it is somebody else's badge now.
  """
  def duplicate_badge(%Scope{} = scope, %Badge{} = badge) do
    badge = owned_badge!(scope, badge)
    {photo_data, _type} = photo(badge) || {nil, nil}

    %{badge | photo_data: photo_data}
    |> Map.take([
      :event_id,
      :first_name,
      :last_name,
      :title,
      :federation,
      :fide_id,
      :role,
      :role_color,
      :room_access,
      :photo_data,
      :photo_content_type,
      :photo_source
    ])
    |> then(&struct(Badge, &1))
    |> Map.put(:source, "manual")
    |> Repo.insert()
  end

  @doc "Deletes a badge."
  def delete_badge(%Scope{} = scope, %Badge{} = badge) do
    scope |> owned_badge!(badge) |> Repo.delete()
  end

  @doc """
  Stores a photo on the badge. `source` is `"upload"` or `"fide"`. Returns
  `{:error, :invalid_image | :too_large | :too_many_pixels}` when the bytes
  are not an acceptable photo.
  """
  def set_photo(%Scope{} = scope, %Badge{} = badge, binary, source \\ "upload")
      when source in ["upload", "fide"] do
    badge = owned_badge!(scope, badge)

    with {:ok, type} <- Image.validate(binary, :photo),
         {:ok, updated} <-
           badge
           |> Ecto.Changeset.change(
             photo_data: binary,
             photo_content_type: type,
             photo_source: source
           )
           |> Repo.update() do
      {:ok, %{updated | photo_data: nil}}
    end
  end

  @doc "Removes the badge's photo."
  def clear_photo(%Scope{} = scope, %Badge{} = badge) do
    scope
    |> owned_badge!(badge)
    |> Ecto.Changeset.change()
    |> forget_photo()
    |> Repo.update()
  end

  ## ---------- FIDE photo ----------

  # One press per badge per minute, whatever the outcome, and a per-user
  # allowance across badges - so neither a double click nor clicking down a
  # 400-row list turns into a burst at ratings.fide.com.
  @fide_cooldown_seconds 60

  @doc "Seconds a badge must wait between two FIDE fetches."
  def fide_cooldown_seconds, do: @fide_cooldown_seconds

  @doc """
  Checks whether "Fetch from FIDE" may run for `badge` now, and if so records
  the attempt (on the badge and in the user's `:fide_photo` allowance) before
  any request is made. Returns `{:ok, badge}` with the attempt recorded, or
  `{:error, :no_fide_id | :already_fetched | :cooldown | :rate_limited}`.
  """
  def claim_fide_fetch(%Scope{user: user} = scope, %Badge{} = badge) do
    badge = owned_badge!(scope, badge)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    key = Integer.to_string(user.id)

    cond do
      badge.fide_id in [nil, ""] ->
        {:error, :no_fide_id}

      badge.photo_source == "fide" and badge.photo_content_type != nil ->
        {:error, :already_fetched}

      badge.photo_fetched_at != nil and
          DateTime.diff(now, badge.photo_fetched_at) < @fide_cooldown_seconds ->
        {:error, :cooldown}

      not RateLimit.allow?(:fide_photo, key) ->
        {:error, :rate_limited}

      true ->
        RateLimit.record(:fide_photo, key)

        badge
        |> Ecto.Changeset.change(photo_fetched_at: now)
        |> Repo.update()
    end
  end

  @doc """
  Fetches the badge's photo from its FIDE profile and stores it (source
  `"fide"`), so the next print does not ask again. Name and federation are
  filled in only where the badge has none. Call `claim_fide_fetch/2` first;
  this function makes the request unconditionally.
  """
  def fetch_fide_photo(%Scope{} = scope, %Badge{} = badge) do
    badge = owned_badge!(scope, badge)

    with {:ok, profile} <- FideProfile.fetch_photo(badge.fide_id),
         {binary, _type} = profile.photo,
         {:ok, badge} <- set_photo(scope, badge, binary, "fide") do
      fill =
        %{
          "first_name" => profile.first_name,
          "last_name" => profile.last_name,
          "federation" => profile.federation
        }
        |> Enum.filter(fn {field, value} ->
          value not in [nil, ""] and Map.get(badge, String.to_existing_atom(field)) in [nil, ""]
        end)
        |> Map.new()

      if fill == %{}, do: {:ok, badge}, else: badge |> Badge.changeset(fill) |> Repo.update()
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, %Ecto.Changeset{}} -> {:error, :bad_photo}
    end
  end

  ## ---------- Import ----------

  @doc """
  Creates or updates one badge per player of the linked tournament.

  Maps the player's name ("Surname, Firstname"), title, federation and FIDE
  ID, with the event's `player` role. New badges open room 1. Returns
  `{:ok, %{created: n, updated: n}}`, or `{:error, :no_tournament}` /
  `{:error, :unauthorized}`.
  """
  def import_players(%Scope{} = scope, %Event{} = event) do
    event = owned!(scope, event)

    with {:ok, tournament} <- linked_tournament(scope, event) do
      role = Event.role(event, "player") || %{}

      rows =
        for player <- Tournaments.list_players(tournament.id) do
          {first, last} = FideProfile.split_name(player.name)

          {player.id,
           %{
             first_name: first,
             last_name: last,
             title: player.title || "",
             federation: player.federation || "",
             fide_id: id_string(player.fide_id),
             role: role["label"] || "PLAYER",
             role_color: role["color"] || "#1E5899"
           }}
        end

      upsert_imported(event, :source_player_id, "player", rows, [1])
    end
  end

  @doc """
  Creates or updates one badge per official of the linked tournament: the
  chief arbiter, the two ranked deputies and every further arbiter, from
  `tournament.chief_arbiter` and the `officials` map (docs/norms.md,
  "Officials"). Title and federation come from the local FIDE rating list
  when the official's FIDE ID is in it. New badges open every room.
  """
  def import_officials(%Scope{} = scope, %Event{} = event) do
    event = owned!(scope, event)

    with {:ok, tournament} <- linked_tournament(scope, event) do
      rows =
        for {slot, role_key, name, fide_id} <- officials(tournament) do
          role = Event.role(event, role_key) || %{}
          {first, last} = FideProfile.split_name(name)
          fide = if fide_id != "", do: Fide.get_player(fide_id)

          {slot,
           %{
             first_name: first,
             last_name: last,
             title: (fide && fide.title) || "",
             federation: (fide && fide.federation) || "",
             fide_id: fide_id,
             role: role["label"] || "ARBITER",
             role_color: role["color"] || "#1B7E39"
           }}
        end

      upsert_imported(
        event,
        :source_official_slot,
        "official",
        rows,
        Enum.to_list(1..event.room_count)
      )
    end
  end

  @doc """
  The officials a tournament names, as `{slot, role_key, name, fide_id}`.
  The same slots `PairingsEngine.TrfExport` reads: chief, deputy1..2, and
  arbiter1..extra_arbiters_count. A slot with no name is skipped.
  """
  def officials(%Tournament{} = t) do
    o = t.officials || %{}

    # A tournament imported from SWAR carries its deputy as the old free-text
    # field only; it fills the first deputy slot when the map names nobody.
    deputy1_name = if blank?(o["deputy1_name"]), do: t.deputy_arbiter, else: o["deputy1_name"]

    slots =
      [
        {"chief", "chief_arbiter", t.chief_arbiter, o["chief_arbiter_fide_id"]},
        {"deputy1", "deputy_chief_arbiter", deputy1_name, o["deputy1_fide_id"]},
        {"deputy2", "deputy_chief_arbiter", o["deputy2_name"], o["deputy2_fide_id"]}
      ] ++
        for n <- 1..extra_count(o["extra_arbiters_count"])//1,
            do: {"arbiter#{n}", "arbiter", o["arbiter#{n}_name"], o["arbiter#{n}_fide_id"]}

    for {slot, role, name, id} <- slots,
        not blank?(name),
        do: {slot, role, String.trim(name), id_string(id)}
  end

  defp extra_count(n) when is_integer(n) and n > 0, do: min(n, 50)

  defp extra_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} -> extra_count(int)
      :error -> 0
    end
  end

  defp extra_count(_), do: 0

  @doc """
  Forgets the hand edits on an imported badge and runs its import again, so
  it shows the tournament's data. A manual badge is returned unchanged.
  """
  def revert_to_source(%Scope{} = scope, %Badge{} = badge) do
    badge = owned_badge!(scope, badge)

    if Badge.imported?(badge) do
      badge = badge |> Ecto.Changeset.change(edited_fields: []) |> Repo.update!()
      event = get_event!(scope, badge.event_id)

      result =
        if badge.source == "player",
          do: import_players(scope, event),
          else: import_officials(scope, event)

      case result do
        {:ok, _} -> {:ok, Repo.reload!(badge)}
        error -> error
      end
    else
      {:ok, badge}
    end
  end

  defp linked_tournament(_scope, %Event{tournament_id: nil}), do: {:error, :no_tournament}

  defp linked_tournament(scope, %Event{tournament_id: id}) do
    case Tournaments.get_authorized_tournament(scope, id) do
      nil -> {:error, :unauthorized}
      tournament -> {:ok, tournament}
    end
  end

  defp upsert_imported(event, key_field, source, rows, default_rooms) do
    existing =
      from(b in Badge,
        where: b.event_id == ^event.id and not is_nil(field(b, ^key_field)),
        select: struct(b, ^@badge_fields)
      )
      |> Repo.all()
      |> Map.new(&{Map.fetch!(&1, key_field), &1})

    rooms = Enum.filter(default_rooms, &(&1 <= event.room_count))

    Repo.transaction(fn ->
      Enum.reduce(rows, %{created: 0, updated: 0, unchanged: 0}, fn {key, attrs}, acc ->
        case Map.get(existing, key) do
          nil ->
            %Badge{event_id: event.id, source: source, room_access: rooms}
            |> Map.put(key_field, key)
            |> Ecto.Changeset.change(attrs)
            |> Repo.insert!()

            Map.update!(acc, :created, &(&1 + 1))

          badge ->
            skip = MapSet.new(badge.edited_fields, &String.to_existing_atom/1)
            attrs = Map.reject(attrs, fn {field, _} -> MapSet.member?(skip, field) end)
            changeset = Ecto.Changeset.change(badge, attrs)
            changeset = drop_stale_fide_photo(changeset, badge)

            if changeset.changes == %{} do
              Map.update!(acc, :unchanged, &(&1 + 1))
            else
              Repo.update!(changeset)
              Map.update!(acc, :updated, &(&1 + 1))
            end
        end
      end)
    end)
  end

  # An official slot can change hands between imports ("deputy1" is somebody
  # else now). A photo fetched from FIDE for the old FIDE ID is the wrong face;
  # an uploaded photo is the organiser's call and stays.
  defp drop_stale_fide_photo(changeset, %Badge{photo_source: "fide"}) do
    if Map.has_key?(changeset.changes, :fide_id), do: forget_photo(changeset), else: changeset
  end

  defp drop_stale_fide_photo(changeset, _badge), do: changeset

  # Forced, because the badge struct in hand never carries the blob (see
  # @badge_fields): a plain change to nil would be dropped as "no change".
  defp forget_photo(changeset) do
    changeset
    |> Ecto.Changeset.force_change(:photo_data, nil)
    |> Ecto.Changeset.force_change(:photo_content_type, nil)
    |> Ecto.Changeset.force_change(:photo_source, nil)
  end

  ## ---------- Rendering ----------

  @doc """
  The flat map `PairingsEngineWeb.BadgeCard` draws. `urls` supplies image
  sources: a function `(kind, badge_or_slot) -> url | nil` so the studio can
  pass served URLs and the tests plain values.
  """
  def card(%Event{} = event, %Badge{} = badge, urls) do
    %{
      id: badge.id,
      first_name: badge.first_name,
      last_name: badge.last_name,
      title: badge.title,
      federation: badge.federation,
      fide_id: badge.fide_id,
      photo_url: if(badge.photo_content_type, do: urls.(:photo, badge)),
      role: badge.role,
      role_color: if(Event.valid_color?(badge.role_color), do: badge.role_color, else: "#374151"),
      room_access: badge.room_access || [],
      event_title: event.name,
      event_subtitle: event.subtitle,
      event_city: event.city,
      event_year: event.year,
      header_logo: if(logo_present?(event, :emblem), do: urls.(:logo, :emblem)),
      custom_logo_left: if(logo_present?(event, :logo_left), do: urls.(:logo, :logo_left)),
      custom_logo_right: if(logo_present?(event, :logo_right), do: urls.(:logo, :logo_right)),
      room_count: event.room_count,
      room_names: Map.new(1..event.room_count//1, &{&1, Event.room_name(event, &1)}),
      conditions_title: event.conditions_title,
      usage_conditions:
        Defaults.fill_conditions(event.usage_conditions, event.name, event.organiser)
    }
  end

  defp logo_present?(event, slot) do
    Map.get(event, :"#{slot}_content_type") != nil
  end

  @doc "The event's QR code as inline SVG, or \"\" when it has no QR text."
  def qr_svg(%Event{qr_url: url}) when url in [nil, ""], do: ""

  def qr_svg(%Event{qr_url: url}) do
    url
    |> String.trim()
    |> EQRCode.encode()
    |> EQRCode.svg(width: 90, background_color: "#ffffff", color: "#000000")
    |> String.replace(~r/<\?xml[^>]*\?>\s*/, "")
    |> String.replace(~r/width="[0-9.]+"/, ~s(width="100%"), global: false)
    |> String.replace(~r/height="[0-9.]+"/, ~s(height="100%"), global: false)
  rescue
    _ -> ""
  end

  ## ---------- Helpers ----------

  defp owned!(%Scope{user: %{id: uid}}, %Event{user_id: uid} = event), do: event

  defp owned!(%Scope{}, %Event{}), do: raise(Ecto.NoResultsError, queryable: Event)

  defp owned_badge!(%Scope{user: user}, %Badge{id: id}) do
    Repo.one!(
      from b in Badge,
        join: e in Event,
        on: e.id == b.event_id,
        where: b.id == ^id and e.user_id == ^user.id,
        select: struct(b, ^@badge_fields)
    )
  end

  @doc "The badge's photo as `{binary, content_type}`, or nil."
  def photo(%Badge{id: id}) do
    case Repo.one(
           from b in Badge, where: b.id == ^id, select: {b.photo_data, b.photo_content_type}
         ) do
      {data, type} when is_binary(data) and is_binary(type) -> {data, type}
      _ -> nil
    end
  end

  defp id_string(nil), do: ""
  defp id_string(id) when is_integer(id), do: Integer.to_string(id)
  defp id_string(id), do: id |> to_string() |> String.trim()

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
