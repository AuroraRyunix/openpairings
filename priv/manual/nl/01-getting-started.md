# Aan de slag

Dit hoofdstuk legt uit wat OpenPairings is, hoe je het installeert en start, en
hoe het programma is opgebouwd. De andere hoofdstukken volgen de volgorde
waarin een arbiter werkt: het toernooi instellen, de spelers invoeren, een
ronde paren, de resultaten invoeren, afdrukken, rapporteren.

## Wat het programma doet {#what-the-program-does}

OpenPairings beheert een schaaktoernooi van de opzet tot het rapport voor het
rating-bureau:

- Het paart Zwitserse toernooien (FIDE Dutch-systeem, C.04.3), Zwitserse
  ploegentoernooien (C.04.6), rondetoernooien (Berger-tabellen, C.05) en
  Keizer-toernooien.
- Het houdt de spelers, de resultaten, de byes en de rangschikking bij, met de
  tiebreaks van FIDE's C.07.
- Het drukt de lijsten af die een arbiter nodig heeft (paringen, rangschikking,
  resultaatkaarten, kruistabellen, spelerskaarten, plaatskaartjes).
- Het leest en schrijft het FIDE-rapportbestand (TRF26, TRF16), en leest
  SWAR-bestanden.
- Het kan een toernooi publiceren op een publieke uitslagensite (OpenResults),
  zodat spelers en toeschouwers het evenement op hun telefoon kunnen volgen.

> [!FIDE] FIDE-modus
> Standaard wordt een toernooi behandeld zoals de paringsregels van FIDE
> voorschrijven. Dit heet de FIDE-modus en wordt beschreven in
> [FIDE-modus](02-fide-mode.md).

## Twee manieren om het te gebruiken {#two-ways-to-run-it}

**Op je eigen computer (de desktopversie).** Eén persoon gebruikt het
programma op één computer. Er is geen aanmelding: het programma start, opent
je webbrowser op `http://localhost:4000` en je bent aangemeld als eigenaar van
die computer. Je toernooien worden op die computer opgeslagen. Het programma
is alleen bereikbaar vanaf die computer, nooit via het netwerk.

**Op een server (de onlineversie).** Het programma draait op een server en je
bereikt het via een webadres. Iedereen heeft een account, elk toernooi behoort
toe aan de eigenaar, en de eigenaar kan andere arbiters uitnodigen om het te
delen (zie [Accounts, delen en overdracht](15-accounts-and-handoff.md)).

Alles wat in deze handleiding staat, werkt in beide. De verschillen worden
vermeld waar ze ertoe doen: aanmelden en accounts bestaan alleen online; de
updatemelding, de datamap en de "lokale weergave" van de live pagina horen bij
de desktopversie.

## De desktopversie installeren {#installing-the-desktop-build}

Download de release voor je systeem van de releasepagina van het project.

**Windows.** Het `.msi`-bestand is de aanbevolen download. Het toont een
installatieprogramma met een welkomstpagina, de licentie en de keuze tussen
installeren alleen voor jezelf (geen beheerdersrechten nodig) of voor iedereen
op de computer. Het `Setup.exe` ernaast installeert meteen voor jezelf, zonder
vragen. Start na de installatie *OpenPairings* vanuit het Startmenu. Er opent
een klein venster en je browser volgt; als je dat kleine venster sluit, stopt
het programma.

> [!TIP]
> Verwijdert je antivirus het losse bestand, gebruik dan de *draagbare* release:
> pak die uit en dubbelklik op `OpenPairings.exe` in de map.

**Linux.** Download het draagbare archief en pak het uit. Voer
`./openpairings.sh` uit (het bestand moet eenmalig uitvoerbaar worden gemaakt:
`chmod +x openpairings.sh`). Het programma opent je browser.

**macOS.** Download `openpairings_app_macos_aarch64.zip` voor een Mac met een
Apple-chip (M1 en later; voor oudere Macs met Intel is er geen versie), open het bestand en sleep *OpenPairings* naar *Programma's*. De app
is nog niet door Apple ondertekend, dus de eerste keer weigert macOS hem te
openen: open *Systeeminstellingen*, *Privacy en beveiliging*, scrol naar
beneden en klik op *Open toch* (*Open Anyway*) naast de melding over
OpenPairings (op macOS 14 of ouder: klik met de rechtermuisknop op de app en
kies *Open*). Daarna opent hij zoals elke andere app. Een klein venster meldt
dat OpenPairings draait en je browser volgt; *Stop OpenPairings* in dat venster
stopt het programma (dat venster is in het Engels). Om bij te werken stop je
het programma, download je de nieuwe zip en vervang je de app in
*Programma's*.

Er is geen Java en geen databaseserver nodig. De Zwitserse paringsengine
(Ainalrami) zit in het programma (zie [Een ronde paren](06-pairing.md)).

### Waar je gegevens staan {#where-your-data-is}

De toernooien staan in één databasebestand in een map van je gebruikersaccount:

- Windows: `%LOCALAPPDATA%\OpenPairingsData`; back-ups in
  `%LOCALAPPDATA%\OpenPairingsBackups`.
- macOS: `~/Library/Application Support/OpenPairings`.
- Linux: `~/.local/share/OpenPairings`.

> [!NOTE]
> Het verwijderen van het programma laat deze gegevens staan.

Het programma maakt ongeveer één keer per dag een back-up van zijn gegevens
(zie "Back-ups" in [Accounts, delen en overdracht](15-accounts-and-handoff.md)).

### Updates {#updates}

Een desktopkopie controleert bij het starten en daarna elke paar uur of er een
nieuwere release bestaat, en toont een melding bovenaan de pagina.

> [!NOTE]
> Het programma installeert nooit zelf iets, en nooit midden in je beslissing:
> een nieuwe versie kan een nieuwere paringsengine bevatten, dus je kiest het
> moment (niet tijdens het spelen van een ronde).

Bij een installatie per gebruiker op Windows heeft de melding een knop
*Installeren en herstarten*; bij de andere installaties verwijst ze naar de
releasepagina. De controle kan worden uitgeschakeld op de pagina Verbindingen.

## De eerste start {#the-first-start}

Open het programma. De eerste pagina is **Toernooien**: de lijst van je
toernooien (aanvankelijk leeg), met *Nieuw toernooi* en de importknoppen.

![De pagina Toernooien met enkele toernooien en de knoppen Nieuw toernooi en importeren bovenaan](screenshots/01-tournaments-list.png "De pagina Toernooien")

De balk bovenaan elke pagina bevat:

- **Toernooien** - de lijst van je toernooien.
- **Hulpmiddelen** - de openbare arbiterhulpmiddelen (normrapporten uit
  geüploade bestanden).
- **Wijzigingen** - wat er in elke release is veranderd.
- **Help** - deze handleiding. Binnen een toernooi opent ze bij het hoofdstuk
  dat past bij de pagina waarop je bent.
- De kleuraccent, de taalkeuze (Engels en Nederlands) en het thema (Systeem,
  Licht, Donker, Leisteen, Papier, Bord, Tom W, Jorian, Hoog contrast).
- Het accountmenu, met *Instellingen* (online), *Functies* en *Afmelden*
  (online), en het versienummer.

Binnen een toernooi toont de balk de eigen tabbladen van het toernooi:

| Tabblad | Waarvoor het dient |
| --- | --- |
| Spelers | de inschrijvingen, ratings, aanwezigheid en het spelersrooster |
| Ploegen | (alleen ploegentoernooien) ploegen, selecties, bordvolgorde |
| Paringen | een ronde paren, resultaten invoeren, handmatige wijzigingen |
| Stand | de rangschikking en de tiebreakkolommen |
| Afdrukken | alle afdrukbare documenten |
| Geavanceerd | Normen, Geschiedenis (herstelpunten), Auditlogboek, Paringsverantwoording, Badges |
| Instellingen | de instellingen van het toernooi (meerdere pagina's) |

![De tabbalk binnen een toernooi, met Spelers, Paringen, Stand, Afdrukken, Geavanceerd en Instellingen](screenshots/01-tournament-tabs.png "De tabbladen van het toernooi")

*Verbindingen* (de ratinglijsten, back-ups, het publicatieadres) verschijnt in
de balk op de pagina Toernooien, voor de beheerder van de installatie. Op een
desktopversie bent dat altijd jij.

## Een eerste toernooi in het kort {#a-first-tournament-in-short}

1. Toernooien, **Nieuw toernooi**: naam, paringssysteem, rondes, plaats,
   startdatum, speeltempo. **Toernooi aanmaken**.
2. Instellingen, **Data**: vul een datum in voor elke ronde (geen enkele ronde
   kan worden gepaard zolang niet elke ronde een datum heeft).
3. Instellingen, **Toernooi**: controleer de tiebreaks en de functionarissen.
4. **Spelers**: voeg de spelers toe (doorzoek de FIDE-lijst of typ ze in).
5. **Paringen**: **Ronde 1 paren**.
6. Voer de resultaten in op de pagina Paringen. Wanneer elk bord een resultaat
   heeft, paar je de volgende ronde.
7. **Stand**, **Afdrukken** wanneer nodig.
8. Na de laatste ronde: Instellingen, **Exporteren**, stuur het TRF-bestand naar
   het rating-bureau (zie [Versturen naar FIDE](11-fide-report.md)).

De volgende hoofdstukken leggen elke stap volledig uit.

## Taal {#language}

De pagina rond de handleiding en het hele programma zijn beschikbaar in het
Engels en het Nederlands (keuzelijst in de bovenbalk; online volgt de keuze
je account). Deze handleiding bestaat in het Engels en het Nederlands en volgt de taal die
je kiest.

## Toetsenbord en toegankelijkheid {#keyboard-and-accessibility}

Elke actie is een knop of een link en is met het toetsenbord bereikbaar. Het
invoeren van resultaten is ontworpen voor het toetsenbord (zie
[Resultaten](07-results.md)): klik op het resultaatveld van het eerste bord en
typ dan <kbd>1</kbd> voor een winst voor Wit, <kbd>2</kbd> voor remise en
<kbd>3</kbd> voor een winst voor Zwart; met de pijltjestoetsen loop je door de
andere waarden. Het spelersrooster heeft eigen toetsenbordbediening (zie
[Spelers en ratinglijsten](04-players-and-ratings.md)): <kbd>Ctrl</kbd>+<kbd>I</kbd>
voegt een speler toe, de pijltjestoetsen bewegen tussen de cellen,
<kbd>Space</kbd> of <kbd>Shift</kbd>+<kbd>F10</kbd> opent het menu van een cel,
en <kbd>Enter</kbd> of <kbd>Space</kbd> op de naam van een speler opent het
inschrijfformulier.

Het programma volgt het kleurenschema dat je kiest: *Systeem* volgt de lichte of
donkere instelling van de computer, en de themakeuze biedt daarnaast Licht,
Donker, Leisteen, Papier, Bord, Tom W (koningsblauw met een hemelsblauw accent),
Jorian (de look van de projectwebsite: een koningsblauwe pagina met witte
tekst en gele knoppen) en Hoog contrast. De live pagina heeft een eigen modus met hoog contrast.
