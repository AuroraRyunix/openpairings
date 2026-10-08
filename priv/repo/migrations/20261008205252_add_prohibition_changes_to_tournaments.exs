defmodule PairingsEngine.Repo.Migrations.AddProhibitionChangesToTournaments do
  @moduledoc """
  Pairing rules, and the record of prohibitions changed once the event was
  under way.

    * `pairing_rules` - "players of the same club do not meet", "same
      federation, if possible, in the last two rounds", "these five never
      meet each other" (`PairingsEngine.Tournaments.PairingRule`). Expanded
      into pairs from the players as they are at pairing time, so a late
      entrant or a corrected club is covered without anybody touching the
      rule.
    * `tournaments.prohibition_changes` - every prohibition added, changed
      or removed after round 1 was paired (VCL4THP Q195/Q196), written as
      `### Prohibition` lines in TRF26 copies. Empty for every existing
      tournament: what was done before this column existed was done under
      the old rules and is not re-judged.

  The four columns the club and federation rules and the soft club wish
  lived in (`club_exclusion`, `club_exclusion_list`, `fed_exclusion`,
  `fed_exclusion_list`, `soft_club_rounds`) are copied into rules here and
  left in place, unread, so a rollback finds them as they were.
  """
  use Ecto.Migration

  def up do
    create table(:pairing_rules) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      # club | federation | group
      add :kind, :string, null: false
      add :soft, :boolean, null: false, default: false
      # club / federation: only these names (empty = every one)
      add :names, {:array, :string}, null: false, default: []
      # group: the players who never meet each other
      add :player_ids, {:array, :integer}, null: false, default: []
      # all | first | last | range
      add :window, :string, null: false, default: "all"
      add :window_rounds, :integer
      add :window_from, :integer
      add :window_to, :integer
      # The first round the rule applies to when it was added after rounds
      # were paired, as `forbidden_pairings.from_round`.
      add :from_round, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:pairing_rules, [:tournament_id])

    alter table(:tournaments) do
      add :prohibition_changes, {:array, :map}, null: false, default: []
    end

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{rows: rows} =
      repo().query!("""
      SELECT id, club_exclusion, club_exclusion_list, fed_exclusion, fed_exclusion_list,
             soft_club_rounds
      FROM tournaments
      """)

    for [id, club, club_list, fed, fed_list, soft_rounds] <- rows,
        rule <- legacy_rules(club, club_list, fed, fed_list, soft_rounds) do
      {kind, soft, names, window, window_rounds} = rule

      repo().query!(
        """
        INSERT INTO pairing_rules
          (tournament_id, kind, soft, names, player_ids, window, window_rounds,
           inserted_at, updated_at)
        VALUES (?, ?, ?, ?, '[]', ?, ?, ?, ?)
        """,
        [
          id,
          kind,
          if(soft, do: 1, else: 0),
          Jason.encode!(names),
          window,
          window_rounds,
          now,
          now
        ]
      )
    end
  end

  def down do
    alter table(:tournaments) do
      remove :prohibition_changes
    end

    drop table(:pairing_rules)
  end

  # The rules the old settings meant, exactly: "all" and "listed" on either
  # axis a hard rule for every round; the soft club wish one for rounds
  # 1..N over every club, skipped where the club rule was already hard for
  # everyone (where it never did anything).
  defp legacy_rules(club, club_list, fed, fed_list, soft_rounds) do
    hard =
      [{"club", club, club_list}, {"federation", fed, fed_list}]
      |> Enum.flat_map(fn
        {kind, "all", _list} -> [{kind, false, [], "all", nil}]
        {kind, "listed", list} -> listed(kind, list)
        _ -> []
      end)

    soft =
      if is_integer(soft_rounds) and soft_rounds > 0 and club != "all",
        do: [{"club", true, [], "first", soft_rounds}],
        else: []

    hard ++ soft
  end

  defp listed(kind, list) do
    case (list || "")
         |> String.split(",")
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> []
      names -> [{kind, false, names, "all", nil}]
    end
  end
end
