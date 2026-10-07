defmodule PairingsEngine.Repo.Migrations.AddOpenresultsTournamentKey do
  @moduledoc """
  A per-tournament key for the OpenResults publishing link.

  ## Why the ingest token was not enough

  There is one ingest token for a whole OpenResults server, and it answers
  exactly one question: *may this machine talk to this server*. It cannot
  answer the second one - *may this machine touch THIS tournament* - so any
  machine holding the token could overwrite any tournament published to that
  server, and nothing could take a tournament down at all. Turning the
  publish switch off stopped future publishes and left everything already
  sent public forever, and a published tournament carries player names,
  ratings, clubs and federations. The only remedy was SSH and SQLite.

  `openresults_key` is the answer to the second question: random, generated
  on the arbiter's machine at FIRST publish (not at creation - a tournament
  that never publishes never needs one, and a key that exists before it has
  been claimed is a secret with nothing behind it), sent with every publish,
  and required by the server for every later publish and for deletion.

  ## Why `openresults_claim` is a second column rather than the same one

  The key travels in a backup file on purpose: rebuilding a laptop from a
  backup has to recover the ability to manage what that laptop published,
  and a key that stayed behind would leave a published tournament permanently
  unmanageable.

  But an import must NOT adopt it. Two people importing the same file would
  both believe they own the tournament, both publish to the same slug, and
  either could delete the other's work. So an imported key lands HERE, in a
  dormant column nothing in the publishing path ever reads, and becomes a
  real key only when an arbiter explicitly takes the tournament over.

  Separate columns rather than a flag beside one column, because the two
  differ in what they authorise, not in how confident we are: `openresults_key`
  is authority this machine holds, `openresults_claim` is authority this
  machine has been *offered* and has not accepted. A single column plus a
  boolean would make forgetting to check the boolean a silent takeover.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # 32 random bytes, url-safe base64 (see
      # `PairingsEngine.Publishing.generate_key/0`). Nullable, and null is
      # the ordinary state: it is filled in at the first successful publish
      # and cleared again by a takedown.
      add :openresults_key, :string

      # `%{"key" => ..., "slug" => ..., "endpoint" => ...}` carried in from
      # an imported backup, or null. Never consulted when publishing - see
      # the moduledoc above.
      add :openresults_claim, :map
    end
  end
end
