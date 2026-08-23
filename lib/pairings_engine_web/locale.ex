defmodule PairingsEngineWeb.Locale do
  @moduledoc """
  Which language a request or a LiveView renders in.

  ## Where the choice comes from

  In order: an explicit pick stored in the session, then the browser's
  `accept-language` header, then the default. The header matters more here
  than in most apps - the people reading the PUBLIC pages are players and
  spectators with no account and no settings screen, so the only thing that
  can speak for them is what their browser already says. A Belgian visitor
  whose browser asks for `nl-BE` should get Dutch without touching anything,
  the day Dutch exists.

  Region subtags are matched loosely: `nl-BE`, `nl-NL` and `nl` all resolve
  to `nl`, because chess vocabulary does not differ between Flanders and the
  Netherlands enough to justify two catalogues.

  ## Why a module rather than a plug alone

  A LiveView does NOT run in the process that served the request, so a plug
  setting `Gettext.put_locale/1` reaches the dead render and nothing after
  it. The locale has to be resolved once, put in the session, and applied
  AGAIN inside the LiveView process (`PairingsEngineWeb.LocaleHook`). Both
  paths call in here so the resolution rules exist once.

  ## Adding a language

  Add it to `@locales` with its own name in its own language, run
  `mix gettext.extract --merge`, translate `priv/gettext/<code>/LC_MESSAGES`,
  and it appears in the picker. Nothing else needs touching - which is the
  whole point of doing this before there is a second language rather than
  after.
  """

  # {code, endonym}. The label is the language's name IN that language, not
  # in English: someone who needs Dutch is looking for "Nederlands", and
  # cannot necessarily read the word "Dutch" to find it.
  @locales [
    {"en", "English"}
  ]

  @default "en"
  @session_key "locale"

  def default, do: @default
  def session_key, do: @session_key

  @doc "Every locale the app can render, as `{code, endonym}`."
  def locales, do: @locales

  @doc "Just the codes, for `Gettext` configuration and validation."
  def codes, do: Enum.map(@locales, &elem(&1, 0))

  @doc "The endonym for a code, or the code itself if it is not one we ship."
  def label(code) do
    case List.keyfind(@locales, code, 0) do
      {_code, name} -> name
      nil -> code
    end
  end

  @doc "Whether this is a locale the app actually ships."
  def known?(code), do: code in codes()

  @doc """
  Resolves the locale for a session map plus an `accept-language` value.

  Takes the header as a plain string (or nil) rather than a `Plug.Conn`, so
  it can be called from a LiveView `mount/3`, where there is no conn.
  """
  def resolve(session, accept_language \\ nil) do
    from_session(session) || from_header(accept_language) || @default
  end

  defp from_session(session) when is_map(session) do
    case Map.get(session, @session_key) do
      code when is_binary(code) -> if known?(code), do: code
      _ -> nil
    end
  end

  defp from_session(_session), do: nil

  # `accept-language: nl-BE,nl;q=0.9,en;q=0.8` - take the first entry we can
  # actually serve, honouring the client's own order. Quality values are used
  # for ordering only; a malformed one sorts last rather than raising, since
  # a header is attacker-controlled input and must never be able to 500 a
  # public page.
  defp from_header(nil), do: nil

  defp from_header(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_code, q} -> -q end)
    |> Enum.find_value(fn {code, _q} -> if known?(code), do: code end)
  end

  defp from_header(_header), do: nil

  defp parse_entry(entry) do
    case String.split(entry, ";") do
      [tag] -> {base(tag), 1.0}
      [tag, q] -> {base(tag), quality(q)}
      _ -> nil
    end
  end

  # "nl-BE" -> "nl". Region is dropped deliberately; see the moduledoc.
  defp base(tag) do
    tag |> String.trim() |> String.downcase() |> String.split("-") |> hd()
  end

  defp quality("q=" <> value) do
    case Float.parse(String.trim(value)) do
      {q, _rest} -> q
      :error -> 0.0
    end
  end

  defp quality(_other), do: 0.0
end
