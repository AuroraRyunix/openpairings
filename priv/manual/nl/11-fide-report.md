# Naar FIDE sturen: het ratingrapport

Een gerate toernooi wordt aan FIDE gerapporteerd in een TRF-bestand (Tournament Report File).
OpenPairings maakt het bestand; **het uploadt het niet**. U (of de ratingofficier
van uw federatie) stuurt het bestand naar de ratingserver van FIDE, op de manier
die uw federatie gebruikt. De taak van het programma is een correct bestand
maken, ervoor zorgen dat geen enkele partij twee keer wordt gerapporteerd, en
een logboek bijhouden van wat er verstuurd is.

## Vóór het rapport {#before-the-report}

Instellingen, **FIDE**:

- vink **Dit toernooi is FIDE-gehomologeerd (gerate/rapporteerbaar)** aan wanneer de
  competitie gerate moet worden; het FIDE-toernooi-ID is dan verplicht;
- **FIDE-toernooi-ID**: het ID van het toernooi; als verschillende delen van de
  competitie verschillende ID's hebben, vul dan **FIDE-ID-bereiken per ronde** in (van ronde,
  tot ronde, ID);
- **FIDE-evenementcode**.

Instellingen, **Toernooi** (en **Geavanceerd**, **Normen**): de hoofdarbiter en de
plaatsvervangers met hun FIDE-ID's, de federatie, de locatie, het speeltempo en
de data. Het programma herinnert u aan de aanbevolen velden op de pagina's Spelers
en Paringen; geen daarvan blokkeert de paring.

> [!FIDE] Byeuitsluiting en bye-voorkeur
> De pagina Exporteren vermeldt welke rondes gewijzigd zijn door een byeuitsluiting of een bye-voorkeur (regels van de organisator, niet van FIDE), omdat de TRF ze niet kan vastleggen en een controleprogramma dat het bestand naspeelt die rondes anders zou paren ([FIDE-modus](02-fide-mode.md), [Byes en afwezigheden](05-byes-and-absences.md)).

> [!WARNING]
> Een TRF kan niet worden gemaakt zolang niet elke ronde een datum heeft.

## De pagina Exporteren {#the-export-page}

Instellingen, **Exporteren**, sectie *TRF (FIDE-ratingrapport)*. Een tabel toont elke gepaarde ronde
met haar borden en haar status:

| Status | Betekenis |
| --- | --- |
| *Wordt gespeeld* | Een bord heeft nog geen uitslag: de ronde kan nog niet verstuurd worden. |
| *Klaar om te versturen* | Elk bord heeft een uitslag. |
| *Verstuurd* | De ronde is verstuurd; de datum en een ontvangstcode worden getoond (bijvoorbeeld `R5·7F2A`). |

![De pagina Exporteren, sectie TRF, met rondes in de statussen Wordt gespeeld, Klaar om te versturen en Verstuurd](screenshots/11-export-trf-rounds.png "Rondes en hun status op de pagina Exporteren")

Vink de rondes aan die u wilt en druk op:

- **Versturen…** - maakt het bestand voor het ratingbureau, downloadt het naar uw computer en **markeert elke partij
  erin als verstuurd**, in één stap. Het bestand krijgt een naam naar het type
  van het toernooi, het FIDE-toernooi-ID, de naam en de rondes. Het bevat alleen
  de records van het rapport, geen opmerkingen.
- **Een kopie downloaden (niet voor rating)** en **Alle rondes (TRF-kopie, niet voor
  rating)** - kopieën voor uw eigen gebruik of een ander programma. De bestandsnaam
  eindigt op `COPY-NOT-FOR-RATING` en het bestand zegt dat in een `###`-commentaarregel.

> [!IMPORTANT]
> **Downloaden is niet versturen.** *Versturen…* bezorgt niets bij wie dan ook:
> u krijgt het bestand, en het programma noteert dat het is afgegeven. U moet
> het gedownloade bestand daarna zelf nog naar uw ratingverantwoordelijke sturen
> (per e-mail, of zoals uw federatie het vraagt). De bevestiging zegt het, de
> regel onder de knop zegt het, en de pagina zegt het na de download nog eens,
> met de code van het ontvangstbewijs.

> [!WARNING]
> Een verstuurde ronde kan niet opnieuw verstuurd worden, en kan niet ongedaan gemaakt worden
> door de paring ervan te wissen. Een verstuurde uitslag kan alleen na een bevestiging gewijzigd worden;
> wijzigen wie tegen wie speelde in een verstuurde ronde, of de afwezigheid van een speler daarin,
> vraagt een vinkje *Ik begrijp het - verstuurde ronde N toch wijzigen*. Dit beschermt
> tegen het twee keer rapporteren van een partij.

Regels die hieruit volgen:

- Twee arbiters die tegelijk op **Versturen…** drukken, kunnen niet allebei een bestand krijgen:
  de database houdt één record per verstuurde partij bij en weigert de tweede.
- Een kopie die naar een andere computer is overgedragen, en een gearchiveerd toernooi,
  versturen niets.
- Een toernooi dat geïmporteerd is uit een back-up, een TRF of een SWAR-bestand is mogelijk al
  gerapporteerd. Zo'n kopie verstuurt niets totdat u **Deze kopie meldt de uitslagen: versturen toelaten**
  aanvinkt op de pagina Exporteren, om te bevestigen dat deze kopie degene is die rapporteert.
- Het programma bewaart van elke verzending een **ontvangstbewijs** (een code, de partijen, wie
  heeft verstuurd en wanneer). Als een uitslag, een naam of een FIDE-ID wordt gewijzigd nadat een ronde
  verstuurd is, tonen de ronde en de pagina Exporteren *Gewijzigd na verzending*, met elke wijziging,
  zodat u die kunt corrigeren met het ratingbureau. Er wordt nooit uit zichzelf opnieuw iets verstuurd.

## De inhoud van het bestand {#the-contents-of-the-file}

Het bestand is TRF26. Naast de rijen van de spelers (de startrangorde, naam, FIDE-ID,
rating, titel, federatie, geboortedatum, punten, rangschikking en het resultaat van elke
ronde met de tegenstander en de kleur) bevat het de kopregels en de records van het
toernooitype die vermeld staan in [Importeren en exporteren](10-import-export.md).
Voor elke ronde zijn de uitslagcodes `1`, `=`, `0` voor gespeelde partijen, `+` en
`-` voor forfaits, `U` voor de door de paring toegekende bye, `H` voor een halvepuntsbye, `F` voor een
volpuntsbye, `Z` voor een nulpuntsbye of een afwezigheid. Een uitgestelde partij waarvan de uitslag
onbekend is, is `?` in een kopie.

Het bestand voor het ratingbureau bevat nooit `?`: een uitgestelde partij die nog open is wanneer
de ronde wordt verstuurd, wordt geschreven als **niet gespeeld** voor beide spelers.
Zo wordt de partij niet twee keer gerate en ook niet verloren; zie hieronder.

> [!NOTE] Verlaten FIDE-modus
> Als het toernooi de FIDE-modus heeft verlaten, vermelden de kopieën vanaf welke ronde in een
> `###`-commentaarregel. Het bestand dat **Versturen…** maakt bevat alleen records: geen
> commentaarregels, geen kolomlineaal.

## Uitgestelde partijen {#postponed-games}

In de FIDE-modus wordt geen bestand verstuurd of gekopieerd dat de ronde van
een uitgestelde partij zonder resultaat bevat. Een bestand met alleen de ronden
ervoor wordt gewoon gemaakt, zoals de kopie in de ratinginbox van een eerder
verstuurde ronde. De pagina Exporteren toont de
openstaande partijen: voer elk resultaat in, of druk op **Niet gespeeld in dit
toernooi**. Dat vraagt het twee keer en haalt het toernooi uit de FIDE-modus;
de kopieën dragen dan `### Not played @ Round 3: 5-12` voor die partij, en het
bestand voor de rating schrijft ze als niet gespeeld (`0000 - Z`).

## Tijdens het toernooi gewijzigde verboden paringen {#prohibitions-changed-during-the-event}

Een verboden paring of een paringsregel die na het paren van ronde 1 wordt
toegevoegd, gewijzigd of verwijderd, staat in de TRF-kopieën, één regel per ronde
waarop ze voor het eerst inwerkt, bijvoorbeeld `### Prohibition @ Round 4: 5-12
added; rule same club removed`. In de FIDE-modus is de eerste zulke wijziging ook
de ronde waarin het toernooi die modus verliet ([FIDE-modus](02-fide-mode.md)).
Het bestand voor de rating bevat alleen records en draagt zo'n regel niet.

Een partij die gespeeld wordt nadat haar ronde verstuurd is, wordt gerapporteerd als een **apart toernooi**
met een eigen naam en een eigen FIDE-toernooi-ID, en FIDE rate maand na maand. Instellingen, Exporteren,
sectie *Uitgestelde partijen* toont elke uitgestelde partij met haar status, de datum waarop
ze gespeeld is en het bestand waarin ze zit:

- Voer de **speeldatum** van elke partij in (wordt ingesteld wanneer ze voor het eerst gespeeld wordt; later wijzigen
  is een aparte stap die in het auditlogboek wordt vastgelegd).
- Voer de **toernooinaam** van het bestand met uitgestelde partijen in (standaard de naam van de competitie
  plus *uitgestelde partijen*) en het **FIDE-toernooi-ID** ervan.
- **Dit bestand maken** maakt het bestand voor één ratingperiode (maand); *Versturen…* downloadt het en markeert
  de partijen erin als verstuurd - en zoals bij een ronde stuurt u het gedownloade bestand
  zelf naar uw ratingverantwoordelijke. Een paginanotitie zegt welke maand het is en dat het bestand
  vóór het einde van die maand verstuurd moet zijn. Een partij die in haar ronde met de echte
  uitslag is verstuurd, wordt nooit opnieuw aangeboden.

## Controles {#checks}

- Voordat het bestand het programma verlaat, wordt elke uitslagcode en elk paar tegenstanders gevalideerd;
  een fout stopt de download met een melding.
- Het bestand terug importeren in OpenPairings (of in een ander programma) is de beste
  controle dat het zegt wat u denkt dat het zegt ([Importeren en exporteren](10-import-export.md)).
- **Ontvangstbewijs (JSON)** op de pagina Exporteren downloadt het ontvangstbewijs van één verstuurd bestand: code en vingerafdruk, ronde of periode, wie het verstuurde en wanneer, de partijen zoals verstuurd, en de SHA-256 en naam van het bestand. Het ontvangstbewijs bewaart ook het exacte bestand; de ratinginbox downloadt en controleert dat bestand.

## De inbox per ratingperiode {#the-rating-period-inbox}

Voor de ratingverantwoordelijke, die beheerder van de installatie is:
**Ratinginbox**, in het menu **Account** op elke pagina en bovenaan de pagina
*Beheer*. Alleen een beheerder ziet die links; op de pagina Exporteren van een
toernooi heeft een beheerder ook een kleine link *De ratinginbox openen* onder
de knop Versturen. De inbox toont per FIDE-ratingperiode wat voor de rating is
verstuurd, wat nog ontbreekt, welke uitgestelde partijen nog openstaan en voor
welke ratinglijst elk bestand bestemd is. Een ronde telt mee voor de maand van
haar datum.

**Welke toernooien erin staan.** Een toernooi waarvan minstens één bestand is
verstuurd, en een toernooi dat als **FIDE-gehomologeerd** is aangeduid
(Instellingen, FIDE). Niets anders: een clubavond die niet als FIDE-gehomologeerd
is aangeduid en nooit iets verstuurde, verschijnt niet. *Nog niet verstuurd:
ronde N is afgelopen en heeft geen ontvangstbewijs* wordt alleen gezegd van een
toernooi dat als FIDE-gehomologeerd is aangeduid; een toernooi dat dat niet is maar
ooit een ronde verstuurde, staat er met dat ontvangstbewijs en het label *niet
aangeduid als FIDE-gehomologeerd*, en van zijn andere rondes wordt niets verwacht.
Het vinkje FIDE-gehomologeerd is de enige instelling die zegt dat een toernooi
geratet wordt; voor een nationale rating bestaat er geen.

*Verstuurd* betekent dat de arbiter op **Versturen…** drukte en dat het bestand
naar zijn computer werd gedownload. Of hij het daarna naar u heeft
doorgestuurd, kan de pagina niet weten: **Bestand downloaden** geeft datzelfde
bestand, voor het geval het nooit is aangekomen.

**De ratinglijst.** FIDE publiceert op de eerste dag van elke maand een lijst,
en de inbox noemt een lijst bij die datum. Het bestand moet op tijd zijn
geüpload voor de lijst na de maand waarin het toernooi eindigde, of voor de
lijst een maand later als het eindigde met vijf dagen of minder over in zijn
maand (B.02 art. 9.1); een bestand met uitgestelde partijen telt vanaf de datum
van zijn laatste partij. Een toernooi dat langer dan 30 dagen duurt, rapporteert
elke maand (art. 4.1): zijn rondes van een maand tellen dus vanaf de laatste
daarvan, niet vanaf het einde van het toernooi. De oktoberrondes van een
kampioenschap dat tot april loopt, zijn voor de lijst van 1 november. Bij elk
toernooi staat hoe het ervoor staat:

- *Voor de ratinglijst van 1 …: te uploaden tegen …* - op tijd.
- In oranje, *De ratinglijst van … is gemist* (bij een maandrapport: *Achterstallig*) -
  die lijst is voorbij; de regel noemt de eerstvolgende lijst die het nog kan
  halen en de dag waarna het helemaal niet meer geratet wordt.
- In rood, *Wordt niet geratet* - het heeft de derde lijst na de laatste dag
  van het toernooi gemist.

Niets wordt geweigerd: een laat bestand kan nog altijd verstuurd worden, en de
inbox toont de lijst waarin het terechtkomt. Elk verstuurd bestand kan worden
gedownload (**Bestand downloaden**) en tegen de controle afgespeeld
(**Controleren**), die elke ronde tot en met dat bestand opnieuw paart en zegt of
de borden en de stand overeenkomen. Het ontvangstbewijs bewaart het exacte
bestand dat verstuurd werd (tot 2 MB). Een bestand dat verstuurd werd voordat de
ontvangstbewijzen hun bestand bewaarden, heeft er geen: de inbox biedt dan een
kopie aan, opnieuw opgebouwd uit het toernooi zoals het nu is, met het label
*opnieuw opgebouwde kopie* - wat niet noodzakelijk is wat verstuurd werd.

## Normrapporten {#norm-reports}

Het IT3-toernooirapport en de formulieren voor arbiter- en spelersnormen zijn afzonderlijke Excel-bestanden;
zie [Categorieën en normen](13-categories-and-norms.md).
