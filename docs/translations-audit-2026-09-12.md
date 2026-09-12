# Translations audit - 2026-09-12

First pass over the gettext dimension, which the whole-codebase audit of
2026-09-05 lists under "What this audit never looked at". Scope: `en` and
`nl`, `priv/gettext/default.pot` + `errors.pot` and the four `.po` files
under them, every `gettext`/`ngettext` call site in `lib/`, and the
router's locale hooks.

Read `docs/i18n.md` first - it holds the rules. This document records what
was found against them, and has been folded back into it where it turned out
to be wrong or incomplete.

Worst first. **Fixed** means the change is in this commit. **Recommended**
means it is a judgment call, a behaviour change, or work large enough to want
deciding rather than doing.

---

## 1. "roughly 4%% of rounds" renders with two percent signs - FIXED

`lib/pairings_engine_web/live/settings_options_live.ex:628` and `:992`, and
the matching entries in all three `default` catalogues.

Both strings were written `roughly 4%% of rounds`, on the assumption that
gettext undoes the doubling the way a printf format or a GNU `c-format`
string does. It does not. `Gettext.Interpolation.Default` replaces `%{name}`
and passes every other byte through:

```
iex> Gettext.Interpolation.Default.runtime_interpolate("roughly 4%% of rounds", %{})
{:ok, "roughly 4%% of rounds"}
```

So the engine-comparison hint under Settings > Options, and the body of the
"Switch to JaVaFo?" confirmation - two of the most carefully written
paragraphs in the application, the ones an arbiter reads while deciding which
rulebook their tournament follows - both showed `4%%`. **In English as well
as in Dutch**, since the msgid renders directly for the source locale. This
is the one finding here that was never a translation bug at all; it took
reading the catalogue as text to see it.

Fixed in the source string and in `default.pot`, `en/default.po` and
`nl/default.po` (msgid and msgstr). `translations_test.exs` now refuses `%%`
anywhere in any msgid, msgid_plural or msgstr, templates included.

## 2. The Connections panel repeats an English sentence under a Dutch heading - RECOMMENDED

`lib/pairings_engine_web/components/connection_status.ex:318-323`, against
`lib/pairings_engine/publishing.ex`.

```elixir
defp detail(%{message: message}, headline) when is_binary(message) do
  case String.split(message, ~r/^#{Regex.escape(headline)}[.:]\s+/, parts: 2) do
    ["", rest] -> rest
    _not_a_repeat -> message
  end
end
```

`headline` comes from `gettext("Connected")`. `message` comes from
`Publishing`, which is a module with **zero** gettext calls:
`{:ok, "Connected. The address and token are both accepted."}`.

In English the split matches and the panel reads

> **Connected**
> The address and token are both accepted.

In Dutch the regex becomes `^Verbonden[.:]\s+`, never matches the English
message, and the panel reads

> **Verbonden**
> Connected. The address and token are both accepted.

- the duplication the function exists to remove, plus a language switch
mid-card. Every state is affected, not just `:connected`.

Not fixed, because every honest fix is bigger than a translation edit.
Wrapping `Publishing`'s messages is the right one, and it has a trap in front
of it - see finding 13b: three places pattern-match on the English text as
control flow. The narrow alternative is to have `Publishing` return a
`{reason, params}` pair and let the component pick both the headline and the
detail from one place.

## 3. Mobile result entry is half English, half Dutch on its first page - RECOMMENDED

`lib/pairings_engine_web/controllers/mobile_enroll_controller.ex` and
`mobile_enroll_html.ex`, against `router.ex:322-327`.

`EnglishHook` is a `live_session` hook. The phone's first page is not a
LiveView: `MobileEnrollController` serves `GET /m`, `POST /m`,
`GET /m/e/:token` and `GET /m/leave` through the `:browser` pipeline, where
`Plugs.Locale` has already resolved the arbiter's language. No hook runs.

The template is unwrapped English - "Enter results", "Scan the QR code your
arbiter is showing…", "Enrollment code", "Continue". The controller's five
error lines **are** wrapped, and are translated:

| line | string |
|---|---|
| 30 | `Too many attempts - wait a few minutes, or ask for a fresh code.` |
| 39 | `That code is wrong or has expired.` |
| 43 | `Enter your code.` |
| 49 | `That enrollment link is invalid or has expired.` |
| 90 | `This code has already been used by another phone - ask your arbiter for a new one.` |

A Dutch session therefore gets an English card with a Dutch error line in it,
and then `/m/results` fully English again. Nothing is broken; it just looks
unfinished, on the one screen a helper who is not the arbiter ever sees.

Two coherent answers, and it is a product call which:

* drop `gettext` from those five sites, matching `EnglishHook`'s own
  reasoning (`english_hook.ex:20-25` says as much: wrapping strings on these
  pages leaves them English anyway while the hook is there); or
* pin the locale for the `/m` scope in the pipeline, and wrap the template
  too - i.e. decide that the enrolment page is arbiter-facing (it is: the
  arbiter reads the code off their own screen) even though result entry is
  not.

`locale_test.exs:307-310` asserts only that the `mobile_results`
*live_session* is pinned. Nothing walks the mobile controller routes, which
is why this is invisible to the suite. Worth an assertion once the direction
is chosen - the shape of the test depends on the answer, so none is added
here.

## 4. `en/default.po` carried a translation of English into English - FIXED

`priv/gettext/en/LC_MESSAGES/default.po`, the entry for
`"Hide the initial standings from the public page again?"`, whose msgstr was
a byte-for-byte copy of its own msgid.

Harmless today and a time bomb: English renders from the msgid, so this is a
second copy of the source text that nothing keeps in step. Reword the msgid
and the duplicate stays behind - from then on English readers see the old
sentence and the extractor sees the new one, with no warning anywhere.
`translations_test.exs`'s own comments call this out ("never to fill it in")
and no test enforced it.

Emptied. `translations_test.exs` now asserts every msgstr in the source
locale is empty.

Note on the question in the brief - whether `en/default.po` matching the
`.pot` line for line is correct or accidental: it is expected. Both files
hold the same 1418 entries in the same order with one line per msgstr, so the
counts track by construction. It is **not** evidence of anything, and this
finding is the proof: the file was equal in length to the template the whole
time it carried a filled translation.

## 5. `W-We` was translated to `W-Wv` - FIXED

`standings_live.ex:801`.

`W-We` is FIDE's own symbol for score minus expected score. The Dutch
catalogue rendered it `W-Wv`, which is not a symbol anything else uses - and
the column immediately to its left is `We`, a bare literal at
`standings_live.ex:792` that no catalogue touches. Two adjacent headers, one
symbol, two spellings.

Dutch msgstr set back to `W-We`, which is how the other codes in the
catalogue are handled (`N-Elo`, `Elo`, `Cl.`, `bye` all have a msgstr
identical to the msgid).

The tidier long-term shape is to unwrap the call, so it matches `We` beside
it and the tie-break codes below it, which are rendered as `{code}`. That is
a source change and a msgid removal, so it is left as a suggestion.

## 6. A sentence tells the arbiter to look for a card that is not on the page - FIXED

`norms_live.ex:516`.

English: `Fill these in under "Officials & FIDE report data" above:` - and
the heading at `norms_live.ex:824` is exactly `Officials & FIDE report data`.

Dutch: `Vul deze hierboven in onder "Functionarissen & FIDE-rapportgegevens":`
- while the heading translates to `Officials & FIDE-rapportgegevens`. The
instruction named a section that does not exist on screen, in a red bar whose
whole job is to say where to go.

The quoted name now matches the heading. The wider inconsistency behind it -
`officials` is variously "functionarissen" and "officials" across the
catalogue - is left alone deliberately: the heading is "Officials", so the
cross-reference has to say "Officials", and unifying the rest is a
terminology decision rather than a bug. Listed under 14.

## 7. A tooltip points at a column called `Pl`, which does not exist - FIXED

`players_live.ex:1836`.

English: `Live tournament rank - click to sort by current standings rank
(same as Cl)`. The column is declared at `players_live.ex:49` as
`{"cl", "Cl", true, …}` and rendered as `<th class="num">Cl</th>` at
`:2540`. `Cl` is on `docs/i18n.md`'s deliberately-English list, so it stays
`Cl` in Dutch too.

The Dutch said `(zelfde als Pl)`. Fixed to `(zelfde als Cl)`.

## 8. Eleven strings address the arbiter as "u" in a catalogue that says "je" - FIXED

110 entries use the informal second person; 11 used the formal one. Not a
coherent grouping - Settings > Options has both registers on one screen, and
strings of equal gravity elsewhere ("jij weet welk van de twee dit is",
`settings_results_live.ex:586`) are informal. It reads as drift, so it was
brought to the majority. Every change, for review:

| source | was | now |
|---|---|---|
| `settings_options_live.ex:638` | `een regel te negeren die u hebt ingesteld` | `… die je hebt ingesteld` |
| `settings_options_live.ex:650` | `de keuze is aan u` | `de keuze is aan jou` |
| `settings_options_live.ex:1010` | `U kunt altijd terugschakelen` | `Je kan altijd terugschakelen` |
| `settings_options_live.ex:1018` | `Dat houdt u niet tegen` / `het antwoord dat u geeft` | `Dat houdt je niet tegen` / `het antwoord dat je geeft` |
| `settings_fide_live.ex:155` | `of u het naar de FIDE stuurt` | `of je het naar de FIDE stuurt` |
| `settings_support.ex:394` | `mag u draaien zoals u wilt` | `mag je draaien zoals je wilt` |
| `fide_live.ex:731` | `een beslissing voor u` | `een beslissing voor jou` |
| `tournaments_live.ex:1547` | `U kunt de engine per toernooi wijzigen` | `Je kan de engine per toernooi wijzigen` |
| `layouts.ex:445`, `:449`, `:460` | `uw toernooien worden apart bewaard` | `je toernooien worden apart bewaard` |
| `mobile_enroll_controller.ex:43` | `Voer uw code in.` | `Voer je code in.` |

If the preference is the other way - formal Dutch throughout - this is the
list to invert, and it is 11 strings against 110 rather than the reverse.

`%{n} u geleden` (`connection_status.ex:341`) is **not** in this set: that
`u` is the abbreviation for *uur*, and it is correct.

## 9. One concept, several Dutch names - FIXED

* **results site.** `uitslagensite` 34 times, `resultatensite` 4
  (`connection_status.ex:167`, `settings_results_live.ex:525`,
  `fide_live.ex:796`, `settings_support.ex:715`). All four moved to
  `uitslagensite`, which is also what the navigation and the printed pages
  say.
* **round robin.** `rondetoernooi` 10 times; `settings_support.ex:461` said
  `ronde-robin` twice in one sentence - a calque no Dutch federation uses.
  Moved.
* **rondes / ronden.** `rondes` 42 times, `ronden` once
  (`settings_support.ex:473`). Both are valid plurals; one of them is this
  application's. Moved.
* **the starting rank number.** `startnummer` in prose, `Startnr.` as the
  `Seed` column header, and `plaatsingsnr.` in the seed tooltip
  (`pairing_explain_live.ex:2134`) - three names for one number. The tooltip
  now says `startnr.`.

## 10. "een halve punt" - FIXED

`print_controller.ex:828`, `requested half-point bye` →
`aangevraagde bye van een halve punt`. As a score unit *punt* is neuter, so
it is *een half punt* - which is how the same catalogue writes it 3000 lines
earlier ("De meeste opens geven een half punt voor de eerste een of twee",
`settings_scoring_live.ex:261`). Fixed to `een half punt`.

This string prints on the absentees section of every pairing sheet that has
one.

## 11. A clause that said the opposite of the English - FIXED

`settings_fide_live.ex:155`. English:

> … and a rated event can be run however its arbiter chooses.

Dutch was:

> … en een verwerkt evenement mag zijn arbiter draaien zoals hij verkiest.

Dutch puts the verb second, so with *evenement* in front this parses as "a
rated event may run its arbiter" - subject and object swapped. Two smaller
problems in the same sentence: `rated` was rendered `verwerkt` ("processed")
here while the rest of the catalogue says `gerateerd` / `ingediend voor
rating`, and `to be rated` was `om verwerkt te worden`.

Now:

> … en een gerateerd evenement mag de arbiter draaien zoals die verkiest.

## 12. One imperative in a menu of infinitives - FIXED

The pairings context menu is infinitive throughout - `Wisselen met…`,
`Markeren als afwezig voor deze ronde`, `Op een lege plaats zetten`,
`Paren met een andere speler die niet speelt…`, `Dit bord verwijderen…` -
except `Award a bye to the remaining player`, which was
`Ken een bye toe aan de overblijvende speler`. Now
`Een bye toekennen aan de overblijvende speler`.

Two more of the same kind are left as suggestions, because they are headings
and disclosures rather than buttons and the right mood is arguable:
`Check for new entries` → `Controleer op nieuwe inschrijvingen`
(`registrations_live.ex:281`, an `<h2>` among noun-phrase headings) and
`Use a password instead` → `Gebruik in plaats daarvan een wachtwoord`
(`user_live/login.ex:170`, a `<summary>`).

## 13. Coverage holes the extractor cannot see - RECOMMENDED

`PrintController` was the documented case: HTML by concatenation, so two
gettext passes walked `~H` blocks and never saw it. The same shape of blind
spot is still open elsewhere. Every module below has **zero** `gettext`
calls unless noted, and every string listed renders in front of an arbiter.
None of them are fragments except where said.

### 13a. Worth wrapping

| where | what | note |
|---|---|---|
| `live/audit_live.ex:125-300` (`describe/2`) | ~59 sentences - *"Entered result %{…} on board %{…} (round %{…}): %{…}."* and so on | The entire readable content of the Audit page, built by interpolation. `docs/i18n.md` counts "audit" as wrapped; that covers the chrome (16 calls) and not the sentences. Each is a whole sentence with value-shaped holes, so they wrap cleanly as ordinary `%{}` bindings. **Biggest single hole.** |
| `pairings_engine/tiebreaks.ex:32-144` | 18 `description` strings | Prose an arbiter reads to choose a tie-break, on six screens. The `name` strings beside them are FIDE identifiers and belong with the codes. |
| `pairings_engine/tournaments/tournament.ex` | every label function (`type_label/1`, `exclusion_mode_label/1`, `soft_position_label/1`, `pairing_system_label/1`, `rr_cycles_label/1`, `publish_mode_label/1`) plus `missing_setup_fields/1` and `missing_recommended_fields/1` | Rendered on ~10 screens including the blocked-pairing banners. `"Ainalrami"` and `"JaVaFo (2017 rules)"` are engine names and stay; `"Swiss - FIDE Dutch"`, `"Round robin (Berger)"`, `"Single"`/`"Double"`, `"Strong - before the colour and float rules"` and the publish-mode sentences do not. |
| `pairings_engine/public_display.ex:41-193` | 27 toggle titles and descriptions | The whole "What the public page shows" surface. |
| `live/print_live.ex:19-58` | 8 document names + 8 descriptions | The link reads `Player cards` in English while the document it opens prints `Spelerskaarten`. |
| `controllers/tools_controller.ex` | 6 error sentences + its own HTML page (`<title>`, "Back to the arbiter tools"), and `<html lang="en">` hardcoded at `:130` | The `/tools/norms` LiveView is wrapped and on `LocaleHook`; the report-download path beside it is not. `print_controller.ex:1562` resolves the locale for its `lang` attribute - this one should too, independently of any wrapping. |
| `controllers/user_session_controller.ex` | 8 flashes, including `"Welcome back!"` and `"Logged out successfully."` | `docs/i18n.md` counts "the login pages" as wrapped. The LiveView half is; the controller half never was. |
| `controllers/keycloak_auth_controller.ex` | 6 flashes | Same. |
| `controllers/backup_controller.ex:60`, `:74` | 2 refusals | |
| `controllers/export_controller.ex:72` | `"Could not export TRF: %{message}"` | The only unwrapped refusal in a file whose other seven are wrapped. |
| `pairings_engine/norms/counts_breakdown.ex:22-23` | 2 group labels | `:25-29` are FIDE title names; leave those. |
| `live/pairings_live.ex:1324-1327`, `live/live_round_live.ex:444-447` | `bye_type_label/1` - the same three labels `print_controller.ex:828-830` wraps | The comment at `print_controller.ex:825` says it uses "same labels PairingsEngineWeb.PairingsLive uses". It no longer does: the printed sheet says "afwezig", the screen says "absent". |
| `print_controller.ex:934`, `:1008` | `<th class="num">Keizer pts</th>` | **Narrowest and most clearly wrong of these.** `msgid "Keizer pts"` already exists, translated (`Keizer-ptn`), because `standings_live.ex:923` wraps it. So a printed Keizer standings table shows one English header in a row where `Value` and `Score` beside it are Dutch. One-line fix; left out only because wrapping needs the `.pot` references updated to stay honest. |
| `print_controller.ex:337`, `:340`, `:342` | `Paid`, `Title`, `Sex` in `@player_list_columns` | All three already exist as translated msgids (`Betaald`, `Titel`, `Geslacht`) from the players screen, and `Sex` is wrapped 700 lines later in the same file (`standings_head_cells/0`). So the printed standings say "Geslacht" and the printed player list says "Sex". A module attribute is compile-time, so this needs the list to become a function first. |
| `live/players_live.ex:48-105` | the `title=` tooltip on ~33 columns | Also compile-time. Three of them are concatenated with unwrapped suffixes at `:1861-1863` (`" - right-click here to set Present/Absent for everyone"`). **Those suffixes are fragments.** Wrap the whole tooltip as one msgid per column with the suffix folded in - three extra msgids - not the suffix alone. |
| `pairing.ex`, `keizer.ex`, `round_robin.ex`, `publishing.ex`, `norms/combine.ex`, `federations/bel/parser.ex`, `federations/bel/api.ex`, `tournament_import.ex`, `trf_import.ex`, `tools/parser.ex` | `{:error, "sentence"}` prose that reaches a flash, a banner or the Connections panel | See 13b before touching these. |

### 13b. Read this before wrapping any of the error tuples

Three places pattern-match on the English text as control flow. Wrapping the
producer without turning the reason into an atom or a struct first changes
behaviour in Dutch, silently:

* `round_robin.ex:191` - `{:error, "All " <> _} ->`
* `publishing.ex:887` / `:890` - `{:error, "No address is set." = message}` and
  `"No token is set."`
* `publishing.ex:897` - `String.starts_with?(message, "Reached")`, which is
  what decides `:refused` (amber, "wrong secret") against `:unreachable`
  (red, "server is not there")

Finding 2 is the same coupling, already broken.

### 13c. Not a hole

`swar_publish.ex`'s literals are the SWAR wire format, `trf_export.ex`'s and
`swar_export.ex`'s are TRF/SWAR field identifiers, `norms/forms.ex`'s are
FIDE form fields. `error_html.ex` renders Phoenix's own
`status_message_from_template/1`. `fide_lookup_controller.ex` is a JSON API.
None of these are prose.

## 14. Smaller things, left as decisions

* **`swar_publish.ex` puts Dutch msgids in the shared `default` domain.**
  27 entries - `Organisator`, `Toernooi`, `Speeltempo`, `Datums`,
  `ngettext("Ronde", "Rondes", …)`, `Begin van de pagina`, `Eindstand`… -
  are wrapped, so they sit in the same catalogue as 1400 English ones, and
  the Dutch translation of each is the msgid unchanged. They are labels of a
  Belgian federation file format, not prose, and three of the same module's
  labels (`tournoi_type_label/1`) are bare literals - so the module is
  already inconsistent with itself. The KBSB is bilingual, which makes this
  more than theoretical: a French catalogue would be handed Dutch msgids and
  could break the format by translating them. A separate domain
  (`dgettext("swar", …)`) or no wrapping at all would both be clearer than
  this. Also note `Bye`, `Score`, `Elo` and `Punten` are msgids **shared**
  with `print_controller.ex`, so translating one surface translates the
  other.
* **The credit line has the personal name inside the msgid.**
  `print_controller.ex:1548` wraps `"Paired by OpenPairings using %{engine} ·
  many thanks to … for his valuable feedback."` as one string, so the name is
  in the Dutch msgstr. `settings_about_live.ex:107` does the same sentence the
  documented way, with a `%[who]` part. `docs/i18n.md` describes only the
  second. Copy it.
* **`Deputy` is untranslated as a phone access level.** `live_round_live.ex:139`
  and `:569`. `Helper` beside it happens to be a Dutch word; `Deputy` is not,
  and the same concept is `Hulparbiter` on the Norms page and the printed
  documents. It is a coined role name for this feature, so it may be
  deliberate - but it is the one entry in the untranslated-but-identical set
  that is neither a code nor a loanword.
* **`%[count] tournament(s) waiting to be sent.`** (`fide_live.ex:857`)
  renders `%[count] toernooi(en) wachten` - a singular noun with a plural
  verb. The English hedges with `(s)` where the two entries above it use
  `ngettext`; making this one a plural too fixes both languages.
* **`leg`** (`pairing_explain_live.ex:2035`) is `ontmoeting`, which normally
  means the whole encounter rather than one game of it. `partij` or `deel`
  would be closer. Low confidence - the surrounding text carries the meaning.
* **`het token` vs `de token`.** The catalogue consistently says `de token`;
  the dictionary prefers `het`. Internally consistent, so left alone.
* **`kan` vs `kunt`.** `je kan` 5, `je kunt`/`kun je` 2. Cosmetic.
* **`Dates` is `Data` in the navigation and `Datums` on the SWAR page.**
  The second is a format label, so this is only half an inconsistency.
* **`en/errors.po` declares no `Plural-Forms` header** while
  `en/default.po` does. Inert - its msgstrs are empty and Gettext knows
  English - but asymmetric. `translations_test.exs` now requires the header
  for every locale except the source one, which leaves this alone
  deliberately.
* **Three msgids are sentence fragments split across calls**, against
  `docs/i18n.md`'s "never wrap a fragment to raise the count". All three
  happen to read correctly in Dutch, which is luck rather than design, and
  all three want `rich_text` or a binding instead:
  * `pairings_live.ex:2160-2161` - `<strong>{gettext("Right-click any
    player")}</strong> {gettext("to swap them, or to mark them absent for
    this round.")}`. The textbook `rich_text` case.
  * `registrations_live.ex:342-345` - `{gettext("This tournament has no
    round")} {round list} - {gettext("that part of the request will be
    dropped.")}`. One sentence in three pieces; wants
    `"This tournament has no round %{rounds} - that part of the request will
    be dropped."`.
  * `players_live.ex:2244` - `ngettext("- apply this?", "- apply these?")`
    appended after an interpolated list. The leading `- ` is the giveaway.

---

## What was checked and found clean

An absence of findings means nothing unless it is stated, so:

**Catalogue integrity.** 1418 messages in `default`, 24 in `errors`. The
msgid sets (with msgctxt) of `default.pot`, `en/default.po` and
`nl/default.po` are **identical**, and so are the three `errors` ones - no
message present in one and missing from another, in either direction. The
`#:` source references agree with the template for every entry. Zero
obsolete `#~` entries in any of the six files. Zero duplicate msgids. Zero
`fuzzy` flags. The only flags present are `elixir-autogen` and
`elixir-format`, on all 1418. Now guarded by two new tests.

**Binding mismatches.** Zero, in both directions, for both placeholder
kinds. Verified three ways: `%{}`/`%[]` set equality between msgid and
msgstr (already pinned by `locale_test.exs` and `translations_test.exs`, and
re-checked independently here); `<:part name=…>` against the msgid's `%[…]`
at all **56** `rich_text` call sites in `lib/`, which match exactly; and -
the direction no test covers - every msgid placeholder against what the
caller actually binds, over **229** call sites. The 25 apparent misses are
all `count` on an `ngettext/3`, which binds it from its own third argument.
No `missing Gettext bindings` is being logged.

**The `%[...]` vs `%{...}` rule.** Held. No msgid mixes them up, no Dutch
msgstr renamed or dropped a part name. Worth knowing what the failure would
look like: `rich_text/1` renders an unmatched `%[name]` as literal visible
text (deliberate, `core_components.ex:518`), but a **part with no matching
placeholder is dropped silently** - so a translator who deletes `%[players]`
makes the link vanish with no error, no log and no trace. The nine-part
sentence at `pairings_live.ex:2105` is the one to be careful with.

**Double-escaped entities.** Zero HTML entities (`&amp;`, `&middot;`,
`&rarr;`, `&nbsp;`, numeric) anywhere in any msgid, msgid_plural or msgstr in
any of the six files, and zero raw markup (`<tag`) either. Both directions
checked: the HEEx path holds the real character (`&` in "Norms & FIDE
reports", `·` in "Round %{round} · Board %{board}", `→` in "Settings →
Export / backup") and the `PrintController` path does too. Now guarded by a
test, templates included.

**Plural forms.** 27 plural messages in `default`, 9 in `errors`.
`nl/default.po` and `nl/errors.po` both declare
`nplurals=2; plural=(n != 1);`, which is right for Dutch. Every
`msgstr[0]`/`msgstr[1]` is filled, and each singular form is genuinely
singular and each plural genuinely plural - read individually, not counted.
No form beyond `[1]` anywhere. `errors.po`'s nine are Ecto's own validation
messages and are correct down to "moet %{count} teken lang zijn" /
"tekens".

**Untranslated-but-not-empty.** 63 entries have a Dutch msgstr byte-identical
to the msgid. 61 are legitimate: the codes and loanwords `docs/i18n.md` lists
(`Elo`, `N-Elo`, `bye`, `Tiebreaks`, `Ctrl+I`, `Pipe |`, `Tab`), words Dutch
spells the same (`Club`, `Status`, `Type`, `Score`, `Norm`, `Logo`, `Master`,
`Account`, `Live`, `Offline`, `Updates`, `Token`, `Document`, `Gratis`,
`mild`), product names (`OpenResults`, `magic link`), placeholder-only strings
(`%{pairs}, over %{edges}`, `%{name} (bye)`), and the 27 SWAR results-page
labels whose msgid is already Dutch. The two that were not: `W-We`
(finding 5, fixed) and `Deputy` (finding 14).

**Opposite-meaning pairs.** 30 pairs enumerated from the catalogue and read
individually: confirm/cancel, accept/decline, accept/discard,
publish/remove-from-site, show/hide, hide/unhide, on/off, turn-on/turn-off,
enable/disable, add/remove, archive/unarchive, lock/unlock, up/down,
float-up/float-down, paired-up/paired-down, yes/no, keep/use, give-back/hand-off,
previous/following, restore/delete, start-fresh/take-over, open/close,
allowed/forbidden, white/black, win/loss, present/absent, paid/free,
public/not-public, listed/unlisted, save/discard. **All correct**, including
the pair that was wrong in the 2026-08-29 pass: `Use JaVaFo` is
`JaVaFo gebruiken` and `Keep Ainalrami` is `Ainalrami behouden`.

**Chess vocabulary.** Read as prose, in blocks, against the source
references. It is good, and specifically it is *Dutch chess* rather than
translated English: `scoregroep` for bracket, `doorschuiver` /
`doorschuiven` for floater, `startnummer`, `kleurbalans`,
`transpositievolgorde`, `trede` for rung, `revanche` for rematch, `remise`,
`forfait`, `notatiebriefjes` for score sheets, `kruistabel`,
`plaatskaartjes`, `Bergertabellen`, `aan de beurt` for due, `stand` /
`eindstand`, `paringsblad`, `verboden paringen`, `bordnummer`. The FIDE
article references (C.04.3, C.07, 5.2.5, B.01) and rule language survive
intact. The findings above are drift and slips, not a translator who did not
know the game.

**The router.** 8 `live_session`s, all with a locale hook: seven on
`LocaleHook`, only `mobile_results` on `EnglishHook`. No arbiter-facing page
behind `EnglishHook`, no player-facing page behind `LocaleHook`.
`Plugs.Locale` is in the `:browser` pipeline once and not in `:api`, which is
right. The pin is still deliberate and `english_hook.ex` still says why. The
hole is the controller route in finding 3, not a misplaced session.

**Runtime-computed msgids.** None, apart from Phoenix's stock
`translate_error/1` at `core_components.ex:614-616`, which passes an Ecto
changeset message into the `errors` domain - and that domain's catalogue is
maintained by hand for exactly that reason. Zero cases of
`gettext("…#{…}…")`, and zero cases of a variable, module attribute,
function call or `case` result as a msgid anywhere else in `lib/`. The two
`~s()` msgids (`categories_live.ex:711`, `pairings_live.ex:2049`) are
compile-time binaries and are extracted; both are in the Dutch catalogue.

---

## What only a person can confirm

Switch to Dutch (the picker is in the top bar) and walk these. Everything
above is either mechanical or a reading; none of it is the app on a screen.

1. **Settings > Options, engine section.** The `4%%` fix: both the hint
   under JaVaFo and the body of the "Switch to JaVaFo?" confirmation should
   read "ongeveer 4% van de rondes". Check the English too.
2. **The same confirmation's two buttons.** `JaVaFo gebruiken` must be the
   one that switches and `Ainalrami behouden` the one that does not. This is
   the pair that shipped inverted once.
3. **Print a pairing sheet with an absentees section**, in Dutch, for a
   tournament with a requested half-point bye. Expect "aangevraagde bye van
   een half punt". While there, check the standings and the player list print
   in Dutch throughout - and note the headers that are deliberately English
   (`Pr.`, `Nr`, `Fed`, `Cl`, `Pts`) so they are not reported as gaps.
4. **Print a Keizer standings table.** Finding 13a: the `Keizer pts` column
   header is expected to be English today, among Dutch neighbours. Confirm
   whether that is as jarring on paper as it looks in the source.
5. **Connections page, in Dutch, with a results site configured.** Finding
   2: expect a Dutch headline with an English sentence under it, the first
   words repeating the headline. Then break the token and reload - every
   state does the same thing.
6. **Norms page with an official missing a FIDE ID.** The red bar should
   name the card exactly as the card is headed: "Officials &
   FIDE-rapportgegevens".
7. **Players page, hover the `Cl` column header's neighbour.** The live-rank
   tooltip should say "zelfde als Cl".
8. **The standings header row.** `We` and `W-We` should now be spelled the
   same way as each other.
9. **`/m` on a phone, with the browser set to Dutch.** Finding 3: the card
   is English; make one error happen (a wrong code) and the error line comes
   back Dutch.
10. **The Audit page.** Finding 13a: the chrome is Dutch and every sentence
    in the list is English. Worth seeing before deciding how much of it to
    wrap.
11. **The update banner** (needs a release to be out, or a forced state).
    Three strings there moved from "uw toernooien" to "je toernooien" -
    check they still read naturally in a banner.
12. **Settings > Scoring and Settings > Dates end to end.** Long
    explanatory paragraphs, translated well as far as reading goes, but they
    are the densest prose in the application and worth one pass with the
    screen in front of you.
