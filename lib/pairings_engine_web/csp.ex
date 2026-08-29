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

  `frame-ancestors 'none'` on every response, with no exceptions and no way
  to ask for one. That is what stops the app being put in someone else's
  iframe and clicked through by a logged-in arbiter.

  Three read-only pages used to opt out, so a club site could embed the
  pairing list. They were removed on 2026-08-29 along with the rest of the
  local public pages: the public reads a tournament on OpenResults now, and
  a club that wants the pairing list on its front page embeds it from there
  - a site with no login, no session and nothing to clickjack, where framing
  is safe by construction rather than by careful argument.

  Every page this app still serves acts with authority the visitor already
  holds, so every page stays at `'none'`.

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
