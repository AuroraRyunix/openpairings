# Byes en afwezigheid

Een speler die een ronde niet speelt, wordt op een paar manieren vastgelegd. Ze
verschillen in hoe de paring de speler behandelt, in wat de ronde waard is, en in
hoe de tiebreaks van C.07 die behandelen.

## De soorten {#the-kinds}

| Soort | Hoe het ontstaat | Waarde | Gepaard? |
| --- | --- | --- | --- |
| **Door de paring toegekende bye** | Het programma kent hem toe wanneer het aantal te paren spelers oneven is. | De waarde *Door de paring toegekende bye* op de pagina Puntentelling (standaard een winst). | Het is een bord van de ronde zonder tegenstander. |
| **Afwezig voor een ronde** | De arbiter markeert de speler als afwezig voor bepaalde rondes, of voor het hele evenement. | *Punten voor een overgeslagen ronde* op de pagina Puntentelling (standaard niets). | Niet gepaard in die ronde. |
| **Teruggetrokken (forfait)** | De arbiter markeert de speler als teruggetrokken (*Forfait*). | Niets: de speler krijgt ook niet de afwezigheidswaarde, en in een rondetoernooi is elke partij vanaf dan een verlies bij forfait. | Niet gepaard in een latere ronde. |
| **Uitgesloten** | De arbiter vinkt **Uitgesloten** aan op het inschrijfformulier. | De speler wordt in geen enkele latere ronde gepaard en wordt uit de rangschikking gelaten. De al gespeelde partijen blijven: de tegenstanders houden de punten en tiebreaks die die partijen hun gaven. | Niet gepaard in een latere ronde. |
| **Forfaitwinst / -verlies van een partij** | Een paring waarvan het resultaat als forfait wordt ingevoerd (1-0 FF, 0-1 FF, 0-0 FF). | Een forfaitwinst telt als winst, een forfaitverlies als verlies. | Het is een gewone paring. |
| **Bye van een vol punt** | De arbiter geeft die, uit de *Lijst met niet-spelenden* van een gepaarde ronde, aan een speler die die ronde niet meespeelt; of kiest hem voor een komende ronde wanneer **Het byetype vragen bij elke afwezigheid** aan staat. | Wat een winst waard is. | Niet gepaard; de speler kan geen door de paring toegekende bye meer krijgen. |
| **Bye van een half of nul punt** | Komt mee met een geïmporteerd SWAR- of TRF-bestand, of met de overdracht van een andere kopie; of wordt gekozen voor een komende ronde wanneer **Het byetype vragen bij elke afwezigheid** aan staat. | Een bye van een half punt is een remise waard; een bye van nul punt niets. | Niet gepaard. |

Details van de puntentelling staan in
[Rangschikking en tiebreaks](08-standings-and-tiebreaks.md).

## Afwezigheid markeren op de pagina Spelers {#marking-absence-on-the-players-page}

De aanwezigheidscel van een speler (kolom *Aanw.*) toont en zet de aanwezigheid,
zoals uitgelegd in [Spelers en ratinglijsten](04-players-and-ratings.md):

- Open het menu van de cel (rechtsklik, of <kbd>Space</kbd> met het toetsenbord)
  om de speler **Afwezig** of **Aanwezig** te zetten. Op het inschrijfformulier
  betekent het vakje **Afwezig** afwezig voor het hele evenement, en het veld
  **Afwezig in de rondes** neemt de rondes die worden overgeslagen, geschreven als
  `3,5` of `2-4` (komma's, puntkomma's, spaties en reeksen worden aanvaard).
- **Forfait** op het inschrijfformulier trekt de speler terug. De rangschikking en
  de afgedrukte rangschikking markeren zo'n speler als *teruggetrokken* en behouden
  de tot dan toe behaalde punten ([Rangschikking en tiebreaks](08-standings-and-tiebreaks.md)).
- **Uitgesloten** op het inschrijfformulier sluit de speler uit. De
  aanwezigheidscel toont `E`. Een uitgesloten speler wordt niet meer gepaard en
  verschijnt niet in de rangschikking.
- Het menu op de kop van de kolom markeert iedereen in één keer aanwezig of
  afwezig; gebruik dit aan het begin van het evenement of het begin van een ronde.

![Het menu van de aanwezigheidscel op de pagina Spelers met Afwezig en Aanwezig](screenshots/05-presence-cell-menu.png "Een speler afwezig zetten")

Een afwezige speler wordt in die ronde niet gepaard. Hun afwezigheid wordt gescoord
zoals ingesteld op de pagina Puntentelling (*Byes en afwezigheden*). De pagina
Paringen en de afgedrukte paringslijst (optie *met afwezigenvak*) tonen de spelers
die niet meespelen, met de waarde van de ronde voor elk van hen.

### Halvepuntsbyes {#half-point-byes}

Een afwezigheid die de pagina Puntentelling als remise scoort, is een halvepuntsbye.

> [!FIDE] C.05:6.7.4
> De regels staan een speler slechts één halvepuntsbye per toernooi toe, en geen
> enkele aan een speler die voorwaarden kreeg of gratis deelname.

Het programma helpt op twee manieren:

- Wanneer het opslaan van het inschrijfformulier een speler een **tweede of latere
  halvepuntsbye** zou geven, toont het formulier een waarschuwing voor de betreffende
  rondes (*De regels staan een speler slechts één halvepuntsbye per toernooi toe*),
  en vraagt de knop **Opslaan** *Toch opslaan?* De opslag gaat pas door nadat u
  bevestigt.
- Het vakje **Komt niet in aanmerking voor byes van een half punt** markeert een
  speler die er geen mag krijgen. Zolang het is aangevinkt, wordt een afwezigheid
  van een half punt voor die speler geweigerd, en het vakje kan niet worden
  aangevinkt voor een speler die er al een heeft; de melding noemt de rondes.

### Het byetype vragen {#asking-the-bye-type}

Standaard is een overgeslagen ronde waard wat de pagina Puntentelling voor een
afwezigheid betaalt, en daarmee is het gezegd. Sommige evenementen willen per
afwezigheid beslissen: een halvepuntsbye voor de speler die op tijd vroeg, een
nulpuntsbye voor de speler die dat niet deed. Zet **Het byetype vragen bij elke
afwezigheid** aan op de pagina Puntentelling, onder *Byes en afwezigheden*. Het
staat standaard uit, en alleen een individueel Zwitsers toernooi biedt het aan.

Staat het aan, dan toont het inschrijfformulier een regel voor elke ronde in
**Afwezig in de rondes** die nog niet is gepaard, met drie keuzes: **Bye van een
half punt**, **Bye van nul punt** en **Bye van een vol punt**. De keuze die de
pagina Puntentelling zou geven, is al aangeduid (met de twee limieten erbij), dus
voor de meeste afwezigheden is **Opslaan** de enige klik. Kies een andere waar het
antwoord verschilt.

- De keuze blijft bij de ronde. Het paren van de ronde laat de speler erbuiten en
  scoort de bye zoals gekozen; het ontparen van de ronde behoudt hem; de ronde uit
  de afwezigheden van de speler halen, verwijdert hem.
- Het FIDE-rapport schrijft hem met de eigen letter, in record 240 zolang de ronde
  niet is gepaard, en een import van dat bestand brengt dezelfde bye terug.
- De regels voor halvepuntsbyes hierboven tellen een gekozen halvepuntsbye mee: een
  tweede vraagt *Toch opslaan?*, en een speler die niet in aanmerking komt, kan er
  geen krijgen. Voor zo'n speler is de nulpuntsbye vooraf aangeduid.
- Een bye van een vol punt kiezen toont dezelfde melding als op de pagina Paringen:
  de paringsregels beschrijven hem niet, en hij moet uitzonderlijk blijven. De
  speler kan later geen door de paring toegekende bye meer krijgen, en zodra de
  ronde is gepaard, voegt het rapport de regel `### FPB` toe.

Dezelfde vraag komt terug in een ronde die al is gepaard: **Markeren als afwezig
voor deze ronde** op de pagina Paringen (zie [Byes met de hand](#byes-by-hand))
toont de drie keuzes in de bevestiging, op dezelfde manier vooraf aangeduid. Een
halvepuntsbye voor een speler die er niet voor in aanmerking komt, kan daar niet
worden toegepast; een tweede halvepuntsbye vraagt een eigen vinkje, *Ik begrijp
het - toch geven*; een bye van een vol punt toont de melding hierboven.

> [!NOTE]
> Een gekozen bye is geen afwezigheid meer, dus telt hij niet mee voor de limiet
> van de eerste N overgeslagen rondes die worden betaald, en ook de keuze die voor
> de volgende ronde wordt aangeduid, telt hem niet. Waar de twee limieten voor die
> ronde minder zouden betalen dan de gekozen bye (de limiet is opgebruikt, of de
> ronde ligt na de laatste betaalde, en u kiest toch een halvepuntsbye), zeggen het
> formulier en de bevestiging dat. Ze houden u niet tegen. De afwezigheidspunten
> later wijzigen, verandert een al gekozen bye niet.

> [!WARNING]
> Markeer de afwezigheden **voordat** u de ronde paart. Een speler die laat komt,
> kan weer als aanwezig worden gemarkeerd en met de hand worden gepaard (zie
> hieronder), of in de volgende ronde worden ingeschreven.

## De door de paring toegekende bye (oneven aantal spelers) {#the-pairing-allocated-bye-odd-number-of-players}

Als het aantal te paren spelers in een Zwitserse ronde oneven is, krijgt een van
hen de door de paring toegekende bye.

> [!FIDE] C.04.3
> De paringsengine kiest de speler volgens de regels van C.04.3: de bye gaat naar
> een speler in de laagste scoregroep waarin nog een legale paring van alle anderen
> mogelijk is, en nooit naar een speler die al eerder een door de paring toegekende
> bye had, een partij bij forfait won, of een bye van een vol punt kreeg.

De speler wordt op de pagina Paringen getoond als een bord met *bye*, en de
uitlegpagina zegt waarom die speler is gekozen en wat elke andere kandidaat zou
hebben gekost ([Een ronde paren](06-pairing.md)).

De bye wordt gescoord als de waarde **Door de paring toegekende bye** (Instellingen,
Puntentelling): standaard een winst, maar hij kan op een halve punt of op een andere
waarde worden gezet.

> [!NOTE]
> De waarde kan in de FIDE-modus niet worden gewijzigd na de eerste ronde.

In een rondetoernooi met een oneven aantal spelers zit elke speler één ronde uit
(het Berger-schema zet het hoogste nummer tegenover niemand). Het programma legt
die ronde vast als een bye van nul punten voor die speler. In Keizer scoort een
speler zonder tegenstander de helft van zijn eigen trede.

## Byes met de hand {#byes-by-hand}

In een gepaarde ronde laat de pagina Paringen u wijzigen wie tegen wie speelt, of
wie niet meespeelt. Het menu *Wijzigingen met de hand* (rechtsklik op de naam van
een speler in de ronde) biedt:

![Het menu Wijzigingen met de hand, geopend op de naam van een speler in een gepaarde ronde](screenshots/05-hand-edits-menu.png "Het menu Wijzigingen met de hand")

- **Markeren als afwezig voor deze ronde**: de plaats van de speler wordt
  leeggemaakt en de speler gaat naar de *Lijst met niet-spelenden*; met **Het
  byetype vragen bij elke afwezigheid** aan, vraagt de bevestiging welke bye het is
  ([Het byetype vragen](#asking-the-bye-type));
- **Paren met een andere speler die niet speelt…**: zet twee spelers van de
  *Lijst met niet-spelenden* op een eigen bord;
- **De door de paring toegekende bye geven** (aan een speler van de *Lijst met
  niet-spelenden*): geeft die speler de bye, gescoord zoals de pagina Puntentelling
  aangeeft;
- **Een bye toekennen aan de overblijvende speler**: geeft de door de paring
  toegekende bye aan de speler die alleen op een bord is overgebleven nadat zijn
  tegenstander is verwijderd;
- **Op een lege plaats zetten**, **Wisselen met…**, **Dit bord verwijderen…**.
- **Bye van een vol punt geven…** (aan een speler van de *Lijst met niet-spelenden*):
  de speler scoort een winst voor de ronde zonder te spelen. Het FIDE-rapport schrijft
  dat als `F`, met een regel `### FPB @ Round r`, en de speler kan in een latere ronde
  geen door de paring toegekende bye meer krijgen. **Bye van een vol punt intrekken…**
  maakt de speler weer afwezig.

> [!FIDE] Byes van een vol punt
> Eerst verschijnt een melding dat de paringsregels byes van een vol punt niet
> beschrijven en dat ze uitzonderlijk moeten blijven.

Elke wijziging met de hand toont eerst een bevestiging met de borden zoals ze nu
zijn en zoals ze zullen worden, en waarschuwt, met een vinkje, wanneer de bye naar
een speler zou gaan die er al een had, een partij bij forfait won, of een bye van
een vol punt had. Wijzigingen met de hand worden gemaakt in een sessie die wordt
gecontroleerd wanneer ze klaar is. Zie [Een ronde paren](06-pairing.md).

*Een halvepuntsbye of nulpuntsbye voor een komende ronde wordt aangevraagd door de
speler voor die ronde als afwezig te markeren: de pagina Puntentelling beslist wat
hij waard is, of, met **Het byetype vragen bij elke afwezigheid** aan, vraagt het
inschrijfformulier het (zie [Het byetype vragen](#asking-the-bye-type)).*

## Organisatorvoorkeuren voor byes {#organiser-s-bye-preferences}

Sommige evenementen willen een bye bij een speler vandaan houden (een lange reis),
of hem juist aan een bepaalde speler geven.

> [!FIDE] Afwijking van de FIDE-modus
> Deze voorkeuren zijn geen FIDE-regels. Ze staan standaard uit en worden niet
> toegepast wanneer het toernooi FIDE-gehomologeerd is.

Om ze te gebruiken, zet u **Byevoorkeuren** aan op de pagina Functies (accountmenu,
*Functies*, Belgisch pakket). Het formulier van de speler biedt dan *Uitsluiten van
de door de paring toegekende bye* en *Voorkeur voor de door de paring toegekende
bye*, elk voor alle rondes of voor bepaalde rondes:

- **Moet hem krijgen, als een legale paring dat toelaat** - de speler krijgt de bye
  wanneer de ronde er een heeft, mits de rest nog legaal gepaard kan worden en de
  speler er nog geen had (FIDE-regel C2 wordt nooit overschreven);
- **Krijgt hem liever** en **Liever niet** - beslissen tussen de spelers met de score
  die de bye krijgt, en tillen hem nooit naar een andere score.

**Uitsluiten van de door de paring toegekende bye** betekent dat de speler wordt
behandeld als iemand die al een bye had: de engine geeft hem die nooit. Wanneer geen
enkele legale ronde de bye bij elke uitgesloten speler vandaan kan houden, zegt de
pagina Paringen dat en biedt ze **Toch paren, zonder de uitsluiting van <naam>** aan.

Alles hiervan geldt alleen voor de Ainalrami-engine (ze worden niet aan JaVaFo
gegeven), en wordt vastgelegd in de uitleg van de ronde, het auditlogboek en de
notities van de TRF-export, omdat de ronde niet meer is wat een door FIDE
onderschreven programma zou paren.

## Byes in het FIDE-rapport {#byes-in-the-fide-report}

Het TRF-rapport (zie [Versturen naar FIDE](11-fide-report.md)) schrijft elke soort
met de eigen code: `U` voor de door de paring toegekende bye, `F` voor een bye van
een vol punt, `H` voor een halvepuntsbye, `Z` voor een nulpuntsbye of een afwezigheid,
`-` voor een forfaitverlies en `+` voor een forfaitwinst. Een bye die de arbiter al
heeft toegekend voor een ronde die nog niet is gepaard, wordt in record 240 geschreven.
