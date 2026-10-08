defmodule PairingsEngine.Tournaments.PairingRule do
  @moduledoc """
  A pairing restriction stated as a RULE rather than a list of pairs:
  players of the same club do not meet, players of the same federation do
  not meet, or these N players never meet each other. FIDE's own example
  (C.05 5.2): "players from the same federation shall, if possible, not meet
  in the last rounds" - a federation rule, soft, in the last N rounds.

  A rule is never stored as pairs. `PairingsEngine.Exclusions` expands it
  from the players as they are when a round is paired, so a late entrant, a
  corrected club or a player who changed federation is covered without
  anybody touching the rule - which is also why that expansion is not a
  "change" in FIDE mode: the rule was announced, its members were not.

    * `kind` - `"club"`, `"federation"` or `"group"`.
    * `names` - club / federation only: the clubs or federations it is
      limited to (trimmed, matched case-insensitively). Empty is every one.
    * `player_ids` - group only: the players who never meet each other.
    * `soft` - a wish ("if possible") rather than a rule: handed to the
      Ainalrami engine as soft groups, never written as `XXP`/`260`.
    * `window` - the rounds it holds for: `"all"`, `"first"` (rounds
      1..`window_rounds`), `"last"` (the last `window_rounds` rounds of the
      tournament as it is set up when the round is paired) or `"range"`
      (`window_from`..`window_to`).
    * `from_round` - set when the rule was added after rounds were paired:
      the first round it can apply to, so the TRF does not claim it for
      rounds paired without it (as `ForbiddenPairing.from_round`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(club federation group)
  @windows ~w(all first last range)

  schema "pairing_rules" do
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    field :kind, :string
    field :soft, :boolean, default: false
    field :names, {:array, :string}, default: []
    field :player_ids, {:array, :integer}, default: []
    field :window, :string, default: "all"
    field :window_rounds, :integer
    field :window_from, :integer
    field :window_to, :integer
    field :from_round, :integer

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def windows, do: @windows

  @doc """
  The arbiter-editable fields. `tournament_id` and `from_round` are set by
  `PairingsEngine.Tournaments`, never cast.
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :kind,
      :soft,
      :names,
      :player_ids,
      :window,
      :window_rounds,
      :window_from,
      :window_to
    ])
    |> normalize_names()
    |> validate_required([:kind, :window])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:window, @windows)
    |> validate_window()
    |> validate_group()
    |> clear_unused()
  end

  # "Chess Club, , chess club " is one club, as the old exclusion list read.
  defp normalize_names(changeset) do
    case get_change(changeset, :names) do
      nil ->
        changeset

      names ->
        names =
          names
          |> Enum.flat_map(&String.split(to_string(&1), ","))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq_by(&String.downcase/1)

        put_change(changeset, :names, names)
    end
  end

  defp validate_window(changeset) do
    case get_field(changeset, :window) do
      w when w in ["first", "last"] ->
        changeset
        |> validate_required([:window_rounds], message: "say how many rounds")
        |> validate_number(:window_rounds, greater_than: 0)

      "range" ->
        changeset
        |> validate_required([:window_from, :window_to], message: "say which rounds")
        |> validate_number(:window_from, greater_than: 0)
        |> validate_number(:window_to, greater_than: 0)
        |> validate_range_order()

      _ ->
        changeset
    end
  end

  defp validate_range_order(changeset) do
    from = get_field(changeset, :window_from)
    to = get_field(changeset, :window_to)

    if is_integer(from) and is_integer(to) and from > to,
      do: add_error(changeset, :window_to, "must not be before the first round"),
      else: changeset
  end

  defp validate_group(changeset) do
    if get_field(changeset, :kind) == "group" do
      ids = changeset |> get_field(:player_ids) |> Kernel.||([]) |> Enum.uniq()

      changeset
      |> put_change(:player_ids, ids)
      |> then(fn cs ->
        if length(ids) < 2,
          do: add_error(cs, :player_ids, "choose at least two players"),
          else: cs
      end)
    else
      changeset
    end
  end

  # A field the kind or window does not read is cleared, so two rules that
  # mean the same thing are stored the same way.
  defp clear_unused(changeset) do
    kind = get_field(changeset, :kind)
    window = get_field(changeset, :window)

    changeset
    |> then(&if(kind == "group", do: put_change(&1, :names, []), else: &1))
    |> then(&if(kind != "group", do: put_change(&1, :player_ids, []), else: &1))
    |> then(&if(window in ["first", "last"], do: &1, else: put_change(&1, :window_rounds, nil)))
    |> then(
      &if(window == "range",
        do: &1,
        else: &1 |> put_change(:window_from, nil) |> put_change(:window_to, nil)
      )
    )
  end
end
