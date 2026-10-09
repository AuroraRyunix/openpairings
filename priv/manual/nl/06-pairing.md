# Een ronde paren

Paringen worden gemaakt op de pagina **Paringen**. Dit hoofdstuk behandelt het
paren van een ronde in elk systeem, de uitleg van een paring, het met de hand
wijzigen van een paring en het ongedaan maken van een ronde.

## De pagina Paringen {#the-pairings-page}

De pagina toont één ronde tegelijk. Een rij rondeknoppen bovenaan verplaatst u
naar andere rondes; een ronde die nog niet gepaard is, wordt leeg getoond met de
knop die haar paart. De tabel heeft één rij per bord: het bordnummer, de witte
speler, het resultaat en de zwarte speler. Een speler met een bye is een bord
met *bye* en zonder zwarte speler.

![De pagina Paringen met ronde 3 gepaard: rondeknoppen, de bordentabel en de menu's Afdrukken en Meer](screenshots/06-pairings-round-paired.png "Een gepaarde ronde op de pagina Paringen")

Naast de tabel heeft de pagina een menu **Afdrukken** (paringen, paringen met de
rubriek afwezigen, resultaatkaartjes, testafdruk, volgorde voor stapelsnijden),
een menu **Meer** (de livepagina, de publieke pagina, PGN, het importeren van
resultaten uit een CSV-bestand, ronde ontparen) en, voor een gepubliceerd
toernooi, de bediening die bepaalt wat toeschouwers van de ronde zien
([Publiceren](14-publishing.md)).

## Voor het paren {#before-pairing}

De knop **Ronde N paren** is beschikbaar wanneer

- de toernooi-instellingen compleet zijn: naam, aantal rondes, een datum voor
  elke ronde, tiebreaks. Ontbreekt er iets, dan toont de pagina de lijst en
  verwijst ze naar de pagina waar het wordt ingesteld;
- de vorige ronde op elk bord een resultaat heeft. Een bord zonder resultaat
  houdt de knop uitgeschakeld, met de melding *De vorige ronde heeft nog
  ontbrekende resultaten*. Als uitgestelde partijen zijn toegestaan (pagina
  Puntentelling), registreert een aparte knop, **Ontbrekende resultaten als
  uitgesteld vastleggen en ronde N paren**, de lege borden als uitgesteld en
  gaat verder, nadat u de waarschuwing hebt gelezen;
- de aanwezigheid van de spelers klopt: spelers die als afwezig zijn gemarkeerd,
  worden niet gepaard ([Byes en afwezigheden](05-byes-and-absences.md));
- er geen sessie met handmatige wijzigingen open staat op een eerdere ronde (zie
  *Een paring met de hand wijzigen*): de knop blijft dan uitgeschakeld, met de
  melding *Rond eerst de handmatige wijzigingen aan ronde N af*.

Vóór ronde 1 waarschuwt de pagina ook, zonder te blokkeren, wanneer het aantal
rondes niet kan worden gepaard voor het aantal spelers: een Zwitsers met meer
rondes dan de spelers zonder herhaalde partij toelaten ("Een ronde die niet
gepaard kan worden, moet met de hand gemaakt worden"), of een rondetoernooi
waarvan het aantal rondes niet overeenkomt met het aantal spelers. De
waarschuwing verwijst naar de instelling die dit oplost
([Toernooi-instellingen](03-tournament-setup.md)).

Rondes worden in volgorde gepaard. De pagina toont ook de controles die gelden
voor de volgende paring: bijvoorbeeld de spelers van elke uitgestelde partij uit
eerdere rondes, die op een voorlopige score worden gepaard, en de spelers wier
byevoorkeuren niet worden toegepast.

## Zwitsers {#swiss}

De knop luidt **Ronde N paren (Ainalrami)**, met de naam van de engine. Druk
erop en bevestig. Het programma

1. geeft de paringsnummers als dit de eerste ronde is (hoogste rating eerst; de
   startkleur wordt door loting bepaald, tenzij u die zelf instelt),
2. bouwt het toernooi op als TRF-bestand, controleert het en geeft het aan de
   engine,
3. leest de paringen van de engine, nummert de borden, kent de byes toe en
   slaat de ronde op.

Bij een groot veld kan dit tot een minuut duren; de knop meldt dat terwijl het
bezig is. De ronde wordt pas opgeslagen als het geheel is gelukt. Als de regels
voor de overgebleven spelers geen wettige paring toelaten, meldt het programma
dit en schrijft het niets weg.

> [!FIDE] C.04.3
> In elke ronde past de engine de absolute criteria van FIDE toe (geen herhaalde
> partij, de kleurregels, geen tweede door de paring toegekende bye) en daarna de
> kwaliteitscriteria in de volgorde die C.04.3 geeft.

Verboden paringen, de paringsregels (dezelfde club, dezelfde federatie, groepen)
die in de ronde gelden, en extra punten worden eveneens aan de engine doorgegeven ([Toernooi-instellingen](03-tournament-setup.md)).
Bij Baku-versnelling worden de virtuele punten voor elke ronde doorgegeven.

De paringsnummers worden toegekend in de volgorde van de toernooirating, daarna
de FIDE-titel, daarna het criterium dat het toernooi heeft aangekondigd
([Spelers en ratinglijsten](04-players-and-ratings.md)). Als de engine helemaal
geen wettige paring vindt, meldt het programma dit en biedt het **Ronde N met de
hand paren…** aan (zie *Een paring met de hand wijzigen*).

**Bordvolgorde.** De borden worden genummerd zoals C.04.2 art. 3.6 ze ordent:
eerst volgens de score van de hoger gerangschikte speler van het paar, hoogste
eerst; dan volgens de som van de scores van beide spelers; dan volgens het
paringsnummer van de hoger gerangschikte speler, laagste eerst. De door de
paring toegekende bye komt als laatste. Bij Baku-versnelling tellen de virtuele
punten mee in de scores.

Een speler met een **vaste tafel** ([Spelers en ratinglijsten](04-players-and-ratings.md))
wordt met die tafel gelabeld; dat is alleen een label voor het afdrukken en
verandert niet wie tegen wie speelt.

## Rondetoernooi {#round-robin}

Een rondetoernooi paart het **hele toernooi in één keer**: de knop luidt *Het
hele toernooi paren (Berger)*, en het programma vraagt om bevestiging.

> [!WARNING]
> Het schema kan achteraf niet meer worden gewijzigd, en spelers die later worden
> toegevoegd, staan er niet in.

De rondes volgen de Berger-tabellen van FIDE (C.05). Bij een oneven aantal
spelers rust elke speler één ronde uit met een bye van nul punten. Een dubbele
cyclus speelt de tabel tweemaal met omgekeerde kleuren (met de laatste twee
rondes van de eerste cyclus in omgekeerde volgorde, als die optie aanstaat). Een
speler die afwezig is of zich heeft teruggetrokken, blijft in het schema: voer
voor zijn partijen een forfaitresultaat in. De startnummers die de Berger-tabellen
gebruiken, zijn de ratingvolgorde, tenzij u ze vóór ronde 1 op de pagina Spelers
instelt (*Startnummers*, met de hand of door loting; [Spelers en ratinglijsten](04-players-and-ratings.md)).

Ernaast maakt **Ronde N met de hand paren…** de volgende ronde zelf in plaats
van die van de tabel
([Een rondetoernooi met de hand gepaard](#a-round-robin-paired-by-hand)).
Zodra er een ronde bestaat, luidt de hoofdknop *De resterende rondes paren
(Berger)* en paart die de rest uit de tabel - tenzij de met de hand gemaakte
rondes de tabel hebben verlaten en haar volgende ronde twee spelers zou paren
die elkaar in die cyclus al ontmoetten: dan weigert hij en zegt hij welke
twee.

## Keizer {#keizer}

Het Keizer-systeem rangschikt de spelers op een ladder: de speler op plaats *i*
is een aantal punten waard dat met elke plaats met één daalt; een overwinning
is de waarde van de tegenstander, een remise de helft daarvan. De ladder wordt
elke keer opnieuw berekend uit alle resultaten wanneer dat nodig is, zodat een
vroege overwinning meer waard wordt wanneer die tegenstander stijgt. Elke ronde
paart het programma van boven naar beneden: elke speler krijgt de dichtstbijzijnde
speler onder zich die nog niet is ontmoet, met terugzoeken. Kleuren worden gegeven
aan de speler die minder vaak wit heeft gehad. De hoogste waarde van de ladder
wordt ingesteld op de pagina Opties. De pagina Stand toont de Keizer-tabel in
plaats van de tiebreak-tabel.

## Teamtoernooien {#team-tournaments}

Voor Zwitserse en rondetoernooien met ploegen paart **Ronde N paren** ploeg
tegen ploeg: elke paring is een match, getoond in een tabel *Matches - ronde N*
boven de borden. De borden van een match worden bord tegen bord gespeeld (zie
[Ploegen](12-teams.md)). Zwitsers met ploegen volgt C.04.6 en wordt gepaard door
de ploegenengine van Ainalrami. Bij een groot veld draait die op de achtergrond
en toont de pagina dat ze bezig is.

## De paringsverantwoording (uitleg) {#the-pairing-rationale-explanation}

Elke ronde die door het programma is gepaard, heeft een uitleg: **Geavanceerd**,
daarna **Paringsverantwoording**, daarna de ronde. (Zolang de uitleg van een ronde
nog wordt uitgewerkt, leidt een link *De uitleg wordt uitgewerkt…* op de pagina
Paringen naar de uitleg.)

Voor een Zwitserse ronde die door Ainalrami is gepaard, toont de pagina

- een kaart van de scoregroepen, waarbij elke paring als lijn tussen de groepen
  is getekend, zodat zichtbaar is wanneer floaters van de ene groep naar de andere
  gaan;
- een kaart per bord met de kleuren, of de verschuldigde kleur is gegeven, en de
  floats;
- voor elke float en voor de bye de vraag *waarom deze speler en geen andere*.
  Open die om te zien wat elke andere kandidaat zou hebben gekost, in termen van
  de criteria van C.04.3, en of de keuze van de engine de beste is. De antwoorden
  worden uitgewerkt wanneer u een vraag opent, en worden opgeslagen.

Ook rondetoernooi en Keizer hebben een exacte verantwoording. Een Zwitserse
ronde zonder eigen verantwoording - gepaard voordat het programma er een
bijhield, of door een engine die het niet meer heeft - kan achteraf worden
geanalyseerd vanuit de borden zoals ze gespeeld zijn; de pagina biedt dat aan
en zegt dat ze het gedaan heeft.

Als een regel van de organisator de ronde heeft veranderd (een byevoorkeur, een
paarwens), meldt de pagina welk bord is verplaatst en wat de FIDE-regels alleen
zouden hebben gegeven.

## Voorvertoning van de volgende ronde {#preview-of-the-next-round}

Terwijl de laatste partijen van een Zwitserse ronde nog worden gespeeld, berekent
**Volgende ronde voorvertonen** (op de pagina Paringen) de volgende ronde voor
elke combinatie van de openstaande resultaten (zes of minder openstaande partijen;
tot 729 combinaties) en slaat niets op. Elk bord wordt dan getoond als **vast**
(hetzelfde in elke uitkomst: de naamkaartjes kunnen uit), **vast maar kan
verschuiven** (het bordbereik is gegeven), **vast met open kleuren**, of **open**,
met de spelers die erbij betrokken kunnen zijn en de partijen die het beslissen.
De voorvertoning werkt zichzelf bij wanneer een resultaat wordt ingevoerd, en kan
worden afgedrukt (vaste borden en een lijst op naam). Ze is beschikbaar voor
afzonderlijke Zwitserse toernooien, en pas als ze is
ingeschakeld: ze hoort bij het Belgische pakket onder Account, **Functies**
([Accounts](15-accounts-and-handoff.md)).

Een resultaat voor een van de openstaande partijen vraagt geen nieuwe paring: elke
al berekende combinatie wordt onthouden, dus de voorvertoning werkt meteen bij.
Het wissen van een resultaat berekent alleen de nieuwe combinaties opnieuw.

### Vaste borden aankondigen {#announcing-fixed-boards}

Wanneer de naamkaartjes van de vaste borden worden uitgegeven, drukt u in de
voorvertoning op **Vaste borden aankondigen**. Het afdrukken van de vaste borden
kondigt ze ook aan zolang **Afdrukken kondigt ze aan** is aangevinkt (dat staat
standaard aan). Elk bord wordt opgeslagen met zijn nummer, wit en zwart, het
tijdstip en wie het heeft aangekondigd, en het auditlogboek legt dit vast. De
pagina Paringen toont dan hoeveel borden van de volgende ronde zijn aangekondigd;
**Intrekken** verwijdert de aankondiging.

Als er iets verandert dat een aangekondigd bord kan breken - een resultaat buiten
de openstaande partijen, een forfait, een speler die is teruggetrokken, afwezig
is of is toegevoegd, een verboden paring, een instelling - dan meldt de pagina
dat. **Opnieuw controleren** berekent de voorvertoning opnieuw en somt de
aangekondigde borden op die niet meer zeker zijn.

Wanneer de ronde is gepaard, wordt elk aangekondigd bord vergeleken met de
paring. Verschilt de tegenstander, de kleur of het nummer van een bord, dan
toont een grote waarschuwing elk verschil, zowel aangekondigd als gepaard: neem
die naamkaartjes terug en druk de paring opnieuw af. De paring zelf wordt nooit
aangepast om aan een aankondiging gelijk te worden; dat zou de paring
manipuleren. Houden alle aangekondigde borden stand, dan zegt een korte regel
dat. Ontparen en opnieuw paren vergelijkt opnieuw.

## Chess960 {#chess960}

Als **Chess960** is aangevinkt op de pagina Instellingen van het toernooi, toont
de pagina Paringen bij een gepaarde ronde de knop **Chess960-stelling trekken**.
Die trekt willekeurig een van de 960 startstellingen (elk even waarschijnlijk),
toont het nummer en de stukken van de eerste rij, en drukt die af met de paringen
van de ronde. Een ronde krijgt één stelling: de trekking kan niet worden herhaald
totdat een stelling bevalt, en een tweede poging wordt geweigerd. De trekking
wordt in het auditlogboek opgenomen.

## Een paring met de hand wijzigen {#changing-a-pairing-by-hand}

Soms moet een paring worden gewijzigd nadat de ronde is gemaakt: een speler komt
te laat, er is een fout bij het invoeren, of twee spelers hebben onder een andere
naam tegen elkaar gespeeld. Het programma noemt dit een
**handmatige wijziging van de paring** en werkt met sessies.

> [!FIDE] C.04.2 4.4
> Het reglement staat een arbiter toe een paring te wijzigen, dus dit brengt het
> toernooi niet uit de FIDE-modus.

### De sessie {#the-session}

- Een sessie op een ronde **begint** met **Meer**, **Paringen met de hand
  aanpassen**, of impliciet met de eerste wijziging met de hand in de ronde. Zolang
  ze open is, toont een banner *Wijzigingen met de hand aan ronde N zijn open*,
  met de knop **Handmatige aanpassingen afronden**.
- Wijzigingen met de hand maakt u met het menu **Wijzigingen met de hand**:
  klik met de rechtermuisknop op een speler (of druk op de toets voor het
  contextmenu) op de pagina Paringen. Het menu biedt, afhankelijk van wat u hebt
  aangeklikt:

| Actie | Wat het doet |
| --- | --- |
| Wisselen met… | Klik op de speler, kies *Wisselen met…*, en klik daarna op een tweede speler op een bord: de twee wisselen van plaats. |
| Wisselen met een speler op een bord… | Wisselt een niet-spelende speler met een speler op een bord. |
| Op een lege plaats zetten | Zet een speler uit de lijst *Lijst met niet-spelenden* op een lege plaats. |
| Markeren als afwezig voor deze ronde | Haalt de speler van het bord en zet hem op de lijst *Lijst met niet-spelenden*. |
| Paren met een andere speler die niet speelt… | Paart twee spelers van de lijst *Lijst met niet-spelenden* op een nieuw bord; u kiest het tafelnummer. |
| De door de paring toegekende bye geven | Geeft een speler van de lijst *Lijst met niet-spelenden* de door de paring toegekende bye, gescoord zoals ingesteld op de pagina Puntentelling. |
| Een bye toekennen aan de overblijvende speler | Geeft de bye aan de speler die alleen op een bord is overgebleven, nadat de tegenstander is verwijderd. |
| Dit bord verwijderen… | Verwijdert een leeg bord (een volledig leeggemaakt bord kan worden verborgen en weer zichtbaar gemaakt). |

- De sessie **eindigt** pas wanneer u op **Handmatige aanpassingen afronden**
  drukt. De volgende ronde kan niet worden gepaard zolang een sessie open is, zodat
  de controle hieronder niet kan worden overgeslagen door door te gaan.

Elke wijziging toont eerst een bevestiging met de borden vóór en na de wijziging,
die u accepteert of annuleert (<kbd>Escape</kbd> annuleert). Terwijl een wijziging
half is gemaakt, toont een banner dat. Een resultaat op een bord dat u wijzigt,
wordt gewist; de bevestiging meldt dat. Elke wijziging wordt in het auditlogboek
vastgelegd.

![De bevestiging van een wijziging met de hand, met de borden vóór en na de wijziging](screenshots/06-hand-edit-confirmation.png "Een wisseling bevestigen")

### Regelwaarschuwingen bij het bewerken {#rule-warnings-while-editing}

Voor een toernooi dat de controleur kan beoordelen (een individueel Nederlands
Zwitsers, zie hieronder) somt de bevestiging van een wijziging ook de paringsregels
op die de borden die ze maakt zouden breken:

- twee spelers die al tegen elkaar hebben gespeeld, of een verboden paring;
- de door de paring toegekende bye voor een speler die er al een had, een partij
  bij forfait had gewonnen, of een bye van een volle punt had;
- een speler die voor de derde keer achter elkaar dezelfde kleur krijgt, of een
  kleurverschil boven twee, vóór de laatste ronde;
- twee spelers die beiden de tegenovergestelde kleur krijgen van die welke elk
  verschuldigd is.

Zo'n wijziging wordt pas toegepast nadat u het vakje hebt aangevinkt waarmee u de
waarschuwing bevestigt. Een wijziging die niets breekt, heeft geen vinkje nodig.

### Afronden: de controle met de paringscontroleur {#finishing-the-check-against-the-pairing-checker}

**Handmatige aanpassingen afronden** vraagt eerst dat elke plaats is gevuld (vul
hem in, geef de overgebleven speler een bye, of maak het bord leeg) en dat ten
minste één bord is gepaard. Daarna draait het programma de paringsengine over de
spelers zoals de ronde ze nu plaatst, en vergelijkt de paring met uw borden, met
kleuren maar zonder de volgorde van de borden:

- **Niets is veranderd sinds de sessie begon, of de borden zijn die van de engine:**
  de sessie eindigt; er wordt niets vastgelegd.
- **De borden verschillen van de paring van de engine:** een dialoog toont de
  paring van de controleur, wat alleen in uw paring staat en wat alleen in die van
  de controleur staat, en de regelwaarschuwingen die nog gelden. Kies **Verder
  aanpassen** om terug te gaan, of vink *Ik begrijp het - houd mijn paringen en
  leg de wijziging vast* aan en druk op **Afronden en vastleggen**. De ronde
  behoudt uw borden en legt de wijziging vast. De TRF-kopieën van het verslag
  bevatten die als commentaarregel:
  `### MPA @ Round r: <checker's boards> => <the round's boards>`. Opnieuw afronden
  van een sessie vervangt de regel van die ronde, of verwijdert hem wanneer de
  borden nu met de engine overeenkomen. Het bestand dat *Versturen…* maakt,
  bevat alleen records, dus het heeft geen zo'n regel ([Verzenden naar FIDE](11-fide-report.md)).
- **De controleur kan de ronde niet beoordelen** (het is een controle op het
  Nederlandse systeem, dus een ploegen-, rondetoernooi-, Keizer-, per-categorie- of
  Zwitsers-matchformaatronde valt buiten zijn bereik): als de borden verschillen van
  waar de sessie begon, wordt de wijziging vastgelegd zonder controle.

### Een ronde zonder wettige paring {#a-round-with-no-legal-pairing}

Als de regels voor de volgende ronde geen wettige paring toelaten, meldt het
programma dit en schrijft het niets weg. De pagina Paringen biedt dan **Ronde N
met de hand paren…** aan. De dialoog zegt dat de ronde wordt gemaakt zonder borden
en met elke speler op de lijst *Lijst met niet-spelenden*, en dat geen paring van
de ronde de regels kan volgen, zodat de ronde wordt vastgelegd als handmatige
wijziging van de paring. U bevestigt met het vinkje *Ik begrijp het - maak ronde N
om met de hand te paren*. Na **Ronde N maken** paart u de spelers uit de lijst
(twee spelers paren, de door de paring toegekende bye geven) en rondt u de
handmatige wijzigingen af zoals hierboven.

### Een rondetoernooi met de hand gepaard {#a-round-robin-paired-by-hand}

In een rondetoernooi (één tabel voor het hele veld, niet in matchvorm, geen
teamtoernooi) staat **Ronde N met de hand paren…** naast de Berger-knop. De
dialoog zegt dat de ronde wordt gemaakt zonder borden en met elke speler op
de lijst *Lijst met niet-spelenden*, en dat een ronde die van de tabel afwijkt
wordt vastgelegd als handmatige wijziging van de paring; u bevestigt met het
vinkje *Ik begrijp het - ronde N aanmaken om met de hand te paren*. Paar daarna
telkens twee spelers uit de lijst. Een speler die u buiten de borden laat,
rust die ronde uit met de bye van nul punten van het rondetoernooi, gegeven
bij het afronden; de door de paring toegekende bye wordt in een rondetoernooi
niet aangeboden.

Elk bord wordt gecontroleerd terwijl u het maakt, en een overtreding vraagt
een eigen vinkje:

- **Twee spelers die elkaar in deze cyclus al ontmoeten** - in een enkel
  rondetoernooi ontmoet iedereen iedereen precies één keer, in een dubbel één
  keer per cyclus.
- **Een derde keer dezelfde kleur op rij** - een speler die in drie
  opeenvolgende rondes wit (of zwart) krijgt. De Berger-tabel doet dat binnen
  een cyclus nooit; een hand doet het makkelijk.

**Handmatige aanpassingen afronden** vergelijkt de ronde met dezelfde ronde van
de Berger-tabel, en controleert of de rondes die in de cyclus overblijven nog
iedereen die elkaar nog niet ontmoette precies één keer kunnen paren (een
speler die in een even veld buiten de ronde blijft, kan bijvoorbeeld niet meer
bijbenen). Wijkt de ronde af van de tabel, dan toont de dialoog de borden van
de tabel, de verschillen, elke overtreding en de regel die de TRF krijgt,
bijvoorbeeld `### MPA @ Round 1: 1-4 2-3 => 1-2 3-4` (startnummers; `5=BYE`
voor de speler die uitrust). Zoals bij een Zwitserse ronde behoudt het vinkje
*Ik begrijp het - mijn paringen behouden en de wijziging vastleggen* ze. Ook de
eerdere rondes van een rondetoernooi kunnen zo met de hand worden gewijzigd,
en worden op dezelfde manier beoordeeld.

### Andere bevestigingen {#other-confirmations}

- **Een ronde die niet de laatste is.** Het wijzigen van een eerdere ronde vraagt
  om een vinkje, omdat latere rondes erop zijn gebaseerd. In de FIDE-modus kunnen
  alleen de laatste twee gespeelde rondes worden gewijzigd ([FIDE-modus](02-fide-mode.md)).
- **Een ronde die al naar het ratingkantoor is verzonden.** Het wijzigen van wie
  tegen wie speelde in een verzonden ronde vraagt het vinkje *Ik begrijp het - wijzig
  toch de verzonden ronde N* ([Verzenden naar FIDE](11-fide-report.md)).

## Een ronde ongedaan maken {#undoing-a-round}

> [!WARNING] Ontparen verwijdert resultaten
> **Meer**, **Ronde ontparen** (alleen bij de laatste gepaarde ronde getoond)
> verwijdert die ronde en elk resultaat erin, na een bevestiging. Het programma
> maakt eerst een herstelpunt ([Accounts, delen en overdracht](15-accounts-and-handoff.md)).

Bij een Zwitsers matchformaat horen de twee rondes van een match bij elkaar. Een
ronde die naar het ratingkantoor is verzonden, kan niet worden ontpaard.

## Resultaten invoeren {#entering-results}

Resultaten worden op dezelfde pagina ingevoerd. Zie [Uitslagen](07-results.md).
