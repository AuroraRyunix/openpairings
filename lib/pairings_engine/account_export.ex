defmodule PairingsEngine.AccountExport do
  @moduledoc """
  "Download everything" from the account page: one zip holding the
  account's own settings and a backup of every tournament it can open.

  ## Nothing new about the files

  Each tournament is `PairingsEngine.TournamentExport.export_tournament/1`,
  byte for byte the file Settings → Export already hands out one at a time,
  and each one can be put back through Tournaments → "Import backup" on this
  or any other installation. A zip of those is a convenience, not a second
  backup format that could drift from the first.

  ## What is in it

    * `account.json` - the address, display name, role, when the account
      was made, the federation features, the stored preferences and the
      "New tournament" defaults. The things on the account page, so the zip
      answers "what does this service hold about me" and not only "give me
      my tournaments".
    * `tournaments/` - every tournament on the Tournaments list, owned or
      shared.
    * `archived/` - the archived ones, owned or shared.
    * `recycle-bin/` - the account's own tournaments waiting in the recycle
      bin. Still the account's data until they are purged.

  File names start with the tournament's id, so two events with the same
  name cannot overwrite each other inside the zip.

  ## The publishing key rides along

  A tournament published on the results site carries its publishing key in
  its backup, exactly as the single download does (see
  `TournamentExport.openresults_block/1`) - that key is what lets a restored
  copy keep updating the same page. The account page says so beside the
  button.
  """

  alias PairingsEngine.Accounts.{Scope, TournamentDefaults, User}
  alias PairingsEngine.{Tournaments, TournamentExport}

  @doc """
  Builds the zip for `scope`'s user. Returns `{filename, binary}`.
  """
  def build(%Scope{user: %User{} = user} = scope) do
    active = scope |> Tournaments.list_tournaments() |> Enum.map(fn {t, _n, _own?} -> t end)

    archived =
      scope |> Tournaments.list_archived_tournaments() |> Enum.map(fn {t, _own?} -> t end)

    binned = Tournaments.list_deleted_tournaments(scope)

    entries =
      [{"account.json", Jason.encode_to_iodata!(account_map(user), pretty: true)}] ++
        tournament_entries("tournaments", active) ++
        tournament_entries("archived", archived) ++
        tournament_entries("recycle-bin", binned)

    {:ok, {_name, zip}} =
      :zip.create(
        ~c"openpairings-account.zip",
        Enum.map(entries, fn {name, data} ->
          {String.to_charlist(name), IO.iodata_to_binary(data)}
        end),
        [:memory]
      )

    {"openpairings-account-#{Date.to_iso8601(Date.utc_today())}.zip", zip}
  end

  @doc false
  def account_map(%User{} = user) do
    %{
      "format" => "openpairings-account",
      "version" => 1,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "account" => %{
        "email" => user.email,
        "display_name" => user.display_name,
        "role" => user.role,
        "signs_in_with_02cloud" => User.sso?(user),
        "created_at" => user.inserted_at && DateTime.to_iso8601(user.inserted_at),
        "confirmed_at" => user.confirmed_at && DateTime.to_iso8601(user.confirmed_at)
      },
      "features" => user.features || [],
      "preferences" => %{
        "language" => user.locale,
        "theme" => user.theme,
        "accent" => user.accent
      },
      "tournament_defaults" => defaults_map(user.tournament_defaults)
    }
  end

  defp defaults_map(nil), do: %{}

  defp defaults_map(%TournamentDefaults{} = defaults) do
    TournamentDefaults.fields()
    |> Map.new(&{Atom.to_string(&1), Map.get(defaults, &1)})
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp tournament_entries(folder, tournaments) do
    Enum.map(tournaments, fn tournament ->
      {"#{folder}/#{tournament.id}-#{slug(tournament.name)}.json",
       Jason.encode_to_iodata!(TournamentExport.export_tournament(tournament))}
    end)
  end

  # ASCII only - a zip entry name is bytes to half the unzip tools out
  # there - and never empty, because the id in front already makes it unique.
  defp slug(name) do
    case (name || "")
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "-")
         |> String.trim("-")
         |> String.slice(0, 60) do
      "" -> "tournament"
      slug -> slug
    end
  end
end
