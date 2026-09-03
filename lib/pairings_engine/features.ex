defmodule PairingsEngine.Features do
  @moduledoc """
  Which optional national-federation features an account has switched on.

  `PairingsEngine.Federations.BEL` is a pack: the KBSB/FRBE member list and
  its sync, the lookups that read it, the bulk club refresh, and the SWAR
  importer/exporter. An arbiter in Ghent needs all of it. An arbiter in
  Dortmund needs none of it, and every button it adds is a button in their
  way. This module is the switchboard between those two.

  ## The rule this module exists to enforce

  **The pack owns entrances, never stored values.**

  Turning a feature off hides controls. It must NEVER change how an existing
  tournament scores, pairs, prints or exports. Everything already imported -
  players, clubs, national IDs, ratings, categories, the SWAR 3-2-1 scoring
  settings (`abs_value`, `abs_jusque`, `abs_nbfois`, `presence_value`,
  `presence_on_allocated_bye`, `extra_points`, `special_table`) - stays
  exactly as it is and scores exactly as it did. Those settings live in the
  core `Tournament` schema and are deliberately NOT gated: an arbiter who
  imported a Belgian tournament last month and switches the pack off today
  must still get the same standings out of it.

  So the only correct place for an `enabled?/2` check is a control's markup
  and the handler that control fires. Never inside a scoring, pairing,
  printing or export computation, and never on a changeset that decides what
  gets written.

  ## Five independent switches, on purpose

  `bel_player_lookup` and `bel_club_sync` READ the table `bel_ratings_sync`
  fills. With the sync off they search whatever was last downloaded -
  possibly nothing. That is a legitimate state ("I have last month's list,
  and I do not want this box pulling 40 MB over somebody else's API"), so
  the dependency is EXPLAINED in the settings page's copy and deliberately
  not enforced. Nothing here auto-enables one key from another.

  ## Per user, not per machine

  Two arbiters can share one installation and run tournaments in different
  countries. A machine-wide switch would make one of them wrong. The keys
  live in `users.features`, a `{:array, :string}` column - see the migration
  `AddUserFeatures` for why a column and not a joined table.

  ## Adding a pack

  A Dutch pack is data: append its entries to `catalogue/0` and its
  federation to `federations/0`. Nothing else in this module, on the
  settings page, or in the gates at the call sites needs to know the
  difference - they all iterate the catalogue.
  """

  # The catalogue carries the words an arbiter reads, so it has to be
  # translatable, and there is exactly one Gettext backend in this
  # application. `PairingsEngine.BrowserLauncher` and `PairingsEngine.Handoff`
  # already reach across for `PairingsEngineWeb.Endpoint`; a message catalogue
  # is a thinner dependency than a web server, and splitting the catalogue in
  # two so the labels could live on the settings page would put the list of
  # features in two places, which is the one thing this module exists to
  # prevent.
  use Gettext, backend: PairingsEngineWeb.Gettext

  import Ecto.Changeset

  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Repo

  @doc """
  The federations that ship a pack, in the order the settings page renders
  them.

  One card per federation rather than a picker: exactly one federation is
  packaged today, and a one-item dropdown is worse UI than a card that
  simply says so.
  """
  def federations do
    [
      %{
        code: "BEL",
        name: gettext("Belgium - KBSB / FRBE"),
        summary:
          gettext(
            "The Belgian federation's member list, the lookups that read it, and SWAR, the tournament program Belgian arbiters exchange files with."
          )
      }
    ]
  end

  @doc """
  Every optional feature, in the order the settings page renders it.

  A function rather than a module attribute so the labels resolve in the
  reader's locale on every call, instead of freezing whatever locale
  compiled the release.
  """
  def catalogue do
    [
      %{
        key: "bel_ratings_sync",
        federation: "BEL",
        label: gettext("National rating list sync"),
        description:
          gettext(
            "Downloads the Belgian member list (players, ratings, clubs) from the KBSB data platform and keeps a local copy. Adds its panel to the Connections page."
          )
      },
      %{
        key: "bel_player_lookup",
        federation: "BEL",
        label: gettext("KBSB player lookup"),
        description:
          gettext(
            "Adds the \"KBSB lookup\" button beside a player's details, and fills the form in as you type a National ID. Reads the local copy of the member list."
          )
      },
      %{
        key: "bel_club_sync",
        federation: "BEL",
        label: gettext("Bulk club update"),
        description:
          gettext(
            "Adds the \"Update clubs\" action on the players page: compares everyone against the local member list and proposes their current club before writing anything. Reads the local copy of the member list."
          )
      },
      %{
        key: "bel_swar_import",
        federation: "BEL",
        label: gettext("SWAR import"),
        description:
          gettext(
            "Adds \"Import SWAR file\": takes a .swar tournament in, with its players, rounds and results, and continues it here."
          )
      },
      %{
        key: "bel_swar_export",
        federation: "BEL",
        label: gettext("SWAR export"),
        description:
          gettext(
            "Adds the .swar download to a tournament's Export page, for handing a tournament back to SWAR."
          )
      }
    ]
  end

  @doc """
  The features belonging to one federation code, in catalogue order.
  """
  def catalogue_for(code) when is_binary(code) do
    Enum.filter(catalogue(), &(&1.federation == code))
  end

  @doc """
  Every key this version understands.
  """
  def keys, do: Enum.map(catalogue(), & &1.key)

  @doc """
  Whether this account has `key` switched on.

  Takes a `Scope`, a `User`, or `nil` - anonymous pages (the public arbiter
  tools) have no user, and no user has no features. Tolerant of a key this
  version does not know rather than raising: a check that crashes is a check
  that fails somewhere unpredictable, and "off" is the only safe direction
  to be wrong in.
  """
  def enabled?(nil, _key), do: false
  def enabled?(%Scope{user: user}, key), do: enabled?(user, key)
  def enabled?(%User{features: features}, key) when is_list(features), do: key in features
  def enabled?(%User{}, _key), do: false

  @doc """
  This account's enabled keys, filtered to the ones this version understands
  and in catalogue order.
  """
  def enabled(scope_or_user) do
    Enum.filter(keys(), &enabled?(scope_or_user, &1))
  end

  @doc """
  Replaces this account's enabled keys with `keys`.

  The settings page always submits the complete set, so this is a replace
  rather than an add/remove pair - there is no partial state for two tabs to
  race over.
  """
  def set_enabled(%User{} = user, keys) when is_list(keys) do
    user
    |> features_changeset(%{features: keys})
    |> Repo.update()
  end

  @doc """
  Changeset for `users.features`.

  Unknown keys are dropped rather than rejected. A key from a version that
  knew about a sixth feature would otherwise make this account's settings
  page unsaveable on a rollback, which is a worse outcome than quietly
  forgetting a switch nothing in this build can honour anyway.
  """
  def features_changeset(%User{} = user, attrs) do
    known = keys()

    user
    |> cast(attrs, [:features])
    |> update_change(:features, fn given ->
      given
      |> Enum.filter(&(is_binary(&1) and &1 in known))
      |> Enum.uniq()
      |> then(fn kept -> Enum.filter(known, &(&1 in kept)) end)
    end)
  end
end
