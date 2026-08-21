defmodule PairingsEngine.Repo.Migrations.AddRoundExplanation do
  use Ecto.Migration

  # What the engine actually decided, captured at pairing time.
  #
  # The rationale page has always RECONSTRUCTED its brackets from the round's
  # input and output, because JaVaFo hands back nothing but pairs. Ainalrami
  # can report its own bracket composition, floats and criterion scores, so
  # for those rounds we store ground truth instead of an inference.
  #
  # Nullable, and every round that already exists stays null: the page falls
  # back to the reconstruction, exactly as before.
  def change do
    alter table(:rounds) do
      add :explanation, :map
    end
  end
end
