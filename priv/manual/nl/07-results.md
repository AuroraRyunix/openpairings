# Resultaten en uitgestelde partijen invoeren

## Een resultaat invoeren {#entering-a-result}

Resultaten worden ingevoerd op de pagina **Paringen**, in de tabel van de ronde.
Elk bord heeft een resultaatveld tussen de twee spelers.

### Met het toetsenbord {#with-the-keyboard}

Klik op het resultaatveld van het eerste bord om het de focus te geven (één klik;
de lijst opent niet). Typ daarna

- <kbd>1</kbd> voor een overwinning voor wit (1-0),
- <kbd>2</kbd> voor een remise (½-½),
- <kbd>3</kbd> voor een overwinning voor zwart (0-1).

Het resultaat wordt opgeslagen en de focus gaat naar het volgende bord, zodat
<kbd>1</kbd><kbd>3</kbd><kbd>1</kbd><kbd>3</kbd><kbd>1</kbd><kbd>2</kbd>
zes borden invult zonder de muis aan te raken. De cijfers worden gelezen op basis
van de fysieke toets, dus de bovenste rij en het numerieke toetsenblok werken
allebei, op elke toetsenbordindeling. De pijltjestoetsen lopen door de andere
waarden heen zonder elke waarde onderweg op te slaan; een tweede klik op het veld
opent de lijst, voor de resultaten die geen cijfer hebben.

![De resultatenkolom van een ronde, met de resultatenlijst open bij één bord](screenshots/07-result-entry.png "Resultaten invoeren op de pagina Paringen")

### Met de muis of een telefoon {#with-the-mouse-or-a-phone}

Kies het resultaat uit de lijst. Op een telefoon of een smal scherm heeft elk bord
ook drie grote knoppen, 1-0, ½-½ en 0-1; de knop van het opgeslagen resultaat is
ingedrukt. Drukt u op de ingedrukte knop nogmaals, dan verandert er niets.

### De resultaten in de lijst {#the-results-in-the-list}

| Resultaat | Betekenis |
| --- | --- |
| 1-0, ½-½, 0-1 | de gewone resultaten |
| ½-0, 0-½ | een remise met een disciplinaire puntcorrectie |
| 1-0 FF, 0-1 FF | een overwinning op forfait (de partij is niet gespeeld) |
| 0-0 FF | een dubbel forfait: geen van beide spelers is komen opdagen |
| 0-0 | beide verliezen, de partij is gespeeld |
| 1-0, 0-1, ½-½ "gespeeld, niet gerate" | een partij die gespeeld is maar niet gerate is |
| * uitgesteld door wit / door zwart | een uitgestelde partij (alleen als het toernooi dat toestaat) |
| … (leeg) | geen resultaat |

Een forfait is een niet-gespeelde partij voor de tiebreaks van C.07
([Stand en tiebreaks](08-standings-and-tiebreaks.md)); een partij die gespeeld is
maar niet gerate is, is een gespeelde partij die FIDE niet rate.

### Een resultaat wissen en corrigeren {#clearing-and-correcting-a-result}

Het kiezen van de lege waarde op een bord dat al een resultaat heeft, wist het niet
meteen: een vakje vraagt *Het geregistreerde resultaat wissen?* en u bevestigt met
**Ja, wis het**, of annuleert. Een resultaat wijzigen in een ander resultaat wordt
meteen opgeslagen en in het auditlogboek vastgelegd, met de oude en de nieuwe
waarde.

Een resultaat in een ronde die al naar het ratingkantoor is **verzonden**, wordt
pas na een bevestiging gewijzigd.

> [!FIDE]
> In de FIDE-modus kan een resultaat alleen worden gewijzigd in de laatste twee
> gespeelde rondes ([FIDE-modus](02-fide-mode.md)); een eerdere fout wordt na het
> toernooi gecorrigeerd, in het verslag aan het ratingkantoor.

### Een resultaat alleen voor het ratingverslag corrigeren {#correcting-a-result-for-the-rating-report-only}

Een fout resultaat dat wordt ontdekt nadat de volgende ronde al is afgelopen, kan
de paringen die ermee zijn gemaakt niet meer veranderen (C.04.2:4.3). Onder elk
afgerond bord van zo'n ronde registreert **Corrigeren voor de rating…** het juiste
resultaat alleen voor het ratingverslag: de paringen en de stand houden het
resultaat dat ze gebruikten, het FIDE-verslag bevat het gecorrigeerde resultaat, en
de TRF26-kopie ervan voegt een regel `### Rating correction @ Round r` toe die
zegt welk resultaat het evenement gebruikte. Het gewone wijzigen van het resultaat
van het bord verwijdert de correctie.

Wanneer het laatste resultaat van een ronde binnen is, kan de volgende ronde worden
gepaard.

## Resultaten uit een bestand (CSV) {#results-from-a-file-csv}

**Meer**, **Resultaten importeren (CSV)** leest een bestand met per bord één regel
`bord,resultaat` (komma of puntkomma; een optionele kopregel). Het bordnummer is
het nummer dat op het paringsblad staat. Geaccepteerde resultaatwoorden: `1-0`,
`0-1`, `1/2-1/2` (ook `½-½`, `0.5-0.5`, `=`), `½-0`, `0-½`, `0-0`, `X`, `1-0FF`,
`0-1FF`, `0-0FF` (`+/-`, `-/+`, `-/-`), de niet-gerate vormen met `U`, en `*W`,
`*B`. Borden die niet worden genoemd, behouden hun resultaat.

> [!NOTE]
> **Er wordt niets opgeslagen tenzij elke regel geldig is**: de pagina somt elk
> probleem op (maximaal 50) en u corrigeert het bestand en verstuurt het opnieuw.

## Resultaten via telefoons {#results-from-phones}

De pagina **Live** van een toernooi (pagina Paringen, **Meer**, *Lokale weergave &
telefoon-QR*) toont de ronde voor projectie en heeft een kaart **Een telefoon
inschrijven om resultaten in te voeren**. Die maakt een QR-code en een code van
8 cijfers. Een helper scant de QR-code of typt de code op zijn eigen telefoon, en
kan daarna resultaten voor dat toernooi invoeren, zonder account.

- Een **helpertelefoon** vult borden in die nog geen resultaat hebben, alleen in de
  laatst gepaarde ronde, en kan een resultaat dat al is vastgelegd niet wijzigen.
- Een **deputy-telefoon** kan in elke ronde een resultaat invoeren en corrigeren.
- Een telefoon kan worden beperkt tot een reeks borden.

De code verloopt na 24 uur en kan op elk moment worden ingetrokken op dezelfde kaart.
Het scherm van de telefoon toont de ratings en scores van de spelers, heeft een
slot dat tegen per ongeluk aantikken beschermt, en een eigen wisselaar voor het
thema. Een telefoon kan niets anders in het programma bereiken.

## Uitgestelde partijen {#postponed-games}

Een partij die niet in haar ronde kan worden gespeeld (verplaatst door
overeenkomst of uitgesteld), is **uitgesteld**. Het toernooi gaat door.

**Zet het aan.** Instellingen, Puntentelling, *Uitgestelde partijen*: **Uitgestelde
partijen toelaten**. Met dit uit, wordt nergens een uitgesteld resultaat aangeboden.
Op dezelfde pagina stelt u in wat een uitgestelde partij telt tot ze is gespeeld,
voor de speler die haar heeft uitgesteld en voor de tegenstander: standaard een
remise voor beiden. De waarde wordt bij elke partij opgeslagen wanneer ze wordt
uitgesteld, dus een latere wijziging van de instelling raakt alleen nieuwe
uitgestelde partijen.

> [!FIDE]
> Een remise voor beide spelers is de FIDE-regel. Elke andere waarde haalt het
> toernooi uit de FIDE-modus.

**Leg het vast.** Kies *uitgesteld door wit* of *uitgesteld door zwart* als resultaat
van het bord. Tot de partij is gespeeld, telt ze zoals de instelling zegt in de
stand, de tiebreaks en de paring van elke latere ronde. Een uitgestelde partij
wordt ook automatisch vastgelegd wanneer u een ronde paart terwijl er borden zonder
resultaat overblijven en u **Ontbrekende resultaten als uitgesteld vastleggen en
ronde N paren** kiest. Een ronde paren terwijl een uitgestelde partij uit een
eerdere ronde nog open is, vraagt om een bevestiging die de spelers noemt: zij
worden op een voorlopige score gepaard.

**Openstaande partijen.** De pagina Paringen toont de openstaande uitgestelde
partijen, met een knop naar hun ronde. Elke partij mag de afgesproken datum dragen
(nooit een uiterste datum; niets wordt te laat) en een korte geschiedenis van
wijzigingen. Een partij kan op elk moment worden gespeeld: voer het echte resultaat
in, met de datum waarop ze is gespeeld. Een resultaat dat geen remise is bij een
uitgestelde partij, vraagt eerst om een bevestiging.

**Afgedrukte briefjes.** Een briefje voor elke speler met de ronde, het bord, de
tegenstander, de kleur, de afgesproken datum en de locatie staat op de pagina
Afdrukken (*Briefjes voor uitgestelde partijen*) en kan per partij worden afgedrukt.
Een agendabestand (`.ics`) voor de afgesproken datum kan uit dezelfde lijst worden
gedownload.

**Overal waar de stand verschijnt.** Zolang een partij open is, zeggen de stand, de
afdrukken en de publiek gepubliceerde stand dat ze *niet definitief* zijn, markeren
ze de speler of ploeg met *1 pending* (1 in behandeling), en blijft het toernooi
lopen. Het archiveren van het toernooi meldt hoeveel partijen nog niet zijn gespeeld.

**Verslaglegging.** In de FIDE-modus is er geen TRF die de ronde van een
uitgestelde partij zonder resultaat bevat, en geen eindstand: Instellingen,
Exporteren toont de openstaande partijen. Een bestand met alleen de ronden
ervoor wordt nog wel gemaakt, en OpenResults blijft de stand tonen, gemarkeerd
als niet definitief. Voer het resultaat in, of druk naast de partij op **Niet
gespeeld in dit toernooi**. Die tweede weg vraagt het twee keer (ze haalt het
toernooi voorgoed uit de FIDE-modus), en het verslag zegt dan in een
`###`-regel om welke partij het gaat. De partij blijft uitgesteld: het bestand
voor de rating schrijft ze als niet gespeeld (`0000 - Z`), en wordt ze later
toch gespeeld, dan gaat het echte resultaat naar de FIDE in een apart bestand
voor de uitgestelde partijen, omdat een partij die in een andere ratingperiode
is gespeeld, als apart toernooi wordt gerapporteerd. Buiten de FIDE-modus wordt
een uitgestelde partij zonder vragen als `?` in de TRF-kopieën en als niet
gespeeld in het bestand voor de rating geschreven. Zie
[Verzenden naar FIDE](11-fide-report.md).
