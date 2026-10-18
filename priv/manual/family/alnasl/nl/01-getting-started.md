# Aan de slag

Alnasl leest de elektronische borden in een speelzaal, leidt uit de stand van de stukken de zetten af en stuurt de zetten en de kloktijden naar de uitslagensite terwijl er gespeeld wordt. Dit hoofdstuk zegt wat het is, op welke twee manieren je het draait, hoe je het installeert en wat je nakijkt voor de eerste ronde.

> [!NOTE] Het beslist nooit over een resultaat
> Een mat op het bord of twee koningen in het midden is een voorstel. Jij bevestigt het. Een bord voert nergens zelf een resultaat in.

## Wat Alnasl doet {#what-alnasl-does}

Wie tegen wie speelt, hoort Alnasl van OpenPairings. Wat elk bord zag, gaat daarheen terug, naast de paring. De zetten en de klokken gaan naar de uitslagensite (OpenResults), waar de toeschouwers ze volgen. Alnasl bewaart eerst alles zelf, dus een zaal zonder internet verliest niets: wat niet kon worden verstuurd, gaat in volgorde weg zodra de verbinding terug is.

Je werkt ermee in een browser, op het kastje zelf of op je laptop in de zaal. De pagina's staan in de balk links, in groepen:

| Groep | Pagina | Waarvoor |
| --- | --- | --- |
| Spelen | Live | Het scherm tijdens het spel: de borden van deze zaal, als tegels of als lijst |
| Spelen | Borden | Wat er aangesloten is, de tafelnummers, "Klaar voor ronde N?" |
| Spelen | Partijen | Partijen als tekst (PGN): inlezen, toewijzen, vergelijken, exporteren |
| Versturen | Resultaten | Wat naar de uitslagensite en de andere bestemmingen gegaan is, en wat nog wacht |
| Beheren | Zalen | De zalen waar je bij hoort, hun bruggen en mensen |
| Beheren | Instellingen | In onderdelen: toernooien, koppelingen, uitslagen en Lichess, dit kastje, toegang, updates, geavanceerd |
| Terugkijken | Logboek | Wat er gebeurd is, in zinnen |
| Terugkijken | Opnames | Alles wat de borden zeiden, ruw, om nog eens te bekijken |
| | Help | Deze handleiding |

Bovenaan de balk: de naam van het kastje (op de server: "server") en, als je meer dan één zaal hebt, de zaalkiezer. Onderaan: de accountknop, met je taal, het kleurthema en Afmelden.

Op een telefoon wordt de balk een strook bovenaan (de naam, de zaalkiezer en de accountknop) en staan de pagina's in een strook onderaan: Live, Borden, Resultaten en Meer, met de rest. Op een telefoon ontbreekt niets; het is één tik verder.

Meldingen (de uitslagensite is niet bereikbaar, een bord speelt buiten zijn toernooi, een vraag over tafels, een nieuwe versie) staan boven de pagina, hoogstens twee tegelijk. De rest wacht achter "nog 1 melding"; druk erop om ze te zien.

Een pagina of lijst waar nog niets in staat, zegt dat in een zin, en zegt wat er iets in brengt: een koppeling voor de toernooien, een brug voor de borden van een zaal, een bord voor een ronde. Is er één voor de hand liggende volgende stap, dan brengt een knop je erheen.

Instellingen is in onderdelen, elk met een eigen adres en een lijst ernaast (een keuzelijst op een telefoon): de **Installatiewizard** (zie [hieronder](#setup-wizard)), **Toernooien** (een regel per toernooi; open er een voor de details, zijn zalen en tafels en het automatisch starten; die met borden in deze zaal staan bovenaan, de afgelopen en de niet begonnen zitten achter een schakelaar), **Koppelingen** (codes en accountkoppelingen, een regel elk met een menu voor Testen, Opnieuw proberen en Verwijderen, en "+ Toevoegen"), **Uitslagen en Lichess**, **Dit kastje** (op de server **Deze server**), **Toegang** en **Updates** (alleen een kastje) en **Geavanceerd** (de tracker, voor beheerders). Een onderdeel dat jouw editie of rol niet kan gebruiken, wordt niet getekend.

## De installatiewizard {#setup-wizard}

Het eerste onderdeel van Instellingen is de **Installatiewizard**. Zolang niet elke stap gedaan is, opent Instellingen daar; daarna opent het op Toernooien, en de wizard blijft in de lijst staan voor de volgende wijziging. Hij is per zaal: open hem op de server in elke zaal, met de zaalkiezer bovenaan.

Hij begint met een paar vragen: hoe de zaal eruitziet (één zaal met één toernooi, één zaal met meerdere toernooien, of meerdere zalen of ruimtes), hoeveel Arkab-bruggen (op de server altijd; op een kastje alleen voor de ruimtes buiten de zijne), ongeveer hoeveel borden, en wat je er nog bij wilt: uitslagen voor toeschouwers, een Lichess-uitzending, een printstation, een omroeper, en op een kastje telefoons en laptops achter een pincode. Eén kabelketting neemt tot twaalf borden; meer borden is een tweede ketting op een eigen poort.

Daarna somt hij de stappen voor precies die zaal op, in volgorde, met elk één knop die naar de plaats gaat waar je de stap doet. De eerste stap die niet gedaan is, is de huidige. Elk vinkje komt uit wat Alnasl echt heeft, niet uit iemand die op Volgende drukt:

| Stap | Afgevinkt als |
| --- | --- |
| De zalen maken (server, meerdere zalen) | Je zoveel zalen ziet als je opgaf |
| De borden aansluiten (kastje) | Het kastje zoveel borden op zijn eigen poorten heeft als je opgaf |
| Arkab installeren | Een brug van deze zaal minstens één keer verbonden is geweest |
| Brug 1 van N, 2 van N... | Die brug bij deze zaal aangesloten is en verbonden is geweest; "nu niet verbonden" als ze plat ligt |
| Borden die binnenkomen (server) | De zaal zoveel borden heeft als bruggen maal borden per brug |
| Het toernooi of de toernooien koppelen | Zoveel toernooien uit OpenPairings in deze zaal staan |
| Tafels per toernooi (meerdere toernooien) | Hoogstens één toernooi "elke vrije tafel" houdt; de andere hebben een reeks |
| De borden nummeren | Elk bord van de zaal een tafelnummer heeft |
| Uitslagen voor toeschouwers | Een toernooi hier een uitslagenpagina en zijn relaissleutel heeft |
| Lichess | Een toernooi hier een Lichess-ronde en zijn token heeft |
| Telefoons en laptops (kastje) | Andere machines in de zaal binnengelaten zijn (Instellingen, Toegang) |
| Printstation, omroeper | Je ze zelf als gedaan aanduidt: Polis en Nunki praten met OpenPairings, niet met Alnasl, dus Alnasl kan ze niet zien |

De koppelcode komt uit OpenPairings: open het toernooi, dan Instellingen, Live borden, en druk op "Nieuwe code". Een stap waar je met jouw rol niets aan kunt doen, houdt zijn vinkje, verliest zijn knop en zegt wie het wel kan. Alleen de eigenaar van de zaal beantwoordt de vragen; "De antwoorden wijzigen" stelt ze opnieuw en de vinkjes lopen gewoon door.

## Twee manieren om het te draaien {#two-ways}

Het is beide keren hetzelfde programma. Het verschil is waar het draait en wat eraan hangt.

**Een kastje in de zaal.** Een kleine computer (een Raspberry Pi, een mini-pc, de laptop van de arbiter) waaraan de borden hangen met een usb- of seriële kabel. Het leest ze zelf. Dit is het gewone geval, en het werkt zonder internet.

**De gehoste server.** Hetzelfde programma draait op een server, op alnasl.zerotwo.cloud. Een server heeft zelf geen borden: hij heeft geen poorten om te lezen. In plaats daarvan neemt hij **bruggen** aan: Arkab, een klein programma in een zaal dat de borden daar leest en via internet doorsturen (zie [Bruggen](03-bridges.md)). De pagina's zijn die je kent: de ronde, de partijen, de correcties. Het verschil is dat elke pagina altijd vraagt wie je bent, en dat accounts alleen op uitnodiging bestaan (zie [Accounts, zalen en rollen](06-accounts-and-halls.md)).

De server laat weg wat alleen een kastje kan, in plaats van het grijs te maken: borden toevoegen en de lijst met seriële poorten op de pagina Borden, simulatorborden, het paneel Updates en meestarten met Windows, de pincode en het zaalnetwerk, en de naam van het kastje. Instellingen, Deze server, zegt welke editie je ziet, onder "Deze kopie van Alnasl"; de onderdelen Toegang en Updates zijn er helemaal niet.

> [!TIP] Welke kies je?
> Borden in je eigen zaal en je wilt het simpel: een kastje in de zaal. Meerdere zalen, een arbiter thuis, of niemand wil een computer in de zaal: bruggen en de server. Je kunt ze samen gebruiken, want één brug mag meer dan één server voeden.

## Installeren {#installing}

**Windows.** Alnasl-Setup.exe installeert alleen voor jou, zonder beheerder, en zet "Alnasl" in het Startmenu. Het programma is niet ondertekend, dus de eerste keer zegt Windows "Windows heeft je pc beschermd": kies "Meer info" en dan "Toch uitvoeren". Het kleine Alnasl-venster is het programma: sluit je het, dan stopt Alnasl, en zolang het gestopt is worden de borden niet gelezen. Er is ook een zipbestand dat niets installeert: uitpakken en Alnasl.exe starten.

**Linux en de Raspberry Pi.** Eén regel installeert Alnasl als dienst die met het kastje opstart (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm, of nieuwer):

```
curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh
```

**Mac.** Download alnasl-macos-aarch64.zip voor een Mac met een Apple-chip (M1 en later; voor Intel-Macs is er geen build), open het en sleep Alnasl naar Programma's. Apple heeft het nog niet ondertekend, dus de eerste keer weigert macOS het te openen: klik in Systeeminstellingen, Privacy en beveiliging, op "Toch openen" bij de melding over Alnasl. Alnasl afsluiten (Cmd-Q) vraagt eerst bevestiging, want zolang het gestopt is worden de borden niet gelezen.

Open daarna de site in een browser: op het kastje zelf via `http://localhost:4040`; vanaf een laptop in het netwerk van de zaal via het adres van het kastje met dezelfde poort (Borden en Instellingen, Toegang, tonen het, met een QR-code voor een telefoon, zodra andere machines binnen mogen).

### Updaten {#updating}

Het kastje vraagt om het halfuur of er een nieuwere versie is en meldt dat bovenaan de pagina. Er wordt niets gedownload voor je ja zegt bij Instellingen, Updates, waar ook staat hoe groot de download is. Het herstart niet terwijl er een partij bezig is, tenzij je aandringt: de zetten tijdens de herstart worden niet gelezen. "Later" vraagt morgen opnieuw; "Niet meer vragen" stopt het zoeken, en Instellingen zet het weer aan.

### Waar je gegevens staan {#where-your-data-is}

Niet in de map van het programma. Windows: `%LOCALAPPDATA%\AlnaslData` (typ dat in de adresbalk van Verkenner). Linux, geïnstalleerd: `/var/lib/alnasl`. Mac: `~/Library/Application Support/AlnaslData`. Daarin staan de database, de PGN van elke partij, de ruwe opnames en de sleutels en codes die je geplakt hebt. Updaten en verwijderen laten die map met rust; opnieuw installeren vindt ze terug. Om naar een andere computer te verhuizen kopieer je die map terwijl Alnasl gestopt is.

Instellingen, Dit kastje, "Deze kopie van Alnasl", zegt de versie, hoe deze kopie gestart is en waar de gegevensmap staat. Een tweede kopie die anders gestart is op dezelfde computer heeft een eigen gegevensmap: eigen borden, nummers en toernooien.

## Voor de ronde {#before-the-round}

Elke keer dezelfde korte lijst. Bij elke stap zegt een pagina in woorden wat er mis is, als er iets mis is.

1. Instellingen, Koppelingen: plak de koppelcode uit OpenPairings; geef dan bij Toernooien aan welke tafels in welk toernooi spelen (zie [OpenPairings, OpenResults en Lichess](05-openpairings-and-openresults.md)). Druk op "Verbinding testen" (in het menu Acties van de koppeling).
2. Borden: elk bord moet een andere toestand tonen dan "Geen signaal", en zijn plaatje moet kloppen met de stukken erop.
3. Borden: de kolom "Beginstelling" moet bij elk bord "Juist" zeggen. Zo niet, dan noemt ze de stukken en velden. Een koning en dame die omgewisseld staan, komt het meest voor.
4. Een bord met een klok is pas "Juist" als de klok dat ook is: rechts van het bord, de hendel omhoog aan de kant van wit, zodat de tijd van wit eerst loopt.
5. Borden: geef elk bord zijn tafelnummer (zie [Borden en poorten](02-boards-and-ports.md)).
6. Borden: "Klaar voor ronde N?" moet "Klaar" zeggen. Zo niet, dan somt het per bord op wat er mis is.
7. Live: elke tegel moet "Wacht op begin" zeggen.

## Taal en kleuren {#language-and-colours}

De site bestaat in het Engels en het Nederlands. De taal is de jouwe, niet die van het kastje: kies ze in het accountmenu (de knop onderaan de balk, op een telefoon rechtsboven). Met een account wordt de keuze bij het account bewaard en volgt ze je naar elke browser; zonder accounts wordt ze in die browser bewaard. Hoe dan ook verandert niemand anders van taal, en deze handleiding volgt de jouwe.

Wie niets koos, leest de standaardtaal van Alnasl. Een beheerder stelt die in bij Instellingen, "Dit kastje" ("Deze server"), Standaardtaal.

De kleuren komen in dezelfde thema's als OpenResults: Papier, Nacht, Bord, Leisteen en Hoog contrast, en Volg het toestel, dat het toestel volgt. Kies in het accountmenu, bij Kleurthema; dat is de enige plek. De keuze geldt alleen voor die browser. Hoog contrast is voor een projector achteraan de zaal.

Er kunnen meer thema's bij als themapakketten: een map per thema, in de map `themes` binnen de gegevensmap. Bij de volgende keer laden staan ze na de ingebouwde thema's. Een pakket dat Alnasl niet wil laden, staat in het grijs in de lijst, met de reden.

## Woorden in deze handleiding {#words}

De schermen en deze handleiding gebruiken één woord per ding:

| Woord | Betekent |
| --- | --- |
| Alnasl | Het programma, waar het ook draait. Een zin die de server ook toont, zegt "Alnasl", niet "het kastje" |
| kastje | Alnasl op een eigen computer in een zaal, die borden leest op zijn eigen poorten |
| server | De gehoste Alnasl op alnasl.zerotwo.cloud, die borden leest via bruggen |
| brug | Arkab, naast de borden van een zaal, die ze naar een kastje of de server stuurt |
| zaal | Een ruimte met tafels en borden; elke pagina gaat over één zaal |
| het eigen toernooi van de zaal | Waar de borden van een zaal spelen als geen paring ze noemt |
| koppeling | Een koppelcode of een accountkoppeling met OpenPairings |
| uitslagensite | OpenResults, waar toeschouwers de partijen volgen |
| uitslagenpagina | De pagina van één toernooi op de uitslagensite |
| Resultaten | De pagina in de balk die toont wat verstuurd is en wat wacht |
| live bord | Een elektronisch bord; de schermen noemen nooit een merk |
| arbiter, kijker | Rollen in een zaal: een arbiter verbetert en start rondes, een kijker kijkt |

Een partij die "in Alnasl blijft", wordt hier bewaard en nergens heen gestuurd; het logboek zegt "Arbiter in Alnasl" als iemand een partij via deze pagina's veranderde.
