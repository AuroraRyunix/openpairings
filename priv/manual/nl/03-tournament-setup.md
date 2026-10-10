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
| Cycli | (alleen rondetoernooi) enkel of dubbel. |
| Ploegentoernooi | Maakt er een ploegenevenement van: Zwitserse ploegen (FIDE C.04.6) of rondetoernooi-ploegen. Keizer kan geen ploegentoernooi zijn. Zie [Ploegen](12-teams.md). |
| Plaats | De stad. |
| Datum vanaf | Vult elke ronde met deze datum; verfijn dit op de pagina Data. |
| Speeltempo | Een lijst met de gebruikelijke bedenktijden voor het gekozen formaat, of *geen*. |
| Formaat | Standaard, Rapid of Blitz. Dat bepaalt welke bedenktijden worden aangeboden, uit welke FIDE-rating de ratings van de spelers worden ververst, en het type rapport. |

![Het formulier Nieuw toernooi met naam, paringssysteem, rondes, plaats, startdatum en speeltempo](screenshots/03-new-tournament-form.png "Het formulier Nieuw toernooi")

Het formulier begint met uw standaardwaarden (pagina Account, *Nieuwe
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
u het aantal behoudt, wordt de ronde die niet kan worden gepaard met de hand
gemaakt ([Een ronde paren](06-pairing.md)). Aanbevolen, maar niet verplicht:
de hoofdarbiter, de federatie, het speeltempo en (voor een FIDE-gerat toernooi)
het FIDE-toernooi-ID.

## De instellingenpagina's {#the-settings-pages}

Het menu **Instellingen** in de bovenbalk heeft deze pagina's:

| Pagina | Bevat |
| --- | --- |
| Toernooi | naam, speelzaal, stad, federatie, organisator; toernooiformaat; aantal rondes; functionarissen; tiebreaks; delen; logo |
| Opties | paringssysteem en -engine, beginkleur, acceleratie, Zwitsers matchformaat, ploegen, type en speeltempo |
| Verboden paringen | verboden paren, regels per club of federatie, groepen spelers die elkaar niet mogen treffen, en de wensen |
| OpenResults | publiceren naar de uitslagensite ([Publiceren](14-publishing.md)) |
| Puntentelling | punten, byes, afwezigheden, uitgestelde partijen |
| Data | één datum per ronde |
| Categorieën | zie [Categorieën en normen](13-categories-and-norms.md) |
| Extra punten | bonus- of handicappunten per ratingband |
| FIDE | de FIDE-modus en de rapportidentificaties ([FIDE-modus](02-fide-mode.md)); de volgorde van de ratinglijsten en de consistentiecontroles van de ratings ([Spelers en ratinglijsten](04-players-and-ratings.md)) |
| Exporteren | TRF, back-ups, CSV ([Importeren en exporteren](10-import-export.md)) |
| Over | versie en de paringsengine die dit toernooi gebruikt |

Elke pagina wordt opgeslagen met de eigen knop **Instellingen opslaan**. Wanneer
een collega dezelfde instellingen wijzigt terwijl u aan het typen bent, meldt de
pagina dat ze verouderd is, in plaats van wat u typte te overschrijven. Elke
wijziging van een instelling wordt met de oude en de nieuwe waarde in het
auditlogboek geschreven.

## Pagina Toernooi {#tournament-page}

**Algemeen.** Naam (verplicht), speelzaal, stad, federatie, organisator, en het
clubnummer van de organisator. **Toernooiformaat** is het type: Zwitsers
(individueel), Rondetoernooi (individueel), Zwitsers (ploegen), Rondetoernooi
(ploegen). **Aantal rondes** kan worden gewijzigd tot de eerste ronde is gepaard
(bij een rondetoernooi volgt het aantal uit de spelers en de cycli).

**Functionarissen.** De hoofdarbiter (naam, en FIDE-ID wanneer bekend),
hulparbiters, en de gegevens die de FIDE-rapporten gebruiken. Dezelfde
functionarissen kunnen op de pagina Normen worden bewerkt.

**Tiebreaks.** Beschreven in [Rangschikking en tiebreaks](08-standings-and-tiebreaks.md).
Dit deel bevat ook *Hoe een ongerate speler in de tiebreaks wordt geteld* (met de
rating die daarvoor is ingetypt) en *Spelers die nog gelijk staan delen een
plaats*.

**Chess960.** Het vinkje *Chess960* zegt dat het toernooi als Chess960 wordt
gespeeld. De arbiter trekt dan voor elke ronde een startpositie op de pagina
Paringen ([Een ronde paren](06-pairing.md)).

**Delen / Team.** De eigenaar kan andere arbiters uitnodigen via hun
e-mailadres (zie [Accounts, delen en overdracht](15-accounts-and-handoff.md)).

**Logo.** Een PNG-, JPEG-, GIF- of WebP-afbeelding van maximaal 2 MB, die bij het
toernooi wordt opgeslagen en op de documenten wordt afgedrukt.

## Toernooigroepen {#tournament-groups}

Eén evenement bestaat vaak uit meerdere afzonderlijke toernooien: de open reeks, een
jeugdreeks, een rapidtoernooi ernaast. Elk heeft zijn eigen spelers, rondes en
paringen - daarom zijn het afzonderlijke toernooien en geen
[categorieën](13-categories-and-norms.md) van één toernooi. Een **groep** brengt ze
samen.

Op **Instellingen → Toernooi**, de kaart **Groep**:

- **Groep aanmaken** start een nieuwe groep, met een naam naar keuze, met dit
  toernooi erin.
- **Of voeg het toe aan een bestaande groep** toont de groepen die u al kunt
  bewerken - die waarin een toernooi zit dat u mag bewerken - en voegt dit toernooi
  achteraan toe. Een toernooi zit in hoogstens één groep.
- **Label van dit toernooi in de keuzestrook** is een korte naam zoals *Open* of
  *U20*. Leeg toont de keuzestrook de eigen naam van het toernooi.
- De pijlen veranderen de volgorde, de knop **Hernoemen** de naam van de groep.
- **Uit de groep halen** haalt dit toernooi eruit. In het toernooi zelf verandert
  niets. Het laatste toernooi dat vertrekt, verwijdert de groep.

Zodra een groep twee toernooien bevat die u kunt openen, begint elke pagina van elk
met een **keuzestrook**: de naam van de groep en haar toernooien naast elkaar, het
huidige gemarkeerd. Een klik opent dezelfde pagina van het andere toernooi -
Rangschikking naar Rangschikking, een instellingenpagina naar dezelfde
instellingenpagina - of de pagina Spelers wanneer het die pagina niet heeft (de
pagina Ploegen van een individueel toernooi, de uitleg van één ronde). Op een
telefoon is de keuzestrook een uitklapmenu.

Wie wat mag: wie een toernooi mag bewerken - de eigenaar, of een medewerker die de
uitnodiging aanvaardde - mag het in een groep zetten, een label geven, de groep
herschikken of het eruit halen. De keuzestrook en de kaart tonen alleen de toernooien
die *u* mag openen. Een toernooi dat alleen met u gedeeld is, verraadt de rest van het
evenement niet.

Op de pagina **Toernooien** staan de toernooien van een groep samen onder de naam van
de groep, in de volgorde van de groep. De pijl voor de naam klapt de groep dicht.
Gearchiveerde en overgedragen toernooien zijn ook hier alleen-lezen: dearchiveer of
haal eerst terug. Een toernooi in de prullenbak verdwijnt uit de keuzestrook en keert
bij herstel terug in zijn groep; definitief verwijderen haalt het eruit.

Groepen zijn een gemak van dit programma. Ze veranderen niets aan paren,
rangschikking of FIDE-rapporten, en worden niet gepubliceerd op OpenResults.

## Pagina Opties {#options-page}

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
onthouden. Wijzigt u deze drie instellingen na ronde 1, dan wordt niemand
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
bepaald wanneer ronde 1 wordt gepaard, of Wit of Zwart door u gekozen. De gebruikte
kleur wordt op de pagina Paringen onder ronde 1 getoond.

> [!FIDE] C.04.3 5.1
> Het bepalen van de beginkleur door loting is de FIDE-regel.

**Cycli** (rondetoernooi): enkel of dubbel. **De laatste twee rondes van de
eerste cyclus in omgekeerde volgorde spelen** volgt FIDE C.05. Een enkele cyclus
kan dubbel worden gemaakt zolang de tweede cyclus nog niet is begonnen.

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

**Ploegen** (ploegentoernooien): of opstellingen verplicht zijn, de manier waarop
de rating van een ploeg wordt berekend voor de volgorde van de ploegen, en de
rating die wordt geteld voor een ongerate speler. Zie [Ploegen](12-teams.md).

**Type en speeltempo.** Het type (Standaard, Rapid, Blitz) en de bedenktijd, uit
een lijst of ingetypt. Het speeltempo wordt in het TRF-rapport geschreven.

Verboden paringen en de club- en federatieregels hebben een eigen pagina,
hieronder.

## Pagina Verboden paringen {#forbidden-pairings-page}

Wie wie niet mag treffen. Alles hier wordt door de Zwitserse engine en door
Keizer gehandhaafd; het schema van een rondetoernooi ligt vast en negeert het.

**Gevolg voor de volgende ronde.** Hoeveel van de partijen die het veld zou
kunnen spelen zijn uitgesloten, en hoeveel wensen er zijn. Wanneer de
beperkingen samen met de al gespeelde partijen een speler niemand meer laten om
te treffen, of de ronde helemaal niet meer paarbaar maken, zegt de pagina dat in
het rood voordat u op Paren drukt. Sluiten ze meer dan de helft van de
mogelijke partijen uit, dan waarschuwt ze dat de engine weinig keuze overhoudt.

**Regels.** *Spelers van dezelfde club* of *Spelers van dezelfde federatie*
treffen elkaar niet - elke club of federatie, of alleen de clubs of federaties
die u opgeeft (gescheiden door komma's). Elke regel is **Nooit - een regel** of
**Indien mogelijk - een wens**, en geldt voor **Elke ronde**, **De eerste
rondes**, **De laatste rondes** (teruggeteld vanaf het aantal rondes) of **Van
ronde … tot ronde …**. Een regel volgt de spelers zoals ze zijn wanneer een
ronde gepaard wordt, dus een late instapper of een verbeterde club valt eronder
zonder dat u de regel aanraakt. Elke regel toont wat hij nu doet, bijvoorbeeld
*4 paren over 2 clubs*; **Bewerken** en **Verwijderen** werken ter plaatse.

**Spelers die elkaar niet mogen treffen.** Zoek op naam, club of federatie, vink
twee of meer spelers aan en druk op **Deze N uit elkaar houden**. Twee spelers
vormen een verboden paar, drie of meer een groep waarvan de leden elkaar nooit
treffen. **Enkel indien mogelijk** maakt er een wens van. Een paar wordt een
wens of weer een regel met **Maak er een wens van** / **Maak er een regel van**;
een groep wijzigt u met **Bewerken**, dat de leden aanvinkt zodat u er kunt
toevoegen of weghalen, en dan **Groep opslaan**.

**Hoe zwaar de wensen wegen.** *Sterk* zet de wensen vóór de kleur- en
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
gelijkgespeelde match en 0 voor een verloren match, standaard; de matchpunten en
partijpunten van een door de paring toegekende bye; en de behandeling van een
ploeg die zich terugtrekt.

**Byes en afwezigheden.** *Punten voor een overgeslagen ronde* is de waarde van
een ronde waarvoor een speler afwezig was (leeg: afwezigheden leveren niets op).
Daarbij horen twee optionele grenzen: de laatste ronde waarvoor het nog geldt, en
een maximum voor het aantal rondes van een speler dat wordt betaald. *Een
overgeslagen ronde als vrijwillig niet gespeelde ronde behandelen voor tiebreaks*
verandert hoe de tiebreaks van C.07 die rondes behandelen. *Rondes voor een
laatkomer die meedoet tellen als afwezigheid* betaalt de rondes vóór een late
inschrijving op dezelfde manier. Deze instellingen veranderen de punten, de
tiebreaks en daarmee de rangschikking, en liggen vast na ronde 1. *Het byetype
vragen bij elke afwezigheid* (individueel Zwitsers, standaard uit) laat het
inschrijfformulier vragen of elke overgeslagen ronde een bye van een half, nul of
vol punt is, met het antwoord dat de punten hierboven geven al aangeduid; zie
[Byes en afwezigheid](05-byes-and-absences.md#asking-the-bye-type).

**Uitgestelde partijen.** *Uitgestelde partijen toestaan* biedt een uitgesteld
resultaat aan op de pagina Paringen. Totdat een uitgestelde partij is gespeeld,
telt ze voor de speler die haar heeft uitgesteld, en voor de tegenstander, zoals
hier is ingesteld (standaard een remise voor beide spelers, wat de FIDE-regel is).
Zie [Resultaten](07-results.md).

## Pagina Data {#dates-page}

Eén datum voor elke ronde:

- **Opeenvolgend invullen vanaf ronde 1** zet opeenvolgende dagen;
- **Wekelijks berekenen vanaf ronde 1** zet één week tussen de rondes;
- **Alles wissen** maakt ze allemaal leeg.

De data worden gebruikt op de afgedrukte lijsten, het TRF-rapport (record 132),
de uitslagformulieren van de matches en de uitslagensite. De begin- en einddatum
van het toernooi worden daaruit afgeleid.

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

## Vergrendelingen {#locks}

Nadat de eerste ronde is gepaard, zijn sommige instellingen vergrendeld omdat ze
bepalen wat al is gebeurd: het paringssysteem en de engine, de matchformaten, de
paring per categorie, de puntentelling van afwezigheden, de beginkleur en (bij
ploegenevenementen) het aantal borden per match en de opstellingsregels. In de
FIDE-modus is de lijst langer; zie [FIDE-modus](02-fide-mode.md).

> [!TIP]
> Buiten de FIDE-modus heeft een vergrendeld veld een bediening *Ontgrendelen* die
> het voor één keer opslaan opent.
