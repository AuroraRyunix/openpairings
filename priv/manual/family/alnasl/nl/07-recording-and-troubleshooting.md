# Opnemen, herhalen en problemen oplossen

Alnasl schrijft alles op wat de borden zeggen, zodat een partij die in de zaal misliep aan een bureau opnieuw bekeken kan worden. Dit hoofdstuk gaat daarover, over de andere pagina's die iets bijhouden, en over wat je doet als er iets mis is.

## Opnames en herhalen {#recordings}

De pagina Opnames toont de ruwe opnames: alles wat elk bord leverde, zoals het het leverde, wat de tracker er ook van maakte. Er wordt altijd opgenomen; er is niets om aan te zetten.

Met een opname kun je:

- **Ze herhalen** via de tracker als proefrun. Er wordt niets bewaard of verstuurd. Je ziet welke zetten de tracker eruit haalt en waar hij de draad kwijtraakte.
- **Ze exporteren als testfixture**, zodat een fout in de zaal een test aan een bureau wordt. Dit is voor wie Alnasl onderhoudt; ben jij dat niet, dan kun je het negeren.
- **Ze downloaden.**

De pagina Opnames toont de borden van de zaal waar je naar kijkt; vink **Al mijn zalen** aan voor de andere. Ze toont vijftig bestanden per pagina, en met zoeken vind je een bord of een bestandsnaam.

## Het Logboek {#the-log}

Wat er gebeurd is, in zinnen, met filters: bord aangesloten, zetten hersteld, niet synchroon, hersteld door de arbiter, offline, terug. Alles wat je op de pagina van een bord doet, een herstel of een correctie, staat er met het tijdstip in. Het toont de regels van deze zaal (**Al mijn zalen** toont de rest), vijftig per pagina, en met het zoekvak vind je een woord erin.

## De pagina Resultaten {#the-outbox}

De verbindingen, eerlijk: voor de uitslagensite en voor elke andere bestemming, verbonden of niet, laatste succes, hoeveel er wacht en waarom het niet weggaat, in woorden. Elk heeft zijn eigen schakelaar en zijn eigen "Nu versturen". Wat wacht, wat de server weigerde en wat weggegaan is. Alles, de tellers en het getal in de omlijsting inbegrepen, gaat over de toernooien die gespeeld worden in de zaal waar je naar kijkt.

## PGN {#pgn}

Lees PGN-bestanden in of plak zetten (ze worden op geldigheid gecontroleerd). Wijs een partij die niet vastgelegd werd toe aan haar bord, na bevestiging. Vergelijk een partijformulier met de vastgelegde partij en zie het eerste verschil. Exporteer een partij, of "Hele ronde als PGN" voor het bulletin.

## Als er iets mis is {#when-something-is-wrong}

### Een bord toont "Niet synchroon" meteen na het begin {#out-of-sync-start}

De beginstelling klopte niet, of de eerste zetten werden gedaan voor het bord gekoppeld was. Gebruik "Hier hersynchroniseren".

### "Klok niet in beginstand" voor de ronde {#clock-start}

De klok staat altijd rechts van het bord, het scherm van wit naar wit. Voor de eerste zet moet de hendel omhoog staan aan de kant van wit, zodat de tijd van wit eerst loopt. Draai de klok om of tik de hendel om; de melding verdwijnt vanzelf.

### Zetten komen laat {#moves-late}

Een zet wordt geloofd als de stukken even stil gestaan hebben, of zodra de volgende speler een stuk opneemt; de klokdruk van de zet zelf maakt het onmiddellijk. Rokade en promotie wachten iets langer.

### "Zet ontbreekt?" op een tegel {#move-missing}

De klok is vaker ingedrukt dan er zetten gezien zijn. Vergelijk het bord met de zettenlijst.

### "Code geweigerd" bij Koppelingen in Instellingen {#code-refused}

OpenPairings aanvaardt de koppelcode niet: ze is daar ingetrokken, of het is niet de volledige regel. Alnasl is gestopt met vragen en de borden gaan door met de paringen die het heeft. Maak een nieuwe code in OpenPairings (Instellingen, Live borden), voeg ze toe, en verwijder de oude.

### "Geen antwoord" bij Koppelingen in Instellingen {#no-answer}

OpenPairings is niet bereikbaar. Er gaat niets verloren: de borden gaan door met de paringen die Alnasl heeft, de partijen worden voor OpenPairings bewaard, en Alnasl vraagt vanzelf opnieuw. Een ronde die intussen gepaard werd, start je met "Ronde N starten" en ze krijgt haar namen zodra de verbinding terug is.

### Een toernooi heeft geen uitslagenpagina {#no-results-page}

Het is niet gepubliceerd vanuit OpenPairings, of daar is geen relaissleutel bewaard (Instellingen, Live borden). Instellingen, Toernooien, zegt welk van de twee. Tot dan gaan de zetten alleen naar OpenPairings; het adres en de sleutel komen vanzelf zodra ze er zijn.

### De uitslagensite toont niets {#results-site-empty}

Kijk op de pagina Resultaten: wacht er iets, en waarom? Is de ronde gepubliceerd vanuit het paringsprogramma? Een partij wordt enkel getoond voor een gepubliceerd bord.

### Een brug is "niet verbonden" {#bridge-down}

De brug kan de server niet bereiken. Er gaat niets verloren: ze blijft lezen en stuurt wat ze miste zodra de lijn terug is (zie [Bruggen](03-bridges.md)). Kijk op de pagina van de brug zelf: een rode stip bij deze server betekent dat de lijn aan haar kant onderbroken is.

### Het kastje werd per ongeluk uitgezet {#switched-off}

Zet het weer aan. Partijen, wachtrij en instellingen staan op schijf; de borden verbinden opnieuw en gaan verder. De zetten tijdens de uitval worden niet gelezen.

### "Je rol in deze zaal laat je de partijen volgen, niet wijzigen" {#role-refused}

Je bent daar kijker. Vraag een eigenaar van de zaal om de rol van arbiter (zie [Accounts, zalen en rollen](06-accounts-and-halls.md)).

> [!TIP] Nog altijd vast
> Open het Logboek en de pagina Opnames voor je iets drastisch doet. Ze zeggen wat de borden zeiden, en dat is meestal het hele verhaal.
