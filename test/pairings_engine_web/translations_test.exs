defmodule PairingsEngineWeb.TranslationsTest do
  @moduledoc """
  The Dutch catalogue, checked mechanically.

  ## Why this exists

  Dutch was filled to 918 of 918 on 2026-08-29 and reported complete. The
  count was true and the conclusion was wrong: **eleven entries were marked
  fuzzy**, and Elixir's Gettext - unlike GNU `msgfmt`, which drops them -
  **uses fuzzy translations at runtime.** So they were not gaps waiting to
  be filled, they were live, wrong Dutch on the screen.

  A fuzzy entry is gettext's guess, produced by `--merge` matching a new or
  reworded string against the most similar existing one. The guesses were
  what you would expect from string similarity and no meaning:

    * `Backups` rendered as "Terug" (Back).
    * `Sending`, on the publish indicator, rendered as "Stand" (Standings).
    * `This tournament has no round` rendered as "Dit toernooi is
      gearchiveerd." - "this tournament is archived", which is a different
      claim about a different thing.
    * Worst, the engine-switch confirmation had its two buttons swapped:
      `Use JaVaFo` read "JaVaFo behouden" (keep) and `Keep Ainalrami` read
      "Ainalrami gebruiken" (use). A Dutch arbiter choosing a pairing engine
      was reading the opposite of what each button did.

  None of this is visible in a completeness count, which is why counting was
  never enough and why this is a test rather than a script somebody
  remembers to run.

  ## The three rules

  Nothing here checks that a translation is GOOD - no test can. It checks
  the three things that are decidable, each of which has actually gone
  wrong:

    1. nothing is untranslated;
    2. nothing is a machine's guess;
    3. every interpolation in the original survives into the translation.

  The third matters most at runtime: a `%{name}` that a translator dropped,
  renamed or typo'd does not render oddly, it raises when the string is
  interpolated. That turns a translation slip into a crashing page in one
  language only, which is exactly the kind of thing that reaches production.
  """
  use ExUnit.Case, async: true

  @locale "nl"

  defp catalogues do
    Path.wildcard("priv/gettext/#{@locale}/LC_MESSAGES/*.po")
  end

  # Every locale, including the source one. Only the fuzzy check uses this:
  # emptiness is expected in `en` (Gettext falls back to the msgid, so the
  # convention is to leave it empty and let the source text speak), but a
  # fuzzy FLAG is meaningless there and dangerous anywhere it is acted on.
  # Left ungoverned, `en` had quietly accumulated 75 of them by 2026-09-02 -
  # inert only because nothing had filled a msgstr beside one yet.
  defp all_catalogues do
    Path.wildcard("priv/gettext/*/LC_MESSAGES/*.po")
  end

  defp locale_of(path) do
    path |> Path.split() |> Enum.at(-3)
  end

  defp messages(path) do
    Expo.PO.parse_file!(path).messages
  end

  defp id(%Expo.Message.Singular{msgid: msgid}), do: IO.iodata_to_binary(msgid)
  defp id(%Expo.Message.Plural{msgid: msgid}), do: IO.iodata_to_binary(msgid)

  defp translations(%Expo.Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp translations(%Expo.Message.Plural{msgstr: msgstr}) do
    Enum.map(msgstr, fn {_n, str} -> IO.iodata_to_binary(str) end)
  end

  # Both shapes this codebase uses: gettext's own `%{name}` and the
  # `rich_text` component's `%[name]`, which wraps markup around a value and
  # is just as fatal to lose.
  defp placeholders(string) do
    ~r/%[{\[]([a-zA-Z0-9_]+)[}\]]/
    |> Regex.scan(string)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.sort()
  end

  test "there is a Dutch catalogue to check" do
    # Guards the whole file: a wildcard that matches nothing makes every
    # test below pass while checking nothing at all.
    assert catalogues() != []
  end

  test "every message is translated" do
    for path <- catalogues(), message <- messages(path) do
      for translation <- translations(message) do
        refute translation == "",
               "#{Path.basename(path)}: #{inspect(id(message))} is untranslated"
      end
    end
  end

  # After `mix gettext.merge`, expect this to fail for `en`: the merge marks
  # fuzzy in every locale, and `en` is merged along with the rest even though
  # its msgstrs are deliberately empty. The remedy there is to REMOVE THE FLAG
  # and leave the msgstr empty - never to fill it in. English renders from the
  # msgid; a filled `en` msgstr is a second copy of the source string that the
  # next reword will silently desynchronise.
  #
  # For `nl` the remedy is the opposite: read the guess, correct it, then
  # remove the flag. Never strip a Dutch flag without reading what it left
  # behind - that is how "Use JaVaFo" came to say "keep JaVaFo".
  test "no message in any locale is left as a machine's guess" do
    for path <- all_catalogues(), message <- messages(path) do
      refute "fuzzy" in List.flatten(message.flags),
             """
             #{locale_of(path)}/#{Path.basename(path)}: #{inspect(id(message))} is marked fuzzy.

             Elixir's Gettext USES fuzzy entries, so this renders on screen. It is
             gettext's guess from a similar string, not a translation. Read it,
             correct it, and remove the flag - or, if the guess happens to be
             right, remove the flag anyway to say a person looked.
             """
    end
  end

  # What a translation of this message is allowed to interpolate. For a
  # plural that is NOT just the singular's placeholders: English writes the
  # singular as a literal "1 tournament waiting to send" while Dutch may well
  # want "%{count}" in both forms, and `ngettext/3` binds `count` for every
  # form regardless of which language spells it out.
  defp available(%Expo.Message.Plural{} = message) do
    plural = IO.iodata_to_binary(message.msgid_plural)
    Enum.sort(Enum.uniq(["count"] ++ placeholders(id(message)) ++ placeholders(plural)))
  end

  defp available(message), do: placeholders(id(message))

  test "no translation interpolates something that will not be bound" do
    # The direction that crashes. A `%{name}` the original does not provide
    # raises when the string is interpolated, so a typo or an invented
    # placeholder takes the page down in Dutch and in no other language.
    for path <- catalogues(), message <- messages(path) do
      allowed = available(message)

      for translation <- translations(message), translation != "" do
        extra = placeholders(translation) -- allowed

        assert extra == [],
               """
               #{Path.basename(path)}: #{inspect(id(message))} interpolates #{inspect(extra)}, which is not bound.

                 available:   #{inspect(allowed)}
                 translation: #{inspect(translation)}
               """
      end
    end
  end

  test "no singular translation quietly drops a placeholder" do
    # The direction that loses information rather than raising: the sentence
    # still renders, without the number or name it was written around.
    #
    # Singulars only. A plural form may legitimately omit `%{count}` - that
    # is exactly what English does in "1 tournament waiting to send".
    for path <- catalogues(), message <- messages(path) do
      case message do
        %Expo.Message.Singular{} ->
          expected = placeholders(id(message))

          for translation <- translations(message), translation != "" do
            missing = expected -- placeholders(translation)

            assert missing == [],
                   """
                   #{Path.basename(path)}: #{inspect(id(message))} drops #{inspect(missing)}.

                     translation: #{inspect(translation)}
                   """
          end

        _ ->
          :ok
      end
    end
  end
end
