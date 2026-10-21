# Accounts, zalen en rollen

Wie wat mag zien en doen. Op een kastje in een zaal zijn er geen accounts tot je er een maakt. Op de gehoste server zijn er altijd accounts, en je krijgt er een op uitnodiging.

## Open tot het eerste account {#open-until-the-first-account}

Een kastje zonder accounts is open: iedereen op het netwerk van de zaal mag alles doen, achter de pincode als die er is. Zo werkt Alnasl altijd al, en een update verandert dat niet.

Bij Instellingen, Toegang, "Accounts", kun je het eerste account maken. Je wordt eigenaar en beheerder van het kastje, en vanaf dan vraagt elke pagina wie er is, ook het eigen scherm van het kastje. De pincode heeft dan niets meer te zeggen.

> [!IMPORTANT] Hiermee gaat de aanmelding aan
> Maak het eerste account als je klaar bent om je op elk toestel in de zaal aan te melden, telefoons inbegrepen. De aanmelding met een QR-code op de telefoon, hieronder, maakt dat pijnloos.

## De gehoste server {#the-hosted-server}

De server op alnasl.zerotwo.cloud leest geen eigen borden, dus daar vraagt elke pagina altijd wie er is. Accounts komen **enkel op uitnodiging**: niemand kan zich zelf registreren. De mensen die de uitrol als beheerder aanduidt, melden zich eerst aan met 02cloud, en hun account wordt dan gemaakt. Een beheerder nodigt de eerste eigenaars van elke zaal uit; een eigenaar kan dan mensen uitnodigen.

Een 02cloud-login alleen laat niemand binnen. Alleen een uitnodiging, of door de uitrol als beheerder aangeduid zijn, doet dat.

## Zalen {#halls}

De poorten van het kastje zelf zijn één zaal. Elke brug hoort bij een zaal, en haar borden en toernooien ook. Een beheerder maakt meer zalen op de pagina Zalen. Elk account ziet zijn eigen zalen en niets van de andere.

Bij meer dan één zaal zegt de zaalkiezer bovenaan de balk over welke zaal de pagina's gaan, en hoeveel van haar borden live zijn. Druk erop voor je zalen, elk met je rol daar en haar live borden (vanaf zeven zalen verschijnt een zoekveld); kies je er een, dan blijf je op de pagina waar je was, nu over die zaal. "Alle zalen" onderaan opent de pagina Zalen, die elke zaal in een tabel toont: jouw rol, borden live, bruggen verbonden, en wat een arbiter nodig heeft.

De pagina van een zaal heeft tabbladen, elk met een eigen adres: **Mensen**, **Uitnodigingen**, **Bruggen** en **Instellingen** (hernoemen, verwijderen). Uitnodigingen en Instellingen zijn voor een eigenaar; een arbiter of kijker heeft Mensen en Bruggen.

### Wat een pagina toont {#scope}

Elke pagina gaat over de zaal waar je naar kijkt: Live, Borden, de pagina's die borden nummeren en zoeken, Partijen, de pagina Resultaten (haar lijsten, haar tellers en het getal in de omlijsting), het Logboek en Opnames. Bij Borden biedt elk bord alleen de toernooien die in deze zaal gespeeld worden, plus dat waarin het bord nu speelt.

Het Logboek en Opnames kunnen ook **Al mijn zalen** tonen: vink het aan en ze tonen elke zaal die je mag zien. Ze tonen vijftig regels of bestanden per pagina, met een zoekvak. Een kastje zonder accounts heeft geen zalen om uit elkaar te houden en toont alles.

## Toernooien en zalen {#placements}

Waar een toernooi gespeeld wordt, zeg je bij Instellingen, Toernooien: open het toernooi, en daar staat **Zalen en tafels**. Elke rij is één zaal, met de tafels van en tot en het eerste bord dat die tafels spelen. De twee gewone gevallen:

- **Twee toernooien, één zaal.** De Open op tafels 1 tot 8, de min-twaalfjarigen op tafels 9 tot 16: elk toernooi heeft één rij in de zaal, en tafel 9 is bord 1 van de min-twaalfjarigen. Dat deed "Tafels van ... tot ..." altijd al, en doet het nog.
- **Eén toernooi, twee zalen.** Borden 1 tot 8 in de grote zaal op haar tafels 1 tot 8, borden 9 tot 16 in de zaal ernaast op haar tafels 1 tot 8: de Open heeft twee rijen, de tweede begint bij bord 9. Tafel 4 van de zaal ernaast speelt bord 12.

**Zaal toevoegen** toont alleen de zalen waar je arbiter of eigenaar bent (een beheerder ziet ze allemaal). Een zaal die je toevoegt, krijgt daar de volgende vrije tafels - na de tafels van elk ander toernooi, en na de tafels waar borden van een ander toernooi staan - en het bord na het hoogste dat al een plaats heeft; pas het gerust aan voor de ronde. Een tafel waarvan het bord een partij aan de gang heeft in een ander toernooi, neemt een zaal toevoegen nooit over: het kastje zegt welk bord, en verandert niets. Een toernooi zonder tafels in een zaal heeft daar elke tafel die bij geen ander toernooi hoort.

Wat niet kan: twee toernooien op dezelfde tafel van één zaal, hetzelfde bord in twee zalen, en een toernooi uit de laatste zaal halen waarin het gespeeld wordt. Haal je een zaal weg, dan gaan haar borden terug naar het eigen toernooi van die zaal; de partijen blijven.

Een toernooi staat in de lijst en opent in elke zaal waarin het gespeeld wordt. Een bord wordt nog altijd alleen in zijn eigen zaal herkend aan zijn serienummer: één toernooi in twee zalen maakt daar geen één ruimte van.

## Rollen {#roles}

In elke zaal is een account eigenaar, arbiter of kijker. Dezelfde persoon kan in de ene zaal eigenaar zijn en in de volgende kijker.

| Rol | Mag |
| --- | --- |
| Kijker | De partijen volgen. Verandert niets |
| Arbiter | Ze leiden: tafels, rondes, resultaten, correcties, de koppelingen met OpenPairings en OpenResults |
| Eigenaar | Dat alles, en bruggen toevoegen en verwijderen, en mensen uitnodigen |
| Beheerder | Elke zaal zien en Alnasl zelf: zijn naam, updates, de tracker, de schakelaars op de pagina Resultaten |

Eén ding is alleen van de eigenaar, wat een beheerder verder ook mag: [fair play](08-fair-play.md). Een beheerder die geen eigenaar van de zaal is, ziet er niets van.

Een gewijzigde rol geldt meteen: als een eigenaar iemand terugzet of uit een zaal haalt (of de zaal wordt verwijderd), maken de open pagina's van die persoon vanzelf opnieuw verbinding en komen ze terug met wat die nu mag, in plaats van de oude rol te houden tot een herlaad.

Voor een toernooi dat in meer dan één zaal gespeeld wordt, telt de hoogste rol die je in een van die zalen hebt - voor wat er in die zaal mee gebeurt. Voor de rest heb je de rol nodig waar het gebeurt:

- **De zaal waar je staat.** Haar tafels aan een toernooi geven, een code toevoegen, haar bruggen: je rol in deze zaal, wat je ook bent in de andere zalen van het toernooi.
- **Het hele toernooi.** Het verwijderen, zijn Lichess-ronde en -sleutel, het vanzelf laten starten, de volgende ronde: je rol in de thuiszaal, de zaal waar het vandaan komt.
- **Eén bord.** Een uitslag of een nieuwe partij op de pagina Live, wat dan ook op de pagina van een bord, of een partij van de pagina Partijen die eraan toegewezen wordt of op een simulator als dat bord gespeeld wordt: je rol in de zaal waar dat bord gespeeld wordt.

"Speel het ook in deze zaal" vraagt alleen de rol van arbiter in de zaal waarvan de eigen code het toernooi bereikt: de code hebben is de toestemming.

Een kijker die op een knop drukt die iets verandert, krijgt te horen dat zijn rol hem de partijen laat volgen, niet wijzigen.

## Mensen uitnodigen {#inviting}

Op het tabblad **Uitnodigingen** van een zaal maakt "Uitnodigen" een link voor één adres en één rol, één keer bruikbaar en een week geldig. Alnasl stuurt geen mail: kopieer de link zelf naar de persoon. Wie hem opent, maakt het account voor dat adres, met een wachtwoord of met 02cloud, of meldt zich aan en komt in de zaal. Een openstaande uitnodiging kan ingetrokken worden.

Een zaal houdt minstens één eigenaar: je kunt de laatste niet uit de zaal halen. Maak eerst iemand anders eigenaar.

## Een zaal verwijderen {#deleting-a-hall}

Op het tabblad **Instellingen** van een zaal vindt een eigenaar (of een beheerder) "Deze zaal verwijderen". Je moet de naam van de zaal typen, en pas dan werkt de knop. De mensen, de openstaande uitnodigingen, de koppelcodes en de borden van de zaal gaan mee.

Een zaal die nog bruggen, toernooien of een koppeling met OpenPairings heeft, wordt niet verwijderd: de melding zegt wat er nog is ("2 bruggen en 1 toernooi"), en die haal je eerst weg. Zo gaat er door deze knop nooit een partij verloren. De eigen zaal van Alnasl (op een kastje de zaal van zijn eigen poorten) kan nooit verwijderd worden. Wie de verwijderde zaal open had, komt terecht in een andere zaal van hem of haar.

## Aanmelden {#signing-in}

### Met 02cloud {#sign-in-with-02cloud}

Waar de uitrol het ingesteld heeft, heeft de aanmeldpagina een knop "Aanmelden met 02cloud". Hij meldt het account met hetzelfde geverifieerde adres aan en koppelt de twee de eerste keer. Hij maakt zelf geen account.

### Telefoons: de QR-code {#phone-sign-in}

Met accounts is de QR-code onder "Open deze site op je telefoon" (op Borden en Instellingen, Toegang) een aanmeldcode. "Maak een aanmeldcode" toont er een die de telefoon eenmalig als jou aanmeldt, binnen vijf minuten. Een telefoon blijft dertig dagen aangemeld. Elke arbiter kan ook een eigen account gebruiken.

### Een vergeten wachtwoord {#forgotten-password}

Er is geen mail om het mee te herstellen. Een beheerder opent het tabblad **Mensen** van de zaal en geeft het account een tijdelijk wachtwoord; bij de volgende aanmelding wordt om een eigen wachtwoord gevraagd, en elke andere browser die als dit account aangemeld was, wordt afgemeld. Je eigen wachtwoord wijzig je bij Account, in het accountmenu (de knop onderaan de balk, op een telefoon rechtsboven), dat ook zegt welke rol je hebt in de zaal waar je bent.
