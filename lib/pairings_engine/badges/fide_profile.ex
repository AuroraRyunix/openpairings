defmodule PairingsEngine.Badges.FideProfile do
  @moduledoc """
  Reads one player's public profile page on ratings.fide.com for the badge
  photo - the scraper from the stand-alone badge maker, made to fail politely.

  FIDE publishes no API for the photo, so this parses HTML, and HTML changes
  without notice. Every way that can go wrong comes back as a reason atom
  (`:page_changed` when neither the name nor the photo can be found any more)
  that the badge editor turns into a sentence telling the organiser to upload
  the photo by hand instead. Nothing here raises on a strange page.

  Only ever called for one badge at a time, from an explicit button press -
  see `PairingsEngine.Badges.fetch_fide_photo/2` for the guards around it.
  Req's automatic retries are off: one press is one request (two when the
  photo is a separate file rather than inlined in the page).

  In tests, `config :pairings_engine, :fide_profile_req_plug` points Req at a
  `Req.Test` stub, so no test reaches FIDE.
  """

  alias PairingsEngine.Badges.Image

  @base "https://ratings.fide.com"
  @user_agent "OpenPairings badge maker (+https://github.com/AuroraRyunix/OpenPairings)"

  @type reason ::
          :invalid_id
          | :not_found
          | :unreachable
          | :http_error
          | :page_changed
          | :no_photo
          | :bad_photo

  @doc """
  Fetches the profile for `fide_id` (digits, or a profile URL containing them).

  Returns `{:ok, %{first_name:, last_name:, federation:, photo: {binary, type} | nil}}`
  or `{:error, reason}`. `photo` is nil only when `fetch/1` is asked for the
  profile alone; a missing photo is `{:error, :no_photo}` from `fetch_photo/1`.
  """
  @spec fetch(String.t() | integer()) :: {:ok, map()} | {:error, reason()}
  def fetch(fide_id) do
    with {:ok, id} <- parse_id(fide_id),
         {:ok, html} <- get_page("#{@base}/profile/#{id}"),
         {:ok, doc} <- parse(html) do
      profile(doc)
    end
  end

  @doc """
  Like `fetch/1`, then resolves the photo into validated image bytes.
  `{:error, :no_photo}` when the profile has none.
  """
  @spec fetch_photo(String.t() | integer()) :: {:ok, map()} | {:error, reason()}
  def fetch_photo(fide_id) do
    with {:ok, profile} <- fetch(fide_id),
         {:ok, src} <- photo_src(profile),
         {:ok, binary} <- photo_bytes(src),
         {:ok, type} <- validate_photo(binary) do
      {:ok, %{profile | photo: {binary, type}}}
    end
  end

  @doc "The FIDE ID in `input` - bare digits or a profile URL - or `{:error, :invalid_id}`."
  def parse_id(input) do
    input = input |> to_string() |> String.trim()

    case Regex.run(~r/profile\/(\d{1,10})/, input) || Regex.run(~r/^\d{1,10}$/, input) do
      [_, id] -> {:ok, id}
      [id] -> {:ok, id}
      nil -> {:error, :invalid_id}
    end
  end

  defp get_page(url) do
    case request(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{}} -> {:error, :http_error}
      {:error, _} -> {:error, :unreachable}
    end
  end

  defp parse(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> {:ok, doc}
      {:error, _} -> {:error, :page_changed}
    end
  end

  defp profile(doc) do
    name = text(doc, ["h1.player-title", ".profile-top-title", ".player-title"])
    photo = attr(doc, ["img.profile-top__photo", ".profile-photo img", ".profile-top img"], "src")
    country = text(doc, [".profile-info-country", ".profile-top-info__block__row__data"])

    cond do
      name == nil and photo == nil ->
        # A profile id FIDE does not know renders a page without a player on
        # it; so does a page whose layout moved. Neither has a name, so tell
        # the two apart by whether FIDE still says "not found" anywhere.
        if Floki.text(doc) =~ ~r/not\s+found|no\s+player/i,
          do: {:error, :not_found},
          else: {:error, :page_changed}

      true ->
        {first, last} = split_name(name)

        {:ok,
         %{first_name: first, last_name: last, federation: country || "", photo: nil, src: photo}}
    end
  end

  defp photo_src(%{src: src}) when is_binary(src) and src != "" do
    if placeholder?(src), do: {:error, :no_photo}, else: {:ok, src}
  end

  defp photo_src(_), do: {:error, :no_photo}

  # FIDE shows a stock silhouette for players without a photo.
  defp placeholder?(src), do: src =~ ~r/(no[-_]?photo|default|avatar|placeholder)/i

  defp photo_bytes("data:" <> rest) do
    with [_meta, data] <- String.split(rest, ",", parts: 2),
         {:ok, binary} <- Base.decode64(String.replace(data, ~r/\s/, "")) do
      {:ok, binary}
    else
      _ -> {:error, :bad_photo}
    end
  end

  defp photo_bytes(src) do
    url = URI.merge(@base, src)

    # Only ever follow a photo link back to FIDE itself.
    if url.scheme == "https" and is_binary(url.host) and
         (url.host == "fide.com" or String.ends_with?(url.host, ".fide.com")) do
      case request(URI.to_string(url)) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %Req.Response{}} -> {:error, :no_photo}
        {:error, _} -> {:error, :unreachable}
      end
    else
      {:error, :bad_photo}
    end
  end

  defp validate_photo(binary) do
    case Image.validate(binary, :photo) do
      {:ok, type} -> {:ok, type}
      {:error, _} -> {:error, :bad_photo}
    end
  end

  defp text(doc, selectors) do
    Enum.find_value(selectors, fn selector ->
      case Floki.find(doc, selector) do
        [el | _] -> el |> Floki.text() |> String.trim() |> blank_to_nil()
        [] -> nil
      end
    end)
  end

  defp attr(doc, selectors, name) do
    Enum.find_value(selectors, fn selector ->
      case Floki.find(doc, selector) do
        [el | _] -> el |> Floki.attribute(name) |> List.first() |> blank_to_nil()
        [] -> nil
      end
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  @doc false
  # FIDE writes "Surname, Firstname"; anything else splits at the first space.
  def split_name(nil), do: {"", ""}

  def split_name(name) do
    case String.split(name, ",", parts: 2) do
      [last, first] ->
        {String.trim(first), String.trim(last)}

      [single] ->
        case String.split(single, " ", trim: true) do
          [] -> {"", ""}
          [one] -> {"", one}
          [first | rest] -> {first, Enum.join(rest, " ")}
        end
    end
  end

  defp request(url) do
    {url, proxy_headers} = via_proxy(url)

    opts =
      [
        url: url,
        headers: [{"user-agent", @user_agent} | proxy_headers],
        retry: false,
        redirect: true,
        max_redirects: 3,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000],
        decode_body: false
      ]
      |> maybe_put_test_plug()

    Req.get(opts)
  rescue
    _ -> {:error, :unreachable}
  end

  # ratings.fide.com does not answer many datacenter ranges, the VPS's among
  # them. With `FIDE_PHOTO_PROXY_URL` and `FIDE_PHOTO_PROXY_TOKEN` set
  # (config/runtime.exs), both requests go through a Cloudflare Worker that
  # fetches exactly these two things: the profile page by id, and a photo on
  # a fide.com host (the deploy repo's cloudflare/fide-photo-proxy). The page
  # still comes back as FIDE's HTML and is parsed here.
  @doc false
  def via_proxy(url) do
    with config when is_list(config) <- Application.get_env(:pairings_engine, :fide_photo_proxy),
         base when is_binary(base) and base != "" <- config[:url],
         token when is_binary(token) and token != "" <- config[:token] do
      base = String.trim_trailing(base, "/")

      proxied =
        case Regex.run(~r"\Ahttps://ratings\.fide\.com/profile/(\d{1,10})\z", url) do
          [_, id] -> "#{base}/profile/#{id}"
          nil -> "#{base}/photo?" <> URI.encode_query(%{"url" => url})
        end

      {proxied, [{"x-proxy-token", token}]}
    else
      _ -> {url, []}
    end
  end

  defp maybe_put_test_plug(opts) do
    case Application.get_env(:pairings_engine, :fide_profile_req_plug) do
      nil -> opts
      name -> Keyword.put(opts, :plug, {Req.Test, name})
    end
  end
end
