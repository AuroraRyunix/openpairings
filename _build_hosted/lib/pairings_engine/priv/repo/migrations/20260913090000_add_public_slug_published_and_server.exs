defmodule PairingsEngine.Repo.Migrations.AddPublicSlugPublishedAndServer do
  @moduledoc """
  Two more facts about a public-mode slug, settled with OpenResults'
  `docs/public-publishing.md` ("OpenPairings desktop", settled in the
  desktop build).

  `tournaments.public_slug_published_at` - when the first publish under the
  minted slug succeeded. The server answers a minted slug with no snapshot
  exactly as it answers an unknown one, so a link shown after the mint but
  before a publish lands would be dead; the link waits for this instead. It
  also tells a released slug (minted, never published, freed after 30 days,
  now `not_owner`) from a tournament that really is owned elsewhere: only
  the first is minted again, silently.

  `tournaments.public_slug_server` - the address the slug was minted on. A
  slug belongs to the server that created it, so pointing this machine at
  another one makes that tournament unminted there.

  A migration of its own rather than an edit to
  `20260912130000_add_public_publishing.exs`: that one has already run on
  every database that has this branch, and an edited migration does not run
  again.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :public_slug_published_at, :utc_datetime
      add :public_slug_server, :text
    end
  end
end
