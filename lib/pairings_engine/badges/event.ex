defmodule PairingsEngine.Badges.Event do
  @moduledoc """
  A badge event: what every badge of one event shares - the header, the back
  page's conditions, the numbered rooms, the role list and the logos - plus
  who owns it and, optionally, the tournament it imports from.

  `user_id`, `tournament_id` and the logo blobs are never cast. The owner is
  set when the event is created, the link goes through
  `PairingsEngine.Badges.link_tournament/3` (which checks the user may see
  that tournament), and the logos through `Badges.set_logo/4` (which checks
  the bytes are an image).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PairingsEngine.Badges.Defaults

  @logo_slots ~w(emblem logo_left logo_right)a

  schema "badge_events" do
    field :name, :string
    field :subtitle, :string, default: ""
    field :organiser, :string, default: ""
    field :city, :string, default: ""
    field :year, :string, default: ""
    field :qr_url, :string, default: ""
    field :conditions_title, :string, default: "USAGE CONDITIONS"
    field :usage_conditions, :string, default: ""
    field :room_count, :integer, default: 8
    field :room_names, :map, default: %{}
    field :roles, {:array, :map}, default: []

    field :emblem_data, :binary, redact: true
    field :emblem_content_type, :string
    field :logo_left_data, :binary, redact: true
    field :logo_left_content_type, :string
    field :logo_right_data, :binary, redact: true
    field :logo_right_content_type, :string

    field :badge_count, :integer, virtual: true, default: 0

    belongs_to :user, PairingsEngine.Accounts.User
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament

    timestamps(type: :utc_datetime)
  end

  @doc "The three logo slots: the header emblem and the two footer logos."
  def logo_slots, do: @logo_slots

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :name,
      :subtitle,
      :organiser,
      :city,
      :year,
      :qr_url,
      :conditions_title,
      :usage_conditions,
      :room_count
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> validate_length(:subtitle, max: 120)
    |> validate_length(:organiser, max: 120)
    |> validate_length(:city, max: 80)
    |> validate_length(:year, max: 20)
    |> validate_length(:qr_url, max: 500)
    |> validate_length(:conditions_title, max: 80)
    |> validate_length(:usage_conditions, max: 4000)
    |> validate_number(:room_count, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
    |> put_room_names(attrs)
    |> put_roles(attrs)
    |> put_defaults()
  end

  # Room names arrive as a map of number => name, from the settings form.
  # Only numbers 1..12 are kept, so a crafted payload cannot grow the map.
  defp put_room_names(changeset, attrs) do
    case attrs["room_names"] || attrs[:room_names] do
      names when is_map(names) ->
        current = get_field(changeset, :room_names) || %{}

        merged =
          Enum.reduce(names, current, fn {num, name}, acc ->
            case Integer.parse(to_string(num)) do
              {n, ""} when n in 1..12 ->
                Map.put(acc, Integer.to_string(n), String.slice(to_string(name), 0, 40))

              _ ->
                acc
            end
          end)

        put_change(changeset, :room_names, merged)

      _ ->
        changeset
    end
  end

  # Roles arrive as an index => %{"label", "color", "key"} map from the form
  # (or a plain list). Keys the event already has keep their identity; the four
  # import roles are always kept, even if a crafted payload leaves them out.
  defp put_roles(changeset, attrs) do
    case attrs["roles"] || attrs[:roles] do
      nil ->
        changeset

      roles ->
        rows =
          roles
          |> normalize_rows()
          |> Enum.map(&clean_role/1)
          |> Enum.reject(&(&1["label"] == ""))
          |> Enum.uniq_by(& &1["key"])
          |> Enum.take(40)

        rows = ensure_import_roles(rows, get_field(changeset, :roles) || [])

        if Enum.all?(rows, &valid_color?(&1["color"])) do
          put_change(changeset, :roles, rows)
        else
          add_error(changeset, :roles, "colours must be written as #RRGGBB")
        end
    end
  end

  defp normalize_rows(roles) when is_list(roles), do: roles

  defp normalize_rows(roles) when is_map(roles) do
    roles
    |> Enum.sort_by(fn {idx, _} ->
      case Integer.parse(to_string(idx)) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Enum.map(fn {_idx, row} -> row end)
  end

  defp clean_role(row) when is_map(row) do
    label = row |> fetch_str("label") |> String.trim() |> String.slice(0, 40)
    key = fetch_str(row, "key")

    key =
      if key =~ ~r/^[a-z0-9_-]{1,40}$/,
        do: key,
        else: "custom_#{System.unique_integer([:positive])}"

    %{"key" => key, "label" => label, "color" => row |> fetch_str("color") |> String.trim()}
  end

  defp clean_role(_), do: %{"key" => "", "label" => "", "color" => ""}

  @role_atoms %{"key" => :key, "label" => :label, "color" => :color}
  defp fetch_str(row, key), do: to_string(row[key] || row[@role_atoms[key]] || "")

  defp ensure_import_roles(rows, previous) do
    keys = MapSet.new(rows, & &1["key"])

    missing =
      for key <- Defaults.import_role_keys(),
          not MapSet.member?(keys, key),
          do:
            Enum.find(previous, &(&1["key"] == key)) ||
              Enum.find(Defaults.roles(), &(&1["key"] == key))

    rows ++ missing
  end

  defp put_defaults(changeset) do
    changeset
    |> then(fn cs ->
      if (get_field(cs, :roles) || []) == [],
        do: put_change(cs, :roles, Defaults.roles()),
        else: cs
    end)
    |> then(fn cs ->
      if (get_field(cs, :room_names) || %{}) == %{},
        do: put_change(cs, :room_names, Defaults.room_names()),
        else: cs
    end)
  end

  @doc "True for a `#RRGGBB` colour, the only form the badge and the colour picker share."
  def valid_color?(color) when is_binary(color), do: color =~ ~r/^#[0-9a-fA-F]{6}$/
  def valid_color?(_), do: false

  @doc "The role with `key`, or nil."
  def role(%__MODULE__{roles: roles}, key), do: Enum.find(roles || [], &(&1["key"] == key))

  @doc "The name printed for room `num`."
  def room_name(%__MODULE__{room_names: names}, num) do
    Map.get(names || %{}, Integer.to_string(num)) ||
      Map.get(Defaults.room_names(), Integer.to_string(num), "ROOM #{num}")
  end
end
