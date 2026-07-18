defmodule PairingsEngine.Repo.Migrations.AddPublicSlugToTournaments do
  use Ecto.Migration

  import Ecto.Query

  # Adds an unguessable public token for the read-only "share this link, no
  # login needed" pages (PublicPairingsLive / PublicStandingsLive — see
  # docs/public-pages.md). Deliberately NOT the tournament's numeric `id`:
  # ids are small sequential integers so they're trivially enumerable, and
  # a public link must not let a visitor page through everyone else's
  # tournaments. `public_slug` is generated with `:crypto.strong_rand_bytes/1`
  # (see PairingsEngine.Tournaments.Tournament.changeset/2), which is not
  # guessable in practice.
  def change do
    alter table(:tournaments) do
      add :public_slug, :string
    end

    # Backfill every existing row so "every tournament always has one" holds
    # even for tournaments created before this migration.
    flush()
    backfill_public_slugs()

    create unique_index(:tournaments, [:public_slug])
  end

  defp backfill_public_slugs do
    repo = repo()

    ids = repo.all(from(t in "tournaments", select: t.id))

    Enum.each(ids, fn id ->
      slug = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
      repo.update_all(from(t in "tournaments", where: t.id == ^id), set: [public_slug: slug])
    end)
  end
end
