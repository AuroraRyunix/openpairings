# OpenResults: de publieke uitslagensite

OpenResults is de alleen-lezen site waar toeschouwers een toernooi volgen: de
paringen, de uitslagen, de stand, een kruistabel, een kaart voor elke speler
en, in de zaal, de schermen aan de muur. Niemand heeft een account nodig, en de
site rekent niets zelf uit. Ze toont wat de computer van de arbiter stuurt, dus
de arbiter bepaalt wat openbaar is en wanneer. Dit hoofdstuk beschrijft wat een
toeschouwer ziet en wat de arbiter regelt. Hoe een toernooi vanuit OpenPairings
naar de site gaat, staat in [Publiceren](14-publishing.md).

## Wat OpenResults is {#what-openresults-is}

OpenResults is een apart programma naast OpenPairings. De computer van de
arbiter is de enige schrijver. De standen komen al berekend binnen, met de
tiebreaks die de arbiter koos, en de site toont ze zoals ze zijn. Heeft de
arbiter de volgorde met de hand gezet, dan zegt de pagina dat. De site moet
altijd overeenkomen met wat er in de zaal gebeurt, en ze houdt zelf geen
toernooitoestand bij.

Omdat de openbare pagina's alleen gelezen worden, kan een drukke pagina een
paringssessie niet storen. Een laptop in een zaal met een slechte verbinding kan
blijven paren. De openbare kopie haalt de zaal in zodra de verbinding terug is.

## Hoe een toernooi op de site komt {#how-a-tournament-gets-there}

Er gaat niets naar OpenResults tot de arbiter het publiceren voor het toernooi
aanzet, in OpenPairings. De arbiter koppelt de uitslagensite één keer en kiest
daarna voor elk toernooi **Uit**, **Alleen link** of **Op de voorpagina**. Zie
[Een uitslagensite verbinden](14-publishing.md#connecting-a-results-site) en
[Een toernooi publiceren](14-publishing.md#publishing-a-tournament).

Zodra een ronde gepubliceerd is, verandert ze op de site niet meer. De site
bewaart haar lang, zodat een pagina die al geladen is, snel blijft.

## Wat toeschouwers zien {#what-spectators-see}

### De standpagina {#the-standings-page}

De standpagina is de voorkant van een toernooi. Ze toont de stand in de
volgorde die de arbiter koos, met de kolommen en tiebreaks die de arbiter
toestond. Bij een tiebreakwaarde kan men openklappen om de berekening te zien:
de tegenstander van elke ronde en de waarde ervan. Vóór ronde 1 toont de pagina
de startrangschikking van de ingeschreven spelers, in plaats van een lege tabel.

De tabel kan op elke kolom gesorteerd worden en gefilterd op club, federatie of
categorie, allemaal in de browser. Een filter op club of federatie blijft in het
adres staan, zodat een link gekopieerd en gedeeld kan worden. De pagina ververst
zichzelf ongeveer elke 20 seconden, zonder de hele pagina opnieuw te laden.

De voorpagina zet de toernooien op de site in drie groepen: lopend, aankomend en
afgelopen. Ze is doorzoekbaar.

### Ronden en paringen {#rounds-and-pairings}

Elke gepubliceerde ronde heeft een eigen pagina, met de paringen en, wanneer de
arbiter dat toestaat, de uitslagen naarmate ze binnenkomen. Een uitgesteld
spel wordt als zodanig gemarkeerd. Hoeveel van een ronde openbaar is, bepaalt de
arbiter, ronde per ronde: zie
[Wat het publiek ziet, ronde per ronde](14-publishing.md#what-the-public-sees-round-by-round).

### De kruistabel {#the-cross-table}

De kruistabel heeft een rij per speler en een kolom per ronde. Bij een
ploegen-Zwitsers staat er ook een tabel met een rij per ploeg. Ze verschijnt
alleen voor de rondes die de openbare stand al weerspiegelt, zodat ze nooit
vooruitloopt op de stand.

### Spelerskaarten {#player-cards}

Elke speler heeft een kaart. Een naam in een tabel is een link naar de kaart.
Een speler die in meer dan één toernooi op dezelfde site speelde, heeft ook een
geschiedenispagina, gezocht op FIDE-id, en die is vanaf de kaart bereikbaar
wanneer er een id is. Ratings, titels, federaties en clubs staan alleen op de
kaart wanneer de arbiter ze toont.

### Ploegen {#teams}

Een ploegentoernooi heeft een lijst van ploegen, een pagina per ploeg met de
wedstrijden, en een pagina per ronde met de ploegwedstrijden. Ploegen worden met
hun volledige naam getoond. Wanneer OpenPairings een ploegrating meestuurt, staat
die in de ploeglijst in een kolom *Rating*.

### Het zaalscherm en de beamerweergave {#the-hall-display-and-the-projector-view}

Voor een televisie of beamer in de speelzaal zijn er twee schermvullende
pagina's, die vanaf de stand-, kruistabel- en rondepagina's bereikbaar zijn.

Het **zaalscherm** wisselt pagina per pagina: de paringen van de nieuwste ronde,
een lijst *Zoek je bord* met alle spelers op alfabet, de uitslagen naarmate ze
binnenkomen, de stand, en de mededeling van de arbiter. Een weergave waar niets
te tonen is, wordt overgeslagen. Zolang een nieuwe ronde nog geen uitslag heeft,
blijft het scherm op de paringen, de naamlijst en de mededeling staan. De
weergaven, het aantal seconden per pagina, het aantal standregels en de
mededeling worden in OpenPairings ingesteld, zie
[Het zaalscherm](14-publishing.md#the-hall-display).

De **beamerweergave** toont alleen de paringen van de nieuwste ronde, in grote
letters. Ze volgt een nieuw gepubliceerde ronde en de uitslagen naarmate ze
binnenkomen, zonder herladen.

Op beide schermen is er een knop Volledig scherm (of de toets <kbd>F</kbd>) en
drie kleurkeuzes: Zwart, de standaard; Wit; en Ultra contrast, puur zwart en wit
met vette lijnen. De keuze wordt onthouden in die browser. Het adres kan de kleur
en de weergaven voor een scherm zonder keuzemenu vastleggen, bijvoorbeeld
`?theme=white` of `?views=names,pairings`.

> [!NOTE] Nooit meer dan de openbare pagina's
> De zaalschermen volgen dezelfde regels als de openbare pagina's. Er verschijnen
> geen paringen zolang de arbiter ze achterhoudt, en geen uitslag uit een ronde
> waarvan de uitslagen niet openbaar zijn.

### Talen en thema's {#languages-and-themes}

De pagina's zijn in het Engels, Nederlands en Frans. Er is een taalkeuze op de
pagina's, en het adres kan de taal ook instellen, bijvoorbeeld `?lang=nl`. De
keuze staat in het adres, zodat een link zijn taal behoudt. De pagina's hebben
ook een keuze voor het thema, die in de browser onthouden wordt. Bij het
afdrukken zijn de rondes en de kruistabel altijd zwart op wit, wat thema ook
gekozen is.

### Afdrukken, feeds en insluiten {#printing-feeds-and-embedding}

Elke pagina kan vanuit de browser worden afgedrukt. Elk toernooi heeft een
Atom-feed, met een item telkens wanneer de paringen, de uitslagen of de stand
van een ronde openbaar worden, zodat een feedlezer elk item één keer toont.

Een pagina kan ook met `?embed=1` in een andere site worden ingesloten. De eigen
koptekst en voettekst van de site vallen dan weg, en één link terug naar de volledige
pagina blijft staan. Welke sites de pagina's mogen tonen, bepaalt wie de
uitslagensite beheert.

### Een pagina melden {#reporting-a-page}

Elke toernooipagina heeft een link **Deze pagina melden**. Een melding heeft een
reden (verkeerde of valse uitslagen, persoonsgegevens, spam of aanstootgevende
inhoud, of iets anders), tot 2000 tekens toelichting, en een optioneel
contactadres. Een bezoeker kan vijf meldingen per tien minuten sturen. Een
melding blijft bewaard wanneer het toernooi van de site gehaald wordt.

## Wat de arbiter regelt {#what-the-arbiter-controls}

Alles wat een toeschouwer ziet, komt van de computer van de arbiter, dus de
arbiter regelt het vanuit OpenPairings. De site kan niet meer tonen dan er
verstuurd is.

| Wat | Waar in OpenPairings |
| --- | --- |
| Of een toernooi gepubliceerd is, en of het vermeld wordt | [Een toernooi publiceren](14-publishing.md#publishing-a-tournament) |
| Welke rondes openbaar zijn, en hoe ver (paringen, uitslagen, standen) | [Wat het publiek ziet, ronde per ronde](14-publishing.md#what-the-public-sees-round-by-round) |
| Automatisch publiceren, en de vertraging ervan | [Automatisch publiceren](14-publishing.md#automatic-publishing) |
| Ratings, titels, federaties, clubs, categorieën, spelerskaarten en de tiebreakkolommen | [Wat de openbare pagina toont](14-publishing.md#what-the-public-page-shows) |
| De startrangschikking vóór ronde 1 | [Wat de openbare pagina toont](14-publishing.md#what-the-public-page-shows) |
| De zaalschermen: weergaven, seconden per pagina, mededeling | [Het zaalscherm](14-publishing.md#the-hall-display) |
| Inschrijvingen voor het toernooi | [Inschrijvingen via de uitslagensite](14-publishing.md#entries-through-the-results-site) |
| Naar een nieuw adres verhuizen, of het toernooi van de site halen | [Het adres](14-publishing.md#the-address) |

Drie dingen volgen uit de manier waarop de site gebouwd is:

- **Een verborgen kolom behoudt haar volgorde.** Een tiebreakkolom verbergen
  verandert de volgorde die ze beslist niet. Wanneer de volgorde een verborgen
  tiebreak gebruikte, zegt de pagina dat.
- **Een achtergehouden ronde ontbreekt.** Een ronde die de arbiter niet
  gepubliceerd heeft, of een uitslag die hij achterhoudt, wordt helemaal niet naar
  de site gestuurd. Ze wordt niet op de pagina weggefilterd.
- **Een volgorde met de hand wordt aangegeven.** Heeft de arbiter de volgorde met
  de hand gezet, dan zegt de stand dat.

## Inschrijvingen {#entries}

De uitslagensite kan inschrijvingen voor een toernooi aannemen. Een inschrijving
gaat naar een wachtrij op de site. Ze schrijft de speler niet zelf in: de arbiter
haalt de wachtrij op in OpenPairings en beslist wie erin komt. Inschrijvingen
worden alleen aanvaard voor een toernooi dat al gepubliceerd is, en het formulier
houdt op wanneer de arbiter het sluit of het maximum bereikt is. De instellingen
van de arbiter staan in
[Inschrijvingen via de uitslagensite](14-publishing.md#entries-through-the-results-site).

## Privacy en beperkingen {#privacy-and-limits}

- **De leespagina's zetten geen cookies.** Er is geen account, geen sessie en geen
  cookiemelding nodig. Een taal die in het adres gekozen wordt, staat in het adres.
  Een kleur of thema dat op een pagina gekozen wordt, wordt in de browser
  onthouden.
- **Namen, bordnummers, uitslagen en plaatsen worden altijd getoond.** Een toernooi
  dat die niet mag tonen, moet niet gepubliceerd worden. Zie
  [Alleen link is geen privacy](14-publishing.md#publishing-a-tournament).
- **Persoonsgegevens worden beperkt bewaard.** De termijnen staan op de
  voorwaardenpagina van de site. Standaard blijven inschrijvingen bewaard tot 30
  dagen na het einde van het toernooi, het contactadres van een melding 90 dagen
  na de afhandeling ervan, en het adres van een melder 30 dagen.
- **Een pagina kan even achterlopen.** Een gepubliceerde ronde verandert niet, en
  de standpagina ververst ongeveer elke 20 seconden, dus een uitslag kan even op
  zich laten wachten.
- **Een site die uitvalt, stopt de zaal niet.** Paren en uitslagen invoeren gaat in
  OpenPairings door, of de site nu antwoordt of niet.
