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

  # The templates `mix gettext.extract` writes. Every catalogue is supposed to
  # be a translation OF one of these, and nothing else.
  defp templates do
    Path.wildcard("priv/gettext/*.pot")
  end

  # The locale the msgids are written in. Its msgstrs are deliberately empty -
  # Gettext falls back to the msgid - so it is the one catalogue the
  # "everything is translated" rule must not be applied to, and the one place a
  # FILLED msgstr is the bug.
  @source_locale "en"

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

  # Every string of a message that a reader can end up looking at: the originals
  # and each translated form. Used by the checks that are about the TEXT rather
  # than about whether a translation exists.
  defp all_strings(%Expo.Message.Singular{} = message) do
    [id(message) | translations(message)]
  end

  defp all_strings(%Expo.Message.Plural{msgid_plural: plural} = message) do
    [id(message), IO.iodata_to_binary(plural) | translations(message)]
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
    assert templates() != []

    # And the template-to-catalogue comparison is only worth anything if the
    # two wildcards agree on what a domain is called.
    for template <- templates() do
      domain = Path.basename(template, ".pot")

      assert Path.wildcard("priv/gettext/*/LC_MESSAGES/#{domain}.po") != [],
             "#{template} has no catalogue to be compared against"
    end
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

  test "no message escapes a percent sign as %%" do
    # `Gettext.Interpolation.Default` replaces `%{name}` and touches nothing
    # else, so `%%` is NOT an escape here the way it is in a printf format or a
    # GNU gettext c-format string. It reaches the screen as two characters.
    #
    # Two strings on Settings > Options - the engine comparison and the "Switch
    # to JaVaFo?" confirmation - read "roughly 4%% of rounds" for exactly this
    # reason, in English as well as in Dutch, because the habit was carried over
    # from a language where the doubling means something.
    #
    # The templates are checked too: a `%%` in a msgid is wrong in every locale
    # at once, and the fix belongs in the source string.
    for path <- templates() ++ all_catalogues(),
        message <- messages(path),
        string <- all_strings(message) do
      refute string =~ "%%",
             """
             #{path}: #{inspect(id(message))} contains "%%".

             Gettext does not unescape it - it renders as two percent signs.
             Write a single "%".

               string: #{inspect(string)}
             """
    end
  end

  test "the source locale's translations are left empty" do
    # English renders from the msgid. A filled `en` msgstr is a second copy of
    # the source text that nothing keeps in step: reword the msgid and the
    # duplicate stays behind, and from then on the app shows the old wording to
    # English readers and the new one to the extractor.
    #
    # One had already happened by 2026-09-12 - "Hide the initial standings from
    # the public page again?", filled with itself - and no count or completeness
    # check can see it, because from the outside it looks exactly like a
    # translated string.
    for path <- all_catalogues(), locale_of(path) == @source_locale do
      for message <- messages(path), translation <- translations(message) do
        assert translation == "",
               """
               #{locale_of(path)}/#{Path.basename(path)}: #{inspect(id(message))} has a translation.

               The source locale renders from the msgid, so this msgstr must
               stay empty - otherwise the next reword leaves this copy behind.

                 msgstr: #{inspect(translation)}
               """
      end
    end
  end

  test "every catalogue holds exactly the messages its template does" do
    # `mix gettext.merge` keeps these in step, and nothing fails if somebody
    # hand-edits one file. The two ways they drift are both silent: a msgid only
    # in the template is a string that renders untranslated, and a msgid only in
    # a catalogue is a translation of something no longer on screen - which
    # keeps a stale phrasing looking maintained.
    for template <- templates() do
      domain = Path.basename(template, ".pot")
      expected = MapSet.new(messages(template), &Expo.Message.key/1)

      for path <- Path.wildcard("priv/gettext/*/LC_MESSAGES/#{domain}.po") do
        actual = MapSet.new(messages(path), &Expo.Message.key/1)

        assert MapSet.to_list(MapSet.difference(expected, actual)) == [],
               """
               #{locale_of(path)}/#{Path.basename(path)} is missing messages that #{Path.basename(template)} has.

               They render untranslated. Run `mix gettext.extract --merge`.
               """

        assert MapSet.to_list(MapSet.difference(actual, expected)) == [],
               """
               #{locale_of(path)}/#{Path.basename(path)} has messages #{Path.basename(template)} does not.

               Nothing on screen asks for them any more. Run
               `mix gettext.extract --merge`, and read what it drops.
               """
      end
    end
  end

  test "no catalogue repeats a message, or keeps an obsolete one" do
    # Duplicates in a `.po` are caught for us: Gettext's compiler raises
    # `Expo.PO.DuplicateMessagesError` and the build stops. The `.pot` files are
    # NOT compiled, so a duplicate there is silent, and it survives a merge as
    # two entries a translator can fill differently - which is the state this
    # catches.
    #
    # An obsolete entry (`#~`) is what `mix gettext.merge` leaves behind for a
    # string that left the source. Keeping them is a supported workflow; this
    # project's is to let the merge drop them, so one appearing means a merge
    # was half-applied or a file was edited by hand.
    for path <- templates() ++ all_catalogues() do
      all = messages(path)

      obsolete = Enum.filter(all, & &1.obsolete)

      assert obsolete == [],
             """
             #{path} keeps #{length(obsolete)} obsolete (#~) message(s):
             #{Enum.map_join(obsolete, "\n", &"  #{inspect(id(&1))}")}
             """

      duplicates =
        all
        |> Enum.frequencies_by(&Expo.Message.key/1)
        |> Enum.filter(fn {_key, count} -> count > 1 end)
        |> Enum.map(fn {key, _count} -> key end)

      assert duplicates == [],
             """
             #{path} has the same message twice:
             #{Enum.map_join(duplicates, "\n", &"  #{inspect(&1)}")}

             Only one of them renders, and it is not obvious which.
             """
    end
  end

  test "no message carries an HTML entity" do
    # Msgids hold the real character - `&`, `·`, `→` - for one spelling per
    # string, and because the two paths that render them want opposite things.
    # HEEx escapes `gettext/1`'s output, so `&amp;` in a msgid reaches the page
    # as the literal text `&amp;`. `PrintController` interpolates raw, so there
    # the entity would work and the real character is what keeps the two
    # spellings the same. See docs/i18n.md.
    entity = ~r/&(?:[a-zA-Z][a-zA-Z0-9]{1,10}|#\d+|#x[0-9a-fA-F]+);/

    for path <- templates() ++ all_catalogues(),
        message <- messages(path),
        string <- all_strings(message) do
      refute string =~ entity,
             """
             #{path}: #{inspect(id(message))} carries an HTML entity.

             Write the character itself - HEEx escapes it on the way out, and
             the print path interpolates it raw.

               string: #{inspect(string)}
             """
    end
  end

  test "every translated catalogue declares its plural forms" do
    # `ngettext/3` picks a form by the locale's plural rule. Gettext falls back
    # to its own table when the header is absent, so a missing `Plural-Forms`
    # is invisible for a language it happens to know - and wrong for one it does
    # not, silently, in the one string shape a completeness count reads as fine.
    for path <- all_catalogues(), locale_of(path) != @source_locale do
      headers = Expo.PO.parse_file!(path).headers |> Enum.join()

      assert headers =~ "Plural-Forms:",
             "#{locale_of(path)}/#{Path.basename(path)} declares no Plural-Forms header"
    end
  end
end
