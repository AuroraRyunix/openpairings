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
| Opties | paringssysteem en -engine, beginkleur, acceleratie, Zwitsers matchformaat, ploegen, type en speeltempo, verboden paringen, club- en federatie-uitsluitingen |
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

## Pagina Opties {#options-page}

**Paringssysteem.** Het systeem ligt vast zodra de eerste ronde is gepaard.

**Zwitserse engine.** *Ainalrami* is de standaard en zit ingebouwd in het
programma; het volgt C.04.3 zoals het luidt vanaf 1 februari 2026. *JaVaFo* is
de referentie-implementatie van FIDE voor de editie van 2017 en heeft Java en het
JaVaFo-programmabestand nodig, dat apart moet worden geïnstalleerd (het zit er
niet bij). De engine ligt vast zodra de eerste ronde is gepaard. Beide engines
krijgen precies hetzelfde bestand (een TRF-bestand dat door het programma is
opgebouwd en gecontroleerd).

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
het wordt geïmporteerd. Wijzigt u deze drie instellingen na ronde 1, dan wordt niemand
die al een nummer heeft opnieuw genummerd; de pagina zegt dat.

Een speler die in ronde 1 afwezig is (een gevraagde bye, een afwezigheid, een
latere startronde) is ook een laatkomer: bij het paren van ronde 1 krijgt die
geen paringsnummer, en wordt genummerd bij aankomst, volgens de instelling
hierboven (C.04.2 2.4). Wordt ronde 1 ontpaard en opnieuw gepaard terwijl de
speler er wel is, dan krijgt die met het veld een nummer volgens rating. Dat
geldt voor elk Zwitsers toernooi dat vanaf versie 0.79 is aangemaakt. Een
toernooi van daarvoor, of een dat uit een TRF- of SWAR-bestand is
geïmporteerd, blijft afwezigen in ronde 1 met het veld nummeren zoals het
altijd deed: de nummers kwamen van elders en blijven zoals ze zijn. Een
back-upbestand houdt wat het toernooi had.

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

**Verboden paringen.** Twee spelers die elkaar niet mogen treffen: kies Speler A
en Speler B en druk op *Paren*. Een regel geldt voor elke ronde en wordt door
beide Zwitserse engines en door Keizer gehandhaafd (een rondetoernooi negeert
haar). **Enkel indien mogelijk** maakt er een wens van in plaats van een regel:
de Ainalrami-engine honoreert die zolang de FIDE-criteria het toelaten, en de
paringsverantwoording toont wanneer hij heeft toegegeven.

> [!FIDE] Afwijking van de FIDE-modus
> Een wens is geen FIDE-regel en wordt als afwijking vastgelegd voor de ronde die
> ze veranderde.

**Club-/federatie-uitsluitingen.** Spelers van dezelfde club (of dezelfde
federatie) worden niet tegen elkaar gepaard: voor alle gedeelde clubs, of alleen
voor de clubs of federaties die u opgeeft. Een tweede optie, *Clubgenoten de
eerste N rondes uit elkaar houden*, vraagt de engine om clubgenoten vroeg te
scheiden zonder er een regel van te maken, en *Hoe hard proberen* bepaalt of die
wens vóór de kleur- en doorschuifcriteria weegt (sterk) of alleen als laatste
tiebreak (zwak).

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
