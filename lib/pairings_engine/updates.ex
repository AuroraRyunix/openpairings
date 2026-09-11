defmodule PairingsEngine.Updates do
  @moduledoc """
  Whether a newer OpenPairings release is out on GitHub - checked from
  desktop installs only, and never applied on its own.

  ## Notify, and the arbiter applies it. Never automatic.

  An update can change Ainalrami's (the pairing engine's) version, and a
  tournament locks the engine's *name*, not its version - see
  `PairingsEngine.Tournaments`. Applying one silently mid-event could change
  the pairing algorithm under a running tournament, so this module only ever
  answers "is there something newer", and the notice it feeds
  (`PairingsEngineWeb.UpdateNotice`) only ever links to the release page.
  Nothing here downloads or installs anything.

  ## Never on the hosted server

  `openpairings.zerotwo.cloud` runs this same application. It must be
  impossible for it to contact GitHub or show this notice, so eligibility is
  gated on `PairingsEngine.Authz.local_mode?/0` - the same signal every other
  desktop/server difference in this app already reads (no login, no SMTP
  required, the data directory, ...), checked here AND again by
  `PairingsEngine.Updates.Checker` AND again by
  `PairingsEngineWeb.UpdateNotice`. Three guards for one property sounds like
  one too many; it is deliberate, because the property this is protecting is
  "a hosted server never talks to a third party the arbiter did not choose",
  and that is worth more than the guards cost.

  ## Silent by design

  Offline, a timeout, and GitHub's 60-requests-per-hour unauthenticated rate
  limit are all the SAME answer here: nothing to show, logged at `:debug`,
  never surfaced as an error. An arbiter running this at a tournament with no
  wifi must never see a warning about a background check they never asked to
  watch.
  """

  alias PairingsEngine.Authz
  alias PairingsEngine.Build
  alias PairingsEngine.Meta
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Updates.{Checker, InstallKind}

  require Logger

  # The public repo the feed lives on - see docs/binaries.md's "Updates"
  # section. Releases only, not tags: a tag with no release attached (there
  # is no such thing here, but the API distinguishes them) would otherwise
  # need a second endpoint.
  @repo "AuroraRyunix/openpairings"
  @releases_url "https://api.github.com/repos/#{@repo}/releases"
  @user_agent "OpenPairings-UpdateCheck"

  @enabled_key "update_check_enabled"

  @doc """
  Whether the automatic check is switched on. Default **on** - see the
  moduledoc for why that is safe: it never applies anything, and it never
  runs anywhere but a desktop install regardless of this setting.
  """
  def enabled? do
    Meta.get(@enabled_key) != "0"
  end

  @doc "Flips the setting. An arbiter can always turn off a thing that contacts a third party."
  def put_enabled(enabled?) when is_boolean(enabled?) do
    Meta.put(@enabled_key, if(enabled?, do: "1", else: "0"))
    :ok
  end

  @doc """
  Whether this build may check at all - desktop only. See the moduledoc;
  this is the first of the three guards.
  """
  def eligible?, do: Authz.local_mode?()

  @doc """
  Asks GitHub for the newest non-draft, non-prerelease release and compares
  its tag to this build's own version, semantically (`Version.compare/2`).

  Returns:

    * `{:ok, %{version:, tag:, url:}}` - a newer release exists.
    * `:no_update` - reached GitHub; the newest usable release is this
      version or older.
    * `:error` - offline, a timeout, a non-2xx (rate-limited included), or a
      release list this build could not parse. Always silent at the call
      site - see the moduledoc. Logged at `:debug` here, with the reason.

  Does not check `eligible?/0` or `enabled?/0` - those gate *whether* to
  call this, not what it does when called, so a test (or a future manual
  "check now") can call it directly without faking desktop mode.
  """
  def check do
    with {:ok, release} <- fetch_latest_release(),
         {:ok, version} <- parse_tag(release["tag_name"]) do
      if newer_than_current?(version) do
        {:ok, %{version: to_string(version), tag: release["tag_name"], url: release["html_url"]}}
      else
        :no_update
      end
    end
  end

  @doc """
  What `PairingsEngineWeb.Components.Layouts.app/1` renders, or `nil`.

  Composes the checker's last known result (an `:ets` read - see
  `PairingsEngine.Updates.Checker.current/0`) with two things that are NOT
  cached because they can change between two checks six hours apart: which
  install this is (`PairingsEngine.Updates.InstallKind`) and whether a
  tournament currently has a round paired but unfinished
  (`PairingsEngine.Tournaments.running_tournament_names/0`). Called once per
  mount by `PairingsEngineWeb.UpdateNotice`, not on every render - see that
  module's moduledoc for why it must not be cheaper-but-wrong there.

  The second of the three desktop-only guards - see the moduledoc.
  """
  def notice_for_render do
    if eligible?() do
      case Checker.current() do
        nil ->
          nil

        %{version: version, url: url} ->
          %{
            version: version,
            url: url,
            install_kind: InstallKind.detect(),
            running: Tournaments.running_tournament_names()
          }
      end
    end
  end

  defp fetch_latest_release do
    request =
      [
        url: @releases_url,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"user-agent", @user_agent}
        ],
        # Short and not retried: this runs in the background on a timer, and
        # a slow or flaky GitHub should never be worth waiting on or trying
        # twice - the next scheduled check is a few hours away either way.
        receive_timeout: 10_000,
        retry: false
      ]
      |> Req.new()
      |> maybe_put_test_plug()

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: releases}} when is_list(releases) ->
        case Enum.find(releases, &usable?/1) do
          nil ->
            Logger.debug("Update check: no non-draft, non-prerelease release found on #{@repo}")
            :error

          release ->
            {:ok, release}
        end

      {:ok, %Req.Response{status: status}} ->
        # 403/429 is the unauthenticated rate limit (60/hour/IP) - the same
        # bucket as every other unauthenticated caller of this address, not
        # a limit raised for this app specifically. It is exactly as silent
        # as offline: there was nothing wrong to tell an arbiter about.
        Logger.debug("Update check: GitHub answered #{status} for #{@repo}")
        :error

      {:error, reason} ->
        Logger.debug("Update check: #{inspect(reason)}")
        :error
    end
  end

  defp usable?(release) do
    is_map(release) and is_binary(release["tag_name"]) and is_binary(release["html_url"]) and
      release["draft"] != true and release["prerelease"] != true
  end

  defp parse_tag("v" <> version), do: Version.parse(version)
  defp parse_tag(version) when is_binary(version), do: Version.parse(version)
  defp parse_tag(_), do: :error

  defp newer_than_current?(%Version{} = latest) do
    case Version.parse(Build.version()) do
      {:ok, current} -> Version.compare(latest, current) == :gt
      :error -> false
    end
  end

  # Same convention as `PairingsEngine.Publishing`/`PairingsEngine.Keycloak`:
  # in prod nothing is configured, so the request goes out over the network;
  # in tests `config/test.exs` points this at a `Req.Test` stub name.
  defp maybe_put_test_plug(request) do
    case Application.get_env(:pairings_engine, :updates_req_plug) do
      nil -> request
      name -> Req.merge(request, plug: {Req.Test, name})
    end
  end
end
