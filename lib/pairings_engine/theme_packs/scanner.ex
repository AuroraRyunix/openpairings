defmodule PairingsEngine.ThemePacks.Scanner do
  @moduledoc """
  Decides whether a theme pack's stylesheet may be served. A pack is CSS
  somebody else wrote, loaded into a page that acts with an arbiter's
  authority, so it is read the way a customs officer reads a suitcase:
  everything that is not on the list stays out.

  ## What passes

    * style rules whose every selector is scoped to the pack - its first
      compound carries `[data-theme="<id>"]`, bare or as `:where(...)` /
      `:is(...)` (so `:root[data-theme="x"]`, `html[data-theme="x"] .card`
      and `[data-accent="blue"]:where([data-theme="x"])` all pass);
    * `@font-face`, `@keyframes` (and `-webkit-keyframes`);
    * `@media` and `@supports`, whose inner rules obey the same scoping.

  ## What does not

    * any `@import`, and every other at-rule;
    * any `url(...)` that is not a relative `fonts/<name>.woff2` of the pack
      itself, and the other ways CSS has of naming a URL (`image-set()`,
      `image()`, `src()`, `element()`);
    * `expression(`, `javascript:`, `vbscript:`, `behavior:`, `-moz-binding`
      - the old ways CSS ran code, refused even where no browser still
      listens, because a refusal costs nothing;
    * a backslash escape outside a string (`@\\69mport` is `@import` to a
      browser and nothing to a regex), nested rules, and anything that does
      not parse.

  Comments are removed before any of this is looked at and strings are kept
  whole, so neither can hide a rule from the scanner or smuggle one past it:
  `/* @import */` is a comment, `content: "}"` does not close a block.
  """

  @ident_chars ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  @url_functions ~w(image-set -webkit-image-set image src element)
  @forbidden [
    {~r/@import/i, "@import"},
    {~r/expression\s*\(/i, "expression("},
    {~r/javascript\s*:/i, "javascript:"},
    {~r/vbscript\s*:/i, "vbscript:"},
    {~r/behavior\s*:/i, "behavior:"},
    {~r/-moz-binding/i, "-moz-binding"}
  ]
  @font_url ~r/\Afonts\/[a-z0-9_-]+\.woff2\z/

  @doc """
  `:ok`, or `{:error, reason}` with a short reason in English, for the log
  and for the picker's "refused" line.
  """
  @spec scan(String.t(), String.t()) :: :ok | {:error, String.t()}
  def scan(css, id) when is_binary(css) and is_binary(id) do
    with true <- String.valid?(css) || {:error, "not UTF-8"},
         {:ok, tokens} <- tokenize(css, []),
         :ok <- forbidden(tokens),
         :ok <- urls(tokens),
         :ok <- rules(tokens, id, false) do
      :ok
    end
  catch
    {:refuse, reason} -> {:error, reason}
  end

  # ---------------------------------------------------------------------------
  # Tokens: a codepoint, or {:str, quote, content} for a whole string.
  # Comments become one space.

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize("/*" <> rest, acc) do
    case :binary.match(rest, "*/") do
      :nomatch ->
        {:error, "unterminated comment"}

      {pos, 2} ->
        tokenize(binary_part(rest, pos + 2, byte_size(rest) - pos - 2), [?\s | acc])
    end
  end

  defp tokenize(<<q, rest::binary>>, acc) when q in [?", ?'] do
    case string(rest, q, []) do
      {:ok, content, rest} -> tokenize(rest, [{:str, q, content} | acc])
      error -> error
    end
  end

  defp tokenize("\\" <> _, _acc), do: {:error, "backslash escape outside a string"}
  defp tokenize(<<c::utf8, rest::binary>>, acc), do: tokenize(rest, [c | acc])

  defp string(<<>>, _q, _acc), do: {:error, "unterminated string"}

  defp string(<<q, rest::binary>>, q, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp string(<<?\n, _::binary>>, _q, _acc), do: {:error, "line break inside a string"}

  defp string(<<?\\, c::utf8, rest::binary>>, q, acc),
    do: string(rest, q, [<<c::utf8>>, ?\\ | acc])

  defp string(<<c::utf8, rest::binary>>, q, acc), do: string(rest, q, [<<c::utf8>> | acc])

  # ---------------------------------------------------------------------------
  # Words that are refused wherever they stand, strings included.

  defp forbidden(tokens) do
    text = render(tokens)

    case Enum.find(@forbidden, fn {re, _} -> text =~ re end) do
      nil -> :ok
      {_, word} -> {:error, "#{word} is not allowed"}
    end
  end

  # ---------------------------------------------------------------------------
  # URLs: only the pack's own fonts.

  defp urls(tokens), do: urls(tokens, [])

  defp urls([], _name), do: :ok

  defp urls([?( | rest], name) do
    case name |> Enum.reverse() |> to_string() |> String.downcase() do
      "url" -> url_argument(rest)
      fun when fun in @url_functions -> {:error, "#{fun}() is not allowed"}
      _ -> urls(rest, [])
    end
  end

  defp urls([c | rest], name) when is_integer(c) and c in @ident_chars, do: urls(rest, [c | name])
  defp urls([_ | rest], _name), do: urls(rest, [])

  defp url_argument(tokens) do
    {value, rest} =
      case skip_ws(tokens) do
        [{:str, _, content} | rest] ->
          {content, rest}

        rest ->
          {raw, rest} =
            Enum.split_while(rest, &(is_integer(&1) and &1 not in [?), ?\s, ?\t, ?\n]))

          {to_string(raw), rest}
      end

    case skip_ws(rest) do
      [?) | rest] ->
        if value =~ @font_url,
          do: urls(rest, []),
          else: {:error, "url(#{value}) is not one of the pack's fonts/*.woff2"}

      _ ->
        {:error, "malformed url()"}
    end
  end

  # ---------------------------------------------------------------------------
  # Structure

  defp rules(tokens, id, nested?) do
    case skip_ws(tokens) do
      [] ->
        if nested?, do: {:error, "unclosed block"}, else: :ok

      [?} | rest] ->
        if nested?, do: {:ok, rest}, else: {:error, "unexpected }"}

      [?@ | rest] ->
        {name, rest} = Enum.split_while(rest, &(is_integer(&1) and &1 in @ident_chars))
        {prelude, terminator, rest} = prelude(rest)
        at_rule(String.downcase(to_string(name)), prelude, terminator, rest, id, nested?)

      tokens ->
        case prelude(tokens) do
          {selector, ?{, rest} ->
            unless scoped?(selector, id) do
              throw(
                {:refuse, "selector not scoped to [data-theme=\"#{id}\"]: #{short(selector)}"}
              )
            end

            rest |> declarations() |> rules(id, nested?)

          {text, _, _} ->
            {:error, "stray text: #{short(text)}"}
        end
    end
  end

  defp at_rule("font-face", _prelude, ?{, rest, id, nested?),
    do: rest |> declarations() |> rules(id, nested?)

  defp at_rule(kf, _prelude, ?{, rest, id, nested?) when kf in ["keyframes", "-webkit-keyframes"],
    do: rest |> keyframes() |> rules(id, nested?)

  defp at_rule(group, _prelude, ?{, rest, id, nested?) when group in ["media", "supports"] do
    case rules(rest, id, true) do
      {:ok, rest} -> rules(rest, id, nested?)
      error -> error
    end
  end

  defp at_rule(name, _prelude, _terminator, _rest, _id, _nested?),
    do: {:error, "@#{name} is not allowed"}

  defp keyframes(tokens) do
    case skip_ws(tokens) do
      [?} | rest] ->
        rest

      tokens ->
        case prelude(tokens) do
          {_frame, ?{, rest} -> rest |> declarations() |> keyframes()
          _ -> throw({:refuse, "malformed @keyframes"})
        end
    end
  end

  # Up to the closing brace of a declaration block. A `{` inside one is a
  # nested rule, which the scoping check would have to follow - so it is not
  # followed, it is refused.
  defp declarations([]), do: throw({:refuse, "unclosed block"})
  defp declarations([?} | rest]), do: rest
  defp declarations([?{ | _]), do: throw({:refuse, "nested rules are not allowed"})
  defp declarations([_ | rest]), do: declarations(rest)

  # A selector or at-rule prelude, up to the `{` or `;` that ends it at
  # bracket depth 0. Returns its text (strings re-quoted), the terminator
  # and the rest.
  defp prelude(tokens), do: prelude(tokens, 0, [])

  defp prelude([], _depth, acc), do: {render(Enum.reverse(acc)), nil, []}

  defp prelude([c | rest], 0, acc) when c in [?{, ?;, ?}],
    do: {render(Enum.reverse(acc)), c, rest}

  defp prelude([c | rest], depth, acc) when c in [?(, ?[], do: prelude(rest, depth + 1, [c | acc])

  defp prelude([c | rest], depth, acc) when c in [?), ?]],
    do: prelude(rest, max(depth - 1, 0), [c | acc])

  defp prelude([t | rest], depth, acc), do: prelude(rest, depth, [t | acc])

  defp skip_ws([c | rest]) when c in [?\s, ?\t, ?\n, ?\r, ?\f], do: skip_ws(rest)
  defp skip_ws(tokens), do: tokens

  defp render(tokens) do
    tokens
    |> Enum.map(fn
      {:str, q, content} -> [q, content, q]
      c -> <<c::utf8>>
    end)
    |> IO.iodata_to_binary()
  end

  defp short(text) do
    text = text |> String.trim() |> String.replace(~r/\s+/, " ")
    if String.length(text) > 60, do: String.slice(text, 0, 57) <> "...", else: text
  end

  # ---------------------------------------------------------------------------
  # Scoping

  @doc """
  Whether every selector in a selector list is scoped to the pack `id`: its
  first compound selector carries `[data-theme="id"]`, bare or as the sole
  argument of `:where()` / `:is()`.
  """
  @spec scoped?(String.t(), String.t()) :: boolean()
  def scoped?(selector_list, id) do
    selectors = split_top(selector_list, ?,)
    selectors != [] and Enum.all?(selectors, &scoped_one?(String.trim(&1), id))
  end

  defp scoped_one?("", _id), do: false

  defp scoped_one?(selector, id) do
    selector
    |> first_compound()
    |> components()
    |> Enum.any?(fn component -> theme_attr?(component, id) or wrapped_attr?(component, id) end)
  end

  defp theme_attr?("[" <> _ = attr, id) do
    String.replace(attr, ~r/\s+/, "") in [
      ~s([data-theme="#{id}"]),
      ~s([data-theme='#{id}']),
      ~s([data-theme=#{id}])
    ]
  end

  defp theme_attr?(_, _), do: false

  defp wrapped_attr?(component, id) do
    case Regex.run(~r/\A:(?:where|is)\((.*)\)\z/is, component, capture: :all_but_first) do
      [inner] -> theme_attr?(String.trim(inner), id)
      nil -> false
    end
  end

  # Everything up to the first combinator at depth 0.
  defp first_compound(selector) do
    selector
    |> String.to_charlist()
    |> take_compound(0, nil, [])
    |> Enum.reverse()
    |> to_string()
  end

  defp take_compound([], _d, _q, acc), do: acc
  defp take_compound([q | rest], d, q, acc), do: take_compound(rest, d, nil, [q | acc])

  defp take_compound([c | rest], d, nil, acc) when c in [?", ?'],
    do: take_compound(rest, d, c, [c | acc])

  defp take_compound([c | rest], d, q, acc) when q != nil,
    do: take_compound(rest, d, q, [c | acc])

  defp take_compound([c | _], 0, nil, acc) when c in [?\s, ?\t, ?\n, ?\r, ?>, ?+, ?~], do: acc

  defp take_compound([c | rest], d, nil, acc) when c in [?(, ?[],
    do: take_compound(rest, d + 1, nil, [c | acc])

  defp take_compound([c | rest], d, nil, acc) when c in [?), ?]],
    do: take_compound(rest, max(d - 1, 0), nil, [c | acc])

  defp take_compound([c | rest], d, nil, acc), do: take_compound(rest, d, nil, [c | acc])

  # A compound selector's simple selectors: `[...]`, `:name(...)`, `:name`,
  # and runs of anything else (a tag, `.class`, `#id`).
  defp components(compound), do: components(String.to_charlist(compound), [])

  defp components([], acc), do: Enum.reverse(acc)

  defp components([?[ | _] = chars, acc) do
    {group, rest} = balanced(chars, ?[, ?])
    components(rest, [group | acc])
  end

  defp components([?: | _] = chars, acc) do
    {colons, rest} = Enum.split_while(chars, &(&1 == ?:))
    {name, rest} = Enum.split_while(rest, &(&1 in @ident_chars))

    case rest do
      [?( | _] ->
        {args, rest} = balanced(rest, ?(, ?))
        components(rest, [to_string(colons ++ name) <> args | acc])

      _ ->
        components(rest, [to_string(colons ++ name) | acc])
    end
  end

  defp components(chars, acc) do
    {run, rest} = Enum.split_while(chars, &(&1 not in [?[, ?:]))
    components(rest, [to_string(run) | acc])
  end

  # The group starting at `open`, through its matching `close`, quote-aware.
  defp balanced(chars, open, close), do: balanced(chars, open, close, 0, nil, [])

  defp balanced([], _o, _c, _d, _q, acc), do: {acc |> Enum.reverse() |> to_string(), []}

  defp balanced([q | rest], o, c, d, q, acc), do: balanced(rest, o, c, d, nil, [q | acc])

  defp balanced([ch | rest], o, c, d, q, acc) when q != nil,
    do: balanced(rest, o, c, d, q, [ch | acc])

  defp balanced([ch | rest], o, c, d, nil, acc) when ch in [?", ?'],
    do: balanced(rest, o, c, d, ch, [ch | acc])

  defp balanced([o | rest], o, c, d, nil, acc), do: balanced(rest, o, c, d + 1, nil, [o | acc])

  defp balanced([c | rest], _o, c, 1, nil, acc),
    do: {[c | acc] |> Enum.reverse() |> to_string(), rest}

  defp balanced([c | rest], o, c, d, nil, acc), do: balanced(rest, o, c, d - 1, nil, [c | acc])
  defp balanced([ch | rest], o, c, d, nil, acc), do: balanced(rest, o, c, d, nil, [ch | acc])

  # Splits on `sep` at depth 0, outside quotes.
  defp split_top(text, sep) do
    text
    |> String.to_charlist()
    |> split_top(sep, 0, nil, [], [])
  end

  defp split_top([], _sep, _d, _q, cur, out),
    do: Enum.reverse([cur |> Enum.reverse() |> to_string() | out])

  defp split_top([q | rest], sep, d, q, cur, out),
    do: split_top(rest, sep, d, nil, [q | cur], out)

  defp split_top([c | rest], sep, d, q, cur, out) when q != nil,
    do: split_top(rest, sep, d, q, [c | cur], out)

  defp split_top([c | rest], sep, d, nil, cur, out) when c in [?", ?'],
    do: split_top(rest, sep, d, c, [c | cur], out)

  defp split_top([sep | rest], sep, 0, nil, cur, out),
    do: split_top(rest, sep, 0, nil, [], [cur |> Enum.reverse() |> to_string() | out])

  defp split_top([c | rest], sep, d, nil, cur, out) when c in [?(, ?[],
    do: split_top(rest, sep, d + 1, nil, [c | cur], out)

  defp split_top([c | rest], sep, d, nil, cur, out) when c in [?), ?]],
    do: split_top(rest, sep, max(d - 1, 0), nil, [c | cur], out)

  defp split_top([c | rest], sep, d, nil, cur, out),
    do: split_top(rest, sep, d, nil, [c | cur], out)
end
