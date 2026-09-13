defmodule PairingsEngine.Publishing.TakedownJournal do
  @moduledoc """
  A record of every tournament this machine took off the results site, kept
  OUTSIDE the database, so that restoring a backup cannot undo a takedown.

  ## Why

  A takedown releases the tournament's claim on the results site and clears
  its key here. A backup taken before it still has the key, the address and
  `publish_to_openresults` - so after a restore, the next change to that
  tournament published it again and claimed the address afresh. The restore
  drill of 2026-09-13 measured it: 404 before, 200 after, and the arbiter was
  not told (`docs/restore-drill-2026-09-13.md`, finding 2). For a tournament
  withdrawn over personal data that is the whole of the harm the takedown
  existed to undo, and the only record of it was the database the restore
  replaced.

  ## The file

  Beside the database, in the same directory, named after it:
  `/var/lib/pairingsengine/pairings_engine-takedowns.jsonl` on the hosted box,
  `openpairings-takedowns.jsonl` in a desktop copy's data folder. Not inside
  the database, so a backup never contains it and a restore never touches it.
  `config :pairings_engine, :takedown_journal` is a path to put it elsewhere,
  or `false` for none (the test environment).

  Append-only, one JSON object per line, written after the results site has
  confirmed the removal and before the tournament's publishing state is
  cleared here:

      {"v":1,"at":"2026-09-13T10:02:11Z","kind":"taken_down","tournament_id":17,
       "slug":"Zk3n2bQm9xYp","key_sha256":"4f1c0e9a7b3d2c55"}

    * `kind` - `taken_down` (the Take down button), `moved` (moving to a new
      address, whose first step is a takedown) or `retracted` (deleting a
      tournament for good, which withdraws it first);
    * `slug` - the address that was withdrawn;
    * `key_sha256` - the first 16 hex digits of the SHA-256 of the tournament
      key the takedown retired. **Not the key**: a 64-bit fingerprint of a
      256-bit random value, useless for publishing or deleting anything, and
      the one fact that tells "the key the restore brought back" from "a key
      minted since".

  No secrets, no personal data: an id, an address that was public and is not
  any more, a fingerprint and a time. Never trimmed - it grows by a line per
  takedown, and a backup downloaded from Connections can be restored years
  later.

  ## Replay

  `replay/1` runs at every boot, after migrations and before anything can
  publish (`PairingsEngine.Application` starts it ahead of the drain). For
  every line, a tournament that still holds exactly the claim that line
  retired - the same id, the same address, a key with the same fingerprint -
  has the takedown's local half applied again: publishing off, key and the
  results site's notes about the address cleared, its queued publish dropped,
  and one `openresults.kept_withdrawn` audit row. A `moved` tournament is also
  given a new local address, so turning publishing back on can never revive
  the one that was moved away from.

  Idempotent without any bookkeeping: once applied, the tournament no longer
  holds that key, so the line never matches again. And a tournament its
  arbiter deliberately published again after the takedown carries a key
  minted since, so it is never touched - the fingerprint is what makes that
  true without a clock. Nothing is sent anywhere: the results site already
  removed the tournament when the takedown happened.

  What it cannot cover: a tournament first published after the backup (its
  key is not in the restored database at all), and a machine that lost the
  disk the journal was on. The deployment guide says what to do about both.
  """

  import Ecto.Query

  alias PairingsEngine.{Audit, Repo}
  alias PairingsEngine.Publishing.QueueEntry
  alias PairingsEngine.Tournaments.Tournament

  require Logger

  @kinds ~w(taken_down moved retracted)

  @doc """
  Where the journal is, or `nil` when it is switched off.
  """
  @spec path() :: Path.t() | nil
  def path do
    case Application.get_env(:pairings_engine, :takedown_journal) do
      false ->
        nil

      configured when is_binary(configured) and configured != "" ->
        configured

      _beside_the_database ->
        database = Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]
        name = database |> Path.basename() |> Path.rootname()
        Path.join(Path.dirname(database), name <> "-takedowns.jsonl")
    end
  end

  @doc """
  Appends one line for `tournament`, whose claim on the results site was just
  withdrawn. `kind` is `:taken_down`, `:moved` or `:retracted`.

  Never raises and never refuses: by the time this runs the results site has
  removed the tournament, and failing the takedown here would only leave this
  machine believing it is still published. A write that fails is logged as
  an error, because it is the one line that would have kept the takedown in
  force after a restore.
  """
  @spec record(Tournament.t(), atom(), keyword()) :: :ok | {:error, term()}
  def record(%Tournament{} = tournament, kind, opts \\ []) when is_atom(kind) do
    kind = Atom.to_string(kind)
    at = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with file when is_binary(file) <- Keyword.get_lazy(opts, :path, &path/0),
         true <- kind in @kinds and is_binary(tournament.openresults_key) do
      line =
        Jason.encode!(%{
          "v" => 1,
          "at" => at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "kind" => kind,
          "tournament_id" => tournament.id,
          "slug" => tournament.public_slug,
          "key_sha256" => fingerprint(tournament.openresults_key)
        })

      case append(file, line) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error(
            "Could not write the takedown journal (#{file}): #{inspect(reason)}. Tournament " <>
              "#{tournament.id} is off the results site, but a restore of an older backup " <>
              "would not keep it off."
          )

          error
      end
    else
      _off_or_nothing_to_record -> :ok
    end
  end

  # Opened, written, synced and closed per line: a takedown is rare, and the
  # line is worth nothing if a crash a second later loses it.
  defp append(file, line) do
    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, device} <- :file.open(file, [:append, :raw, :binary]) do
      try do
        with :ok <- :file.write(device, line <> "\n") do
          :file.sync(device)
        end
      after
        :file.close(device)
      end
    end
  end

  @doc "The first 16 hex digits of SHA-256 of `key` - a fingerprint, not the key."
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(key) when is_binary(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc """
  Every well-formed line, oldest first. A line that does not parse - the torn
  last line of a write a crash interrupted - is skipped and logged, never
  fatal: one bad line must not stop the others from being replayed.
  """
  @spec entries(Path.t() | nil) :: [map()]
  def entries(nil), do: []

  def entries(file) do
    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok,
             %{"kind" => kind, "tournament_id" => id, "slug" => slug, "key_sha256" => print} =
                 entry}
            when kind in @kinds and is_integer(id) and is_binary(slug) and is_binary(print) ->
              [entry]

            _ ->
              Logger.warning("Skipped an unreadable line in the takedown journal #{file}")
              []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error("Could not read the takedown journal #{file}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Applies every journalled takedown a restored database undid. Returns how
  many tournaments were changed. See the moduledoc.
  """
  @spec replay(keyword()) :: non_neg_integer()
  def replay(opts \\ []) do
    opts |> Keyword.get_lazy(:path, &path/0) |> entries() |> Enum.count(&reapply/1)
  end

  defp reapply(%{"tournament_id" => id, "slug" => slug, "key_sha256" => print} = entry) do
    case Repo.get(Tournament, id) do
      %Tournament{public_slug: ^slug, openresults_key: key} = tournament when is_binary(key) ->
        if fingerprint(key) == print, do: keep_withdrawn(tournament, entry), else: false

      _gone_moved_or_published_again ->
        false
    end
  end

  defp keep_withdrawn(%Tournament{} = tournament, entry) do
    moved? = entry["kind"] == "moved"

    changes =
      [
        publish_to_openresults: false,
        openresults_key: nil,
        public_slug_minted_at: nil,
        public_slug_server: nil,
        public_slug_published_at: nil
      ] ++ if(moved?, do: [public_slug: Tournament.generate_public_slug()], else: [])

    {:ok, _} =
      Repo.transaction(fn ->
        {1, _} =
          Repo.update_all(from(t in Tournament, where: t.id == ^tournament.id), set: changes)

        Repo.delete_all(from q in QueueEntry, where: q.tournament_id == ^tournament.id)
      end)

    Audit.log(tournament.id, nil, "openresults.kept_withdrawn", %{
      slug: entry["slug"],
      kind: entry["kind"],
      taken_down_at: entry["at"]
    })

    Logger.warning(
      "Tournament #{tournament.id} was withdrawn from the results site (#{entry["kind"]}, " <>
        "#{entry["at"]}) after the backup this database was restored from; publishing it is " <>
        "switched off again."
    )

    true
  end

  @doc false
  # A supervision-tree entry that replays and is gone: `start_link/1` does the
  # work and answers `:ignore`, so everything after it in the children list -
  # the publish drain above all - starts only once it has finished.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc false
  def start_link(_opts) do
    case replay() do
      0 -> :ok
      n -> Logger.warning("Kept #{n} tournament(s) off the results site after a restore.")
    end

    :ignore
  end
end
