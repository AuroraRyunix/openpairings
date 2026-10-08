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

- **Versturen…** - maakt het bestand voor het ratingbureau en **markeert elke partij
  erin als verstuurd**, in één stap. Het bestand krijgt een naam naar het type
  van het toernooi, het FIDE-toernooi-ID, de naam en de rondes. Het bevat alleen
  de records van het rapport, geen opmerkingen.
- **Een kopie downloaden (niet voor rating)** en **Alle rondes (TRF-kopie, niet voor
  rating)** - kopieën voor uw eigen gebruik of een ander programma. De bestandsnaam
  eindigt op `COPY-NOT-FOR-RATING` en het bestand zegt dat in een `###`-commentaarregel.

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

In de FIDE-modus wordt er niets verstuurd en geen kopie gemaakt zolang een
uitgestelde partij geen resultaat heeft. De pagina Exporteren toont de
openstaande partijen: voer elk resultaat in, of druk op **Niet gespeeld in dit
toernooi**. Dat vraagt het twee keer en haalt het toernooi uit de FIDE-modus;
de kopieën dragen dan `### Not played @ Round 3: 5-12` voor die partij, en het
bestand voor de rating schrijft ze als niet gespeeld (`0000 - Z`).

Een partij die gespeeld wordt nadat haar ronde verstuurd is, wordt gerapporteerd als een **apart toernooi**
met een eigen naam en een eigen FIDE-toernooi-ID, en FIDE rate maand na maand. Instellingen, Exporteren,
sectie *Uitgestelde partijen* toont elke uitgestelde partij met haar status, de datum waarop
ze gespeeld is en het bestand waarin ze zit:

- Voer de **speeldatum** van elke partij in (wordt ingesteld wanneer ze voor het eerst gespeeld wordt; later wijzigen
  is een aparte stap die in het auditlogboek wordt vastgelegd).
- Voer de **toernooinaam** van het bestand met uitgestelde partijen in (standaard de naam van de competitie
  plus *uitgestelde partijen*) en het **FIDE-toernooi-ID** ervan.
- **Dit bestand maken** maakt het bestand voor één ratingperiode (maand); *Versturen…* markeert
  de partijen erin als verstuurd. Een paginanotitie zegt welke maand het is en dat het bestand
  vóór het einde van die maand verstuurd moet zijn. Een partij die in haar ronde met de echte
  uitslag is verstuurd, wordt nooit opnieuw aangeboden.

## Controles {#checks}

- Voordat het bestand het programma verlaat, wordt elke uitslagcode en elk paar tegenstanders gevalideerd;
  een fout stopt de download met een melding.
- Het bestand terug importeren in OpenPairings (of in een ander programma) is de beste
  controle dat het zegt wat u denkt dat het zegt ([Importeren en exporteren](10-import-export.md)).
- Een **ratingvalidator** (YAML) wordt aangekondigd op de pagina Exporteren en is nog niet beschikbaar.

## Normrapporten {#norm-reports}

Het IT3-toernooirapport en de formulieren voor arbiter- en spelersnormen zijn afzonderlijke Excel-bestanden;
zie [Categorieën en normen](13-categories-and-norms.md).
