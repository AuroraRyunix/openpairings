defmodule PairingsEngine.PublicServerStub do
  @moduledoc """
  A stand-in for an OpenResults server with public publishing switched on,
  answering exactly the wire in its `docs/public-publishing.md`.

  Every request is reported to the test process as
  `{:public_request, method, path, headers, body}` before it is answered, so
  a test can assert what was sent - including that nothing was. Any answer
  can be replaced per `{method, path}` (or `{method, :any}`) with a function
  of the conn.
  """

  import Plug.Conn

  @key "orik_" <> String.duplicate("K3y", 14) <> "x"
  @installation "in_7Hq2rT0bXk"

  def key, do: @key
  def installation_id, do: @installation

  def server_body(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "OpenResults",
        "version" => "0.14.0",
        "operator" => "ZeroTwo",
        "terms_url" => "https://openresults.cloud/terms",
        "public_registration" => "open",
        "public_publishing" => "active"
      },
      overrides
    )
  end

  @doc """
  What the stub answers `method path` with when nothing overrides it, as
  `{status, decoded body}` - for the contract test.
  """
  def default_answer(method, path, body \\ "") do
    conn =
      Plug.Test.conn(method, path, body)
      |> assign(:raw_body, body)
      |> default()

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Installs the stub. `answers` maps `{method, path}` to a function of the
  conn that sends the answer; everything else gets the contract's success.
  The request body has already been read by then, and is in
  `conn.assigns.raw_body`.
  """
  def install(test_pid, answers \\ %{}) do
    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      {:ok, body, conn} = read_body(conn)
      conn = assign(conn, :raw_body, body)

      headers = Map.new(conn.req_headers)
      send(test_pid, {:public_request, conn.method, conn.request_path, headers, body})

      case Map.get(answers, {conn.method, conn.request_path}) ||
             Map.get(answers, {conn.method, :any}) do
        nil -> default(conn)
        answer -> answer.(conn)
      end
    end)
  end

  def json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  def error(status, code, extra \\ %{}) do
    fn conn -> json(conn, status, Map.merge(%{"error" => code, "detail" => "Test."}, extra)) end
  end

  defp default(%{method: "GET", request_path: "/api/server"} = conn),
    do: json(conn, 200, server_body())

  defp default(%{method: "POST", request_path: "/api/installations"} = conn),
    do: json(conn, 201, %{"installation_id" => @installation, "key" => @key})

  defp default(%{method: "POST", request_path: "/api/tournaments"} = conn),
    do: json(conn, 201, %{"slug" => mint_slug()})

  # The success answers are the shapes OpenResults' vendored contract
  # (`priv/contracts/vendor/openresults/publish-v1`) gives them, and
  # `PairingsEngine.OpenResultsPublishContractTest` holds this stub to it: a
  # fake that answers what the real server never would is a test of the fake.
  defp default(%{method: "POST", request_path: "/api/snapshots"} = conn) do
    slug =
      case Jason.decode(conn.assigns.raw_body) do
        {:ok, %{"tournament" => %{"slug" => slug}}} when is_binary(slug) -> slug
        _ -> "unknown"
      end

    json(conn, 200, %{"status" => "ok", "slug" => slug, "received_at" => now()})
  end

  defp default(%{method: "DELETE", request_path: "/api/tournaments/" <> slug} = conn) do
    json(conn, 200, %{
      "status" => "deleted",
      "slug" => URI.decode(slug),
      "deleted" => %{"snapshots" => 1, "registrations" => 0, "key" => 1}
    })
  end

  defp default(conn), do: json(conn, 404, %{"error" => "not_found", "detail" => "Not found."})

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # 9 random bytes, base64url - the shape the contract promises.
  defp mint_slug, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)

  @doc "Every request reported so far, oldest first, as `{method, path, headers, body}`."
  def requests(acc \\ []) do
    receive do
      {:public_request, method, path, headers, body} ->
        requests([{method, path, headers, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The same, as `{method, path}` only."
  def calls, do: Enum.map(requests(), fn {method, path, _h, _b} -> {method, path} end)
end
