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
ingedrukt. Druk je op de ingedrukte knop nogmaals, dan verandert er niets.

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
meteen: een vakje vraagt *Het geregistreerde resultaat wissen?* en je bevestigt met
**Ja, wis het**, of annuleert. Een resultaat wijzigen in een ander resultaat wordt
meteen opgeslagen en in het auditlogboek vastgelegd, met de oude en de nieuwe
waarde.

Een resultaat in een ronde die al naar het ratingkantoor is **verstuurd**, wordt
pas na een bevestiging gewijzigd.

> [!FIDE]
> In de FIDE-modus kan een resultaat alleen worden gewijzigd in de laatste twee
> gespeelde rondes ([FIDE-modus](02-fide-mode.md)); een eerdere fout wordt na het
> toernooi gecorrigeerd, in het verslag aan het ratingkantoor.

Wanneer twee arbiters aan dezelfde ronde werken, wordt een resultaat geweigerd als de
spelers aan het bord niet meer degenen zijn die je pagina toonde - een collega heeft
een speler gewisseld of vervangen nadat je pagina was opgebouwd. De melding is *Niet
opgeslagen: dit bord is gewijzigd*; er wordt niets weggeschreven. Laad de pagina
opnieuw en voer het resultaat in op het bord zoals het nu is. Een telefoon die voor
resultaten wordt gebruikt, zegt hetzelfde voor zijn bord. Twee arbiters die een
verschillend resultaat invoeren op hetzelfde, ongewijzigde bord worden niet geweigerd:
het laatst ingevoerde resultaat geldt, en beide staan in het auditlogboek.

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

Met elektronische borden in de zaal heeft de pagina Paringen ook een kolom **Bord
zag**: wat het bord meldde, naast je invoer. Ze voert nooit een resultaat in. Zie
[De bordkolom](17-live-boards.md#the-board-column).

## Resultaten uit een bestand (CSV) {#results-from-a-file-csv}

**Meer**, **Resultaten importeren (CSV)** leest een bestand met per bord één regel
`bord,resultaat` (komma of puntkomma; een optionele kopregel). Het bordnummer is
het nummer dat op het paringsblad staat. Geaccepteerde resultaatwoorden: `1-0`,
`0-1`, `1/2-1/2` (ook `½-½`, `0.5-0.5`, `=`), `½-0`, `0-½`, `0-0`, `X`, `1-0FF`,
`0-1FF`, `0-0FF` (`+/-`, `-/+`, `-/-`), de niet-gerate vormen met `U`, en `*W`,
`*B`. Borden die niet worden genoemd, behouden hun resultaat.

> [!NOTE]
> **Er wordt niets opgeslagen tenzij elke regel geldig is**: de pagina somt elk
> probleem op (maximaal 50) en je corrigeert het bestand en verstuurt het opnieuw.

## Resultaten via telefoons {#results-from-phones}

Op de pagina Paringen opent **Meer**, **Telefoon-QR** een groot venster (sluit
het met de knop, Escape of een klik erbuiten). Het deel **Resultaten invoeren
op een telefoon** maakt een QR-code en een code van
8 cijfers. Een helper scant de QR-code of typt de code op zijn eigen telefoon, en
kan daarna resultaten voor dat toernooi invoeren, zonder account.

- Een **helpertelefoon** vult borden in die nog geen resultaat hebben, alleen in de
  laatst gepaarde ronde, en kan een resultaat dat al is vastgelegd niet wijzigen -
  ook niet een resultaat dat de arbiter net heeft ingevoerd, voordat het scherm van
  de telefoon was bijgewerkt.
- Een **deputy-telefoon** kan in elke ronde een resultaat invoeren en corrigeren, en ook wissen: onder een bord met een resultaat staat een knop **Wissen**. De eerste tik verandert die een paar seconden in *Tik nogmaals om bord N te wissen*, de tweede wist het bord en zet het terug tussen de onafgemaakte. Het al gekozen resultaat nog eens aantikken verandert niets. De knop ontbreekt waar het programma het wissen zou weigeren (een gearchiveerd toernooi, een resultaat dat al in een afgesloten TRF is verstuurd, een gesloten ronde in FIDE-modus) en op helpertelefoons.
- Een telefoon kan worden beperkt tot een reeks borden.

De code verloopt na 24 uur en kan op elk moment worden ingetrokken op dezelfde kaart.
Het scherm van de telefoon toont de ratings en scores van de spelers, heeft een
slot dat tegen per ongeluk aantikken beschermt, en een eigen wisselaar voor het
thema. Een telefoon kan niets anders in het programma bereiken.

**Op de desktopinstallatie** antwoordt het programma alleen deze computer tot
je in hetzelfde venster **Telefoons op dit netwerk laten verbinden** aanzet en
het adres van deze computer op het netwerk van de zaal kiest (en zo nodig een
poort; 4748 tenzij je die wijzigt). Vanaf dan, zolang er minstens één
telefooncode actief is, bereiken telefoons op hetzelfde netwerk de
telefoonpagina's - resultaten en incidenten, verder niets - op het adres in de
QR-code. Alle andere pagina's blijven alleen op deze computer. Zet het uit als
de ronde gedaan is; de firewall van de computer kan één keer vragen of het mag.
Het is gewone http op het netwerk van de zaal, net als de bordkoppeling.

### Arbiters met een eigen account {#arbiters-with-their-own-account}

Een arbiter op het gehoste programma kan onder zijn eigen naam werken in plaats
van met een gedeelde code. De eigenaar nodigt hem uit in Instellingen,
**Delen / Team**, met de rol **Arbiter - uitslagen en incidenten op een
telefoon**. Na het aanvaarden opent de arbiter `/m/connect` op zijn telefoon
(de codepagina linkt ernaar), kiest het toernooi en tikt **Deze telefoon
gebruiken**; **Toon een code voor een andere telefoon** toont een QR-code voor
een tweede telefoon of voor de geïnstalleerde app. Een arbiter:

- voert resultaten in en corrigeert ze en meldt incidenten zoals een
  deputy-telefoon, en alles wat hij invoert staat in het auditlogboek onder
  zijn eigen account;
- kan het toernooi niet aan de tafel openen, niet paren en verder niets
  wijzigen;
- verliest zijn telefoons zodra hij verwijderd wordt of vertrekt.

In het venster Telefoon-QR geeft **Borden van de arbiters** elke arbiter een
reeks borden; **Mijn borden** op zijn telefoon toont dan alleen die. De
eigenaar en de bewerkers kunnen alles wat een arbiter kan.

### Het zaaloverzicht {#the-hall-view}

- Elk bord zegt of het nog **Bezig** of **Afgelopen** is.
- Een regel onder de ronde zegt hoe lang ze al loopt: sinds de paringen
  gepubliceerd zijn, of, als dat niet gebeurde, sinds het eerste live bord
  meldde. Hij zegt welke van de twee. Zonder een van beide zegt hij niets, in
  plaats van te gokken.
- **Zoek een speler of een bord** zoekt op naam of bordnummer.
- Met live borden ([Live borden](17-live-boards.md)) toont elk bord ook wat het
  bord in de zaal zag: dezelfde uitslag, een uitslag die nog niet is ingevoerd,
  of, in het rood, een andere. Het is een waarschuwing; de telefoon voert ze
  nooit zelf in.
- Als twee arbiters voor hetzelfde bord een andere uitslag invoeren, wordt de
  tweede geweigerd en tonen beide telefoons de onenigheid in het rood bij dat
  bord. Niets wordt overschreven; spreek het af en voer de juiste in.
- **Scherm aan laten** houdt de telefoon wakker zolang de pagina openstaat
  (waar de telefoon dat kan), en **Met één hand** zet de knoppen onderaan met
  grotere uitslagknoppen. Beide onthoudt de telefoon zelf.

### Manubrium Lite, als de wifi wegvalt {#manubrium-lite-when-the-wifi-drops}

Deze telefoonpagina's zijn **Manubrium Lite**: een pagina in de browser van de
telefoon, geleverd door het programma zelf, niets te installeren. Ze blijft
werken als de wifi in de zaal wegvalt, zolang je de pagina openlaat:

- Een aangetikt resultaat gaat eerst naar het postvak op de telefoon en wordt
  van daaruit verstuurd, in de volgorde waarin je het invoerde. Zonder
  verbinding wacht het op de telefoon en wordt het verstuurd zodra de wifi terug
  is. Bovenaan staat hoeveel er wachten, en elk bord toont *Wacht*,
  *Verstuurd* of *Niet aanvaard*.
- Het programma beoordeelt elk resultaat wanneer het aankomt, niet wanneer het
  werd aangetikt. Een resultaat dat niet meer mag - de code van de telefoon werd
  ingetrokken, de ronde is voor een helper niet meer de laatste, de spelers aan
  het bord zijn veranderd, of het bord kreeg intussen een ander resultaat - wordt
  **niet aanvaard**, en de telefoon zegt per bord waarom, tot je het wegdoet.
  Een resultaat dat aan de tafel van de arbiter werd ingevoerd, wordt nooit
  overschreven door een telefoon die onbereikbaar was.
- Hetzelfde resultaat twee keer versturen (een verloren antwoord, een
  herlaadbeurt) slaat het maar één keer op.
- Een resultaat wissen, het slot, de rondekeuze en **Meer** hebben een
  verbinding nodig.
- **Verlaten** op een telefoon waar nog resultaten wachten, vraagt eerst
  bevestiging: wie weggaat, gooit ze weg.

Het hele toernooi vanaf een telefoon leiden - koppelen, spelers, stand - doe je
met de volledige Manubrium-app, die apart verbinding maakt met het programma.

### Incidenten aan de borden {#incidents-logged-at-the-boards}

Elk bord op de telefoon heeft een knop voor incidenten.

- Een **deputy-telefoon** meldt een incident: onreglementaire zet, probleem met
  de klok, telefoon of elektronisch toestel, klacht, tijd bijgegeven, partij
  teruggezet, arbiter geroepen of andere, met een korte opmerking en, als dat
  helpt, een foto die je ter plaatse neemt (de telefoon verkleint ze voor het
  versturen; er komt hoogstens zo'n 2 MB aan). Het bord, de ronde, de spelers en de tijd
  komen er vanzelf bij; de opmerking is niet de plaats voor namen.
- Een **helpertelefoon** heeft in de plaats **Arbiter roepen**: die meldt
  alleen dat de arbiter naar dat bord moet komen.

Incidenten gaan door hetzelfde postvak als resultaten, en wachten dus ook op de
wifi. Op de pagina Paringen zegt een regel onder de ronde hoeveel er zijn, en
**Meer**, **Incidenten** toont ze allemaal, per ronde, de nieuwste eerst; een
nieuw incident verschijnt terwijl de pagina openstaat. Een foto staat daar als
miniatuur, en alleen daar: ze staat op geen enkele openbare pagina, een
arbiteraccount kan ze niet openen, ze reist niet mee in een export, en ze
verdwijnt als het toernooi verwijderd wordt. Elk incident staat ook in het
auditlogboek. Een afdrukbaar incidentenverslag komt later.

## Uitgestelde partijen {#postponed-games}

Een partij die niet in haar ronde kan worden gespeeld (verplaatst door
overeenkomst of uitgesteld), is **uitgesteld**. Het toernooi gaat door.

**Zet het aan.** Instellingen, Puntentelling, *Uitgestelde partijen*: **Uitgestelde
partijen toelaten**. Met dit uit, wordt nergens een uitgesteld resultaat aangeboden,
behalve in een round robin: dat biedt het altijd aan, omdat het
schema niet van de scores afhangt. Daar staat de schakelaar aan en kun je hem niet
uitzetten.
Op dezelfde pagina stel je in wat een uitgestelde partij telt tot ze is gespeeld,
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
wordt ook automatisch vastgelegd wanneer je een ronde paart terwijl er borden zonder
resultaat overblijven en je **Ontbrekende resultaten als uitgesteld vastleggen en
ronde N paren** kiest. Een ronde paren terwijl een uitgestelde partij uit een
eerdere ronde nog open is, vraagt om een bevestiging die de spelers noemt: zij
worden op een voorlopige score gepaard.

**Borden zonder uitslag, in een round robin.** Een round robin paart
alle ronden vooraf, dus een partij die niet gespeeld wordt, blijft vaak gewoon
zonder uitslag staan. Zodra een *latere* ronde al haar uitslagen heeft, telt zo'n
bord als een uitgestelde partij waar niemand om vroeg: beide spelers krijgen in de
stand en de tiebreaks wat de instelling aan de tegenstander geeft (standaard een
remise), de stand zegt hoeveel partijen nog open zijn, en de uitslagensite toont
*Uitslag nog niet binnen* op het bord. Er wordt niets op het bord geschreven: de
TRF en de bestanden voor de rating zien nog altijd een bord zonder uitslag, en je
kunt de ronde pas versturen als ze er een heeft. Een partij die vooraf gespeeld is
in een latere ronde, maakt die ronde niet volledig; de hele ronde moet binnen zijn.
Wil je dat de stand dezelfde avond al doorloopt, zet het bord dan zelf op
*uitgesteld door wit* of *uitgesteld door zwart*. Zwitserse, Keizer- en
ploegentoernooien doen dit niet: daar kun je sowieso niet verder paren met een leeg
bord.

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
lopen. Een ronde met een open uitgestelde partij, of met alleen nog de borden uit
een round robin hierboven zonder uitslag, houdt de gepubliceerde stand niet
tegen: die loopt door tot de laatste zulke ronde en zegt hoeveel partijen nog
gespeeld moeten worden (op de uitslagensite: *Voorlopig: 2 partijen hebben nog geen
uitslag en tellen tot dan als remise*). Een ronde die nog bezig is, houdt de stand
wel tegen, zoals altijd. Het archiveren van het toernooi meldt hoeveel partijen nog niet zijn gespeeld.

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
[Versturen naar FIDE](10-fide-report.md).
