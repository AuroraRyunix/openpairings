# Fair play: eerlijk spel

Alnasl kan de zetten in de partijen die de borden vastleggen naast een sterke schaakengine leggen en de eigenaar van de zaal laten zien welke spelers vaker dezelfde zetten speelden als de engine, en minder verloren, dan hun rating voorspelt. Het is een reden om een partij beter te bekijken. Het is geen bewijs, geen beschuldiging en voor niemand zichtbaar behalve de eigenaar en wie de eigenaar een rapport laat zien.

## Wat het is, en wat niet {#what-it-is}

Het is een screening: een getal per speler per toernooi, met de aantallen erachter, zodat een eigenaar die twijfelt iets heeft om naar te kijken naast een onderbuikgevoel.

Het is **niet** de methode die FIDE heeft goedgekeurd. De FIDE Fair Play Regulations (door de Raad goedgekeurd in november 2024) zeggen in art. 1.6 dat voorlopig alleen de methodologie van prof. Kenneth W. Regan is goedgekeurd, en art. 1.5 zegt dat een vermoeden van valsspelen alleen uit een goedgekeurd algoritme kan komen. Het getal van Alnasl is op dezelfde ideeën gebouwd, maar het is een ander programma met een eigen kalibratie, en het mag nooit aangehaald worden alsof het van FIDE is. Elke pagina van het rapport zegt dat.

Het kijkt alleen naar de zetten. Het kijkt niet naar de spelers, de borden, de telefoons of de klok, en het zegt niet waarom een speler speelde zoals hij speelde.

Het wijst alleen op opvallend sterk spel. Zwak spel is niemands zaak.

## Wie het ziet {#who-sees-it}

**De eigenaar van de zaal, en de mensen met wie de eigenaar het deelt. Niemand anders.** Niet de arbiters, niet de kijkers, en ook niet de beheerder van de Alnasl-server: een beheerder kan elke zaal beheren en ziet toch niets van de fair play van een andere zaal. De pagina staat in niemand anders' menu en wordt voor iedereen anders beantwoord als een pagina die er niet is.

De eigenaar kan één rapport, of alle rapporten van de zaal, **delen** (hieronder) met mensen van de zaal die hij bij naam kiest: de hoofdarbiter, een fair-playverantwoordelijke. Zij kunnen kijken, tot een datum die de eigenaar koos, en niets anders: ze veranderen geen instelling, uploaden niets, bewaren niets langer en delen niets verder. Beheerder zijn geeft niemand toegang.

Een kastje zonder accounts kent geen eigenaren om uit elkaar te houden: iedereen op het netwerk van de zaal is daar eigenaar, zoals bij al het andere, dus de instellingen en het rapport staan voor allemaal open. Maak het eerste account (Instellingen, Toegang) voordat je fair play aanzet als dat in jouw zaal uitmaakt.

Telkens als de eigenaar, of iemand met wie het gedeeld is, een rapport of de pagina van een speler opent, schrijft Alnasl op wie en wanneer, en het rapport toont de laatste keren dat het geopend is. Delen, stoppen met delen, uploaden, een upload verwijderen en een ronde laten analyseren worden ook opgeschreven.

Gegevens over fair play staan nooit op de uitslagenpagina's, in de PGN-bestanden, in wat naar OpenResults of Lichess gaat, in het logboek van de arbiter of in de wachtrij van de resultaten. Ze staan in de database van de Alnasl van de zaal en op het scherm van de eigenaar.

## Aanzetten, en de engine {#installing-the-engine}

Kies **Fair play** in het menu links, onder Beheren, en dan **Instellingen** bij de zaal. Het staat er alleen als je een zaal bezit; wie dat niet doet, ziet het niet. Het staat **uit** tot je het aanzet, zaal per zaal.

Alnasl heeft een engine nodig om het werk te doen: Stockfish 19, de officiële release. Alnasl wordt er niet mee geleverd. De pagina toont of hij geïnstalleerd is.

1. Druk op **Stockfish 19 downloaden**. Alnasl haalt het officiële bestand op bij GitHub, controleert dat het precies het bestand is dat gepubliceerd werd, haalt het programma eruit en laat Stockfish zijn eigen test (`bench`) draaien om zeker te zijn dat het de build is waarvoor de getallen gekalibreerd zijn.
2. Wacht een minuutje. De status zegt **Geïnstalleerd**, met de versie.
3. Zet Fair play aan.

**Geen internet in de zaal?** Download het bestand op een andere computer, van de releasepagina van Stockfish 19 op GitHub (`official-stockfish/Stockfish`, tag `sf_19`): `stockfish-windows-x86-64-universal.zip` voor Windows, `stockfish-macos-universal.tar.gz` voor een Mac, `stockfish-linux-x86-64-universal.tar.gz` voor Linux (de arm64-versies voor ARM-computers). Neem het mee op een USB-stick, druk op **Kies een bestand** en kies het. Dezelfde controles gebeuren. Een bestand dat niet het officiële is, wordt geweigerd met een zin die zegt waarom.

> [!NOTE] Oudere Macs
> De Mac-build van Stockfish 19 heeft macOS 10.15 of nieuwer nodig. Op een Mac met macOS 10.13 of 10.14 zegt de instellingenpagina dat, met de versie die ze vond, en biedt ze noch de download noch het bestand aan; er wordt niets gedownload. Al het andere in Alnasl werkt als voorheen.

Vanaf dan analyseert Alnasl elke zet zodra de tracker er zeker van is, op de achtergrond en met de laagste prioriteit die de computer biedt, met een paar engines tegelijk (het aantal kernen min één; één op de Alnasl-server). Niets daarvan vertraagt de borden: als de wachtrij vol is, wacht een partij, en de volgende zet van die partij zet hem opnieuw in de rij.

Stockfish is vrije software (GPL-3.0), van stockfishchess.org. Alnasl draait het als apart programma en geeft het nooit door.

## Het rapport {#the-report}

Onder **Rapporten** op dezelfde pagina open je het rapport van een toernooi. Het toont de spelers, hoogste score eerst, t/m de ronde die je kiest (of alleen die ronde). Per speler:

- **Getelde zetten**: hoeveel zetten in de getallen zitten (hieronder: wat niet meetelt).
- **Zelfde zet als de engine**, en wat daarvan **verwacht** werd voor de rating van die speler in die stellingen.
- **Gemiddeld verlies**, en wat verwacht werd. Het verlies is hoeveel slechter de gespeelde zet was dan de beste van de engine, geschaald zodat een pion weggooien in een gelijke stelling zwaarder weegt dan een pion weggooien als je twee pionnen voor staat.
- **Score**, met het interval, en een van de twee formuleringen hieronder.
- **Niet meegeteld**: hoeveel zetten niet meetelden, en waarom.

Druk op de naam van een speler voor de **stellingen om te bekijken**: de zetten van die speler die de eerste keuze van de engine waren, waar die keuze het meest afstak van de tweede, elk op een bord met de gespeelde zet en de vier beste van de engine.

### Zetten die niet meetellen {#left-out}

Een zet zegt niets over de speler, of Alnasl weet niet zeker dat hij gespeeld is, in deze gevallen. Elk wordt geteld en getoond:

| Niet meegeteld | Waarom |
| --- | --- |
| geen rating | Zonder rating is er niets om mee te vergelijken. Ratings komen uit de paring |
| geraden door de tracker | De tracker wist niet zeker wat er gespeeld werd, en dat geldt ook voor elke zet erna in die partij |
| herschreven, uitslag nog niet bevestigd | De tracker heeft hem gecorrigeerd en de arbiter heeft de uitslag nog niet bevestigd |
| opening (zet 1 tot 8) | Theorie, geen denkwerk |
| herhaalde stelling | Dezelfde stelling stond eerder op het bord |
| gedwongen zet | Maar één legale zet, of de beste is twee pionnen beter dan de tweede |
| minder dan een minuut op de klok | Als de klok bekend is |
| beslist | De engine ziet vóór de zet één kant meer dan drie pionnen voor |
| niet geanalyseerd | De engine gaf geen antwoord |

Een speler krijgt alleen een score bij minstens 40 getelde zetten in het toernooi; daaronder zegt het rapport **te weinig zetten**.

## Wat de getallen betekenen {#what-the-numbers-mean}

De **verwachte** waarden komen uit een model dat gefit is op echte partijen uit toernooien aan het bord (Lichess-uitzendingen, met FIDE-ratings en klokken): hoe vaak wordt voor een speler met die rating, in een stelling met zoveel goede zetten, de eerste keuze van de engine gespeeld, en hoeveel gaat er gemiddeld verloren. De **score** is hoe ver de speler van die verwachting af zit, in standaarddeviaties, waarbij de drie maten (de eerste keuze spelen, een even goede zet spelen, het verlies) samen genomen worden. Nul is zoals verwacht. Hoger is sterker dan de rating voorspelt.

- **Vanaf 2: "de moeite van een nader onderzoek waard".** Zulke scores komen bij een paar van elke honderd eerlijke spelers toevallig voor. Kijk naar de partijen, niet naar het getal.
- **Boven 5: "statistisch zeer ongewoon".** Eerlijke spelers hebben zo'n score in een model dat past vrijwel nooit. Het is nog steeds geen bewijs van iets, en het volgende onderdeel zegt wat je ermee mag doen.

Die twee woorden en die twee getallen zijn van Alnasl zelf, voor zijn eigen score. Het zijn niet de drempels van FIDE (de 5,00 van FIDE voor spel aan het bord hoort bij de goedgekeurde methode, en de 2,50 steunt alleen ander bewijs), en een 5 hier is geen 5 daar.

Het interval naast de score is het bereik waarin de werkelijke stand van de speler waarschijnlijk ligt: een score van 2,4 uit 40 zetten verschilt niet veel van een score van 0,5.

### Hoe vaak een eerlijke speler zo hoog scoort {#false-positives}

Naast een score van 2 of meer zegt het rapport hoe zeldzaam die is: **"ongeveer 1 op N normale speler-toernooien scoort zo hoog"**, met een bereik. Een speler-toernooi is de partijen van één speler in één toernooi. Het getal is gemeten, niet uit een formule berekend: als het model gemaakt wordt, gaat een deel van de partijen (hele toernooien, nooit gebruikt om het model te fitten) opzij, krijgt elke speler daarin een score, en telt Alnasl hoeveel er 2,0, 2,5, 3,0 enzovoort tot 5,0 halen. Het bereik is het exacte 95%-interval (Clopper-Pearson) van die telling.

- Als geen enkel opzijgezet speler-toernooi die score haalde, zegt de pagina **"minder dan ongeveer 1 op N"**: met een paar duizend speler-toernooien bewijst een nul maar zoveel.
- Die partijen zijn grotendeels eerlijk, niet zeker eerlijk. Een echte valsspeler ertussen maakt het getal iets hoger, en dat is aan de voorzichtige kant.
- Het getal geldt voor de spelers waarmee het model gemaakt is (spelers met rating, standaard bedenktijd, minstens 40 getelde zetten). Een jeugdtoernooi waar de ratings ver achter de sterkte van de spelers aan lopen, geeft meer hoge scores dan de tabel zegt.

**Niet gekalibreerd** betekent wat het zegt: er is geen model voor de geïnstalleerde engine, dus geen score, en ook geen getal. Alnasl verzint er geen.

> [!IMPORTANT] Geen kalibratie, geen score
> Het model is een bestand dat bij één engine-build hoort. Zolang Alnasl er geen heeft voor de engine die je installeerde, toont het rapport de aantallen en zegt het duidelijk dat er **geen score** is. De aantallen kloppen. Ze zijn geen score en moeten niet als een score gelezen worden. Het model is gemaakt voor standaard bedenktijden; rapid en blitz zijn niet gekalibreerd.

Wat de screening niet kan zien: een partij die zonder de borden gespeeld is (tenzij je ze uploadt, hieronder), een zet die de tracker niet kon lezen, openingskennis, een speler die gewoon veel sterker is dan zijn rating, een speler die één variant erg goed voorbereid heeft. Sterke, eenvoudige, gedwongen ogende stellingen geven veel overeenkomst zonder dat iemand iets verkeerd doet.

## Partijen uit een PGN-bestand {#pgn-upload}

Partijen die zonder de borden gespeeld zijn, of een heel toernooi van elders, kun je ook laten screenen. In de fair-playinstellingen van de zaal, onder **Partijen uit een PGN-bestand**:

1. Kies het `.pgn`-bestand (gewone tekst, hoogstens 10 MB en 2.000 partijen; pak een gezipt bestand eerst uit).
2. Kies het toernooi waar het bij hoort, of **Geen** voor een eigen rapport. Hoort het bij een toernooi, dan worden de spelers gekoppeld aan die van het toernooi (op FIDE-ID, dan op naam, in welke volgorde die ook geschreven is) en tellen de partijen mee in het rapport van het toernooi.
3. Geef het een naam als de toernooinaam in het bestand niet volstaat, en druk op **Uploaden en analyseren**.

De ratings komen uit de tags `WhiteElo` en `BlackElo`. Een speler zonder rating krijgt geen score, en de upload zegt dat; Alnasl raadt nooit een rating. Klokken (`[%clk]`) worden gebruikt als het bestand ze heeft. De ronde komt uit de tag `Round` ("5" of "5.12" voor ronde 5, bord 12).

Elke partij wordt eerst gecontroleerd. Een partij met een onwettige zet, een beginstelling die niet te lezen is, of een andere variant dan standaardschaak wordt geweigerd, en een partij die twee keer voorkomt, wordt één keer genomen; de upload toont elke partij met haar nummer in het bestand en de reden. Een partij van een gekoppeld toernooi die de borden al opnamen, wordt geen tweede keer geanalyseerd.

De partijen worden op de achtergrond geanalyseerd, na de live partijen: een upload vertraagt nooit de analyse van de ronde die gespeeld wordt. Het rapport van de upload toont hoeveel er klaar zijn en hoeveel er wachten, en vult zich aan als ze klaar zijn. Werd Alnasl intussen herstart, dan gaat het verder waar het was; **De wachtende partijen opnieuw in de wachtrij zetten** is er voor het geval dat niet lukte.

Het bestand zelf wordt niet bewaard: alleen de naam, de grootte en de vingerafdruk (om het te herkennen als het opnieuw geüpload wordt), de partijen en hun analyse. Niets ervan wordt ooit getoond aan iemand anders dan de eigenaar en de mensen met wie de eigenaar het rapport deelt. **Deze upload verwijderen** verwijdert de partijen, hun analyse en wat erover opgeschreven is, meteen.

## Een ronde op vraag {#round-on-demand}

Een ronde die gespeeld werd terwijl fair play uit stond, voor de engine geïnstalleerd was, of die de wachtrij niet kon bijhouden, kun je achteraf laten analyseren. Kies op het rapport van het toernooi, onder **Een ronde op vraag analyseren**, de ronde en druk op **Deze ronde analyseren**. De partijen van de ronde wachten achter de live partijen. Zetten die al met dezelfde engine geanalyseerd zijn, blijven, dus twee keer vragen kost niets.

## Delen {#sharing}

De eigenaar beslist wie fair play nog ziet, bij naam en tot een datum:

- **Eén rapport**: op het rapport, onder **Gedeeld met**.
- **Alle rapporten van de zaal**: in de fair-playinstellingen, onder **Delen**.

Kies de persoon en het aantal dagen (hoogstens 365) en druk op **Delen**. Alleen mensen van de zaal kun je kiezen, als arbiter of kijker; nodig de persoon eerst uit in de zaal. **Niet meer delen** stopt het meteen. Delen stopt ook vanzelf op de datum, en als de persoon uit de zaal gehaald wordt.

De persoon vindt de rapporten onder **Fair play** in het menu, onder **Met jou gedeeld**. Die ziet het rapport, de rondes en de pagina's van de spelers, met een regel die zegt dat het gedeeld is en vertrouwelijk is. Die ziet niet wie het nog opende, hoe lang het bewaard blijft of met wie het nog gedeeld is, en kan niets veranderen of delen.

## De regels waaraan je gebonden bent {#the-rules}

Uit de FIDE Fair Play Regulations 2024:

- **Art. 1.6**: alleen de goedgekeurde methodologie (die van Regan) kan een vermoeden dragen; voor spel aan het bord is de drempel 5,00, en 2,50 of meer alleen ter ondersteuning van ander bewijs. De screening van Alnasl is dat niet en zegt dat ook.
- **Art. 1.7**: een roekeloze of kennelijk ongegronde beschuldiging is zelf een overtreding. Een speler, een ouder, de organisator of de zaal vertellen dat "de computer het zegt" is precies dat, als je alleen dit scherm hebt. Een vermoeden in vertrouwen aan een arbiter melden mag wel.
- **Art. 3.1.2 a**: de hoofdarbiter (of de Chief Fair Play Officer) mag een zaak melden aan de FIDE Fair Play Commission.
- **Art. 3.2.12**: strikte vertrouwelijkheid. Dit rapport is vertrouwelijk. Print het niet, stuur het niet rond en laat het aan niemand zien die geen deel van de procedure is.

## Wat te doen met een opvallende score {#unusual-score}

1. **Controleer eerst de gegevens.** Open de pagina van de speler. Zijn er veel of weinig getelde zetten? Zijn er veel zetten niet meegeteld omdat de tracker ze raadde of herschreef? Zijn de partijen de hele tijd op de borden gespeeld? Lijken de genoemde stellingen op stellingen waarin alleen een goede zet verstandig is?
2. **Vertel het niet aan de speler en niet aan iemand anders.** Nog niet, en niet in de zaal. Dat is art. 1.7 en art. 3.2.12.
3. **Als je nog steeds reden tot zorg hebt**, zeg het in vertrouwen tegen de hoofdarbiter. De hoofdarbiter mag de zaak melden aan de FIDE Fair Play Commission (art. 3.1.2 a) en **vraagt daar om een echte analyse**, volgens de goedgekeurde methode. Die analyse telt, niet dit scherm.
4. **Bewaar de gegevens zolang de zaak loopt** (hieronder), en schrijf op waarom.

Een eigenaar die niet de hoofdarbiter van het toernooi is, geeft de zaak aan die hoofdarbiter en beslist zelf niets.

## Hoe lang het bewaard blijft {#retention}

De analyse van een toernooi, en de lijst van wie de rapporten opende, worden verwijderd **30 dagen na de laatste ronde van het toernooi** (de laatste keer dat een partij ervan beëindigd of gewijzigd werd). Eén keer per dag ruimt een taak ze op. De beheerder van de installatie kan het aantal dagen veranderen (`ALNASL_FAIR_PLAY_RETENTION_DAYS`).

Een zaak die naar de FIDE Fair Play Commission gaat, heeft de gegevens misschien langer nodig. Geef op het rapport van het toernooi, onder **Hoe lang dit bewaard blijft**, een aantal dagen na de laatste ronde, **hoogstens 365**, en **een reden**. De reden wordt ermee bewaard. Als die datum voorbij is, gaat alles weg.

Een geüploade PGN die bij een toernooi hoort, blijft even lang bewaard als het toernooi. Eén op zichzelf telt zijn 30 dagen vanaf het uploaden, en kan op dezelfde manier langer bewaard worden. Een gedeeld rapport verdwijnt met het rapport. Wat met de hele zaal gedeeld werd, en wat daarover in het eigen overzicht van de zaal staat, wordt een jaar na het einde verwijderd.

Fair play uitzetten stopt de analyse van nieuwe zetten. Wat er al is, wordt niet verwijderd; dat doet de bewaartermijn.
