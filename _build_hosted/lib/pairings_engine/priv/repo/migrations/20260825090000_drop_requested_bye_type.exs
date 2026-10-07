defmodule PairingsEngine.Repo.Migrations.DropRequestedByeType do
  @moduledoc """
  Removes `requested_bye_type`, added earlier the same day and never
  deployed.

  It existed to answer "what is a bye the player asked for worth?" as a
  separate question from "what is an absence worth?". That turned out to be
  a distinction with nothing behind it: you only ever know a player is
  absent BEFORE the round is paired because they told you, and an
  unannounced no-show is paired and forfeits on the board. So every absence
  the pairing sees is an announced one, and there is exactly one question -
  answered by `abs_value` with its two caps, which was already here.

  Nothing to preserve on the way out: the column had one release-less day
  and every tournament still holds its default.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      remove :requested_bye_type
    end
  end

  def down do
    alter table(:tournaments) do
      add :requested_bye_type, :string, null: false, default: "zero"
    end
  end
end
