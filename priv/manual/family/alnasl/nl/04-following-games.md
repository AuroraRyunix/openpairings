# Partijen volgen, correcties en rondes

Waar je tijdens een ronde op moet letten, wat de tegels je vertellen, hoe je een bord herstelt dat de mist in ging, en hoe rondes beginnen en eindigen. Hou de pagina Live open en het meeste regelt zichzelf.

## De pagina Live {#the-round-page}

Live is de voorpagina. Ze toont de zaal waar je bent (de zaalkiezer bovenaan de balk zegt welke): de toernooien die in deze zaal geplaatst zijn, en daarvan alleen de borden van deze zaal en de partijen die hier gespeeld zijn. Een toernooi dat in twee zalen gespeeld wordt, borden 1-8 hier en 9-16 in de bijzaal, toont hier borden 1-8 en daar 9-16. Met meer dan één toernooi hier toont een rij namen bovenaan er één apart; met één is er geen rij.

Een tegel per bord: de spelers, de stelling waar Alnasl zeker van is, de klokken, de laatste zet, en de toestand als een vorm en een woord. Kleur draagt de betekenis nooit alleen.

| Toestand | Wat het betekent |
| --- | --- |
| Wacht op begin | De ronde staat klaar, er is nog niets gespeeld |
| Live | De partij wordt gevolgd |
| Bezig | Een hand boven het bord, of een zet is half gedaan. Niets te doen |
| Afgeleid | Zetten werden niet één voor één gezien en zijn uit de stelling afgeleid |
| Niet synchroon | Het bord komt niet overeen met de partij en er wordt niets voor verstuurd |
| Geen signaal | Het bord antwoordt niet. Kijk kabel en stroom na. De partij blijft bewaard |
| Klok verkeerd om | De klok van zwart loopt en wit heeft nog niet gezet |
| Afgelopen | Er is een resultaat ingesteld |

Een balk over de volle breedte bovenaan betekent dat de uitslagensite niet bereikt kan worden. Het spel gaat door en er gaat niets verloren; de pagina Resultaten zegt hoeveel er wacht en waarom.

### Tegels of een lijst {#live-views}

"Borden" en "Lijst" bovenaan wisselen tussen de tegels en een lijst met een rij per bord: het bordnummer, de spelers, de laatste zet, de klokken en de toestand. De lijst is die voor een zaal met veertig borden. De keuze wordt in deze browser bewaard; een browser die niets koos, krijgt de lijst vanaf 24 borden. Het bordnummer in de lijst opent de pagina van het bord, zoals een tegel.

"Delen" naast een toernooi toont de QR-code van zijn livepagina op de uitslagensite, om in de zaal omhoog te houden; druk op Sluiten (of nog eens op Delen) om ze weg te doen.

Een tegel is de weg naar de eigen pagina van het bord. Eronder staan "Partij beëindigen" en "Nieuwe partij".

Alleen borden die hier bestaan krijgen een tegel: een bord van deze zaal dat op dat bordnummer zit, of een bord met al een bewaarde partij. Paringen zonder een van beide worden geteld in één regel onder de kop ("26 paringen zonder bord hier"). Een toernooi zonder bord hier en zonder enige partij wordt niet getekend, en een toernooi dat alleen in een andere zaal geplaatst is ook niet; één regel onderaan zegt hoeveel het er zijn ("14 andere toernooien staan niet op de borden hier") en leidt naar Instellingen, Toernooien. Met één toernooi wordt niets verborgen: elke paring krijgt een tegel, met of zonder bord, en een zaal die nog geen paringen heeft, zegt dat, en wat je eraan doet. Een toernooi dat je opent met zijn eigen adres zie je altijd, op dezelfde manier geteld als hierboven.

## De pagina van een bord {#a-board}

De stelling groot, de zettenlijst, en het gereedschap. De pijltoetsen links en rechts, de knoppen onder het bord, of een tik op een zet laten je door de partij terugstappen; Home is het begin, End of "Live" is de partij zoals ze gespeeld wordt. Zetten die binnenkomen terwijl je terugkijkt, komen in de lijst en verschuiven het bord niet.

Als bord en partij uit elkaar gelopen zijn, toont de pagina wat het bord leest naast wat zeker is.

## Zetten die Alnasl afgeleid heeft {#reconstructed}

Heeft Alnasl niet elke zet gezien, dan leidt het ze af uit de stelling, zodat het bord mee blijft. Elke zet zo is in de lijst gemarkeerd:

- **Afgeleid** (oranje, een ruit): slechts één reeks zetten past.
- **Geraden** (rood, een vraagteken): er pasten er meer en Alnasl nam er één.

De tegel en de lijst Borden tellen ze. Tik op een geraden zet, of op "Kijk ze na" op de pagina van het bord, en Alnasl vraagt welke zet het was, één vraag per keer, elke mogelijkheid op een klein bord, de meest waarschijnlijke eerst. "Laat het zoals het staat" is één tik. Past er geen andere reeks, dan zegt het dat en biedt het aan de zetten te houden, terug te nemen, of naar de plek te gaan waar je de juiste zetten typt.

De uitslagensite en Lichess krijgen deze zetten als alle andere, zonder markering. Een correctie vervangt de partij daar. Het aantal afgeleide en geraden zetten reist met de partij mee naar OpenPairings, zodat de arbiter daar ziet hoeveel van een partij gelezen is en hoeveel afgeleid.

## Meldingen die zeggen wat ze zagen {#alarms}

Sommige meldingen noemen wat het bord toont:

- "Zwart zette (Pc6), maar wit is aan zet" en "Een zet die niet kan: witte loper c1-g5": iemand zette buiten zijn beurt, of deed een zet die de regels niet toelaten. Alnasl voegt er niets aan de partij voor toe en verzint geen zetten om het te laten passen. Zet het stuk terug en de melding is weg.
- "Er ontbreekt een zet hiervoor" brengt je naar waar je zetten typt, voor als het bord een zet miste.
- "Klok niet in beginstand" of een klok die verkeerd om loopt: stop hem, zet hem goed, start hem opnieuw. De melding verdwijnt vanzelf. De zetten worden intussen gewoon gevolgd.
- "Witte paard niet gezien op f3" is een waarschuwing, geen alarm: een stuk verliet zijn veld (naast het bord geparkeerd, of de sensor verloor het) en de partij ging door, dus Alnasl neemt aan dat het er nog staat. Het verdwijnt als het stuk er weer gezien wordt, zet, of geslagen wordt. Was het stuk wel degelijk geslagen, verbeter dan de zetten op de pagina van het bord.
- "gelezen als d3" naast een zet betekent dat het bord die zet één veld ernaast las (een stuk neergezet tussen twee velden) en een latere zet toonde waar het echt heen ging. Alnasl heeft het rechtgezet en zegt het boven de zetten; "Kijk het na" heeft de zet zoals hij gelezen werd.

## Een bord herstellen {#repairing}

Op de pagina van het bord.

- **Het bord klopt - hier hersynchroniseren.** Zoekt dieper en langer naar de gemiste zetten en zegt welke het toevoegde. Passen er meer reeksen, dan wordt er één genomen en als gok gemarkeerd, zodat jij het kunt nakijken. Zetten die je net met Ongedaan maken hebt teruggenomen, zet het niet terug.
- **De zetten typen** van het partijformulier, zoals `Pf3 Pc6 Lb5`.
- **Laatste zet ongedaan maken** en **Een zet wijzigen.** De kopie van de toeschouwers wordt ook verbeterd.
- **Starten vanuit een stelling**, voor een hervatte partij, of als niets anders helpt.
- **Versturen pauzeren.** Het bord wordt gevolgd, maar er gaat niets weg tot je hervat.

Alles wat je hier doet, komt met het tijdstip in het Logboek.

> [!TIP] Blitz en bullet
> Instellingen, Geavanceerd, heeft "Bullet / snel spel" voor partijen van een paar minuten of minder: een zet moet korter blijven staan, en een teruggezet stuk wordt niet als terugname gelezen. Alnasl leidt tot twee gemiste zetten af; daarboven wordt het bord "Niet synchroon" en zoekt "Hier hersynchroniseren" dieper.

## Een partij afsluiten {#finishing}

Stel op elk bord het resultaat in, of bevestig het voorstel: "Partij beëindigen" op de pagina van het bord, of onder zijn tegel op de pagina Live. Er zijn drie resultaten, of "Geen resultaat" voor een partij die gestaakt werd.

### Een nieuwe partij op hetzelfde bord {#new-game}

"Nieuwe partij op dit bord". De partij ervoor blijft bewaard en staat met haar PGN in de lijst. Van een bord gaat één partij naar de uitslagensite, Lichess en OpenPairings:

- Noemt een paring het bord en heeft de partij **geen resultaat** (gestaakt, een valse start, "Geen resultaat"), dan is de nieuwe partij die partij: ze vervangt de oude op alle drie, en de oude blijft in Alnasl.
- Heeft de partij **wel een resultaat**, dan is de nieuwe partij een extra die in Alnasl blijft, zodat een afgewerkte partij nooit overschreven wordt. "Ze vervangt de partij van de paring" staat er voor als je dat echt bedoelt. Een partij die in Alnasl blijft, zegt dat op haar tegel, op haar pagina en op de pagina Resultaten, met "Verstuur deze in de plaats".
- Op een bord dat geen paring noemt, begint het opnieuw opstellen van de stukken vanzelf de volgende partij. Instellingen, Dit kastje (Deze server), kan dat altijd of nooit maken.

Een partij die helemaal niet vastgelegd werd: pagina Partijen, lees de zetten van het partijformulier in en wijs ze toe aan haar bord.

## Rondes {#rounds}

Met OpenPairings begint een ronde vanzelf een paar seconden nadat de arbiter ze daar paart: de borden van dat toernooi tonen de nieuwe ronde met namen, ratings en kleuren. De borden van de andere toernooien blijven ongemoeid. "Ronde N starten" op de pagina Live blijft er voor als er geen verbinding is, en een toernooi kan ingesteld worden om rondes niet vanzelf te starten (Instellingen, Toernooien, open het toernooi).

Zonder OpenPairings zet "Ronde N starten" de borden van het toernooi door naar de volgende ronde.

### Als een paring verandert {#pairing-changed}

Verandert de arbiter een paring in OpenPairings nadat de ronde begonnen is:

- Een bord waarop nog niets gespeeld werd, neemt gewoon de nieuwe paring over.
- Een partij met zetten blijft zoals ze is, en haar tegel zegt "Paring gewijzigd". Open het bord en kies: **Deze zetten zijn die partij** als de spelers dezelfde zijn als in de nieuwe paring (een kleurwissel, een verbeterde naam), of **Opzijzetten, opnieuw beginnen** als de partij op het bord van niemand meer is. Ze blijft met haar PGN in Alnasl en het bord begint opnieuw.
- Een partij die enkel een ander bordnummer kreeg, verhuist daar vanzelf naartoe.

## Teamwedstrijden {#team-events}

Een teamtoernooi staat op de pagina Live als wedstrijden: "Wedstrijd 3: Team A - Team B", de borden van de wedstrijd eronder in bordvolgorde, elke tegel met het team van elke speler en zijn plaats in de wedstrijd. Naast de wedstrijd staat de stand zoals de borden hem zagen eindigen. Alleen dat: de stand die telt is die welke de arbiter in OpenPairings invoert.

"Elke wedstrijd bij elkaar houden" (standaard aan) telt de tafels van een toernooi wedstrijd per wedstrijd, zodat een wedstrijd naast elkaar zit en nummeren door aan te raken wedstrijd per wedstrijd gaat. De PGN van een teampartij draagt WhiteTeam en BlackTeam, en Round als ronde en bord ("3.6").
