# Live borden en Alnasl

Live borden tonen de partijen van een ronde terwijl ze gespeeld worden, zet voor
zet, met de klokken, op de uitslagensite. De zetten komen van een relais in de
speelzaal. Alnasl is dat relais: een klein kastje naast elektronische DGT-borden
dat de zetten leest en ze naar OpenResults stuurt. De toeschouwerspagina's zijn
gebouwd en staan op de uitslagensite; ze blijven leeg tot een relais zetten
doorstuurt. Alnasl zelf is gepland.

> [!WARNING] Het relais is nog niet beschikbaar
> De livepagina's horen bij de uitslagensite, maar een toernooi toont pas borden
> wanneer een relais in de zaal de zetten doorstuurt - en Alnasl, dat relais, is
> nog niet af: de repository bevat het plan en een hulpmiddel om het signaal van
> het bord op te nemen, en er draait nog niets. Elk onderdeel hieronder is als
> **gebouwd** of **gepland** gemarkeerd.

## Stand van zaken in één oogopslag {#status-at-a-glance}

| Onderdeel | Stand |
| --- | --- |
| De livepagina's: uitzending, Alle borden, beamerweergave, stukkensets, PGN, uitzendvertraging | gebouwd |
| De ingestroute die de zetten en klokken van een bord ontvangt, en de relaissleutels | gebouwd |
| Alnasl, het relais in de zaal | gepland, ontwerpfase |
| Een schakelaar van de arbiter in OpenPairings die zegt dat een toernooi live borden heeft | gebouwd |

## Wat Alnasl is {#what-alnasl-is}

*Gepland.* Alnasl is een relais in de speelzaal. Het leest de elektronische
borden, zet wat ze melden om in legale zetten, en stuurt de zetten en de
bedenktijden naar OpenResults terwijl de partij gespeeld wordt. Het blijft werken
wanneer het internet van de zaal wegvalt, en een bord dat hangt of een losse kabel
kan het paringsprogramma niet raken, want Alnasl is een apart programma naast
OpenPairings.

Alnasl is niet gelieerd aan en niet goedgekeurd door DGT. De naam DGT wordt alleen
gebruikt om te zeggen met welke borden Alnasl praat.

## De geplande hardware {#the-planned-hardware}

*Gepland.* Dit zijn de plannen in de Alnasl-repository. Niets daarvan is gebouwd.

- **Borden:** elektronische DGT-borden, in de RS232- en USB-C-modellen. Beide
  komen neer op een seriële stroom, dus één stuurprogramma past op beide.
- **Eén lus:** een seriële lus van tot 12 borden, elk met een eigen adres op de
  bus, om beurten bevraagd.
- **Zetten:** afgeleid uit de posities die de borden melden, zodat een stuk dat
  opgetild en teruggezet wordt, een slag in twee stappen of een omgevallen stuk
  geen verkeerde zet wordt.
- **Klokken:** uit een DGT-klok op het bord, wanneer er een is.
- **Het kastje:** een Raspberry Pi met een scherm, toetsenbord en muis voor de
  arbiter, met Photon OS, schermvullend in een kioskbrowser.
- **Offline:** zetten worden op het kastje bewaard en in volgorde verstuurd zodra
  de verbinding terug is. Een afgelopen partij wordt ook als PGN-bestand op het
  kastje bewaard.
- **Een lokaal scherm voor de arbiter:** welke borden antwoorden, de live stand van
  elk bord, een bord koppelen aan een partij van een ronde, en de verbinding met
  OpenResults met het aantal zetten dat wacht.

Latere plannen zijn meer lussen per kastje en meer merken borden, elk achter
dezelfde interface.

De Alnasl-repository bevat een handleiding om een echte lus op te nemen: de
software van DGT stuurt de borden aan via een tussenprogramma dat elke byte
opschrijft. Het plan is het stuurprogramma te schrijven tegen zo'n opname, voordat
het een bord ziet. Er staan hier geen installatiestappen, omdat de bronnen die nog
niet beschrijven.

## Relaissleutels {#relay-keys}

*Gebouwd.* Een relais is een kastje tussen mensen in een zaal,
en het mag het hele toernooi niet kunnen herschrijven. Daarom krijgt elk relais een
eigen sleutel. Een beheerder van de uitslagensite maakt een relaissleutel voor één
toernooi, op de pagina Toernooien, het toernooi, Relaissleutels. De sleutel wordt
één keer getoond en alleen als vingerafdruk bewaard. De pagina toont per sleutel
wanneer ze voor het laatst gebruikt is, en een sleutel kan ingetrokken worden.

Een relaissleutel werkt voor dat ene toernooi en alleen voor de liveroute. Ze kan
niets publiceren, verwijderen of anders wijzigen. Ze heeft een eigen budget van
1200 verzoeken per minuut. Een toernooi van de site halen verwijdert de
relaissleutels ervan, en een overdracht naar een andere installatie trekt ze in.

De route is `POST /api/tournaments/:slug/live`. Het volledige contract voor wie een
relais schrijft, staat in `docs/live-boards-api.md` van OpenResults.

## Toeschouwerspagina's {#spectator-pages}

*Gebouwd.* De pagina's werken als verbindingen: ze lezen de
partijen zelf opnieuw in, dus een zet verschijnt binnen een seconde, en er wordt
niets uit een cache geleverd.

### De uitzending {#the-broadcast}

De uitzending is de pagina voor de partijen van een ronde, op
`/t/<toernooi>/live`, die naar de nieuwste ronde gaat. Ze heeft drie kolommen:

- **Links:** de ronde-knoppen, een zoekveld, en elke partij van de ronde, met het
  bord, beide spelers, de uitslag (`1-0` of `½-½`), en de lopende partijen
  gemarkeerd. De borden van een ploegronde staan onder hun wedstrijd.
- **Midden:** één partij, groot, met een balk boven en onder het bord. De balken
  tonen de naam, de titel, de federatie en de rating, de klok in een vakje, en de
  score zodra er een uitslag is. De laatste zet is opgelicht, en er is een knop
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

*Gebouwd.* De beamerweergave zet de partijen die u kiest op een
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
vanzelf van het scherm. Een partij die eindigt, toont haar uitslag een halve minuut
over het bord, en maakt dan plaats voor de andere. In deze modus worden forfaits
nooit getoond. Wanneer de laatste partij weg is, zegt het scherm dat en somt de
uitslagen op. Zonder de automatische modus blijven afgelopen partijen staan met hun
uitslag. Het oudere paringenscherm op de uitslagensite is een aparte pagina en
verandert niet. Zie [Het zaalscherm en de beamerweergave](16-openresults.md#the-hall-display-and-the-projector-view).

### Stukkensets {#piece-sets}

*Gebouwd.* De borden worden getekend met een van twee
stukkensets: Cburnett, de standaard, en Chessnut. De kijker kiest met de keuzelijst
Stukken op de livepagina's, en de keuze wordt in de browser onthouden. Een scherm
zonder keuzelijst krijgt een set in het adres, met `?pieces=chessnut`.

### Forfaits en uitslagen {#forfeits-and-results}

*Gebouwd.* Een forfait dat de arbiter heeft gepubliceerd
(`1-0FF`, `0-1FF` of `0-0FF`) wordt als forfait getoond, wat het relais ook stuurt.
Aan een forfaitbord zit niemand, dus het bord toont *Forfait* of *Dubbel forfait*, de
uitslag als `1-0 FF`, en een leeg bord met *Niet gespeeld - forfait*. Een bord met een
gepubliceerde uitslag en geen partij van het relais toont *Partij voorbij*, niet *Nog
niet gestart*.

Een gepubliceerde uitslag wint altijd. Anders wordt, zodra de partij afgelopen is en de
uitslagen van de ronde openbaar zijn, de uitslag van het relais getoond, met de
aanduiding voorlopig. In een ronde waarvan de arbiter de uitslagen achterhoudt, toont een
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
vinkje *Federatievlaggen*, standaard aan tenzij u het uitvinkt), wordt een klein vlaggetje
naast de federatiecode van een speler getoond: op de startlijst, de inschrijvingslijst, de
spelerskaart, het zaalscherm en de livepagina's (op de beamerweergave alleen de vlag, zonder
de code). Een speler die onder de FIDE zelf staat (code FID) krijgt een witte vlag met het
woord FIDE erop. Een code die geen federatie aanduidt, houdt de code en krijgt geen plaatje.

## De livepagina's aanzetten {#turning-live-boards-on}

*Gebouwd.* In OpenPairings: Instellingen, OpenResults, de kaart *Elke ronde publiceren*, de
schakelaar **Live borden**. Hij staat uit voor elk toernooi tot u hem aanzet, en wordt alleen
aangeboden zolang het toernooi gepubliceerd is.

Aan: OpenPairings stuurt een woord mee in de momentopname (`live_boards: true` in het deel
over het toernooi) en publiceert het toernooi meteen opnieuw. De openbare pagina's linken dan
naar de live borden. Uit: het woord wordt niet gestuurd en de link verdwijnt met de volgende
kopie. De livepagina's zelf werken met of zonder dat woord, voor wie hun adres heeft.

De schakelaar is uw verklaring dat de borden worden doorgestuurd. Hij start Alnasl niet en
zoekt er niet naar: zonder relais dat zetten stuurt, leidt de link naar borden in de
beginstelling. De instelling zit in een JSON-back-up en komt in het auditlogboek.

## Beperkingen {#limits}

- **Alleen gepubliceerde partijen worden getoond.** Een partij op een bord dat niet in de
  gepubliceerde momentopname staat, wordt bewaard maar niet getoond, tot de arbiter die
  ronde publiceert.
- **De klokken komen van het relais.** Een lopende klok wordt in de browser afgeteld vanaf
  het laatste bericht, en bij elk bericht bijgesteld.
- **Onwettige zetten worden geweigerd.** De site controleert elke zet op de regels. Een zet
  die onwettig is, of op twee legale zetten past, weigert de update en noemt de zet, en er
  wordt uit die update niets bewaard.
- **Alleen twee stukkensets** worden aangeboden.
