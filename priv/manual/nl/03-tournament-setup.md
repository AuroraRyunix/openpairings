# Een toernooi aanmaken en de instellingen

Dit hoofdstuk behandelt het formulier Nieuw toernooi en elke instellingenpagina,
behalve de publicatiepagina ([Publiceren](14-publishing.md)), de exportpagina
([Importeren en exporteren](10-import-export.md),
[Versturen naar FIDE](11-fide-report.md)) en Categorieën
([Categorieën en normen](13-categories-and-norms.md)).

## Een toernooi aanmaken {#creating-a-tournament}

Toernooien, **Nieuw toernooi**.

| Veld | Betekenis |
| --- | --- |
| Naam | Verplicht. |
| Paringssysteem | **Zwitsers - FIDE Dutch**, **Rondetoernooi (Berger)** of **Keizer**. Het kan niet worden veranderd nadat de eerste ronde is gepaard. |
| Rondes | 1 tot 99. Een rondetoernooi berekent zelf het aantal rondes uit de spelers en de cycli. |
| Aantal keer dat iedereen tegen iedereen speelt | (alleen rondetoernooi) 1 tot 10. |
| Ploegentoernooi | Maakt er een ploegenevenement van: Zwitserse ploegen (FIDE C.04.6) of rondetoernooi-ploegen. Keizer kan geen ploegentoernooi zijn. Zie [Ploegen](12-teams.md). |
| Plaats | De stad. |
| Datum vanaf | Vult elke ronde met deze datum; verfijn dit op de pagina Data. |
| Speeltempo | Een lijst met de gebruikelijke bedenktijden voor het gekozen formaat, of *geen*. |
| Formaat | Standaard, Rapid of Blitz. Dat bepaalt welke bedenktijden worden aangeboden, uit welke FIDE-rating de ratings van de spelers worden ververst, en het type rapport. |

![Het formulier Nieuw toernooi met naam, paringssysteem, rondes, plaats, startdatum en speeltempo](screenshots/03-new-tournament-form.png "Het formulier Nieuw toernooi")

Het formulier begint met je standaardwaarden (pagina Account, *Nieuwe
toernooien*: systeem, rondes, formaat, speeltempo, plaats, organisator,
publicatiemodus). Het toernooi wordt aangemaakt in de FIDE-modus
([FIDE-modus](02-fide-mode.md)).

Andere manieren om een toernooi te starten: **Importeren** van een `.swar`-
bestand, een `.trf`-bestand of een JSON-back-up, of **Een overdracht
ontvangen** (zie [Importeren en exporteren](10-import-export.md) en
[Accounts, delen en overdracht](15-accounts-and-handoff.md)); of **Kopiëren**
van een bestaand toernooi in de lijst (een kopie bevat alles van het origineel,
ronden en resultaten inbegrepen, en heet *Kopie van …*).

### Wat moet worden ingesteld vóór het paren {#what-must-be-set-before-pairing}

> [!WARNING]
> Een ronde kan niet worden gepaard zolang de **toernooinaam**, het **aantal
> rondes**, een **datum voor elke ronde** en een **tiebreakselectie** ontbreken.

De pagina's Spelers en Paringen zeggen wat nog ontbreekt en linken naar de
pagina waar het wordt ingesteld. De pagina Paringen waarschuwt ook, vóór ronde 1
en zonder te blokkeren, wanneer het aantal rondes niet kan worden gepaard voor de
ingeschreven spelers: een Zwitsers toernooi met meer rondes dan de spelers zonder
herhaalpartij toelaten, of een rondetoernooi waarvan het aantal rondes niet
overeenkomt met het aantal spelers. De waarschuwing linkt naar de instelling; als
je het aantal behoudt, wordt de ronde die niet kan worden gepaard met de hand
gemaakt ([Een ronde paren](06-pairing.md)). Aanbevolen, maar niet verplicht:
de hoofdarbiter, de federatie, het speeltempo en (voor een FIDE-gerat toernooi)
het FIDE-toernooi-ID.

## De instellingenpagina's {#the-settings-pages}

Het menu **Instellingen** in de bovenbalk opent de pagina Toernooi. Naast elke
instellingenpagina staat de lijst van pagina's (op een telefoon erboven), in drie
groepen: **Opzet** (Toernooi, Groep, Opties, Puntentelling, Data, Ruimtes, Categorieën,
Extra punten, Verboden paringen), **Publiceren** (OpenResults, Live borden) en
**Rapporteren** (FIDE, Exporteren, Over).

### Gewone en geavanceerde instellingen {#common-and-advanced-settings}

Elke pagina toont eerst wat bijna elk toernooi instelt. De rest wacht achter
de schakelaar **Geavanceerde instellingen tonen** bovenaan de pagina. De
schakelaar hoort bij je account: hij staat hetzelfde op elke
instellingenpagina, in elk toernooi en op elke computer waarop je aanmeldt.
Een instelling verbergen verandert haar nooit - een geavanceerde instelling
houdt haar waarde en wordt zoals vroeger met de pagina opgeslagen.

Staat een geavanceerde instelling van de pagina niet op haar standaardwaarde,
dan zegt de pagina dat naast de schakelaar (*2 geavanceerde instellingen staan
niet op de standaardwaarde - toon ze*); een klik toont ze. Een pagina waar, zoals ze nu voor jouw toernooi is, niets geavanceerds op staat,
toont geen schakelaar. Een paar kaarten
zijn alleen geavanceerd zolang je ze niet gebruikt: een toernooi
met een logo, met wensen bij de verboden paringen, met een FIDE-ID-bereik per
ronde of met een open inschrijvingsformulier toont die kaart altijd.

Nog twee dingen houden de pagina's kort:

- De instellingen van een paringssysteem verschijnen alleen als dat systeem
  gekozen is op de pagina Opties. Kies je *Rondetoernooi*, dan verdwijnen de
  Zwitserse instellingen meteen, nog voor je opslaat.
- Een functie met een eigen vinkje toont alleen dat vinkje tot ze aan staat:
  *Toernooi duurt langer dan 30 dagen*, *Uitgestelde partijen toelaten*, *Dit
  toernooi is FIDE-gehomologeerd*. De twee grenzen voor betaalde afwezigheden
  verschijnen zodra *Punten voor een overgeslagen ronde* een waarde heeft.

| Pagina | Getoond | Met *Geavanceerde instellingen tonen* |
| --- | --- | --- |
| Toernooi | naam, speelzaal, stad, federatie, organisator; toernooiformaat; aantal rondes; tiebreaks; Chess960 en het vinkje voor 30 dagen; delen | clubnummer van de organisator; hoe een ongerate speler in de tiebreaks telt; spelers die nog gelijk staan delen een plaats; logo |
| Opties | paringssysteem, toernooirating, cycli (rondetoernooi), Keizer-topwaarde (Keizer), opstellingen (ploegen), type en speeltempo | engine, beginkleur, gelijke rating en titel, paringsnummers van laatkomers, afwezigen in ronde 1, acceleratie, de matchformaten, ploegrating en rating van een ongerate speler (ploegen), ander speeltempo |
| Puntentelling | punten, matchpunten, uitgestelde partijen | de hele kaart *Byes en afwezigheden* (punten voor een overgeslagen ronde en de grenzen ervan, vrijwillig niet-gespeelde rondes, afwezigheden van laatkomers, het byetype vragen); bye, forfait en terugtrekking van een ploeg |
| Data | één datum per ronde | - |
| Ruimtes | de ruimtes van de zaal en hun borden | - |
| Categorieën | zie [Categorieën en normen](13-categories-and-norms.md) | - |
| Extra punten | bonus- of handicappunten per ratingband | - |
| Verboden paringen | het effect op de volgende ronde, de regels, spelers die elkaar niet mogen treffen | hoe zwaar de wensen wegen |
| OpenResults | publiceren naar de uitslagensite en per ronde ([Publiceren](14-publishing.md)) | wat de publieke pagina toont, het zaalscherm, het inschrijvingsformulier |
| Live borden | de boxen en de partijen die ze meldden ([Live borden](17-live-boards.md)) | - |
| FIDE | de FIDE-modus, het vinkje gehomologeerd, de rapportidentificaties, de volgorde van de ratinglijsten ([FIDE-modus](02-fide-mode.md), [Spelers en ratinglijsten](04-players-and-ratings.md)) | FIDE-ID-bereiken per ronde, consistentiecontroles van de ratings |
| Functionarissen & normen | de functionarissen en arbiters die de FIDE-formulieren noemen; het type evenement voor titelnormen; of de regel voor het grote open Zwitserse toernooi geldt | - |
| Exporteren | TRF, back-ups, de CSV-download van de spelers ([Importeren en exporteren](10-import-export.md)) | de kolommen, het scheidingsteken, de volgorde en de opties van de CSV |
| Over | versie en de paringsengine die dit toernooi gebruikt | - |

Elk formulier wordt opgeslagen met zijn eigen knop **Opslaan**, en het antwoord
verschijnt ernaast. Wanneer een collega dezelfde instellingen wijzigt terwijl je
aan het typen bent, meldt de pagina dat ze verouderd is, in plaats van wat je
typte te overschrijven. Elke wijziging van een instelling wordt met de oude en
de nieuwe waarde in het auditlogboek geschreven.

Een hint onder een instelling toont één regel; wijs de instelling aan, of klik
erin, voor de rest.

## Pagina Toernooi {#tournament-page}

**Algemeen.** Naam (verplicht), speelzaal, stad, federatie, organisator, en
(geavanceerd) het clubnummer van de organisator. **Toernooiformaat** is het type: Zwitsers
(individueel), Rondetoernooi (individueel), Zwitsers (ploegen), Rondetoernooi
(ploegen). **Aantal rondes** kan worden gewijzigd tot de eerste ronde is gepaard
(bij een rondetoernooi volgt het aantal uit de spelers en de cycli).

**Tiebreaks.** Beschreven in [Rangschikking en tiebreaks](08-standings-and-tiebreaks.md).
Met *Geavanceerde instellingen tonen* bevat deze kaart ook *Hoe een ongerate
speler in de tiebreaks wordt geteld* (met de rating die daarvoor is ingetypt) en
*Spelers die nog gelijk staan delen een plaats*.

**Bijzondere formules.** Het vinkje *Chess960* zegt dat het toernooi als
Chess960 wordt gespeeld. De arbiter trekt dan voor elke ronde een startpositie
op de pagina Paringen ([Een ronde paren](06-pairing.md)). Het vinkje *Toernooi
duurt langer dan 30 dagen* laat een speler tijdens het toernooi meer dan één
rating hebben; staat het aan, dan verschijnen eronder de twee instellingen voor
de tiebreaks op basis van rating ([Rangschikking en
tiebreaks](08-standings-and-tiebreaks.md)), en ook *Rapporteren aan FIDE*:
maandelijkse rapporten of één rapport op het einde ([Uitgestelde
partijen](11-fide-report.md#postponed-games) legt beide uit). Een **?** naast het vinkje legt het
uit. In zo'n toernooi voegt *Ratings vernieuwen* de ratings van een nieuwe lijst
toe als latere ratings vanaf een ronde, in plaats van de startrating te
vervangen ([Ratings vernieuwen](04-players-and-ratings.md#refreshing-ratings)),
en de paringsnummers veranderen er nooit door. Beslaan de rondedata meer dan 30
dagen en staat het vinkje uit, dan zegt de kaart dat.

**Delen / Team.** De eigenaar kan andere arbiters uitnodigen via hun
e-mailadres (zie [Accounts, delen en overdracht](15-accounts-and-handoff.md)).

**Logo** (geavanceerd tot er een logo is). Een PNG-, JPEG-, GIF- of WebP-afbeelding van maximaal 2 MB, die bij het
toernooi wordt opgeslagen en op de documenten wordt afgedrukt.

## Toernooigroepen {#tournament-groups}

Eén evenement bestaat vaak uit meerdere afzonderlijke toernooien: de open reeks, een
jeugdreeks, een rapidtoernooi ernaast. Elk heeft zijn eigen spelers, rondes en
paringen - daarom zijn het afzonderlijke toernooien en geen
[categorieën](13-categories-and-norms.md) van één toernooi. Een **groep** brengt ze
samen.

Op **Instellingen → Groep** (een eigen pagina in de lijst Opzet):

- **Groep aanmaken** start een nieuwe groep, met een naam naar keuze, met dit
  toernooi erin.
- **Of voeg het toe aan een bestaande groep** toont de groepen die je al kunt
  bewerken - die waarin een toernooi zit dat je mag bewerken - en voegt dit toernooi
  achteraan toe. Een toernooi zit in hoogstens één groep.
- **Label van dit toernooi in de keuzestrook** is een korte naam zoals *Open* of
  *U20*. Leeg toont de keuzestrook de eigen naam van het toernooi.
- De pijlen veranderen de volgorde, de knop **Hernoemen** de naam van de groep.
- **Uit de groep halen** haalt dit toernooi eruit. In het toernooi zelf verandert
  niets. Het laatste toernooi dat vertrekt, verwijdert de groep.

Zodra een groep twee toernooien bevat die je kunt openen, begint elke pagina van elk
met een **keuzestrook**: de naam van de groep en haar toernooien naast elkaar, het
huidige gemarkeerd. Een klik opent dezelfde pagina van het andere toernooi -
Rangschikking naar Rangschikking, een instellingenpagina naar dezelfde
instellingenpagina - of de pagina Spelers wanneer het die pagina niet heeft (de
pagina Ploegen van een individueel toernooi, de uitleg van één ronde). Op een
telefoon is de keuzestrook een uitklapmenu.

Wie wat mag: wie een toernooi mag bewerken - de eigenaar, of een medewerker die de
uitnodiging aanvaardde - mag het in een groep zetten, een label geven, de groep
herschikken of het eruit halen. De keuzestrook en de kaart tonen alleen de toernooien
die *jij* mag openen. Een toernooi dat alleen met jou gedeeld is, verraadt de rest van het
evenement niet.

Op de pagina **Toernooien** staan de toernooien van een groep samen onder de naam van
de groep, in de volgorde van de groep. De pijl voor de naam klapt de groep dicht.
Gearchiveerde en overgedragen toernooien zijn ook hier alleen-lezen: dearchiveer of
haal eerst terug. Een toernooi in de prullenbak verdwijnt uit de keuzestrook en keert
bij herstel terug in zijn groep; definitief verwijderen haalt het eruit.

Groepen zijn een gemak van dit programma. Ze veranderen niets aan paren,
rangschikking of FIDE-rapporten.

### Een groep op de uitslagensite {#a-group-on-the-results-site}

Zodra twee of meer toernooien van een groep [gepubliceerd](14-publishing.md) zijn,
toont OpenResults ze als één evenement: een rij tabs bovenaan de pagina's van elk
toernooi (*Open | U20 | U12*, volgens het label, in de volgorde van de groep) die
dezelfde pagina van het andere toernooi opent - stand naar stand, ronde 3 naar
ronde 3 - en een **evenementpagina** die ze oplijst met hun aantal spelers en de
ronde waarin ze zitten. De startpagina van de uitslagensite zet ze samen onder de naam
van de groep. De kaart **Groep** toont *De evenementpagina openen* zodra dit toernooi
er deel van is.

- Alleen gepubliceerde toernooien worden genoemd. Een toernooi van de groep dat niet
  gepubliceerd is, in de prullenbak zit of overgedragen is, staat nergens op de
  uitslagensite: niet zijn naam, niet zijn label, geen lege plek waar het zou staan.
- Een toernooi dat gepubliceerd is maar **niet op de startpagina vermeld** staat, wordt
  alleen genoemd op de andere toernooien die er ook niet vermeld staan. Een vermelde
  pagina verwijst nooit naar een pagina die alleen via de link bereikbaar is.
- De **naam van de groep** is openbaar als naam van het evenement zodra twee van haar
  toernooien gepubliceerd zijn.
- Een toernooi publiceren of intrekken, hernoemen, een label, de volgorde of de naam
  van de groep wijzigen verstuurt de andere toernooien vanzelf opnieuw; je hoeft ze niet
  één voor één te publiceren.

## Pagina Opties {#options-page}

Standaard getoond: het paringssysteem, de toernooirating, de cycli
(rondetoernooi), de Keizer-topwaarde (Keizer), de opstellingen (ploegen) en het
type en speeltempo. Al de rest op deze pagina is geavanceerd. De Zwitserse
instellingen verschijnen alleen bij een Zwitsers toernooi, die van een
rondetoernooi alleen bij een rondetoernooi.

**Paringssysteem.** Het systeem ligt vast zodra de eerste ronde is gepaard.

**Zwitserse engine.** Elk Zwitsers toernooi wordt gepaard door *Ainalrami*,
dat in het programma zit ingebouwd en C.04.3 volgt zoals het luidt vanaf
1 februari 2026. Er valt niets te kiezen of te installeren; de pagina noemt de
engine. De engine krijgt een TRF-bestand dat door het programma is opgebouwd en
gecontroleerd.

![De instellingenpagina Opties met het paringssysteem, de Zwitserse engine en de toernooirating](screenshots/03-settings-options.png "Instellingen, Opties")

**Toernooirating.** De rating die de spelers rangschikt, en daarmee hun
paringsnummers bepaalt, en die de op rating gebaseerde tiebreaks gebruiken. De
keuzes zijn de methoden van het TRF26-rapport: *alleen FIDE-rating (FIDE)*,
*alleen nationale rating (NRO)*, *FIDE-rating, anders nationaal (FIDON)*, wat de
standaard is, *nationale rating, anders FIDE (NIDOF)*, *hoogste van FIDE,
nationaal en handmatig (HBFN)* en *handmatige rating per speler (OTHER)*. Een
handmatige rating wordt per speler ingetypt (*Toernooirating* op het formulier
van de speler, zie [Spelers en ratinglijsten](04-players-and-ratings.md)).

**Gelijke rating en titel.** Spelers met dezelfde toernooirating worden
geordend op FIDE-titel (GM, IM, WGM, FM, WIM, CM, WFM, WCM, geen titel), en
daarna op dit criterium: alfabetisch (de FIDE-standaard), op FIDE-ID (laagste
eerst), oudste eerst of jongste eerst. Kondig het criterium aan vóór het
evenement.

**Paringsnummers van laatkomers** (alleen Zwitsers). *Volgens rating* (de
standaard) geeft een speler die meedoet nadat de nummers zijn uitgedeeld het
nummer dat hun rating oplevert, en iedereen daaronder schuift één plaats omlaag
(C.04.2 2.4); rondes die al zijn gespeeld houden hun borden. *Achter het veld*
geeft hun in de plaats het eerstvolgende vrije nummer. De FIDE-regels doen dat
niet, dus wie dat kiest, haalt het toernooi uit de FIDE-modus
([FIDE-modus](02-fide-mode.md)). Een toernooi dat is aangemaakt voordat
*Volgens rating* de standaard werd, houdt *Achter het veld* zoals het dat had,
zonder de FIDE-modus te verlaten; een back-upbestand uit die tijd ook, wanneer
het wordt geïmporteerd. Zo'n toernooi zegt dat één keer, op deze pagina en op de
pagina Paringen, tot ronde 4 gepaard is: **Overschakelen naar volgens rating**
wijzigt de instelling, **Behouden** laat ze staan, en elk antwoord wordt
onthouden. Wijzig je deze drie instellingen na ronde 1, dan wordt niemand
die al een nummer heeft opnieuw genummerd; de pagina zegt dat.

Een speler die in ronde 1 afwezig is (een gevraagde bye, een afwezigheid, een
latere startronde) is ook een laatkomer: bij het paren van ronde 1 krijgt die
geen paringsnummer, en wordt genummerd bij aankomst, volgens de instelling
hierboven (C.04.2 2.4). Wordt ronde 1 ontpaard en opnieuw gepaard terwijl de
speler er wel is, dan krijgt die met het veld een nummer volgens rating. Dat
geldt voor elk Zwitsers toernooi dat vanaf versie 0.79 is aangemaakt; die
hebben het ingeschakeld. Een toernooi van daarvoor, of een dat uit een TRF- of
SWAR-bestand is geïmporteerd, blijft afwezigen in ronde 1 met het veld nummeren
zoals het altijd deed: de nummers kwamen van elders en blijven zoals ze zijn.
Met het selectievakje *Spelers die in ronde 1 afwezig zijn, zijn laatkomers*,
direct onder de instelling hierboven, kan het worden in- of weer
uitgeschakeld, maar alleen zolang ronde 1 niet is gepaard; daarna is het vakje
grijs, omdat omschakelen spelers in al gespeelde ronden zou hernummeren. Baku
heeft het altijd aan, en bij een round robin of Keizer verschijnt het vakje
niet. Een back-upbestand houdt wat het toernooi had.

**Beginkleur.** Voor de eerste ronde van een Zwitsers toernooi: door loting
bepaald wanneer ronde 1 wordt gepaard, of Wit of Zwart door jou gekozen. De gebruikte
kleur wordt op de pagina Paringen onder ronde 1 getoond.

> [!FIDE] C.04.3 5.1
> Het bepalen van de beginkleur door loting is de FIDE-regel.

**Aantal keer dat iedereen tegen iedereen speelt** (rondetoernooi): elk getal
van 1 tot 10 - 1 is een enkel rondetoernooi, 2 een dubbel, 3 een drievoudig.
Elke cyclus speelt de Berger-tabel opnieuw, met de kleuren omgekeerd ten
opzichte van de vorige cyclus. **De laatste twee rondes van de eerste cyclus in
omgekeerde volgorde spelen** volgt FIDE C.05 en kan je alleen bij een dubbel
rondetoernooi kiezen (FIDE beschrijft het voor twee cycli, en de TRF heeft er
voor geen ander aantal een code voor). Je kan het aantal cycli verhogen zolang
de tweede cyclus nog niet is begonnen; een dubbel rondetoernooi waarvan de
omgekeerde rondes al gepaard zijn, blijft dubbel.

**Keizer-topwaarde**: de waarde van de hoogste trede van de Keizerladder, of leeg
voor de automatische waarde.

**Acceleratie.** Geen, of **Baku-acceleratie (FIDE C.04.7)**: het programma
berekent in de eerste ronden de virtuele punten van elke speler en geeft die
ronde na ronde aan de engine. Het geldt alleen voor Zwitserse toernooien en kan
niet meer worden gewijzigd zodra de eerste ronde is gepaard. Groep A wordt
geteld over de spelers die in ronde 1 gepaard zijn: wie in ronde 1 afwezig is
(een gevraagde bye, een afwezigheid, een latere startronde) krijgt pas een
paringsnummer bij aankomst, en dan zoals elke laatkomer (C.04.2 2.4): na het
veld of volgens rating, zoals *Paringsnummers van laatkomers* zegt.

**Zwitsers matchformaat.** Elke paring wordt twee keer achter elkaar gespeeld,
de tweede partij met omgekeerde kleuren. Het vereist een even aantal rondes (elke
match telt twee rondes).

> [!FIDE] Afwijking van de FIDE-modus
> Het Zwitserse matchformaat is een afwijking van de FIDE-modus.

**Ploegen** (ploegentoernooien): of opstellingen verplicht zijn, en
(geavanceerd) de manier waarop de rating van een ploeg wordt berekend voor de
volgorde van de ploegen, en de rating die wordt geteld voor een ongerate speler.
Zie [Ploegen](12-teams.md).

**Type en speeltempo.** Het type (Standaard, Rapid, Blitz) en de bedenktijd uit
een lijst, of (geavanceerd) ingetypt bij *Ander speeltempo*. Het speeltempo wordt
in het TRF-rapport geschreven.

Verboden paringen en de club- en federatieregels hebben een eigen pagina,
hieronder.

## Pagina Verboden paringen {#forbidden-pairings-page}

Wie wie niet mag treffen. Alles hier wordt door de Zwitserse engine en door
Keizer gehandhaafd; het schema van een rondetoernooi ligt vast en negeert het.

**Gevolg voor de volgende ronde.** Hoeveel van de partijen die het veld zou
kunnen spelen zijn uitgesloten, en hoeveel wensen er zijn. Wanneer de
beperkingen samen met de al gespeelde partijen een speler niemand meer laten om
te treffen, of de ronde helemaal niet meer paarbaar maken, zegt de pagina dat in
het rood voordat je op Paren drukt. Sluiten ze meer dan de helft van de
mogelijke partijen uit, dan waarschuwt ze dat de engine weinig keuze overhoudt.
Een bord dat met forfait eindigde is geen gespeelde partij: de twee mogen nog
tegen elkaar gepaard worden, en de pagina telt het zo.

**Regels.** *Spelers van dezelfde club* of *Spelers van dezelfde federatie*
treffen elkaar niet - elke club of federatie, of alleen de clubs of federaties
die je opgeeft (gescheiden door komma's). Elke regel is **Nooit - een regel** of
**Indien mogelijk - een wens**, en geldt voor **Elke ronde**, **De eerste
rondes**, **De laatste rondes** (teruggeteld vanaf het aantal rondes) of **Van
ronde … tot ronde …**. Een regel volgt de spelers zoals ze zijn wanneer een
ronde gepaard wordt, dus een late instapper of een verbeterde club valt eronder
zonder dat je de regel aanraakt. Elke regel toont wat hij nu doet, bijvoorbeeld
*4 paren over 2 clubs*; **Bewerken** en **Verwijderen** werken ter plaatse.

**Spelers die elkaar niet mogen treffen.** Zoek op naam, club of federatie, vink
twee of meer spelers aan en druk op **Deze N uit elkaar houden**. Twee spelers
vormen een verboden paar, drie of meer een groep waarvan de leden elkaar nooit
treffen. **Enkel indien mogelijk** maakt er een wens van. Een paar wordt een
wens of weer een regel met **Maak er een wens van** / **Maak er een regel van**;
een groep wijzig je met **Bewerken**, dat de leden aanvinkt zodat je er kunt
toevoegen of weghalen, en dan **Groep opslaan**.

Een paar of een regel die je toevoegt wanneer er al rondes gepaard zijn, geldt
vanaf de eerstvolgende ronde die gepaard wordt, en het TRF-rapport zegt dat.
Maak je daarna een ronde ongedaan, dan geldt de beperking vanaf die ronde: paar
ze opnieuw en de beperking wordt toegepast.

**Hoe zwaar de wensen wegen** (geavanceerd tot er een wens is). *Sterk* zet de wensen vóór de kleur- en
floatcriteria, *Zwak* gebruikt ze alleen als laatste beslissing. Alleen de
Zwitserse engine past wensen toe: Keizer houdt zich aan de regels maar negeert
de wensen, en de pagina zegt dat.

> [!FIDE] Vóór ronde 1 instellen
> De Algemene Reglementen van de FIDE (C.05 5.2) laten beperkingen op de
> paringen toe - hun eigen voorbeeld is "spelers van dezelfde federatie
> ontmoeten elkaar, indien mogelijk, niet in de laatste rondes" - wanneer de
> spelers ze vóór de eerste ronde te horen krijgen. Stel ze in de FIDE-modus dus
> in voordat ronde 1 gepaard wordt. Daarna vraagt het toevoegen, wijzigen of
> verwijderen van een paar of een regel (of het wijzigen van hoe zwaar de wensen
> wegen) twee keer om bevestiging en haalt het het toernooi uit de FIDE-modus;
> de TRF-kopieën vermelden elke wijziging als een regel `### Prohibition`. Een
> speler die later instapt en onder een regel valt, is geen wijziging.

> [!FIDE] Afwijking van de FIDE-modus
> Een wens is geen FIDE-regel: een ronde waarin een wens een bord verplaatst,
> wordt voor die ronde als afwijking vastgelegd.

## Pagina Puntentelling {#scoring-page}

**Punten** voor een winst (standaard 1), een remise (½) en een verlies (0), en de
waarde van de **door de paring toegekende bye** (standaard: een winst).

> [!FIDE] Puntentelling
> In de FIDE-modus kunnen deze niet worden gewijzigd na ronde 1, en een waarde
> waarbij een remise of de bye meer waard is dan een winst, markeert het toernooi
> als een afwijking van de FIDE-regels.

**Matchpunten** (ploegentoernooien): 2 voor een gewonnen match, 1 voor een
gelijkgespeelde match en 0 voor een verloren match, standaard; en, geavanceerd,
de matchpunten en partijpunten van een door de paring toegekende bye; wat een wedstrijd die als
geheel forfait is aan partijpunten oplevert ([Ploegen](12-teams.md)); en de
behandeling van een ploeg die zich terugtrekt.

**Byes en afwezigheden.** (geavanceerd) *Punten voor een overgeslagen ronde* is de waarde van
een ronde waarvoor een speler afwezig was (leeg: afwezigheden leveren niets op).
Daarbij horen twee optionele grenzen, die verschijnen zodra het een waarde heeft:
de laatste ronde waarvoor het nog geldt, en een maximum voor het aantal rondes van
een speler dat wordt betaald. De drie instellingen daarna zijn geavanceerd. *Een
overgeslagen ronde als vrijwillig niet gespeelde ronde behandelen voor tiebreaks*
verandert hoe de tiebreaks van C.07 die rondes behandelen; een ronde die evenveel
oplevert als een winst is daar een bye van een vol punt, wat deze instelling ook
zegt (C.07 16.1.1 houdt "aangevraagde bye" voor een half punt of geen). *Rondes voor een
laatkomer die meedoet tellen als afwezigheid* betaalt de rondes vóór een late
inschrijving op dezelfde manier. Deze instellingen veranderen de punten, de
tiebreaks en daarmee de rangschikking, en liggen vast na ronde 1. *Het byetype
vragen bij elke afwezigheid* (individueel Zwitsers, standaard uit) laat het
inschrijfformulier vragen of elke overgeslagen ronde een bye van een half, nul of
vol punt is, met het antwoord dat de punten hierboven geven al aangeduid; zie
[Byes en afwezigheid](05-byes-and-absences.md#asking-the-bye-type).

**Uitgestelde partijen.** *Uitgestelde partijen toelaten* biedt een uitgesteld
resultaat aan op de pagina Paringen; de twee waarden eronder verschijnen zodra
het aangevinkt is. Totdat een uitgestelde partij is gespeeld,
telt ze voor de speler die haar heeft uitgesteld, en voor de tegenstander, zoals
hier is ingesteld (standaard een remise voor beide spelers, wat de FIDE-regel is).
Een round robin biedt uitgestelde resultaten altijd aan, dus daar staat de
schakelaar aan en vast; de waarden gelden nog altijd. Zie [Resultaten](07-results.md).

## Pagina Data {#dates-page}

Eén datum voor elke ronde:

- **Opeenvolgend invullen vanaf ronde 1** zet opeenvolgende dagen;
- **Wekelijks berekenen vanaf ronde 1** zet één week tussen de rondes;
- **Alles wissen** maakt ze allemaal leeg.

De data worden gebruikt op de afgedrukte lijsten, het TRF-rapport (record 132),
de resultaatformulieren van de matches en de uitslagensite. De begin- en einddatum
van het toernooi worden daaruit afgeleid.

## Pagina Ruimtes {#rooms-page}

Voor een zaal met meer dan een ruimte. Elke ruimte heeft een naam en de
borden die erin staan, getypt zoals je ze zou zeggen: `1-20, 35, 40-45`
(komma's, puntkomma's of spaties ertussen; `1 - 20` is één reeks). **Ruimte
toevoegen** voegt een rij toe, **Verwijderen** haalt er een weg, en
**Ruimtes opslaan** bewaart het geheel.

Elke rij wordt nagekeken terwijl je typt, en de regel eronder zegt wat er
gelezen werd (*Borden 1-20, 35: 21 borden.*) of wat er mis is:

- elke ruimte heeft een naam nodig, en twee ruimtes mogen niet dezelfde
  hebben (hoofdletters maken een naam niet anders);
- een bord kan maar in één ruimte staan - *Bord 18 zit al in Grote zaal.*;
- een bord in geen enkele ruimte mag, en een ruimte zonder borden ook.

Het nummer van een bord is het getal waarmee zijn label begint: bord `3.1`
van een ploegentoernooi staat in de ruimte die 3 heeft, en een vaste tafel
telt met haar eigen nummer.

Zodra een toernooi ruimtes heeft, zet de pagina Paringen de naam van de
ruimte boven het eerste bord van elke ruimte, en krijgen de afgedrukte
paringenlijst en de alfabetische lijst een kolom **Ruimte**. Een toernooi
zonder ruimtes ziet eruit zoals altijd.

Waar een printstation of een zaalomroeper geïnstalleerd is, kun je die in
een van deze ruimtes zetten: een printstation drukt dan alleen de borden van
die ruimte af, een omroeper leest alleen de borden van die ruimte voor. Een
ruimte hernoemen houdt wat erin stond; een ruimte verwijderen laat die
toestellen zonder ruimte, en dat is weer de hele zaal.

De ruimtes reizen mee in de JSON-export van het toernooi en komen terug bij
het importeren.

## Pagina Extra punten {#extra-points-page}

Extra punten zijn punten die een arbiter bovenop de partijpunten toekent. Er zijn
twee soorten:

- **Handicap**: een voorsprong voor spelers *onder* een rating.
- **Acceleratie**: de extra punten van SWAR, voor spelers *op of boven* een
  rating; ze brengen de sterke spelers eerder bij elkaar.

*Elo-banden* worden geschreven als `rating:bonus`-paren, gescheiden door komma's.
**Banden op spelers toepassen** geeft elke speler de punten van zijn band; punten
kunnen ook per speler worden ingetypt op de pagina Spelers. *Extra punten
meetellen (stand en paring)* laat de rangschikking (en, bij een handicap, de
paring) ze gebruiken; bij acceleratie heet de schakelaar *Accelerationspunten
behouden in de eindrangschikking*. In het TRF-rapport verschijnen ze in record
299.

> [!FIDE] Afwijking van de FIDE-modus
> Extra punten maken geen deel uit van de FIDE-regels; een ronde waarvoor de
> paring ze gebruikte, wordt als afwijking vastgelegd.

## Pagina Functionarissen & normen {#officials-and-norms-page}

**Functionarissen.** De hoofdarbiter, de organisator, de persoon die
verantwoordelijk is voor de paringen, twee gerangschikte hulparbiters en zoveel
andere arbiters als het evenement had (*+ Arbiter toevoegen*), de e-mailadressen
van de hoofdarbiter en de organisator, het IT4-evenementtype en de link naar de
paringswebpagina, en vier bijzondere opmerkingen voor het IT3. Typ een naam of
een FIDE-ID en kies de juiste speler: elke functionaris heeft een FIDE-ID nodig,
en opslaan met een functionaris zonder ID wordt geweigerd, want FIDE stuurt zo'n
rapport terug. De formulieren IT3, FA1, IA1 en IT4 op de pagina Normen worden
hiermee ingevuld ([Categorieën en normen](13-categories-and-norms.md)).

**Titelnormen.** *Type evenement voor titelnormen* zegt de normbeoordeling als
wat voor evenement de FIDE Title Regulations (B.01) dit toernooi zien. Enkel de
soorten die bij het toernooi passen (team of individueel) worden aangeboden:

| Type evenement | Wat er verandert |
| --- | --- |
| Gewoon evenement (de standaard) | niets: 9 partijen en de normale federatiemix |
| Wereld- of continentaal kampioenschap voor teams / clubs | 7 partijen volstaan als het evenement 7, 8 of 9 rondes heeft (1.4.1 b) |
| World Cup of Women's World Cup | 8 partijen volstaan (1.4.1 b) |
| Finale van een nationaal kampioenschap | geen federatiemix voor spelers van de eigen federatie van het toernooi (1.4.3 a) |
| Nationaal teamkampioenschap | hetzelfde, voor een teamtoernooi (1.4.3 b) |
| Zonaal of subzonaal toernooi | voor niemand een federatiemix (1.4.3 c) |

Daarnaast zegt de pagina of de regel voor het **grote open Zwitserse toernooi**
(1.4.3 d) geldt. Je hoeft niets in te stellen: het programma telt het uit de
spelers. Een individueel Zwitsers toernooi komt in aanmerking als minstens 20
FIDE-gerate spelers van buiten de organiserende federatie (de eigen federatie
van het toernooi, onder Toernooi), uit minstens 3 federaties, van wie minstens
10 GM, IM, WGM of WIM, elk hoogstens een van de afgewerkte rondes misten. Een
door de paring toegekende bye is geen gemiste ronde; een gevraagde bye, een
afwezigheid of een verloren forfait wel. Spelers onder de FIDE-vlag tellen niet
mee. Als de regel geldt, heeft niemands norm de federatiemix nodig.

> [!FIDE] Eén norm met de normale mix
> Elke vrijstelling geldt voor één norm. Een titelaanvraag heeft nog altijd
> minstens één norm nodig die aan de normale federatievereiste voldoet (B.01
> 1.4.3 e); de normbeoordeling zegt dat bij elke vrijgestelde controle.

## Vergrendelingen {#locks}

Nadat de eerste ronde is gepaard, zijn sommige instellingen vergrendeld omdat ze
bepalen wat al is gebeurd: het paringssysteem en de engine, de matchformaten, de
paring per categorie, de puntentelling van afwezigheden, de beginkleur en (bij
ploegenevenementen) het aantal borden per match en de opstellingsregels. In de
FIDE-modus is de lijst langer; zie [FIDE-modus](02-fide-mode.md).

> [!TIP]
> Buiten de FIDE-modus heeft een vergrendeld veld een bediening *Ontgrendelen* die
> het voor één keer opslaan opent.
