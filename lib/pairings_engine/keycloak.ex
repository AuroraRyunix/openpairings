defmodule PairingsEngine.Keycloak do
  @moduledoc """
  Minimal OIDC Authorization Code client for 02cloud SSO (`auth.zerotwo.cloud`,
  Keycloak realm `zerotwo`) — see the `auth framework` repo for the identity
  provider itself; this module is the only thing on this side of that
  integration.

  Deliberately not a general-purpose OIDC library: there is exactly one
  identity provider in play, so the three endpoints are derived directly from
  the realm issuer using Keycloak's stable, documented URL scheme rather than
  fetched from `.well-known/openid-configuration` — the same approach
  `auth framework`'s own `launcher.js` takes for its client-side OIDC flow.

  This is a confidential client (`openpairings`, server-side, holds a secret)
  using plain Authorization Code + `state` for CSRF protection. PKCE is
  deliberately omitted: it defends a *public* client's authorization code in
  transit on the user's own device, which doesn't apply here — the code is
  exchanged server-to-server over a direct HTTPS POST authenticated with the
  client secret, which is the actual security boundary for a confidential
  client.
  """

  @token_endpoint_path "/protocol/openid-connect/token"
  @authorize_endpoint_path "/protocol/openid-connect/auth"
  @userinfo_endpoint_path "/protocol/openid-connect/userinfo"

  @doc """
  Builds the URL to redirect the browser to for login, embedding the given
  CSRF `state` (the caller is responsible for generating and later verifying
  it against what comes back on the callback).
  """
  def authorize_url(state) when is_binary(state) do
    config = config!()

    query =
      URI.encode_query(%{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        response_type: "code",
        scope: "openid email profile",
        state: state
      })

    config.issuer <> @authorize_endpoint_path <> "?" <> query
  end

  @doc """
  Exchanges an authorization `code` for tokens at the token endpoint.

  Returns `{:ok, %{"access_token" => ..., "id_token" => ...}}` or
  `{:error, reason}`. `reason` is either a `Req.TransportError`-style struct
  (network failure) or `{:unexpected_status, status, body}` (Keycloak
  rejected the request — expired/reused code, wrong redirect_uri, etc.).
  """
  def exchange_code(code) when is_binary(code) do
    config = config!()

    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: config.redirect_uri,
      client_id: config.client_id,
      client_secret: config.client_secret
    }

    request(:post, config.issuer <> @token_endpoint_path, form: body)
  end

  @doc """
  Fetches the authenticated user's claims from the userinfo endpoint using an
  access token obtained from `exchange_code/1`.

  Returns `{:ok, %{"sub" => ..., "email" => ..., ...}}` or `{:error, reason}`.
  """
  def fetch_userinfo(access_token) when is_binary(access_token) do
    config = config!()

    request(:get, config.issuer <> @userinfo_endpoint_path, auth: {:bearer, access_token})
  end

  @doc false
  # Exposed so tests can point requests at a `Req.Test` stub plug instead of
  # the network; not meant to be called from application code.
  def request(method, url, opts) do
    req_opts =
      opts
      |> Keyword.merge(method: method, url: url)
      |> maybe_put_test_plug()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # In prod, no `:keycloak_req_plug` is configured, so `opts` passes through
  # unchanged and Req performs a real HTTP request. In tests, `config/test.exs`
  # points it at a `Req.Test` stub name — see `Req.Test`'s moduledoc for the
  # `plug: {Req.Test, name}` convention this follows.
  defp maybe_put_test_plug(opts) do
    case Application.get_env(:pairings_engine, :keycloak_req_plug) do
      nil -> opts
      name -> Keyword.put_new(opts, :plug, {Req.Test, name})
    end
  end

  @doc """
  Whether SSO is configured (a client id/secret are set). The login page and
  the `/auth/keycloak` routes use this to fail gracefully with a flash
  instead of a crash if it's ever unset (e.g. a fresh dev checkout).
  """
  def configured? do
    case Application.get_env(:pairings_engine, :keycloak, []) do
      [] -> false
      opts -> !!(opts[:client_id] && opts[:client_secret])
    end
  end

  defp config! do
    opts = Application.fetch_env!(:pairings_engine, :keycloak)

    %{
      issuer: Keyword.fetch!(opts, :issuer),
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      redirect_uri: Keyword.fetch!(opts, :redirect_uri)
    }
  end
end
