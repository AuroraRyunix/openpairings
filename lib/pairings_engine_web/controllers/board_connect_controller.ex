defmodule PairingsEngineWeb.BoardConnectController do
  @moduledoc """
  Connecting a hall box to an account without copying a secret by hand
  (`PairingsEngine.BoardLink.connect/2`, docs/board-link-api.md,
  "Connecting an account").

    1. The box sends the arbiter's browser to `GET /boards/connect` with
       `return_to` (where to come back to), `state` (the box's own, handed
       back untouched) and `box` (what it calls itself).
    2. Signed in - the router's `:require_authenticated_user`, so a person
       who is not is sent to sign in and brought back here - they see which
       box asks and, in large letters, the host it will be sent to.
    3. "Allow" makes an account code and a two-minute grant, and sends the
       browser to `return_to?grant=...&state=...`. "Cancel" sends it to
       `return_to?error=denied&state=...`.
    4. The box trades the grant for the code: `POST /api/boards/v1/grant`
       (`grant/2`), which needs no session - the grant is the credential,
       good once.

  `return_to` is only ever http or https, without a user name, a password
  or a fragment. Anything else is refused on a page of its own here, and
  the browser is sent nowhere: an address that is not a box's is not
  somewhere to send a grant.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{BoardLink, RateLimit}
  alias PairingsEngineWeb.{BoardLinkAddress, ClientIp, CSP}

  @max_return_to 2000
  @max_state 512

  ## ---------- the consent page ----------

  def new(conn, params) do
    scope = conn.assigns.current_scope

    case read_request(params) do
      {:ok, request} ->
        conn
        |> CSP.allow_form_action(request.origin)
        |> render(:new,
          page_title: gettext("Connect a board box"),
          request: request,
          codes: length(BoardLink.list_account_links(scope)),
          max: BoardLink.max_links()
        )

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  def create(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, request} <- read_request(params) do
      if params["decision"] == "allow" do
        case BoardLink.connect(scope, label: request.box) do
          {:ok, _link, grant} ->
            redirect(conn, external: back(request, %{"grant" => grant}))

          {:error, reason} ->
            redirect(conn, external: back(request, %{"error" => to_string(reason)}))
        end
      else
        redirect(conn, external: back(request, %{"error" => "denied"}))
      end
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, reason) do
    conn
    |> put_status(400)
    |> render(:invalid, page_title: gettext("Connect a board box"), reason: reason)
  end

  @doc false
  # What the box asked for, checked: `{:ok, %{return_to, origin, host,
  # state, box}}` or `{:error, :return_to}`.
  def read_request(params) do
    return_to = params["return_to"]
    state = params["state"]

    with true <- is_binary(return_to) and byte_size(return_to) <= @max_return_to,
         %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri
         when scheme in ["http", "https"] <- URI.parse(return_to),
         true <- is_binary(host) and host =~ ~r/\A[A-Za-z0-9.\-]+\z|\A\[[0-9A-Fa-f:.]+\]\z/,
         true <- is_nil(state) or (is_binary(state) and byte_size(state) <= @max_state) do
      port = if uri.port == URI.default_port(scheme), do: nil, else: uri.port
      host_port = if port, do: "#{host}:#{port}", else: host

      {:ok,
       %{
         return_to: return_to,
         origin: "#{scheme}://#{host_port}",
         host: host_port,
         secure?: scheme == "https",
         state: state || "",
         box: clip(params["box"])
       }}
    else
      _invalid -> {:error, :return_to}
    end
  end

  defp clip(value) when is_binary(value) do
    case value |> String.replace(~r/[\x00-\x1F\x7F]/u, " ") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, 80)
    end
  end

  defp clip(_other), do: nil

  # `return_to` with what goes back added to its query, and the box's
  # `state` always.
  defp back(%{return_to: return_to, state: state}, extra) do
    uri = URI.parse(return_to)
    query = URI.decode_query(uri.query || "") |> Map.merge(extra) |> Map.put("state", state)
    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  ## ---------- POST /api/boards/v1/grant ----------

  @doc """
  The box trades a grant for its code: `{"code": "<root>#oplu_..."}`, once.
  Every refusal is the same `401 invalid_grant`, counted against the
  address like a refused connect code, with the same budget.
  """
  def grant(conn, params) do
    address = ClientIp.get(conn)

    if RateLimit.allow?(:board_link_auth, address) do
      case BoardLink.redeem_grant(params["grant"]) do
        {:ok, secret} ->
          json(conn, %{"code" => BoardLinkAddress.connect_code(secret), "kind" => "account"})

        :error ->
          RateLimit.record(:board_link_auth, address)

          conn
          |> put_status(401)
          |> json(%{
            "error" => "invalid_grant",
            "detail" => "no grant, or one that was used, ran out or was never issued"
          })
      end
    else
      conn
      |> put_resp_header("retry-after", "600")
      |> put_status(429)
      |> json(%{
        "error" => "rate_limited",
        "detail" => "too many refused grants from this address"
      })
    end
  end
end
