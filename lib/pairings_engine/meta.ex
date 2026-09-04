defmodule PairingsEngine.Meta do
  @moduledoc """
  The `meta` table: a plain machine-wide key/value store for the handful of
  settings that are properties of THIS INSTALLATION rather than of any one
  tournament - where it publishes to, what token it publishes with, the
  standing site notice, and (as of the SWAR results-page generator) the
  `Version` string a Belgian club stamps into every SWAR HTML export.

  ## Why this exists

  `PairingsEngine.Publishing` and `PairingsEngine.Notice` each grew their
  own identical `meta_get/1` / `meta_put/2` / `meta_delete/1` trio, reading
  and writing the same table with the same `INSERT ... ON CONFLICT` upsert.
  Two independent copies of a five-line SQL pattern is a coincidence; a
  third would have been a pattern nobody had actually decided to keep
  copying. So it is lifted here once, and both of those modules now call
  through it instead of carrying their own.

  This is deliberately a thin key/value primitive and not a settings
  registry with typed schemas or a picker of known keys - `Features`
  already owns "which keys exist and what they mean" for the one place
  that needed that (per-user feature flags, a different table). Every
  caller here still owns its OWN namespacing (`"openresults_endpoint"`,
  `"bel_swar_version"`, ...) and its own validation; this module only
  guarantees the read/write mechanics behave the same way everywhere.
  """

  alias PairingsEngine.Repo

  @doc "The stored value for `key`, or `nil` if it has never been set."
  def get(key) when is_binary(key) do
    case Repo.query!("SELECT value FROM meta WHERE key = ?", [key]).rows do
      [[value]] -> value
      _ -> nil
    end
  end

  @doc "Sets `key` to `value`, replacing whatever was there."
  def put(key, value) when is_binary(key) and is_binary(value) do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES (?, ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [key, value]
    )

    :ok
  end

  @doc "Removes `key` entirely, so a later `get/1` answers `nil` again."
  def delete(key) when is_binary(key) do
    Repo.query!("DELETE FROM meta WHERE key = ?", [key])
    :ok
  end
end
