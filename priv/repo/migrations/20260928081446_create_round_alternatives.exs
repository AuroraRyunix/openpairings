defmodule PairingsEngine.Repo.Migrations.CreateRoundAlternatives do
  @moduledoc """
  `round_alternatives`: the "why him and not me" answers of a round - why
  this player floated, why the bye went where it went - each worked out
  when somebody first opens it on the explanation page and kept here, so it
  is worked out once per round (`PairingsEngine.Pairing.open_alternative/4`).

  Keyed by the round, the `job` fingerprint of the account it belongs to
  (`rounds.explanation["job"]`) and the question. SQLite hands a freed row
  id out again, so a round unpaired and paired afresh can have the old
  one's id; its fingerprint differs, so an answer about the old pairing is
  never read as one about the new. The rows go with their round.

  A table of its own rather than more keys on `rounds.explanation`: every
  write to `rounds` changes the tournament's `data_version` (the standings
  cache key), and an arbiter opening a question changes no standing.
  """
  use Ecto.Migration

  def change do
    create table(:round_alternatives) do
      add :round_id, references(:rounds, on_delete: :delete_all), null: false
      add :job, :string, null: false
      add :question, :string, null: false
      add :result, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:round_alternatives, [:round_id, :job, :question])
  end
end
