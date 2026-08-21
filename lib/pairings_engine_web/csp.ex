defmodule PairingsEngineWeb.CSP do
  @moduledoc """
  Sets a Content-Security-Policy on every browser response.

  `put_secure_browser_headers/2` covers frame options, content-type sniffing
  and referrer policy, but sets no CSP at all. HEEx escapes interpolations and
  the print logo is sniffed down to four raster formats
  (`PairingsEngine.Tournaments.set_logo/2`), so this is a backstop rather than
  the only thing standing between a stray unescaped value and script
  execution - but it is the difference between a mistake being a bug and it
  being an account takeover.

  ## The policy

    * `script-src 'self' 'nonce-...'` - bundled JS, plus the one inline
      bootstrap in the root layout (it sets the theme before first paint, so
      it cannot be deferred into `app.js` without a flash of the wrong
      theme) and the print pages' `window.print()` trigger. Both carry the
      per-response nonce below; anything injected into a page cannot guess it.
    * `style-src 'self' 'unsafe-inline'` - the app leans on `style="..."`
      attributes throughout, and a nonce cannot whitelist an attribute. Far
      less of a lever than script, and tightening it is a template-wide job.
    * `img-src 'self' data:` - the favicon, the QR codes and the print logo
      are all `data:` URIs.
    * `connect-src 'self'` - the LiveView socket, same origin.
    * `default-src 'self'`, `object-src 'none'`, `base-uri 'self'`,
      `frame-ancestors 'none'`, `form-action 'self'` - nothing here loads
      third-party anything, so everything else is closed.

  ## Framing

  `frame-ancestors 'none'` is the default on every response, which is what
  stops the authenticated app being put in someone else's iframe and
  clicked through by a logged-in victim. Two routes opt out of it:
  `/p/:slug/pairings` and `/p/:slug/standings`, the read-only public pages,
  via `allow_framing/2` in the router's `:embeddable` pipeline. Those pages
  hold no session, take no input and are already world-readable to anyone
  with the slug, so framing them grants a page no capability it did not
  already have - which is the property that makes it safe, and the one the
  register form, the arbiter tools, the mobile result entry and the whole
  authenticated app do NOT have. They stay at `'none'`.

  ## The nonce

  Regenerated per response and readable two ways, because the two kinds of
  page reach it differently: controllers get `@csp_nonce` in assigns, while a
  LiveView's root layout is rendered without them and calls `nonce/0`, which
  reads the value this plug stashed in the request process. Both run in the
  process this plug ran in, so both see the same value.
  """
  import Plug.Conn

  @process_key :csp_nonce

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode64()
    Process.put(@process_key, nonce)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  @doc """
  The current response's nonce, for templates rendered without access to conn
  assigns (the LiveView root layout). Returns `""` outside a request, which
  simply produces a nonce that matches nothing.
  """
  @spec nonce() :: String.t()
  def nonce, do: Process.get(@process_key, "")

  @doc """
  Re-open `frame-ancestors` for a route that is safe to embed.

  A plug, meant to run AFTER the `:browser` pipeline so it rewrites the
  header `call/2` already set - the default stays `'none'` and a route has
  to ask, rather than the other way round. Only the directive changes; the
  nonce and everything else are left exactly as they were, so this cannot
  loosen script or style handling by accident.

  The value comes from `config :pairings_engine, :public_frame_ancestors`
  (`PUBLIC_FRAME_ANCESTORS` at runtime), default `*`: a club website that
  wants the pairing list on its front page should not have to be added to
  an allowlist first. Set it to a space-separated origin list to restrict
  embedding to particular sites, or to `'none'` to switch embedding off
  entirely without touching the router.

  `x-frame-options` is deleted alongside it. Phoenix's
  `put_secure_browser_headers/2` does not set one, but a reverse proxy or a
  custom header map might, and the older header has no syntax for "these
  origins" - a stray `SAMEORIGIN` would silently override the CSP in the
  browsers that still prefer it.
  """
  def allow_framing(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> rewrite_frame_ancestors()
  end

  defp rewrite_frame_ancestors(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [policy | _] ->
        put_resp_header(
          conn,
          "content-security-policy",
          String.replace(policy, "frame-ancestors 'none'", "frame-ancestors #{ancestors()}")
        )

      [] ->
        conn
    end
  end

  defp ancestors do
    :pairings_engine
    |> Application.get_env(:public_frame_ancestors, "*")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "'none'"
      value -> value
    end
  end

  defp policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors 'none'",
      "form-action 'self'"
    ]
    |> Enum.join("; ")
  end
end
