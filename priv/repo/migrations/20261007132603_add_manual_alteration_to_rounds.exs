defmodule PairingsEngine.Repo.Migrations.AddManualAlterationToRounds do
  @moduledoc """
  A round's manual pairing alteration (VCL4THP Q65-Q69, the TEC Manual's
  MPA PIBE): `mpa_session` is the session in progress on the round (the
  boards it started from), nil when none is open; `mpa_pibe` is the line
  the round's MPA PIBE writes into the TRF as a `###` comment, nil when the
  round's boards are the pairing checker's own. Both nil for every existing
  round. See `PairingsEngine.ManualPairing`.
  """
  use Ecto.Migration

  def change do
    alter table(:rounds) do
      add :mpa_session, :map
      add :mpa_pibe, :string
    end
  end
end
