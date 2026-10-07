defmodule PairingsEngine.Repo.Migrations.DropPublicPagesEnabled do
  @moduledoc """
  Retires `public_pages_enabled` now that this app serves no public pages.

  The field answered "may anyone holding the link read this tournament *here*".
  With `/p/:slug/...` gone there is no "here" to read it from, so the question
  has no answer to give and the column would only be a second, silent switch
  that no longer switches anything.

  ## The data migration is the point

  Dropping the column without the UPDATE would take every currently-shared
  tournament dark: its arbiter had said "this is public", and the only thing
  changing is *where* the public reads it. Carrying that intent across to
  `publish_to_openresults` is what makes this an upgrade rather than an
  outage, and it is the honest reading of what the arbiter already asked for.

  On a machine with no results site configured this changes nothing anyone can
  observe - `Publishing.enqueue/1` needs an endpoint, so the switch flips but
  no copy leaves. The tournament simply has no public page, which is the new
  truth for every unpublished tournament regardless.
  """
  use Ecto.Migration

  def up do
    execute "UPDATE tournaments SET publish_to_openresults = 1 WHERE public_pages_enabled = 1"

    alter table(:tournaments) do
      remove :public_pages_enabled
    end
  end

  def down do
    alter table(:tournaments) do
      add :public_pages_enabled, :boolean, default: false, null: false
    end

    # The inverse of the UPDATE above, and lossy in the same way: a tournament
    # that published without ever having local pages on comes back with them
    # on. Rolling back to a build that serves those pages is the only reason
    # to run this, and in that build "published" and "publicly readable" were
    # the same intent anyway.
    execute "UPDATE tournaments SET public_pages_enabled = 1 WHERE publish_to_openresults = 1"
  end
end
