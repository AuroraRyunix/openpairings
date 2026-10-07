defmodule PairingsEngine.Repo.Migrations.AddSwarPublishTimestamps do
  @moduledoc """
  Two per-tournament timestamps for the SWAR results-page upload
  (`PairingsEngine.Federations.BEL.SwarUpload`) - when this machine last PUT
  the generated HTML to the federation's intake (step 1), and when the
  federation's own index step (step 2) last actually confirmed it.

  ## Why two, not one

  The upload is a two-step protocol and the steps can succeed independently:
  a PUT that lands followed by a GET that times out leaves a file staged on
  the federation's server but not indexed - normal (see that module's
  moduledoc), and the fix is to run the index step again, NOT to re-upload.

  `swar_uploaded_at` moves on every successful step 1; `swar_published_at`
  moves only when the step 2 that follows it also succeeds. Comparing the
  two - rather than a single timestamp plus a boolean - is how
  `SwarUpload.staged_but_not_indexed?/1` tells "fully live" from "staged,
  and only the second step still needs a retry" without a flag that could
  fall out of sync with either date. The same reasoning is why
  `tournaments.openresults_key` and `openresults_claim` are two columns
  rather than one column and a flag.

  Neither is cast by `Tournament.changeset/2` - both are written only by
  `SwarUpload` itself, the same as `openresults_key` above.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :swar_uploaded_at, :utc_datetime
      add :swar_published_at, :utc_datetime
    end
  end
end
