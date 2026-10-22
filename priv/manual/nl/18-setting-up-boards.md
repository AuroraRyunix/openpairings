# Elektronische borden installeren

Dit hoofdstuk is de installatiegids voor live borden, van begin tot eind: wat je
nodig hebt, wat je in welk programma aanklikt en wat je doet als een ronde bezig
is. Er is één pad voor een **gehoste** OpenPairings (het webadres dat je
vereniging beheert) en één voor de **desktopversie** op je eigen pc. Wat live
borden zijn en wat elke pagina ervan toont, staat in
[Live borden en Alnasl](17-live-boards.md).

> [!WARNING] Een eerste uitgave
> Alnasl, het programma dat de borden leest, is in zijn eerste uitgave. Het is
> gedraaid op gesimuleerde borden. Op echte apparatuur is het geprobeerd met
> losse borden van twee firmwaregeneraties (één met een klok) en met
> twee borden op één kabel, een lus. Op een echt bord zijn enkele zetten gespeeld,
> nog geen hele partij, en er is nog geen toernooi mee gespeeld. Niet geprobeerd:
> een hele partij op een echt bord, een zet of klok op een lus, meer dan twee
> borden op een lus en een Raspberry Pi. Het installatieprogramma is gepubliceerd,
> maar nog niemand heeft Alnasl ermee geïnstalleerd, bijgewerkt of verwijderd. De
> README van Alnasl zegt zelf wat nog niet af is. Probeer de hele opstelling vóór
> het evenement uit in je eigen ruimte, met de borden die je gaat gebruiken.

## Wat je nodig hebt {#what-you-need}

- **De borden.** Elektronische schaakborden (USB/serieel), elk met zijn kabel naar de computer.
  Alnasl leest ze als seriële poorten: een USB-bord rechtstreeks, of een
  serieel bord via een USB-serieel-adapter. Een klok op één bord is gelezen;
  klokken op een lus zijn nog niet geprobeerd.
- **Meerdere borden op één kabel (een lus).** Voeg de poort toe in Alnasl en het
  vindt de borden op die poort vanzelf, elk met een eigen rij. Twee borden op
  één kabel zijn zo gelezen. Zetten en klokken op een lus, en meer dan twee
  borden, zijn op echte apparatuur nog niet gezien.
- **Een computer in de zaal voor Alnasl.** Alnasl draait op een pc met Windows 10
  of 11 (64-bit), of op een Linux-kastje: 64-bit Debian 12, Ubuntu 22.04, of
  Raspberry Pi OS "Bookworm" 64-bit of nieuwer. Er is geen 32-bit versie. De
  README beschrijft een Raspberry Pi met scherm, toetsenbord en muis voor de
  arbiter, maar nog geen Pi heeft Alnasl gedraaid.
- **Alnasl zelf.** Een apart, gratis programma. Installeer het met het
  installatieprogramma voor je systeem:
- **Windows.** Download **Alnasl-Setup.exe** via
  `https://github.com/teapot-chess/Alnasl/releases/latest/download/Alnasl-Setup.exe`
  en start het. Het installeert alleen voor jou, zonder beheerdersrechten, en start
  een klein venster en je browser op `http://localhost:4040`. Windows waarschuwt
  de eerste keer, omdat Alnasl niet ondertekend is: klik op **Meer informatie**
  en dan op **Toch uitvoeren**.
- **Linux en Raspberry Pi (64-bit).** Op het kastje, in een terminal:
  `curl -fsSL https://github.com/teapot-chess/Alnasl/releases/latest/download/install.sh | sudo sh`.
  Dat installeert Alnasl en start het samen met het kastje; de beheersite staat
  dan op `http://localhost:4040` op het kastje. Een zaal zonder internet kan het
  archief vooraf downloaden: de sectie Install van de README zegt hoe.
- **Updates.** Alnasl zoekt naar een nieuwere versie en zegt dat op zijn
  pagina's. Het installeert er pas een als je ja zegt (Instellingen, bij de
  updates), en nooit terwijl er een partij op een bord bezig is.
- **Zelf bouwen uit de broncode** kan nog steeds; zie de README op
  `https://github.com/teapot-chess/Alnasl`.
- **Het netwerk van de zaal**, bij een gehoste OpenPairings: de computer met
  Alnasl moet het internet bereiken. Voor de desktopversie is geen internet
  nodig: met Alnasl op dezelfde pc helemaal geen netwerk, en met Alnasl op een
  andere machine een kabel of een klein eigen netwerk tussen de twee
  (zie [Installeren met de desktopversie](#set-up-desktop)).
- **Tafelnummers op de borden.** Stickers met het nummer van elke tafel. Alnasl
  drukt een vel etiketten af (Borden, **Etiketten**).

## Wie met wie praat {#who-talks-to-whom}

Drie programma's, twee richtingen van gesprek.

- **OpenPairings** leidt het toernooi en beheert de resultaten. **Alnasl belt
  het** ongeveer elke vijf seconden op om te vragen wie tegen wie speelt en welke
  ronde bezig is, en meldt wat elk bord zag: de zetten, de klokken, de PGN en de
  resultaat op het bord. OpenPairings belt Alnasl nooit, dus de zaal zet geen poort
  open. Een bord voert nooit een resultaat in.
- **Alnasl** staat in de zaal, leest de borden via hun kabels en zet wat het ziet
  om in zetten. Het heeft een eigen beheersite in een browser,
  `http://localhost:4040` op zijn eigen computer (ook vanaf een telefoon of
  laptop op het zaalnetwerk, zie hieronder).
- **OpenResults**, de publieke uitslagensite, toont de partijen live. Alnasl
  stuurt de zetten er rechtstreeks heen, en in één richting: het leest er niets
  van. Het adres van de uitslagensite, de korte naam van het toernooi en de
  toestemming om daarheen te sturen komen allemaal **via OpenPairings** bij
  Alnasl; OpenPairings haalt die toestemming zelf bij de uitslagensite op.
  Daarvan wordt op het kastje niets getypt, en niemand hoeft een beheerder iets
  te vragen.

## Installeren met een gehoste OpenPairings {#set-up-hosted}

OpenPairings staat op het web, Alnasl staat in de zaal met internet.

### In OpenPairings {#in-openpairings}

1. **Zet het toernooi op de uitslagensite.** Instellingen, **OpenResults**,
   **Op de uitslagensite**: **Alleen link** of **Op de voorpagina**. De
   uitslagensite moet eerst gekoppeld zijn (zie
   [Een uitslagensite verbinden](14-publishing.md#connecting-a-results-site)).
   Staat het toernooi op de site, dan zegt Instellingen, **Live borden**
   *Verbonden met … als …*.
2. **Maak een koppelcode.** Instellingen, **Live borden**, kaart **Codes voor
   dit toernooi**, druk op **Nieuwe code**. De pagina toont de code als regel
   tekst en als QR-code, **één keer**: *De nieuwe code. Ze wordt alleen nu
   getoond.* Kopieer de regel nu. Ben je ze kwijt, maak dan een nieuwe; een
   code is één klik.

   Meer heeft het kastje niet nodig. De kaart **De uitslagensite** op dezelfde
   pagina gaat vanzelf van *Toestemming wordt bij de uitslagensite opgehaald…*
   naar *Ja. Het kastje mag daar zetten naartoe sturen.*, meestal binnen
   enkele seconden. Er is geen sleutel om aan te vragen, te kopiëren of te
   plakken. (Wat daarachter gebeurt:
   [De toestemming van het kastje](17-live-boards.md#the-relay-key-for-the-box).)
3. **Besluit over de openbare link.** De schakelaar **Live-link op de
   uitslagensite** (Aan / Uit) zet een link *Live borden* op de openbare
   pagina's. Een kastje koppelen zet hem niet aan: dat is aan jou, wanneer de
   borden echt doorgegeven worden.

Stap 1 en 2 mogen in beide volgordes. Een code die gemaakt is voordat het
toernooi op de uitslagensite staat, werkt meteen voor de paringen, en de
toestemming voor de uitslagensite volgt zodra het toernooi daar is aangekomen.

### In Alnasl, in de zaal {#in-alnasl}

4. **Plak de code.** Open Alnasl (`http://localhost:4040`), **Instellingen**,
   paneel **Toernooien**. Plak de hele regel in **Koppelcode** en druk op
   **Toevoegen**. Vanaf een telefoon: scan de QR-code met de *eigen* camera van
   de telefoon, kopieer de link die hij toont in plaats van hem te openen, en
   plak die. De pagina van Alnasl kan de QR-code zelf niet scannen (een browser
   leent zijn camera alleen aan pagina's via https), dus op het kastje is de code
   alleen te plakken.
5. **Verbinding testen.** Dit controleert drie dingen, elk in woorden: *Adres*
   (OpenPairings antwoordt), *Code* (de koppelcode is aanvaard), *Toernooien*
   (*De code bereikt N toernooi(en)*). Onder elk toernooi zie je de ronde die
   bezig is en *de uitslagenpagina en relaissleutel zijn meegekomen* (de
   relaissleutel is de toestemming die OpenPairings ophaalde; je deed er niets
   voor). Al het andere wordt uitgelegd in
   [Als er iets mis is](#troubleshooting).
6. **Geef op welke tafels in het toernooi spelen.** Onder het toernooi: **Tafels
   van** … **tot** …, dan **Deze tafels spelen hier**. Tafel 5 is dan bord 1 van
   het toernooi. Het kastje toont hoeveel borden het nu heeft.
7. **Nummer de borden.** Borden, **Nummeren door aan te raken**: druk op Start,
   til een stuk op van het bord van tafel 1, dan van tafel 2, enzovoort. (Op een
   telefoon is deze pagina gemaakt om in één hand te houden. Om het kastje vanaf
   een telefoon te openen, start je het met `ALNASL_LISTEN=lan` en **stel je eerst
   een PIN in** bij Instellingen, voordat de zaal vol loopt.) Of **Alles nummeren
   in aansluitvolgorde**, of typ het nummer in de kolom **Tafel**.
8. **Controleer "Klaar voor ronde N?"** op Borden. Het moet *Klaar* zeggen. Zo
   niet, dan staat er bord per bord wat er mis is: twee borden met hetzelfde
   nummer, een bord dat niet antwoordt, een verkeerde beginstelling, een klok
   die niet in beginstelling staat (de wip omhoog aan de kant van wit).
9. **Controleer de pagina Ronde.** Elke tegel moet *Wacht op begin* zeggen.

### De ronde {#the-round}

10. **Paar de ronde in OpenPairings** zoals altijd (**Ronde N paren**).
    OpenPairings heeft geen knop die een ronde start: een ronde die gepaard is,
    is bezig. Binnen ongeveer vijf seconden tonen de borden van dat toernooi de
    nieuwe ronde, met namen, ratings en kleuren. Gebeurt dat niet (geen
    verbinding), dan doet **Ronde N starten** op de pagina Ronde van Alnasl het
    met de hand.
11. **Spelen.** Houd de pagina Ronde van Alnasl open. Een tegel per bord toont de
    toestand als een vorm en een woord: *Live*, *Bezig*, *Afgeleid*,
    *Niet synchroon*, *Geen signaal*, *Klok verkeerd om*, *Afgelopen*. Op de
    pagina Paringen van OpenPairings toont de kolom **Bord zag** wat het bord
    meldde, naast het resultaat die je invoert.
12. **Voer de resultaten in OpenPairings in**, op de pagina Paringen, zoals je
    altijd doet ([Resultaten invoeren](07-results.md)). Een bord voert er nooit
    een in. Zag het bord een andere resultaat dan die je invoerde, dan staat de
    vermelding in het rood met *wijkt af* en zegt de hovertekst *Controleer de
    notatieformulieren. Er wordt niets geblokkeerd.* Controleer het
    notatieformulier, verbeter wat fout is, en ga door.
13. **Toeschouwers** zien de zetten op de livepagina's van de uitslagensite. Ze
    zien een partij alleen voor een bord van een **gepubliceerde** ronde.

## Installeren met de desktopversie {#set-up-desktop}

OpenPairings draait op je eigen pc (de desktopversie). Alnasl draait **op
dezelfde pc**, of **op een andere machine in de zaal** die op hetzelfde lokale
netwerk zit.

> [!IMPORTANT] Twee manieren, twee codes
> De desktopversie antwoordt op zijn eigen computer en nergens anders. Voor een
> Alnasl op dezelfde computer volstaat dat, en de koppelcode zegt
> `http://127.0.0.1:<poort>`. Een Alnasl op een andere machine kan hem pas
> bereiken nadat je **Laat borden op dit netwerk verbinden** hebt aangezet; de
> code daarvoor bevat in de plaats het adres van je computer op het netwerk.
> Een code is voor het ene of voor het andere, en de pagina zegt welk.

Stap 2 tot en met 13 hierboven zijn hetzelfde, met deze verschillen:

- **De code, Alnasl op dezelfde pc.** Instellingen, **Live borden** zegt in
  plaats van een serveradres: *Deze kopie antwoordt alleen op deze computer*.
  Druk op **Nieuwe code voor een kastje op deze computer** (stap 2) en plak ze
  in de Alnasl op dezelfde pc (stap 4). Verbinding testen werkt zonder
  internet.
- **De code, Alnasl op een andere machine.** Zie
  [Alnasl op een andere machine](#desktop-on-the-network) hieronder.
- **De uitslagensite is optioneel.** Met internet doe je stap 1 als bij de
  gehoste installatie, en dan gaan de zetten ook naar de uitslagensite. Zonder
  internet doe je dat niet: Alnasl en OpenPairings werken nog steeds samen.
- **Publiceer zolang je nog internet hebt.** Het adres van de uitslagensite, de
  korte naam en de toestemming die Alnasl nodig heeft, bestaan pas zodra het
  toernooi de uitslagensite heeft bereikt en de desktopkopie de toestemming
  heeft opgehaald. Heeft het evenement geen internet, doe dan stap 1 en 2 thuis
  en wacht tot de kaart **De uitslagensite** zegt *Ja. Het kastje mag daar
  zetten naartoe sturen.* Zonder verbinding blijft de kaart *Toestemming wordt
  bij de uitslagensite opgehaald…* zeggen en probeert ze het vanzelf opnieuw
  zodra er verbinding is.

### Alnasl op een andere machine {#desktop-on-the-network}

Voor een kastje naast de borden en OpenPairings op je laptop aan de
arbiterstafel. Internet is niet nodig, alleen een netwerk dat de twee machines
delen.

1. **Verbind de twee machines.** Het best: één netwerkkabel ertussen, of een
   kleine eigen router waar niemand anders op zit. Een wifi die de spelers
   gebruiken werkt ook, en is die om te vermijden: lees de waarschuwing op de
   pagina.
2. In OpenPairings, Instellingen, **Live borden**, kaart **Kastjes elders op
   dit netwerk**: zet **Laat borden op dit netwerk verbinden** aan. Lees wat er
   staat; het is kort.
3. **Windows vraagt** of het programma op het netwerk mag. Vink **Particuliere
   netwerken** aan, kies **Toestaan**. Zag je de vraag nooit en krijgt het
   kastje geen antwoord, sta OpenPairings dan met de hand toe:
   Windows-beveiliging, Firewall en netwerkbeveiliging, Een app door de
   firewall toestaan.
4. De kaart toont het adres dat je computer op dat netwerk heeft, bijvoorbeeld
   `http://192.168.1.20:4747`. Zit de computer op meerdere netwerken, kies dan
   dat waar het kastje op zit en druk op **Gebruik deze**.
5. Druk op **Nieuwe code voor een kastje op het netwerk**. De pagina zegt waar
   de code heen leidt. Plak ze in Alnasl op de andere machine (stap 4 van de
   gehoste installatie) en druk op Verbinding testen.
6. Vanaf hier is het hetzelfde als elke andere installatie.

Wat je moet weten:

- De deur die dit opent, antwoordt het kastje van de borden en **niets
  anders**. Je toernooien en de pagina's van OpenPairings blijven op je eigen
  computer.
- Een netwerkcode werkt tot ze wordt ingetrokken. Trek ze in als het evenement voorbij is.
- **Verandert het adres van je computer** (een andere dag, een ander netwerk,
  de router herstart), dan zegt het kastje *Geen antwoord* en zegt de pagina in
  OpenPairings *Het adres van deze computer is veranderd van … naar …*. Kies
  het nieuwe adres, maak een nieuwe code, geef ze aan het kastje. Een vast
  adres voor je computer, of een kabel tussen de twee machines, voorkomt het.
- Na het evenement: trek de code in. Zonder netwerkcode sluit de deur vanzelf;
  je kunt ze ook uitzetten, op dezelfde kaart of onder Verbindingen.

### Wat zonder internet werkt {#what-works-offline}

| | Met internet | Zonder internet |
| --- | --- | --- |
| Namen, borden, kleuren en rondes van OpenPairings naar Alnasl | werkt | werkt (op dezelfde pc, of over een eigen netwerk naar een andere machine) |
| De ronde die vanzelf start als je ze paart | werkt | werkt |
| Zetten, klokken, PGN en het resultaat die het bord zag, terug naar OpenPairings | werkt | werkt |
| De kolom **Bord zag**, de partijpagina en de PGN met zetten | werkt | werkt |
| Zetten naar de uitslagensite (livepagina's voor toeschouwers) | werkt | **wacht** in de wachtrij van Alnasl (de pagina Wachtrij zegt hoeveel) en gaat in volgorde weg zodra er verbinding is |
| Lichess-uitzending (als je er in Alnasl een instelde) | werkt | wacht op dezelfde manier |
| Het toernooi publiceren, en OpenPairings dat de toestemming van het kastje voor de uitslagensite ophaalt | werkt, vanzelf | wacht, en gebeurt vanzelf zodra er verbinding is |

Een balk op elke pagina van Alnasl zegt wanneer de uitslagensite niet bereikbaar
is. Het spel gaat door en er gaat niets verloren.

## Meerdere toernooien in één zaal {#several-tournaments}

Tafels 1 tot 4 kunnen één categorie spelen en tafels 5 tot 8 een andere. Eén
kastje houdt meerdere toernooien vast, elk met eigen paringen, eigen lopende
ronde en eigen uitslagenpagina.

- **Een code per toernooi**, of **één code voor een groep**. Een toernooi in een
  [groep](03-tournament-setup.md#tournament-groups) heeft ook de kaart **Codes
  voor de groep**. Eén groepscode brengt elk toernooi van de groep dat *de maker
  van de code* mag openen, en een toernooi dat later aan de groep wordt
  toegevoegd, verschijnt op het kastje zonder nieuwe scan. Een toernooi van een
  andere arbiter, dat je niet kunt openen, komt niet op je kastje.
- **Welke tafel in welk toernooi speelt, zeg je op het kastje**, niet in
  OpenPairings: onder elk toernooi **Tafels van 5 tot 8**, **Deze tafels spelen
  hier**. De bordnummers beginnen in elk toernooi opnieuw.
- **Een ronde start vanzelf, alleen voor de borden van dat toernooi.** De borden
  van de andere toernooien worden niet aangeraakt.
- **Eén code per toernooi op één kastje.** Twee codes die hetzelfde toernooi
  bereiken, laten Alnasl het twee keer bijhouden, en elke partij wordt dan twee
  keer gemeld. Maakte je voor hetzelfde evenement een toernooicode en een
  groepscode, voeg dan maar één van beide toe (**Verwijderen** de andere bij
  Instellingen).
- Een toernooi kan tot 8 codes hebben, en een groep ook. Trek een code in die je
  niet meer gebruikt.

## Tijdens de ronde {#during-the-round}

- **Een bord dat niet synchroon is.** De tegel zegt *Niet synchroon*; er wordt
  niets verstuurd voor dat bord. Open de pagina van het bord in Alnasl: ze toont
  wat het bord leest naast wat zeker is, en de herstelmiddelen (*Het bord is
  juist - hier hersynchroniseren*, *De zetten typen*, *Laatste zet ongedaan
  maken*). Alles wat je daar doet, staat in het Logboek. Een bord dat weer klopt,
  komt vanzelf terug.
- **De markeringen op zetten.** Oranje (*Afgeleid*): het kastje zag de
  zet niet gebeuren en rekende hem uit, één lijn van zetten past. Rood
  (*geraden*): meer dan één lijn paste en het kastje nam er één; tik erop en het
  kastje vraagt welke het was. *gelezen als d3* naast een zet: hij werd één veld ernaast
  gelezen en later rechtgezet. Deze aantallen reizen met de partij mee naar
  OpenPairings en staan op de partijpagina daar. De details staan in de eigen
  Help van Alnasl (de pagina **Help** op het kastje).
- **Paring gewijzigd.** Wijzig je een paring in OpenPairings nadat de ronde
  begon, dan neemt een bord waar niets gespeeld is de nieuwe paring over. Een
  partij met zetten blijft bewaard en haar tegel zegt *Paring gewijzigd in
  OpenPairings*. Open het bord en kies: **Deze zetten zijn die partij** (de
  spelers zijn die van de nieuwe paring) of **Opzijzetten, opnieuw beginnen**.
  Een partij die alleen een ander bordnummer kreeg, verhuist vanzelf.
- **Een ingetrokken code.** Druk je op **Intrekken** bij een code, dan wordt het
  kastje dat ze heeft bij zijn volgende verzoek geweigerd. Zijn koppeling zegt
  *Code geweigerd*; het vraagt niet meer en de borden gaan door met de paringen
  die het heeft. Maak een nieuwe code en voeg ze toe.
- **Een bord losgetrokken.** De tegel zegt *Geen signaal*. Controleer kabel en
  stroom; de partij blijft bewaard. Een bord dat op een andere poort terugkomt,
  wordt herkend aan zijn serienummer zodra je het op die poort toevoegt.
- **Geen internet.** Beschreven in [Wat zonder internet werkt](#what-works-offline).

## Na de ronde en na het evenement {#after-the-round}

1. **Controleer de resultaten.** Kijk de kolom **Bord zag** na op rood. Er wordt
   niets geblokkeerd: je kunt de volgende ronde paren en publiceren. Elke
   vermelding is een link naar de partijpagina.
2. **Beëindig partijen op het kastje** waar dat nodig is (*Partij beëindigen*,
   onder de tegel of op de pagina van het bord: een resultaat, of *Geen
   resultaat*). Dat is het eigen archief van Alnasl, niet het resultaat in
   OpenPairings.
3. **PGN met de zetten.** De partijpagina biedt **PGN downloaden**, en **De eigen
   PGN van het kastje** ter vergelijking. Instellingen, **Live borden**, kaart
   **Partijen die de borden meldden**: **PGN, hele toernooi** en een knop per
   ronde. Het resultaat in het bestand is dat wat je invoerde, of `*` zolang je dat
   niet deed. De PGN-export van de pagina Paringen (**Meer**, PGN) bevat nog
   steeds geen zetten. Alnasl heeft zelf een pagina PGN (*Hele ronde als PGN*).
4. **Wat waar bewaard wordt.** De partijen worden bij het toernooi in
   OpenPairings bewaard en staan in de JSON-export en de herstelpunten. De
   koppelcodes en de toestemming van het kastje voor de uitslagensite niet: een
   kopie elders maakt haar eigen codes en haalt haar eigen toestemming op. Op het
   kastje staan de partijen, de wachtrij en de instellingen op schijf in de
   gegevensmap van Alnasl, met een PGN-bestand per partij. Die map is
   `%LOCALAPPDATA%\AlnaslData` op Windows (geïnstalleerd of als zip),
   `/var/lib/alnasl` op een geïnstalleerd Linux-kastje, en `~/.alnasl` voor een
   kopie die vanuit de broncode in productie draait. Het scherm Instellingen
   toont de map in gebruik. Een update of een herinstallatie raakt die map niet
   aan, en verwijderen laat hem ook staan; wist je hem zelf wanneer je dat wilt.
   Een kopie die op een andere manier op dezelfde computer is gestart, bijvoorbeeld
   uit de broncode, heeft een eigen gegevensmap met eigen borden en partijen.
5. **Trek de codes in** als het evenement voorbij is: Instellingen, Live borden,
   **Intrekken**, en in Alnasl **Verwijderen** bij Instellingen, Toernooien. Een
   toernooi van het kastje halen laat het de partijen daar vergeten (de al
   geschreven PGN-bestanden blijven op schijf); OpenPairings houdt wat eraan
   gemeld is.
6. **Haal de openbare link weg** als je hem niet meer wilt: de schakelaar
   **Live-link op de uitslagensite**.

## Als er iets mis is {#troubleshooting}

| Wat je ziet | Waarom | Wat te doen |
| --- | --- | --- |
| Alnasl: *Dat is geen volledige koppelcode: het deel na de # ontbreekt.* | De regel is bij het kopiëren afgebroken. | Kopieer de hele regel, van `https://` tot het einde. |
| Alnasl: *OpenPairings kent deze code niet* of *OpenPairings weigert de koppelcode*; de koppeling zegt *Code geweigerd* | Verkeerd getypt, of in OpenPairings **ingetrokken**. Het kastje vraagt niet meer. | Maak een nieuwe code (Instellingen, Live borden), voeg ze toe in Alnasl, verwijder de oude. |
| Alnasl: *OpenPairings is niet bereikbaar*; de koppeling zegt *Geen antwoord* | De server of het zaalnetwerk ligt eruit. Er gaat niets verloren: de borden gaan door met de paringen die ze hebben en het kastje vraagt vanzelf opnieuw. | Controleer het netwerk. Een ronde die intussen gepaard is: **Ronde N starten**. |
| *Geen antwoord. Deze code is voor een OpenPairings op deze zelfde computer: draait het?* | Een code *voor een kastje op deze computer* wordt gebruikt op een computer die niet die van OpenPairings is, of OpenPairings draait niet. | Draai Alnasl op dezelfde pc als de desktop-OpenPairings en start OpenPairings; of maak een code *voor een kastje op het netwerk* (zie [Alnasl op een andere machine](#desktop-on-the-network)). |
| Alnasl op een andere machine: *OpenPairings is niet bereikbaar*, bij een desktop-OpenPairings | Een van: de schakelaar staat uit; de firewall van Windows liet het niet toe; de twee machines zitten niet op hetzelfde netwerk; het adres van je computer is veranderd; er bestaat geen netwerkcode meer, dus de deur is dicht. | Instellingen, Live borden, kaart **Kastjes elders op dit netwerk** zegt welke. Adres veranderd: kies het nieuwe, maak een nieuwe code. Firewall: sta OpenPairings toe op particuliere netwerken in Windows-beveiliging. |
| OpenPairings: *Poort 4747 is in gebruik door een ander programma op deze computer* | Een ander programma heeft die poort. | Kies op dezelfde kaart een andere poort en druk op **Gebruik deze**, maak daarna een nieuwe code. Verder verandert er niets. |
| Alnasl: *Code geweigerd*, met een netwerkcode die eerder werkte | De code is ingetrokken, of het is een code *voor een kastje op deze computer* die vanaf een andere machine wordt gebruikt. | Maak een nieuwe code *voor een kastje op het netwerk*. |
| De kolom **Bord zag** is leeg nadat je een ronde opnieuw paarde | De partijen van de oude paringen zijn samen met die paringen verwijderd. | Niets: het kastje begint de nieuwe partijen. De oude staan nog op het kastje. |
| *Er antwoordt iets op dat adres, maar niet als de bordkoppeling van OpenPairings* | Een aanmeldpagina van het zaalnetwerk, of een ander programma op die poort. | Meld je aan op het zaalnetwerk, of controleer het adres. |
| *… het is niet gepubliceerd op een uitslagensite, dus de zetten gaan alleen naar OpenPairings* | Het toernooi staat niet op de uitslagensite. | Publiceer het (stap 1). Het adres en de toestemming komen daarna vanzelf. |
| *… het staat op een uitslagensite, maar in OpenPairings is geen relaissleutel bewaard* | OpenPairings heeft de toestemming van het kastje (nog) niet van de uitslagensite gekregen. Meestal is dat een kwestie van seconden; anders is de uitslagensite niet bereikbaar, zei ze nee, of is ze een oudere versie. | Open Instellingen, Live borden, kaart **De uitslagensite**: die zegt welke. *Toestemming wordt … opgehaald…*: wacht, het wordt vanzelf opnieuw geprobeerd. *Nog niet … : reden*: lees de reden, dan **Opnieuw proberen**. *Oudere versie*: zie de volgende rij. |
| De kaart zegt *het is een oudere versie die dit niet zelf kan* en toont een veld **Relaissleutel** | De uitslagensite is van voor ze de toestemming kon uitgeven. | Vraag de beheerder van die site om een relaissleutel voor het toernooi en plak ze in het veld. Zie [Relaissleutels](17-live-boards.md#relay-keys). |
| De kaart zegt *Zet het toernooi eerst op de uitslagensite* | Het toernooi staat nog niet op de uitslagensite. | Publiceer het (stap 1). |
| *Dat lijkt niet op een relaissleutel: 16 tot 200 tekens, zonder spaties.* | Alleen bij een oudere uitslagensite: de geplakte sleutel is afgebroken of heeft spaties. | Plak hem opnieuw. |
| Het kastje stuurde en de uitslagensite weigert het nu | De toestemming is vervangen of ingetrokken (door jou, of door de beheerder van de site). | Instellingen, Live borden, **De toestemming van het kastje vervangen**. Het kastje haalt de nieuwe vanzelf op. |
| *Er zijn al 8 codes.* | De grens. | Trek een code in die je niet meer gebruikt. |
| *De code bereikt nu geen toernooi* | Het toernooi is verwijderd of gearchiveerd, of de groep is leeg. | Controleer het toernooi; een gearchiveerd of overgedragen toernooi kan niet op een kastje staan. |
| *OpenPairings vraagt om het rustiger aan te doen* | Te veel verzoeken. | Niets: het kastje probeert het vanzelf opnieuw. |
| De nieuwe ronde verschijnt niet | Het kastje vraagt ongeveer elke vijf seconden. | Wacht een paar seconden. Nog niets, kijk dan naar de stand van de koppeling bij Instellingen, of gebruik **Ronde N starten**. |
| *Klok niet in beginstelling: … de klok staat omgekeerd of de wip staat verkeerd* | De klok staat niet voor wit klaar (ze staat rechts van het bord, de wip omhoog aan de kant van wit). | Draai de klok of tip de wip. De melding verdwijnt vanzelf. |
| Dezelfde partij wordt twee keer gemeld | Twee codes bereiken hetzelfde toernooi op één kastje. | Houd één code (zie [meerdere toernooien](#several-tournaments)). |
| Geen kolom **Bord zag** op de pagina Paringen | Nog geen code bereikt dit toernooi en geen bord meldde een partij. | Maak een code (stap 2) en voeg ze toe op het kastje. |
| Rood *wijkt af* in de kolom Bord zag | Het bord zag een andere resultaat dan de ingevoerde. | Controleer de notatieformulieren. Er wordt niets geblokkeerd. |
| Een tegel zegt *Paring gewijzigd in OpenPairings* | Een paring veranderde nadat er zetten waren gespeeld. | Zie [Tijdens de ronde](#during-the-round). |
| De uitslagensite toont niets | De partijen wachten in de wachtrij; of de ronde is niet gepubliceerd; of het kastje heeft nog geen toestemming (het toernooi staat niet op de uitslagensite, of de site is onbereikbaar, zei nee, of is te oud). | De pagina **Wachtrij** van Alnasl zegt wat er wacht en waarom, en Instellingen, Live borden, kaart **De uitslagensite** zegt hoe het met de toestemming staat. Een partij wordt alleen getoond voor een bord van een gepubliceerde ronde. |

## Beperkingen van nu {#limits-today}

- **Teamtoernooien** staan op het kastje als losse borden, doorgenummerd
  door de ronde, niet gegroepeerd per wedstrijd en zonder de teamnamen.
- **Alleen de eerste partij van een bord in een ronde verlaat het kastje.** Een
  tweede partij op hetzelfde bord (een nieuwe partij na een onderbreking) blijft
  op het kastje en in zijn PGN; de uitslagensite, Lichess en OpenPairings kennen
  één partij per bord en ronde.
- **Chess960** wordt niet ondersteund.
- **Een kastje op een andere machine gebruikt een desktop-OpenPairings over
  gewoon http.** Het werkt op het eigen netwerk van de zaal nadat je het hebt
  aangezet, de code gaat leesbaar over dat netwerk, en een veranderd adres
  betekent een nieuwe code; zie
  [Alnasl op een andere machine](#desktop-on-the-network). Het is uitgevoerd op
  één computer die met zijn eigen netwerkadres praat, nog niet tussen twee
  machines in een zaal.
- **De koppelcode is op het kastje alleen te plakken.** Scan de QR-code met de
  eigen camera van de telefoon, kopieer de link, plak hem.
- **Geen Raspberry Pi-image en geen 32-bit versie.** De Linux-installatie vraagt
  een 64-bit systeem, en nog geen Pi heeft Alnasl gedraaid; zie
  [Wat je nodig hebt](#what-you-need).
- Meer beperkingen van de koppeling zelf staan in
  [Beperkingen](17-live-boards.md#limits).
