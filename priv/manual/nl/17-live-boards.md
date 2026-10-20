# Live borden en Alnasl

Live borden tonen de partijen van een ronde terwijl ze gespeeld worden, zet voor
zet, met de klokken, op de uitslagensite. De zetten komen van een kastje in de
speelzaal. Alnasl is dat kastje: een kleine computer naast elektronische
schaakborden die de zetten leest. Het praat met twee programma's. Aan
**OpenPairings** vraagt het wie waar zit, en het meldt terug wat de borden zagen.
Naar **OpenResults** stuurt het de zetten en de klokken voor de toeschouwers.

> [!NOTE] Installeren
> Dit hoofdstuk zegt wat live borden zijn en wat elke pagina ervan toont. Voor de
> installatie, stap voor stap, gehost of op een desktopkopie, zie
> [Elektronische borden installeren](18-setting-up-boards.md).

> [!WARNING] Alnasl is een eerste versie
> De livepagina's op de uitslagensite, de koppelcodes, de bordkolom op de pagina
> Paringen en de bewaarde partijen met hun PGN zijn hier gebouwd. Alnasl, het
> programma in de zaal, heeft de andere kant van de koppeling en heeft ze met
> gesimuleerde borden tegen OpenPairings doorlopen. Het heeft één echt bord
> gelezen; een hele partij op een echt bord is nog niet bewezen (zie zijn README,
> "What is not done").

## Stand van zaken in één oogopslag {#status-at-a-glance}

| Onderdeel | Stand |
| --- | --- |
| De livepagina's: uitzending, Alle borden, beamerweergave, stukkensets, PGN, uitzendvertraging | gebouwd |
| De ingestroute die de zetten en klokken van een bord ontvangt, en de toestemming van het kastje om ze te gebruiken (door OpenPairings opgehaald, niets te kopiëren) | gebouwd |
| De koppeling in OpenPairings: koppelcodes, wat het kastje te horen krijgt, wat het meldt, de bordkolom, bewaarde partijen en PGN | gebouwd |
| De kant van Alnasl van de koppeling met OpenPairings | gebouwd, in Alnasl; met gesimuleerde borden doorlopen, nog niet in een zaal |
| De koppeling van een desktopkopie naar een kastje op een andere machine in de zaal | gebouwd, uit tot je ze aanzet; zie [Een kastje elders op het netwerk](#boxes-on-the-network) |

## Wat Alnasl is {#what-alnasl-is}

Alnasl is een kastje in de speelzaal. Het leest de elektronische
borden, zet wat ze melden om in legale zetten, en stuurt de zetten en de
bedenktijden door terwijl de partij gespeeld wordt. Het blijft werken wanneer het
internet van de zaal wegvalt, en een bord dat hangt of een losse kabel kan het
paringsprogramma niet raken, want Alnasl is een apart programma naast
OpenPairings.

Het kastje belt altijd zelf. OpenPairings belt het kastje nooit, dus de zaal zet
geen poort open en heeft geen vast adres nodig.

## De hardware {#the-planned-hardware}

Waar het kastje mee werkt. Wat een bepaalde versie van Alnasl ondersteunt, staat
in de eigen documentatie van Alnasl.

- **Borden:** elektronische schaakborden, in de RS232- en USB-C-modellen. Beide
  komen neer op een seriële stroom, dus één stuurprogramma past op beide.
- **Eén lus:** een seriële lus van tot 12 borden, elk met een eigen adres op de
  bus, om beurten bevraagd.
- **Zetten:** afgeleid uit de posities die de borden melden, zodat een stuk dat
  opgetild en teruggezet wordt, een slag in twee stappen of een omgevallen stuk
  geen verkeerde zet wordt. Een zet die het kastje achteraf afleidde, of raadde,
  wordt als zodanig geteld, en dat aantal reist mee met de partij.
- **Klokken:** uit een klok op het bord, wanneer er een is.
- **Het kastje:** een Raspberry Pi met een scherm, toetsenbord en muis voor de
  arbiter, schermvullend in een kioskbrowser.
- **Offline:** zetten worden op het kastje bewaard en in volgorde verstuurd zodra
  de verbinding terug is.
- **Meerdere toernooien op één kastje:** tafels 1 tot 4 kunnen in het ene toernooi
  spelen en tafels 5 tot 8 in een ander. Welke tafel bij welk toernooi hoort,
  wordt op het kastje bepaald, niet in OpenPairings.

## Een kastje koppelen {#connecting-a-box}

*Gebouwd.* Een kastje wordt met een koppelcode aan OpenPairings gekoppeld. In
OpenPairings: Instellingen, **Live borden** - of, helemaal zonder code, door
[je account te koppelen](#connecting-your-account). Hetzelfde, als stappen, staat in
[Elektronische borden installeren](18-setting-up-boards.md).

### Een code voor het toernooi {#a-code-for-the-tournament}

Druk op **Nieuwe code**. De pagina toont een regel tekst en dezelfde regel als
QR-code. Scan ze met het kastje, of kopieer de regel naar de instelpagina van het
kastje. Meer instellen is er niet: de code bevat het adres van deze server en een
geheim, en het kastje verneemt de rest via de koppeling.

De code wordt **één keer** getoond. Wanneer je de pagina verlaat, kan ze niet
opnieuw getoond worden, want OpenPairings bewaart ze niet, alleen een
vingerafdruk. Ben je ze kwijt, maak dan een nieuwe: een code kost één klik.

Maak één code per kastje. De lijst onder de knop toont elke code met haar laatste
vier tekens, met het kastje dat ze gebruikt, de versie ervan, wanneer het voor het
laatst belde en hoeveel borden het op dit toernooi heeft. **Intrekken** beëindigt
een code: het kastje dat ze heeft, wordt vanaf zijn volgende verzoek geweigerd en
heeft een nieuwe nodig. Een toernooi kan tot 8 codes hebben.

### Een code voor een groep {#a-code-for-a-group}

Een toernooi in een [groep](03-tournament-setup.md#tournament-groups) krijgt ook
**Codes voor de groep**. Eén scan van een groepscode stelt het kastje in voor elk
toernooi van de groep, en een toernooi dat later aan de groep wordt toegevoegd,
bereikt het kastje zonder nieuwe scan.

Een groepscode geeft toegang tot de toernooien van de groep die **de persoon die
de code maakte** mag openen, en tot geen andere. Een afdeling van een andere
arbiter, die je niet kunt openen, gaat ook niet naar je kastje.

### Je account koppelen {#connecting-your-account}

De derde manier heeft helemaal geen code nodig. Op het kastje stuurt Alnasl via
**Instellingen -> Toernooien -> Een OpenPairings-account koppelen** je browser
hierheen. Je meldt je aan als je dat nog niet was, en een pagina vraagt of dat
kastje je toernooien mag lezen. Ze noemt het kastje en, in grote letters, het
adres waar je naar teruggestuurd wordt: kijk na dat het je eigen kastje is
voor je op **Toestaan** drukt. **Annuleren** koppelt niets.

Een accountkoppeling bereikt elk toernooi dat je mag bewerken - je eigen en de
toernooien die met je gedeeld zijn - dat **actueel** is: niet afgelopen, of
afgelopen in de laatste 14 dagen (gerekend vanaf de datum van de laatste ronde).
Een toernooi zonder ronde telt als actueel, net als een toernooi dat nog op een
uitgestelde partij wacht. Gearchiveerde en overgedragen toernooien bereiken het
kastje nooit, en een toernooi waar je geen toegang meer toe hebt, valt weg bij
het volgende verzoek van het kastje. Een toernooi dat je volgende week maakt,
verschijnt vanzelf op het kastje.

De koppelingen van je account staan op je **accountpagina, Live borden**: de
naam van het kastje, wanneer het laatst belde en de laatste tekens van zijn
code. **Intrekken** sluit een kastje af vanaf zijn volgende verzoek. Een account
kan tot 8 kastjes gekoppeld hebben. Een koppeling maken en intrekken staan in
het auditlogboek van de installatie, omdat ze bij geen enkel toernooi horen.

Op de pagina **Instellingen, Live borden** van een toernooi staan de
accountkoppelingen die dat toernooi bereiken ook, onder **Accountbrede
koppelingen**: het kastje, het account, wanneer ze gemaakt is en wanneer het
kastje het laatst belde. De lijst is alleen-lezen en alleen wie het toernooi
mag bewerken ziet hem. Elke regel verwijst naar de accountpagina, waar het
account waartoe ze behoort haar intrekt.

Op een desktopkopie werkt dit voor een kastjesprogramma op dezelfde computer.
Een kastje elders op het zaalnetwerk heeft nog altijd een netwerkcode nodig
(hieronder): de netwerkluisteraar neemt geen accountkoppelingen aan.

### Een kastje elders op het netwerk {#boxes-on-the-network}

*Gebouwd, alleen in de desktopeditie. Uit tot je het aanzet.* De desktopeditie
antwoordt op haar eigen computer en nergens anders, en dat verandert niet. Een
kastje dat niet op die computer staat (een kleine computer naast de borden, een
tweede laptop) heeft een ingang nodig, en die kun je geven: Instellingen,
**Live borden**, kaart **Kastjes elders op dit netwerk**, schakelaar **Laat
borden op dit netwerk verbinden**.

Wat de schakelaar doet:

- Hij opent **één extra deur** op je computer, op het netwerkadres dat je kiest,
  voor het kastje van de borden en voor niets anders. Je toernooien, de
  pagina's van OpenPairings en al het andere blijven alleen vanaf je eigen
  computer bereikbaar, precies zoals voorheen. Wie die deur in een browser
  opent, krijgt "niets hier".
- De pagina biedt daarna **twee soorten code** aan: *Nieuwe code voor een
  kastje op deze computer* (zoals voorheen, `http://127.0.0.1`) en *Nieuwe code
  voor een kastje op het netwerk*, die het adres van je computer op het netwerk
  van de zaal bevat. De pagina zegt in woorden waar elke code heen leidt, naast
  de QR-code.
- De deur antwoordt alleen op een code die voor het netwerk is gemaakt, alleen
  aan machines op een lokaal netwerk, en ze is **dicht zolang er geen zo'n code
  bestaat**: trek de laatste in en ze sluit. Een netwerkcode werkt tot ze wordt ingetrokken; trek ze in als het evenement voorbij is.
- Het is een instelling van je computer, voor alle toernooien, en ze wordt
  onthouden: na een herstart is de deur er vanzelf weer. Verbindingen toont hoe
  het ervoor staat en heeft een knop **Uitzetten**.

> [!WARNING] De code reist leesbaar
> De deur spreekt gewoon http. De code van een kastje gaat onbeschermd over het
> netwerk, om de paar seconden. Over **een kabel tussen de twee machines**, of
> **een eigen netwerk** (je eigen kleine router, niemand anders erop), is dat
> prima. Op **een wifi waar ook de spelers op zitten** kan wie weet hoe, de code
> lezen, en dan de paringen zien en zetten insturen alsof hij een bord was. Een
> resultaat invoeren kan hij niet (dat doet een bord nooit), een paring wijzigen
> evenmin, en iets anders zien ook niet. Neem liever een kabel of een eigen
> netwerk, en trek de code in na het evenement.

> [!IMPORTANT] Windows stelt een vraag
> De eerste keer toont Windows *Windows-beveiliging: wilt u toestaan dat deze
> app communiceert op deze netwerken?* Vink **Particuliere netwerken** aan en
> kies **Toestaan**. OpenPairings kan die vraag niet voor je beantwoorden. Koos
> je Annuleren, of zag je de vraag nooit, dan krijgt het kastje geen antwoord:
> open Windows-beveiliging, Firewall en netwerkbeveiliging, **Een app door de
> firewall toestaan**, en sta OpenPairings toe op particuliere netwerken.

**Welk adres.** Zit je computer op één lokaal netwerk, dan neemt de pagina dat
adres. Zit hij op meerdere (een kabel naar het kastje en de wifi van de zaal),
kies dan dat waar het kastje op zit: alleen dat ene wordt geopend. De poort is
`4747` tenzij je ze wijzigt; gebruikt een ander programma ze al, dan zegt de
pagina dat en kies je een andere. Verder verandert daar niets door.

**Als het adres verandert.** De meeste netwerken delen zelf adressen uit, en
morgen kan het jouwe een ander zijn. De code van vandaag wijst dan naar een adres
waar niets is. OpenPairings merkt het, bij het opstarten en op deze pagina:
*Het adres van deze computer is veranderd van … naar …: kastjes met de oude
code vinden hem niet meer.* Het verhuist de deur **niet** vanzelf naar het
nieuwe adres, want een laptop die plots op een ander netwerk zit, is precies
het moment waarop je eerst gevraagd wilt worden. Kies het nieuwe adres, maak een
nieuwe code en geef ze aan het kastje. Om het te voorkomen geef je de computer
een **vast adres** (in de router, of in de netwerkinstellingen van Windows), of
gebruik je een kabel tussen de twee machines en niets anders. De lijst met
codes toont bij elke netwerkcode het adres waarvoor ze gemaakt is, en zegt het
in het rood wanneer de computer daar niet meer antwoordt.

Op een computer met één netwerk kan de pagina dezelfde code ook tonen met de
**naam** van de computer in plaats van zijn adres. Een naam overleeft een
veranderd adres, maar werkt alleen als het kastje de naam kan opzoeken, en dat
hangt van het netwerk af. Probeer eerst het adres.

### Wie mag {#who-may}

Wie het toernooi mag bewerken: de eigenaar en de arbiters met wie het gedeeld is.
Niet op een gearchiveerd of overgedragen toernooi. Een code maken, een code
intrekken, de uitslagensite die de toestemming van het kastje uitgeeft of
weigert, die toestemming vervangen, en de eerste keer dat een kastje een code
gebruikt, staan allemaal in het auditlogboek.

### Wat het kastje te horen krijgt {#what-the-box-is-told}

De naam, plaats en data van het toernooi, het speeltempo, de rondes, en per ronde
de borden: wie wit heeft en wie zwart, met naam, titel, rating, federatie en
FIDE-ID, en bij een ploegentoernooi de wedstrijd en het bord daarbinnen. Verder
gaat er niets over een speler de deur uit: geen geboortedatum, geen club, geen
e-mailadres, geen telefoonnummer.

Het krijgt ook te horen welke ronde bezig is. OpenPairings heeft geen knop die een
ronde start: een ronde die gepaard is, is bezig. Wanneer je dus een ronde paart,
start het kastje ze zelf, binnen ongeveer vijf seconden. Van de rondes die het laatst
samen gepaard zijn (één in een Zwitsers of een Keizer, beide legs van een
tweelegswedstrijd, alle rondes van een rondetoernooi), is de ronde die bezig is de
eerste met een partij die nog openstaat, of de laatste als er geen is. Een
resultaat die in ronde 2 gewist wordt terwijl ronde 3 gespeeld wordt, stuurt de
borden dus niet terug naar ronde 2.

Een wijziging daarna bereikt het kastje op dezelfde manier: een bord gewisseld,
een speler vervangen, een ronde opnieuw gepaard. Meldt het kastje nog een partij
voor een paring die niet meer bestaat, of waarvan de spelers veranderd zijn, dan
wordt de melding geweigerd en wordt er niets onder de verkeerde partij bewaard.

### De toestemming van het kastje voor de uitslagensite {#the-relay-key-for-the-box}

Om zetten naar de uitslagensite te sturen heeft het kastje de toestemming van
die site nodig, voor dit ene toernooi. **OpenPairings regelt dat zelf.** Er is
niemand om iets aan te vragen, niets te kopiëren en niets te plakken.

De kaart **De uitslagensite** op Instellingen, Live borden zegt hoe het ervoor
staat:

| De kaart zegt | Wat het betekent |
| --- | --- |
| *Zet het toernooi eerst op de uitslagensite* | Het toernooi is niet gepubliceerd, dus de zetten kunnen nergens heen. Instellingen, OpenResults. |
| *Nog niet gevraagd.* | Het toernooi staat op de site en er is geen kastje in zicht. Niets te doen: er wordt gevraagd zodra er een koppelcode is of de Live-link aanstaat. |
| *Toestemming wordt bij de uitslagensite opgehaald…* | Er wordt gevraagd. Meestal enkele seconden. Is de site niet bereikbaar, dan wordt het vanzelf opnieuw geprobeerd, en de kaart zegt dat. |
| *Ja. Het kastje mag daar zetten naartoe sturen.* | Klaar. Het kastje krijgt de toestemming via de koppeling, met het adres van de site en de korte naam van het toernooi. Op het kastje wordt niets getypt. |
| *Nog niet. De uitslagensite gaf geen toestemming: …* | De site zei nee, en de kaart zegt waarom. **Opnieuw proberen** vraagt meteen; er wordt ook vanzelf enkele keren per dag opnieuw gevraagd. |

OpenPairings vraagt wanneer het toernooi op de uitslagensite staat en een van
deze dingen waar is: een koppelcode bereikt het (zijn eigen code, of die van
zijn groep), een kastje heeft een partij gemeld, of **Live-link op de
uitslagensite** staat aan. De volgorde waarin je de dingen doet, maakt niet uit.
Een code die gemaakt is voordat het toernooi gepubliceerd was, wordt bediend
zodra de eerste publicatie is aangekomen.

**De toestemming van het kastje vervangen** vraagt de uitslagensite om een
nieuwe. De site aanvaardt de oude vanaf dat moment niet meer. Een verbonden
kastje haalt de nieuwe binnen enkele seconden op; een kastje dat uitstaat,
doet dat zodra het terug is. Gebruik dit wanneer een kastje zoek is of
uitgeleend werd.

Zonder de toestemming leest het kastje de borden nog wel en meldt het aan
OpenPairings. Het stuurt niets naar de uitslagensite.

Wat daarachter gebeurt, en het ene geval waarin een sleutel nog met de hand
geplakt wordt, staat in [Relaissleutels](#relay-keys).

## De bordkolom {#the-board-column}

*Gebouwd.* Op de pagina Paringen, rechts van de paringen, krijgt een toernooi met
live borden een kolom **Bord zag**. Een toernooi zonder kastje heeft de kolom
niet.

**Een bord voert nooit een resultaat in.** Je voert de resultaten in zoals voorheen.
De kolom toont wat het bord meldde, naast wat je invoerde:

| De kolom toont | Het betekent |
| --- | --- |
| `-` | Het bord meldde niets voor deze partij. |
| *bezig* | Er is een partij bezig. |
| een resultaat, vet | Het bord zag een resultaat en je hebt er nog geen ingevoerd. |
| een resultaat, onopvallend | Het bord zag het resultaat die je invoerde. |
| een resultaat in het rood, *wijkt af* | Het bord zag een andere resultaat dan die je invoerde. |
| *geen resultaat* | Het bord zag de partij eindigen en kon niet uitmaken hoe. |

Rood is een waarschuwing en niets meer. Het blokkeert niets: je kunt de volgende
ronde paren, publiceren en versturen zoals gewoonlijk. Controleer de
notatieformulieren, en verbeter het resultaat als het de ingevoerde is die fout is.
Een forfait dat je invoerde, wordt vergeleken op wie het punt kreeg: een bord dat
`1-0` zag, komt overeen met `1-0FF`.

Op een telefoon staat de melding van het bord op een eigen regel onder de
resultaatknoppen. De kolom wordt niet afgedrukt en staat niet in de paringslijst
voor aan de muur: ze is de controle van de arbiter, geen deel van de paring.

## Partijen en PGN {#games-and-pgn}

*Gebouwd.* Elke vermelding in de kolom is een link naar de partij: de zetten, de
klokken bij de laatste melding, het resultaat van het bord naast die van jou, en hoeveel
zetten het kastje achteraf afleidde of raadde. Een geraden zet is de beste lezing
van een onduidelijk bord door het kastje, niet iets wat het zag.

De partijen worden bij het toernooi bewaard. Er zijn drie downloads:

- **één partij**, op de pagina van de partij;
- **één ronde** en **het hele toernooi**, op Instellingen, Live borden.

In elk bestand komen de kopregels uit het toernooi: evenement, plaats, datum,
ronde en bord (`3.12` is bord 12 van ronde 3), wit, zwart, ratings, FIDE-ID's en
het speeltempo. Het **resultaat is dat wat je invoerde**, of `*` zolang je dat niet
deed. Een bord dat `1-0` zag op een partij die je niet hebt ingevoerd, is in het
bestand nog steeds `*`. Kloktijden staan na de zetten als `{[%clk 1:29:58]}` waar
het kastje ze meldde.

De pagina van de partij biedt ook **De eigen PGN van het kastje**, het bestand
precies zoals het kastje het schreef, ter vergelijking.

De PGN-export op de pagina Paringen (**Meer**, PGN) is ongewijzigd en bevat nog
steeds geen zetten.

**Een partij gaat mee met haar paring.** Wanneer je een ronde ontpaart en
opnieuw paart, worden de partijen die de borden voor de oude paringen hadden
gemeld op dat moment uit OpenPairings verwijderd: ze horen bij partijen die
niet meer bestaan. Hetzelfde geldt voor een bord dat je verwijdert, een
ploegopstelling die een bord laat vallen, en een herstelpunt dat de paring niet
heeft. Het auditlogboek krijgt één regel met het aantal verwijderde partijen.
Het kastje houdt zijn eigen kopie en zijn eigen PGN. Een partij waarvan de
paring alleen naar een ander bord verhuisde, of een andere speler kreeg, blijft
bewaard. Ga je terug naar een herstelpunt van vóór het opnieuw paren, dan
komen de oude paringen terug met hun partijen zoals ze stonden toen het punt
werd genomen; het kastje stuurt de latere zetten niet vanzelf opnieuw, maar je
kunt een partij vanaf het kastje opnieuw laten sturen.

## Relaissleutels {#relay-keys}

*Gebouwd.* Dit deel is naslag. In het gewone verloop zie je nooit een
relaissleutel: zie [De toestemming van het kastje](#the-relay-key-for-the-box).

Een relais is een kastje tussen mensen in een zaal, en het mag het hele
toernooi niet kunnen herschrijven. Daarom krijgt het kastje nooit waarmee
OpenPairings publiceert. Het krijgt een **relaissleutel**: een sleutel die
voor één toernooi werkt en alleen voor de liveroute. Ze kan niets publiceren,
verwijderen of anders wijzigen, en heeft een eigen budget van 1200 verzoeken
per minuut.

**Hoe het kastje er een krijgt.** OpenPairings vraagt de uitslagensite erom,
met dezelfde gegevens waarmee het het toernooi publiceert, en de site geeft
een relaissleutel aan precies die uitgever, alleen voor dat toernooi.
OpenPairings bewaart ze op zijn eigen machine en geeft ze via de koppeling aan
het kastje door. De uitslagensite bewaart alleen een vingerafdruk. De sleutel
zit niet in een export, niet in een back-up die op een andere machine wordt
teruggezet, en wordt nergens getoond: de instellingenpagina en het
auditlogboek tonen haar laatste vier tekens.

**Opnieuw vragen vervangt.** Omdat de site alleen een vingerafdruk bewaart,
kan ze dezelfde sleutel geen twee keer uitgeven. Telkens als OpenPairings
vraagt, krijgt het een nieuwe sleutel en werkt de vorige niet meer. Dat is wat
**De toestemming van het kastje vervangen** doet.

**Wanneer het ophoudt.** Een toernooi van de uitslagensite halen verwijdert
daar zijn relaissleutels, en OpenPairings gooit zijn kopie weg. Een overdracht
naar een andere installatie trekt ze in, en dat gebeurt ook als de beheerder
van de site de installatie intrekt. De beheerder van de uitslagensite ziet
elke relaissleutel van een toernooi op de pagina Tournaments, het toernooi,
Relay keys (wie ze maakte, wanneer, wanneer ze voor het laatst gebruikt is) en
kan er daar elke van intrekken. Gebeurt dat, druk dan op **De toestemming van
het kastje vervangen**.

**Een oudere uitslagensite.** Een uitslagensite van voor dit alles kan geen
relaissleutel uitgeven. De kaart zegt dan *Nog niet. De uitslagensite gaf geen
toestemming: het is een oudere versie die dit niet zelf kan*, en toont alleen
dan een veld **Relaissleutel**. Vraag de beheerder van die uitslagensite om
een sleutel voor het toernooi te maken (Tournaments, het toernooi, Relay keys)
en plak ze één keer. Het kastje krijgt ze zoals gewoonlijk via de koppeling.
Is de site bijgewerkt, dan haalt **Opnieuw proberen** er een op de gewone
manier.

De route waar het kastje naar post is `POST /api/tournaments/:slug/live`, en
die waarop OpenPairings vraagt `POST /api/tournaments/:slug/relay-keys`. Het
volledige contract van beide staat in `docs/live-boards-api.md` van
OpenResults.

## Toeschouwerspagina's {#spectator-pages}

*Gebouwd.* De pagina's werken als verbindingen: ze lezen de
partijen zelf opnieuw in, dus een zet verschijnt binnen een seconde, en er wordt
niets uit een cache geleverd.

### De uitzending {#the-broadcast}

De uitzending is de pagina voor de partijen van een ronde, op
`/t/<toernooi>/live`, die naar de nieuwste ronde gaat. Ze heeft drie kolommen:

- **Links:** de ronde-knoppen, een zoekveld, en elke partij van de ronde, met het
  bord, beide spelers, het resultaat (`1-0` of `½-½`), en de lopende partijen
  gemarkeerd. De borden van een ploegronde staan onder hun wedstrijd.
- **Midden:** één partij, groot, met een balk boven en onder het bord. De balken
  tonen de naam, de titel, de federatie en de rating, de klok in een vakje, en de
  score zodra er een resultaat is. De laatste zet is opgelicht, en er is een knop
  voor het volledige scherm.
- **Rechts:** de naam van het evenement, de data, de plaats en de ronde, en de zetten
  als tabel in figurine-notatie, met de huidige zet gemarkeerd. Naast de zetten
  staat een tabblad *Partijinfo*.

De pagina opent op de eerste lopende partij. Een link naar één bord,
`/t/<toernooi>/live/<ronde>/<bord>`, opent op die partij, en wie een partij uit de
lijst kiest, verandert het midden zonder herladen. Op een telefoon vallen de kolommen
onder elkaar en schuift niets opzij. Er is geen evaluatiebalk, want er is geen engine.

### Alle borden {#all-boards}

*Gebouwd.* Alle borden, op `/t/<toernooi>/live/<ronde>/all`, is
een raster van elk bord van een ronde, met een klok op elke tegel en een
livemarkering bij de partijen die lopen. Het is één klik heen en terug van de
uitzending.

### De beamerweergave {#the-projector-view}

*Gebouwd.* De beamerweergave zet de partijen die je kiest op een
scherm in de zaal. Ze opent vanuit de uitzending of Alle borden met de knop
*Beamer*, die een lijst van de borden van de ronde toont om aan te vinken: allemaal,
geen, of enkele.

De link die ze opent, kan voor de zaalcomputer als bladwijzer bewaard worden, bijvoorbeeld
`/t/<toernooi>/live/<ronde>/projector?boards=1,3,5&auto=1&pieces=chessnut`.
Zonder lijst van borden toont ze elk bord. Een kleur kan ook in het adres vastgelegd
worden.

Het scherm bevat alleen de partijen: geen koptekst, geen zetten en geen knoppen om
ergens doorheen te bladeren. Elke tegel toont de balk van Zwart, de stand met de
laatste zet opgelicht, en de balk van Wit. De tegels vullen het venster, en de pagina
berekent hoeveel kolommen de grootste borden geven. Druk op <kbd>f</kbd> voor
volledig scherm.

Met `auto=1`, wat in de lijst standaard aan staat, verdwijnen afgelopen partijen
vanzelf van het scherm. Een partij die eindigt, toont haar resultaat een halve minuut
over het bord, en maakt dan plaats voor de andere. In deze modus worden forfaits
nooit getoond. Wanneer de laatste partij weg is, zegt het scherm dat en somt de
resultaten op. Zonder de automatische modus blijven afgelopen partijen staan met hun
resultaat. Het oudere paringenscherm op de uitslagensite is een aparte pagina en
verandert niet. Zie [Het zaalscherm en de beamerweergave](16-openresults.md#the-hall-display-and-the-projector-view).

### Stukkensets {#piece-sets}

*Gebouwd.* De borden worden getekend met een van twee
stukkensets: Cburnett, de standaard, en Chessnut. De kijker kiest met de keuzelijst
Stukken op de livepagina's, en de keuze wordt in de browser onthouden. Een scherm
zonder keuzelijst krijgt een set in het adres, met `?pieces=chessnut`.

### Forfaits en resultaten {#forfeits-and-results}

*Gebouwd.* Een forfait dat de arbiter heeft gepubliceerd
(`1-0FF`, `0-1FF` of `0-0FF`) wordt als forfait getoond, wat het relais ook stuurt.
Aan een forfaitbord zit niemand, dus het bord toont *Forfait* of *Dubbel forfait*, de
resultaat als `1-0 FF`, en een leeg bord met *Niet gespeeld - forfait*. Een bord met een
gepubliceerde resultaat en geen partij van het relais toont *Partij voorbij*, niet *Nog
niet gestart*.

Een gepubliceerde resultaat wint altijd. Anders wordt, zodra de partij afgelopen is en de
resultaten van de ronde openbaar zijn, het resultaat van het relais getoond, met de
aanduiding voorlopig. In een ronde waarvan de arbiter de resultaten achterhoudt, toont een
afgelopen partij alleen *Partij voorbij*.

### De uitzendvertraging {#the-broadcast-delay}

*Gebouwd.* Sommige organisatoren moeten de partij een aantal minuten
na het spel tonen, onder anti-valsspelregels. Een beheerder van de uitslagensite stelt
dit per toernooi in, in minuten, op de pagina Toernooien, het toernooi, *Vertraging live
borden*. De standaard is 0. Elke pagina, het zaalscherm en de PGN-download tonen dan de
partij zoals ze een aantal minuten geleden stond. De server bewaart alles in echte tijd,
en niets na het afgesproken moment wordt naar een browser gestuurd. Een wijziging werkt
meteen, in beide richtingen.

### PGN-download {#pgn-download}

*Gebouwd.* Een partij kan als PGN-bestand worden gedownload. Het adres
eindigt op `/pgn`, bijvoorbeeld `/t/<toernooi>/live/<ronde>/<bord>/pgn`. Het bestand wordt
bij elk verzoek opgebouwd, op de uitzendvertraging.

### Federatievlaggen {#federation-flags}

*Gebouwd.* Waar OpenPairings de instelling voor vlaggen meestuurt (het
vinkje *Federatievlaggen*, standaard aan tenzij je het uitvinkt), wordt een klein vlaggetje
naast de federatiecode van een speler getoond: op de startlijst, de inschrijvingslijst, de
spelerskaart, het zaalscherm en de livepagina's (op de beamerweergave alleen de vlag, zonder
de code). Een speler die onder de FIDE zelf staat, of een code heeft die geen land aanduidt,
houdt de code en krijgt geen plaatje.

## De livepagina's aanzetten {#turning-live-boards-on}

*Gebouwd.* In OpenPairings: Instellingen, OpenResults, de kaart *Elke ronde publiceren*, de
schakelaar **Live borden**. Dezelfde schakelaar staat op Instellingen, Live borden, als
**Toon de live borden op de uitslagensite**. Hij staat uit voor elk toernooi tot je hem aanzet, en wordt
alleen aangeboden zolang het toernooi gepubliceerd is.

Aan: OpenPairings stuurt een woord mee in de momentopname (`live_boards: true` in het deel
over het toernooi) en publiceert het toernooi meteen opnieuw. De openbare pagina's linken dan
naar de live borden. Uit: het woord wordt niet gestuurd en de link verdwijnt met de volgende
kopie. De livepagina's zelf werken met of zonder dat woord, voor wie hun adres heeft.

De schakelaar is je verklaring dat de borden worden doorgestuurd. Een kastje koppelen zet hem
niet aan, en de schakelaar start geen kastje: zonder iets dat zetten stuurt, leidt de link
naar borden in de beginstelling. De instelling zit in een JSON-back-up en komt in het
auditlogboek.

## Beperkingen {#limits}

- **Een desktopkopie bereikt een kastje op een andere machine alleen als je dat toelaat.**
  De desktopeditie antwoordt op haar eigen computer en nergens anders. Een
  kastjesprogramma op die computer heeft niets meer nodig. Een kastje elders in de zaal
  heeft de schakelaar **Laat borden op dit netwerk verbinden** nodig, een code die voor
  het netwerk is gemaakt, en een netwerk waar beide machines op zitten; zie
  [Een kastje elders op het netwerk](#boxes-on-the-network). Die verbinding is gewoon
  http, alleen IPv4, en haar codes werken tot ze worden ingetrokken. De gehoste editie heeft geen van die
  beperkingen, en ook die schakelaar niet.
- **OpenPairings controleert de zetten niet.** Het heeft zelf geen schaakregels. Een zet
  wordt bewaard zoals het kastje hem schreef, mits hij de vorm van een zet heeft. Het
  kastje controleert de wettigheid, en de uitslagensite ook.
- **Een code is een sleutel.** Wie een code heeft, kan de paringen van het toernooi lezen
  en er partijen voor melden. Hij kan geen resultaat invoeren, geen paring wijzigen en niets
  anders lezen. Trek een code in die je niet meer gebruikt.
- **Wat meereist in een export.** De partijen die de borden meldden, zitten in de
  JSON-export en in een herstelpunt. De koppelcodes en de toestemming van het kastje voor de
  uitslagensite (de relaissleutel) niet: een kopie op een andere machine maakt
  haar eigen codes en haalt haar eigen toestemming op.
- **Alleen gepubliceerde partijen worden op de uitslagensite getoond.** Een partij op een
  bord dat niet in de gepubliceerde momentopname staat, wordt bewaard maar niet getoond, tot
  de arbiter die ronde publiceert.
- **De klokken komen van het kastje.** Een lopende klok wordt in de browser afgeteld vanaf
  het laatste bericht, en bij elk bericht bijgesteld.
- **Onwettige zetten worden door de uitslagensite geweigerd.** De site controleert elke zet
  op de regels. Een zet die onwettig is, of op twee legale zetten past, weigert de update en
  noemt de zet, en er wordt uit die update niets bewaard.
- **Alleen twee stukkensets** worden aangeboden.
- **Ploegentoernooien staan als losse borden op het kastje**, doorgenummerd door
  de ronde, niet per wedstrijd gegroepeerd.
- **Alleen de eerste partij van een bord in een ronde verlaat het kastje.**
  Verdere partijen op hetzelfde bord blijven op het kastje.
- **Chess960 wordt niet ondersteund.**
