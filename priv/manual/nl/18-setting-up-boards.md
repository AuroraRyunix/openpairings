# Elektronische borden installeren

Dit hoofdstuk is de installatiegids voor live borden, van begin tot eind: wat u
nodig hebt, wat u in welk programma aanklikt en wat u doet als een ronde bezig
is. Er is één pad voor een **gehoste** OpenPairings (het webadres dat uw
vereniging beheert) en één voor de **desktopversie** op uw eigen pc. Wat live
borden zijn en wat elke pagina ervan toont, staat in
[Live borden en Alnasl](17-live-boards.md).

> [!WARNING] Een eerste versie
> Alnasl, het programma dat de borden leest, is een eerste versie. Het is
> gedraaid op gesimuleerde borden en heeft één echt DGT-bord met klok gelezen;
> een hele partij op een echt bord en een lus met meerdere borden zijn nog niet
> bewezen. De README van Alnasl zegt dat zelf, onder "What is not done". Probeer
> de hele opstelling vóór het evenement uit in uw eigen ruimte, met de borden
> die u gaat gebruiken.

## Wat u nodig hebt {#what-you-need}

- **De borden.** Elektronische DGT-borden, elk met zijn kabel naar de computer.
  Alnasl leest ze als seriële poorten. Een DGT-klok op het bord geeft de
  kloktijden.
- **Een computer in de zaal voor Alnasl.** De README beschrijft een Raspberry Pi
  met scherm, toetsenbord en muis voor de arbiter; een pc kan ook. Hij heeft een
  C-compiler en `make` nodig om de seriële bibliotheek te bouwen (op Windows
  staat die bibliotheek uit tenzij u erom vraagt, en ze struikelt over mappen
  met een spatie in de naam: zie "Serial ports" in de README).
- **Alnasl zelf.** Het is een apart, gratis programma. Haal het uit zijn
  repository, `github.com/AuroraRyunix/Alnasl`, en installeer het zoals de README
  zegt. **Er is nog geen installatieprogramma, geen kant-en-klaar image en geen
  systeemdienst**: u bouwt het uit de broncode met Elixir en start het met
  `mix phx.server`. Is dat meer dan u wilt doen, vraag het dan aan wie uw
  computers beheert, of lees de README samen met die persoon.
- **Het netwerk van de zaal**, bij een gehoste OpenPairings: de computer met
  Alnasl moet het internet bereiken. Voor de desktopversie is geen netwerk nodig
  (zie [Installeren met de desktopversie](#set-up-desktop)).
- **Tafelnummers op de borden.** Stickers met het nummer van elke tafel. Alnasl
  drukt een vel etiketten af (Borden, **Etiketten**).

## Wie met wie praat {#who-talks-to-whom}

Drie programma's, twee richtingen van gesprek.

- **OpenPairings** leidt het toernooi en beheert de uitslagen. **Alnasl belt
  het** ongeveer elke vijf seconden op om te vragen wie tegen wie speelt en welke
  ronde bezig is, en meldt wat elk bord zag: de zetten, de klokken, de PGN en de
  uitslag op het bord. OpenPairings belt Alnasl nooit, dus de zaal zet geen poort
  open. Een bord voert nooit een uitslag in.
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
   getoond.* Kopieer de regel nu. Bent u ze kwijt, maak dan een nieuwe; een
   code is één klik.

   Meer heeft het kastje niet nodig. De kaart **De uitslagensite** op dezelfde
   pagina gaat vanzelf van *Toestemming wordt bij de uitslagensite opgehaald…*
   naar *Ja. Het kastje mag daar zetten naartoe sturen.*, meestal binnen
   enkele seconden. Er is geen sleutel om aan te vragen, te kopiëren of te
   plakken. (Wat daarachter gebeurt:
   [De toestemming van het kastje](17-live-boards.md#the-relay-key-for-the-box).)
3. **Besluit over de openbare link.** De schakelaar **Live-link op de
   uitslagensite** (Aan / Uit) zet een link *Live borden* op de openbare
   pagina's. Een kastje koppelen zet hem niet aan: dat is aan u, wanneer de
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
   (*De code bereikt N toernooi(en)*). Onder elk toernooi ziet u de ronde die
   bezig is en *de uitslagenpagina en relaysleutel zijn meegekomen* (de
   relaissleutel is de toestemming die OpenPairings ophaalde; u deed er niets
   voor). Al het andere wordt uitgelegd in
   [Als er iets mis is](#troubleshooting).
6. **Geef op welke tafels in het toernooi spelen.** Onder het toernooi: **Tafels
   van** … **tot** …, dan **Deze tafels spelen hier**. Tafel 5 is dan bord 1 van
   het toernooi. Het kastje toont hoeveel borden het nu heeft.
7. **Nummer de borden.** Borden, **Nummeren door aan te raken**: druk op Start,
   til een stuk op van het bord van tafel 1, dan van tafel 2, enzovoort. (Op een
   telefoon is deze pagina gemaakt om in één hand te houden. Om het kastje vanaf
   een telefoon te openen, start u het met `ALNASL_LISTEN=lan` en **stelt u eerst
   een PIN in** bij Instellingen, voordat de zaal vol loopt.) Of **Alles nummeren
   in aansluitvolgorde**, of typ het nummer in de kolom **Tafel**.
8. **Controleer "Klaar voor ronde N?"** op Borden. Het moet *Gereed* zeggen. Zo
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
    toestand als een vorm en een woord: *Live*, *Bezig*, *Gereconstrueerd*,
    *Niet synchroon*, *Geen signaal*, *Klok verkeerd om*, *Afgelopen*. Op de
    pagina Paringen van OpenPairings toont de kolom **Bord zag** wat het bord
    meldde, naast de uitslag die u invoert.
12. **Voer de uitslagen in OpenPairings in**, op de pagina Paringen, zoals u
    altijd doet ([Resultaten invoeren](07-results.md)). Een bord voert er nooit
    een in. Zag het bord een andere uitslag dan die u invoerde, dan staat de
    vermelding in het rood met *wijkt af* en zegt de hovertekst *Controleer de
    notatieformulieren. Er wordt niets geblokkeerd.* Controleer het
    notatieformulier, verbeter wat fout is, en ga door.
13. **Toeschouwers** zien de zetten op de livepagina's van de uitslagensite. Ze
    zien een partij alleen voor een bord van een **gepubliceerde** ronde.

## Installeren met de desktopversie {#set-up-desktop}

OpenPairings draait op uw eigen pc (de desktopversie) en Alnasl draait **op
dezelfde pc**.

> [!IMPORTANT] Dezelfde computer
> De desktopversie antwoordt op zijn eigen computer en nergens anders. De
> koppelcode zegt daarom `http://127.0.0.1:<poort>` en werkt alleen voor een
> Alnasl op die computer. **Een Alnasl op een andere machine in de zaal kan een
> desktop-OpenPairings vandaag niet bereiken.** Dat is een bekende beperking.
> Moet het kastje een aparte kleine computer zijn, gebruik dan de gehoste
> versie.

Stap 2 tot en met 13 hierboven zijn hetzelfde, met deze verschillen:

- **De code.** Instellingen, **Live borden** zegt in plaats van een
  serveradres: *Deze kopie antwoordt alleen op deze computer, dus het
  kastjesprogramma moet ook op deze computer draaien*. Maak de code (stap 2) en
  plak ze in de Alnasl op dezelfde pc (stap 4). Verbinding testen werkt zonder
  internet.
- **De uitslagensite is optioneel.** Met internet doet u stap 1 als bij de
  gehoste installatie, en dan gaan de zetten ook naar de uitslagensite. Zonder
  internet doet u dat niet: Alnasl en OpenPairings werken nog steeds samen.
- **Publiceer zolang u nog internet hebt.** Het adres van de uitslagensite, de
  korte naam en de toestemming die Alnasl nodig heeft, bestaan pas zodra het
  toernooi de uitslagensite heeft bereikt en de desktopkopie de toestemming
  heeft opgehaald. Heeft het evenement geen internet, doe dan stap 1 en 2 thuis
  en wacht tot de kaart **De uitslagensite** zegt *Ja. Het kastje mag daar
  zetten naartoe sturen.* Zonder verbinding blijft de kaart *Toestemming wordt
  bij de uitslagensite opgehaald…* zeggen en probeert ze het vanzelf opnieuw
  zodra er verbinding is.

### Wat zonder internet werkt {#what-works-offline}

| | Met internet | Zonder internet |
| --- | --- | --- |
| Namen, borden, kleuren en rondes van OpenPairings naar Alnasl | werkt | werkt (op dezelfde pc) |
| De ronde die vanzelf start als u ze paart | werkt | werkt |
| Zetten, klokken, PGN en de uitslag die het bord zag, terug naar OpenPairings | werkt | werkt |
| De kolom **Bord zag**, de partijpagina en de PGN met zetten | werkt | werkt |
| Zetten naar de uitslagensite (livepagina's voor toeschouwers) | werkt | **wacht** in de wachtrij van Alnasl (de pagina Verzendlijst zegt hoeveel) en gaat in volgorde weg zodra er verbinding is |
| Lichess-uitzending (als u er in Alnasl een instelde) | werkt | wacht op dezelfde manier |
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
  andere arbiter, dat u niet kunt openen, komt niet op uw kastje.
- **Welke tafel in welk toernooi speelt, zegt u op het kastje**, niet in
  OpenPairings: onder elk toernooi **Tafels van 5 tot 8**, **Deze tafels spelen
  hier**. De bordnummers beginnen in elk toernooi opnieuw.
- **Een ronde start vanzelf, alleen voor de borden van dat toernooi.** De borden
  van de andere toernooien worden niet aangeraakt.
- **Eén code per toernooi op één kastje.** Twee codes die hetzelfde toernooi
  bereiken, laten Alnasl het twee keer bijhouden, en elke partij wordt dan twee
  keer gemeld. Maakte u voor hetzelfde evenement een toernooicode en een
  groepscode, voeg dan maar één van beide toe (**Verwijderen** de andere bij
  Instellingen).
- Een toernooi kan tot 8 codes hebben, en een groep ook. Trek een code in die u
  niet meer gebruikt.

## Tijdens de ronde {#during-the-round}

- **Een bord dat niet synchroon is.** De tegel zegt *Niet synchroon*; er wordt
  niets verzonden voor dat bord. Open de pagina van het bord in Alnasl: ze toont
  wat het bord leest naast wat zeker is, en de herstelmiddelen (*Het bord is
  juist - hier hersynchroniseren*, *De zetten typen*, *Laatste zet ongedaan
  maken*). Alles wat u daar doet, staat in het Logboek. Een bord dat weer klopt,
  komt vanzelf terug.
- **De markeringen op zetten.** Oranje (*Gereconstrueerd*): het kastje zag de
  zet niet gebeuren en rekende hem uit, één lijn van zetten past. Rood
  (*gegokt*): meer dan één lijn paste en het kastje nam er één; tik erop en het
  kastje vraagt welke het was. *read as d3* naast een zet: hij werd één veld ernaast
  gelezen en later rechtgezet. Deze aantallen reizen met de partij mee naar
  OpenPairings en staan op de partijpagina daar. De details staan in de eigen
  Hulp van Alnasl (de pagina **Hulp** op het kastje).
- **Indeling gewijzigd.** Wijzigt u een paring in OpenPairings nadat de ronde
  begon, dan neemt een bord waar niets gespeeld is de nieuwe paring over. Een
  partij met zetten blijft bewaard en haar tegel zegt *Indeling gewijzigd in
  OpenPairings*. Open het bord en kies: **Deze zetten zijn die partij** (de
  spelers zijn die van de nieuwe paring) of **Opzijzetten, opnieuw beginnen**.
  Een partij die alleen een ander bordnummer kreeg, verhuist vanzelf.
- **Een ingetrokken code.** Drukt u op **Intrekken** bij een code, dan wordt het
  kastje dat ze heeft bij zijn volgende verzoek geweigerd. Zijn koppeling zegt
  *Code geweigerd*; het vraagt niet meer en de borden gaan door met de paringen
  die het heeft. Maak een nieuwe code en voeg ze toe.
- **Een bord losgetrokken.** De tegel zegt *Geen signaal*. Controleer kabel en
  stroom; de partij blijft bewaard. Een bord dat op een andere poort terugkomt,
  wordt herkend aan zijn serienummer zodra u het op die poort toevoegt.
- **Geen internet.** Beschreven in [Wat zonder internet werkt](#what-works-offline).

## Na de ronde en na het evenement {#after-the-round}

1. **Controleer de uitslagen.** Kijk de kolom **Bord zag** na op rood. Er wordt
   niets geblokkeerd: u kunt de volgende ronde paren en publiceren. Elke
   vermelding is een link naar de partijpagina.
2. **Beëindig partijen op het kastje** waar dat nodig is (*Partij beëindigen*,
   onder de tegel of op de pagina van het bord: een uitslag, of *Geen
   uitslag*). Dat is het eigen archief van Alnasl, niet de uitslag in
   OpenPairings.
3. **PGN met de zetten.** De partijpagina biedt **PGN downloaden**, en **De eigen
   PGN van het kastje** ter vergelijking. Instellingen, **Live borden**, kaart
   **Partijen die de borden meldden**: **PGN, hele toernooi** en een knop per
   ronde. De uitslag in het bestand is die welke u invoerde, of `*` zolang u dat
   niet deed. De PGN-export van de pagina Paringen (**Meer**, PGN) bevat nog
   steeds geen zetten. Alnasl heeft zelf een pagina PGN (*Hele ronde als PGN*).
4. **Wat waar bewaard wordt.** De partijen worden bij het toernooi in
   OpenPairings bewaard en staan in de JSON-export en de herstelpunten. De
   koppelcodes en de toestemming van het kastje voor de uitslagensite niet: een
   kopie elders maakt haar eigen codes en haalt haar eigen toestemming op. Op het
   kastje staan de partijen, de wachtrij en de instellingen op schijf in de
   gegevensmap van Alnasl (`~/.alnasl` in productie), met een PGN-bestand per
   partij.
5. **Trek de codes in** als het evenement voorbij is: Instellingen, Live borden,
   **Intrekken**, en in Alnasl **Verwijderen** bij Instellingen, Toernooien. Een
   toernooi van het kastje halen laat het de partijen daar vergeten (de al
   geschreven PGN-bestanden blijven op schijf); OpenPairings houdt wat eraan
   gemeld is.
6. **Haal de openbare link weg** als u hem niet meer wilt: de schakelaar
   **Live-link op de uitslagensite**.

## Als er iets mis is {#troubleshooting}

| Wat u ziet | Waarom | Wat te doen |
| --- | --- | --- |
| Alnasl: *Dat is geen volledige koppelcode: het deel na de # ontbreekt.* | De regel is bij het kopiëren afgebroken. | Kopieer de hele regel, van `https://` tot het einde. |
| Alnasl: *OpenPairings kent deze code niet* of *OpenPairings weigert de koppelcode*; de koppeling zegt *Code geweigerd* | Verkeerd getypt, of in OpenPairings **ingetrokken**. Het kastje vraagt niet meer. | Maak een nieuwe code (Instellingen, Live borden), voeg ze toe in Alnasl, verwijder de oude. |
| Alnasl: *OpenPairings is niet bereikbaar*; de koppeling zegt *Geen antwoord* | De server of het zaalnetwerk ligt eruit. Er gaat niets verloren: de borden gaan door met de paringen die ze hebben en het kastje vraagt vanzelf opnieuw. | Controleer het netwerk. Een ronde die intussen gepaard is: **Ronde N starten**. |
| *Geen antwoord. Deze code is voor een OpenPairings op deze zelfde computer: draait het?* | Een desktopcode wordt gebruikt op een computer die niet die van OpenPairings is, of OpenPairings draait niet. | Draai Alnasl op dezelfde pc als de desktop-OpenPairings, en start OpenPairings. |
| *Er antwoordt iets op dat adres, maar niet als de bordkoppeling van OpenPairings* | Een aanmeldpagina van het zaalnetwerk, of een ander programma op die poort. | Meld u aan op het zaalnetwerk, of controleer het adres. |
| *… het is niet gepubliceerd op een uitslagensite, dus de zetten gaan alleen naar OpenPairings* | Het toernooi staat niet op de uitslagensite. | Publiceer het (stap 1). Het adres en de toestemming komen daarna vanzelf. |
| *… het staat op een uitslagensite, maar in OpenPairings is geen relaysleutel opgeslagen* | OpenPairings heeft de toestemming van het kastje (nog) niet van de uitslagensite gekregen. Meestal is dat een kwestie van seconden; anders is de uitslagensite niet bereikbaar, zei ze nee, of is ze een oudere versie. | Open Instellingen, Live borden, kaart **De uitslagensite**: die zegt welke. *Toestemming wordt … opgehaald…*: wacht, het wordt vanzelf opnieuw geprobeerd. *Nog niet … : reden*: lees de reden, dan **Opnieuw proberen**. *Oudere versie*: zie de volgende rij. |
| De kaart zegt *het is een oudere versie die dit niet zelf kan* en toont een veld **Relaissleutel** | De uitslagensite is van voor ze de toestemming kon uitgeven. | Vraag de beheerder van die site om een relaissleutel voor het toernooi en plak ze in het veld. Zie [Relaissleutels](17-live-boards.md#relay-keys). |
| De kaart zegt *Zet het toernooi eerst op de uitslagensite* | Het toernooi staat nog niet op de uitslagensite. | Publiceer het (stap 1). |
| *Dat lijkt niet op een relaissleutel: 16 tot 200 tekens, zonder spaties.* | Alleen bij een oudere uitslagensite: de geplakte sleutel is afgebroken of heeft spaties. | Plak hem opnieuw. |
| Het kastje stuurde en de uitslagensite weigert het nu | De toestemming is vervangen of ingetrokken (door u, of door de beheerder van de site). | Instellingen, Live borden, **De toestemming van het kastje vervangen**. Het kastje haalt de nieuwe vanzelf op. |
| *Er zijn al 8 codes.* | De grens. | Trek een code in die u niet meer gebruikt. |
| *De code bereikt nu geen toernooi* | Het toernooi is verwijderd of gearchiveerd, of de groep is leeg. | Controleer het toernooi; een gearchiveerd of overgedragen toernooi kan niet op een kastje staan. |
| *OpenPairings vraagt om het rustiger aan te doen* | Te veel verzoeken. | Niets: het kastje probeert het vanzelf opnieuw. |
| De nieuwe ronde verschijnt niet | Het kastje vraagt ongeveer elke vijf seconden. | Wacht een paar seconden. Nog niets, kijk dan naar de stand van de koppeling bij Instellingen, of gebruik **Ronde N starten**. |
| *Klok niet in beginstelling: … de klok staat omgekeerd of de wip staat verkeerd* | De klok staat niet voor wit klaar (ze staat rechts van het bord, de wip omhoog aan de kant van wit). | Draai de klok of tip de wip. De melding verdwijnt vanzelf. |
| Dezelfde partij wordt twee keer gemeld | Twee codes bereiken hetzelfde toernooi op één kastje. | Houd één code (zie [meerdere toernooien](#several-tournaments)). |
| Geen kolom **Bord zag** op de pagina Paringen | Nog geen code bereikt dit toernooi en geen bord meldde een partij. | Maak een code (stap 2) en voeg ze toe op het kastje. |
| Rood *wijkt af* in de kolom Bord zag | Het bord zag een andere uitslag dan de ingevoerde. | Controleer de notatieformulieren. Er wordt niets geblokkeerd. |
| Een tegel zegt *Indeling gewijzigd in OpenPairings* | Een paring veranderde nadat er zetten waren gespeeld. | Zie [Tijdens de ronde](#during-the-round). |
| De uitslagensite toont niets | De partijen wachten in de wachtrij; of de ronde is niet gepubliceerd; of het kastje heeft nog geen toestemming (het toernooi staat niet op de uitslagensite, of de site is onbereikbaar, zei nee, of is te oud). | De pagina **Verzendlijst** van Alnasl zegt wat er wacht en waarom, en Instellingen, Live borden, kaart **De uitslagensite** zegt hoe het met de toestemming staat. Een partij wordt alleen getoond voor een bord van een gepubliceerde ronde. |

## Beperkingen van nu {#limits-today}

- **Ploegentoernooien** staan op het kastje als losse borden, doorgenummerd
  door de ronde, niet gegroepeerd per wedstrijd en zonder de ploegnamen.
- **Alleen de eerste partij van een bord in een ronde verlaat het kastje.** Een
  tweede partij op hetzelfde bord (een nieuwe partij na een onderbreking) blijft
  op het kastje en in zijn PGN; de uitslagensite, Lichess en OpenPairings kennen
  één partij per bord en ronde.
- **Chess960** wordt niet ondersteund.
- **Een kastje op een andere machine kan een desktop-OpenPairings niet
  gebruiken.**
- **De koppelcode is op het kastje alleen te plakken.** Scan de QR-code met de
  eigen camera van de telefoon, kopieer de link, plak hem.
- **Geen installatieprogramma of Pi-image voor Alnasl**; zie
  [Wat u nodig hebt](#what-you-need).
- Meer beperkingen van de koppeling zelf staan in
  [Beperkingen](17-live-boards.md#limits).
