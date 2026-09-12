defmodule PairingsEngine.Publishing.Installation do
  @moduledoc """
  This installation's own key for the results site, and the steps that get
  one: OpenResults' `docs/public-publishing.md`, "OpenPairings desktop".

  ## Why a desktop copy has a key of its own

  The operator token is the break-glass master key on the server - present it
  where a tournament key belongs and any tournament can be overwritten or
  deleted - so it can never ship inside a desktop release. Instead, a desktop
  copy with no token asks the server for an installation key, once, after an
  arbiter has agreed to it. That key may publish and delete the tournaments
  the server minted for this installation, and nothing else.

  Only in public mode (`PairingsEngine.Publishing.public_mode?/0`): a local
  run with no operator token. **Hosted OpenPairings never registers** - a
  server registering itself would put every one of its users' tournaments
  under one installation key, shared by strangers. `register/0` and `mint/1`
  refuse outside public mode on their own, so that property does not rest on
  every caller having checked first.

  ## The order, and what is sent when

  Nothing is sent until an arbiter turns publishing on for a tournament.
  Then:

    1. `server_info/0` - `GET /api/server`, for the consent dialog: who runs
       the site and where its terms are. The only request made before the
       arbiter has agreed to anything, and it carries no credential.
    2. The dialog. `give_consent/1` records the answer; declining records
       nothing and sends nothing.
    3. `register/0` - `POST /api/installations`, from the drain, only with
       consent on record for THIS server. The key is stored here.
    4. `mint/1` - `POST /api/tournaments`; the slug it returns becomes the
       tournament's `public_slug`, and only then is a link shown anywhere.
    5. The publish, exactly as in operator mode.

  A step that fails leaves the queue row where it was; the drain retries.

  ## Custody

  The key lives in the `meta` table under keys that all start with
  `meta_prefix/0`, and `PairingsEngine.Backup` deletes every one of them from
  the copy it writes - a backup is made to leave the machine, and a restore
  onto another machine must not make that machine this installation. No
  export, snapshot, hand-off file or TRF reads `meta` at all. The key is
  never rendered, never logged (logs get the installation id, which is not a
  credential), and never written to the audit trail.

  **Stricter than a tournament's `openresults_key`**, which is carried in
  backups on purpose so a rebuilt laptop can manage what it published. The
  equivalent for an installation is a transfer by the operator (the contract's
  `Moderation.transfer/3`), which is why the installation id - not the key -
  is shown to the arbiter.

  A key is also bound to the server that issued it (`openresults_
  installation_server`). Pointing this machine at another address makes the
  key disappear from `key/0` rather than be sent somewhere it was not meant
  for, and the consent recorded for one server is not consent for another.

  ## Never re-registered silently

  A revoked or unrecognised key stops publishing (`put_state/1` with a
  stopping code) and withdraws the consent that allowed registration, so the
  drain has nothing it may do. Only `start_over/1` - the arbiter's
  "Register again", after the dialog - discards the old key and allows a new
  one. Silent re-registration would turn every revocation into a one-second
  inconvenience.
  """

  import Ecto.Query

  alias PairingsEngine.{Meta, Publishing, Repo, Tournaments}
  alias PairingsEngine.Publishing.Failure
  alias PairingsEngine.Tournaments.Tournament

  require Logger

  @prefix "openresults_installation_"

  @key @prefix <> "key"
  @id @prefix <> "id"
  @server @prefix <> "server"
  @consent @prefix <> "consent"
  @state @prefix <> "state"

  @doc """
  The prefix every installation `meta` key starts with.

  `PairingsEngine.Backup` strips by this prefix rather than by a list, so a
  key added here later is excluded from backups without anyone having to
  remember to add it there.
  """
  def meta_prefix, do: @prefix

  @doc "Topic the installation's state changes are broadcast on."
  def topic, do: "publishing:installation"

  ## ---------- what is stored ----------

  @doc """
  The installation key, or nil - including when the key was issued by a
  different server than the one configured now.
  """
  @spec key() :: String.t() | nil
  def key do
    with key when is_binary(key) and key != "" <- Meta.get(@key),
         true <- Meta.get(@server) == server() do
      key
    else
      _ -> nil
    end
  end

  @doc "The installation id the server assigned, or nil. Not a credential."
  @spec id() :: String.t() | nil
  def id do
    if key(), do: Meta.get(@id)
  end

  @doc "Whether this installation holds a key for the configured server."
  def registered?, do: not is_nil(key())

  @doc """
  The consent on record for the configured server, or nil:
  `%{operator:, terms_url:, host:, at:}`.
  """
  @spec consent() :: map() | nil
  def consent do
    with raw when is_binary(raw) <- Meta.get(@consent),
         {:ok, %{"server" => server} = map} <- Jason.decode(raw),
         true <- server == server() do
      %{
        operator: map["operator"],
        terms_url: map["terms_url"],
        host: map["host"],
        at: map["at"]
      }
    else
      _ -> nil
    end
  end

  def consented?, do: not is_nil(consent())

  @doc """
  Records that an arbiter agreed to register this installation with the
  server `info` describes (`server_info/0`'s answer).
  """
  def give_consent(%{} = info) do
    Meta.put(
      @consent,
      Jason.encode!(%{
        "server" => server(),
        "operator" => info[:operator],
        "terms_url" => info[:terms_url],
        "host" => info[:host],
        "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    )

    broadcast()
    :ok
  end

  @doc "Forgets the consent, so nothing may register until it is given again."
  def withdraw_consent do
    Meta.delete(@consent)
    :ok
  end

  @doc """
  "Register again": the arbiter has seen the dialog again and agreed.

  Discards the old key and any remembered refusal, and records the new
  consent, so the drain's next pass registers afresh. The one path that may
  replace a key - see the moduledoc.
  """
  def start_over(%{} = info) do
    Enum.each([@key, @id, @server, @state], &Meta.delete/1)
    give_consent(info)
  end

  @doc """
  The last installation-wide refusal the server gave, as a
  `t:PairingsEngine.Publishing.rejection/0`, or nil.
  """
  @spec state() :: Publishing.rejection() | nil
  def state do
    with raw when is_binary(raw) <- Meta.get(@state),
         {:ok, %{"status" => status} = map} <- Jason.decode(raw),
         true <- is_integer(status) do
      code = if is_binary(map["code"]), do: map["code"]
      {:rejected, status, code, nil}
    else
      _ -> nil
    end
  end

  @doc """
  Remembers an installation-wide refusal. A revoked or unrecognised key also
  withdraws the consent - see "Never re-registered silently".
  """
  def put_state({:rejected, status, _code, _detail} = rejection) do
    code = Failure.effective_code(rejection)
    Meta.put(@state, Jason.encode!(%{"status" => status, "code" => code}))

    if code in ["installation_revoked", "unauthorized"], do: withdraw_consent()

    broadcast()
    :ok
  end

  @doc "Forgets the remembered refusal - after a success, or the arbiter's Try again."
  def clear_state do
    if Meta.get(@state) do
      Meta.delete(@state)
      broadcast()
    end

    :ok
  end

  @doc """
  Whether the drain may not send anything at all right now: no key and no
  consent to get one, or a refusal only the arbiter can act on.
  """
  def halted? do
    stopping_state?() or (not registered?() and not consented?())
  end

  @doc "Whether the remembered refusal is one the queue must stop for."
  def stopping_state? do
    case state() do
      nil -> false
      rejection -> Failure.from_rejection(rejection).stop == :installation
    end
  end

  @doc """
  Whether the server has said this key is no good at all - revoked, or not
  recognised. Only registering again answers either. Narrower than
  `stopping_state?/0`, which also stops for a blocked address: that one
  still lets a key read what it owns.
  """
  def key_dead? do
    case state() do
      nil -> false
      rejection -> Failure.effective_code(rejection) in ["installation_revoked", "unauthorized"]
    end
  end

  ## ---------- the requests ----------

  @doc """
  `GET /api/server`, parsed. Carries no credential: it is an open route, and
  it is the one request made before an arbiter has agreed to anything.

  `{:ok, %{operator:, terms_url:, host:, public_registration:,
  public_publishing:}}`, or `{:error, check_failure}`. An address that does
  not have the route at all - an OpenResults older than public publishing -
  is `{:unconfigured, :token_required}`, which is what it means for this
  machine: that server needs a token from its operator.
  """
  @spec server_info() :: {:ok, map()} | {:error, Publishing.check_failure()}
  def server_info do
    case Req.get(Publishing.request("/api/server", auth: nil)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case decode(body) do
          %{} = map -> {:ok, parse_server(map)}
          _ -> {:error, {:refused, {:rejected, 200, nil, Publishing.describe_body(body)}}}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, {:unconfigured, :token_required}}

      {:ok, %Req.Response{} = response} ->
        {:error, {:refused, Publishing.rejection_of(response)}}

      {:error, error} ->
        {:error, {:unreachable, Publishing.transport_reason_of(error)}}
    end
  end

  @doc """
  `POST /api/installations`, and store the key. Requires public mode and
  consent on record for the configured server; refuses without sending
  otherwise.
  """
  @spec register() :: {:ok, String.t()} | {:error, Failure.t()}
  def register do
    cond do
      not Publishing.public_mode?() ->
        {:error, Failure.new({:unconfigured, :no_token})}

      not consented?() ->
        {:error, Failure.new({:unconfigured, :consent_required})}

      true ->
        do_register()
    end
  end

  defp do_register do
    request =
      Publishing.request("/api/installations",
        auth: nil,
        json: %{"client" => "OpenPairings", "client_version" => client_version()}
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with %{"key" => key, "installation_id" => id} <- decode(body),
             true <- valid_key?(key),
             true <- is_binary(id) and id != "" and byte_size(id) <= 100 do
          Meta.put(@key, key)
          Meta.put(@id, id)
          Meta.put(@server, server())
          Meta.delete(@state)
          broadcast()
          # The id, never the key.
          Logger.info("OpenResults: this installation registered as #{id}")
          {:ok, id}
        else
          _ ->
            {:error,
             Failure.new({:refused, {:rejected, status, nil, "unexpected registration answer"}})}
        end

      # A server without the route, or with public publishing switched off
      # (the framework's own 404, `{"errors": {"detail": "Not Found"}}`, with
      # no `error` code), is what an older OpenResults or one with the gate
      # unset looks like: this machine needs a token from its operator.
      {:ok, %Req.Response{status: 404}} ->
        {:error, Failure.new({:unconfigured, :token_required})}

      {:ok, %Req.Response{} = response} ->
        {:error, Publishing.failure_of(response)}

      {:error, error} ->
        {:error, Failure.new({:unreachable, Publishing.transport_reason_of(error)})}
    end
  end

  @doc """
  `POST /api/tournaments`: the server mints this tournament's slug.

  The slug replaces `public_slug` and `public_slug_minted_at` is set in the
  same write. Broadcast straight on the tournament's topic rather than
  through `Tournaments.broadcast_tournament_change/2`, which would enqueue a
  publish from inside the publish that is minting - the pages need to hear
  that a link now exists, the queue does not.
  """
  @spec mint(Tournament.t()) :: {:ok, Tournament.t()} | {:error, Failure.t()}
  def mint(%Tournament{} = tournament) do
    cond do
      not Publishing.public_mode?() ->
        {:error, Failure.new({:unconfigured, :no_token})}

      is_nil(key()) ->
        {:error, Failure.new({:unconfigured, :consent_required})}

      true ->
        do_mint(tournament)
    end
  end

  defp do_mint(%Tournament{} = tournament) do
    request = Publishing.request("/api/tournaments", auth: {:bearer, key()}, json: %{})

    case Req.post(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with %{"slug" => slug} <- decode(body),
             true <- valid_slug?(slug),
             {:ok, minted} <- store_slug(tournament, slug) do
          {:ok, minted}
        else
          _ ->
            {:error, Failure.new({:refused, {:rejected, status, nil, "unexpected mint answer"}})}
        end

      # With public publishing gated off, this route answers the framework's
      # own unmatched-route 404 - no `error` code, on purpose (the contract,
      # "Error bodies", settled in the build). `GET /api/server` saying
      # `unavailable` normally catches that first; when it does not, it means
      # the same thing: this server does not offer public publishing.
      {:ok, %Req.Response{status: 404} = response} ->
        case Publishing.rejection_of(response) do
          {:rejected, 404, nil, _detail} ->
            {:error, Failure.new({:unconfigured, :token_required})}

          _coded ->
            {:error, Publishing.failure_of(response)}
        end

      {:ok, %Req.Response{} = response} ->
        {:error, Publishing.failure_of(response)}

      {:error, error} ->
        {:error, Failure.new({:unreachable, Publishing.transport_reason_of(error)})}
    end
  end

  defp store_slug(%Tournament{} = tournament, slug) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(t in Tournament, where: t.id == ^tournament.id),
      set: [public_slug: slug, public_slug_minted_at: now]
    )

    Phoenix.PubSub.broadcast(
      PairingsEngine.PubSub,
      Tournaments.tournament_topic(tournament.id),
      {:tournament_changed, tournament.id, :settings}
    )

    {:ok, %{tournament | public_slug: slug, public_slug_minted_at: now}}
  rescue
    # The unique index on `public_slug`. The server's slugs are unique on
    # the server; one colliding with a local placeholder is a 72-bit
    # coincidence, and the next attempt mints another.
    _error in [Ecto.ConstraintError, Exqlite.Error] -> :error
  end

  ## ---------- helpers ----------

  # The key the installation's records are bound to: the address this
  # machine sends to.
  defp server, do: Publishing.endpoint()

  defp broadcast do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, topic(), :installation_changed)
  end

  defp client_version do
    case Application.spec(:pairings_engine, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp decode(%{} = body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  defp decode(_), do: nil

  # 32 random bytes base64url is 43 characters; the prefix makes 48. Checked
  # loosely - the server owns the format - but a value that would not survive
  # an HTTP header is refused rather than stored.
  defp valid_key?(key) when is_binary(key),
    do: String.starts_with?(key, "orik_") and Regex.match?(~r/\A[A-Za-z0-9_\-]{20,200}\z/, key)

  defp valid_key?(_), do: false

  # It lands in a URL path and in every printed link. The contract says 12
  # base64url characters; anything that could not be one is refused.
  defp valid_slug?(slug) when is_binary(slug),
    do: Regex.match?(~r/\A[A-Za-z0-9_\-]{8,64}\z/, slug)

  defp valid_slug?(_), do: false

  defp parse_server(map) do
    %{
      operator: text(map["operator"]),
      terms_url: web_url(map["terms_url"]),
      host: host(),
      public_registration: one_of(map["public_registration"], ~w(open closed), "unavailable"),
      public_publishing: one_of(map["public_publishing"], ~w(active paused), "unavailable")
    }
  end

  defp host do
    case URI.parse(server() || "") do
      %URI{host: host} when is_binary(host) -> host
      _ -> server()
    end
  end

  # Shown in the consent dialog. HEEx escapes it; this only keeps a hostile
  # or broken server from filling the dialog.
  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 120)
    end
  end

  defp text(_), do: nil

  # Rendered as a link, so only http(s) - a `javascript:` URL from a server
  # would otherwise be one click from running in this app's origin.
  defp web_url(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) ->
        String.trim(value)

      _ ->
        nil
    end
  end

  defp web_url(_), do: nil

  defp one_of(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp one_of(_value, _allowed, fallback), do: fallback
end
