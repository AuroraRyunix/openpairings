# Live borden en Alnasl

Live borden tonen de partijen van een ronde terwijl ze gespeeld worden, zet voor
zet, met de klokken, op de uitslagensite. De zetten komen van een kastje in de
speelzaal. Alnasl is dat kastje: een kleine computer naast elektronische
DGT-borden die de zetten leest. Het praat met twee programma's. Aan
**OpenPairings** vraagt het wie waar zit, en het meldt terug wat de borden zagen.
Naar **OpenResults** stuurt het de zetten en de klokken voor de toeschouwers.

> [!WARNING] Het kastje is een eerste versie
> De livepagina's op de uitslagensite werken, en alles aan deze kant van de
> koppeling ook: de koppelcodes, de bordkolom op de pagina Paringen, de bewaarde
> partijen en hun PGN. Alnasl zelf is een eerste versie. Het draait op
> gesimuleerde borden en heeft één echt bord gelezen, en zijn helft van de
> koppeling met OpenPairings moet nog gebouwd worden. Elk onderdeel hieronder is
> als **gebouwd** of **gepland** gemarkeerd.

## Stand van zaken in één oogopslag {#status-at-a-glance}

| Onderdeel | Stand |
| --- | --- |
| De livepagina's: uitzending, Alle borden, beamerweergave, stukkensets, PGN, uitzendvertraging | gebouwd |
| De ingestroute die de zetten en klokken van een bord ontvangt, en de relaissleutels | gebouwd |
| De koppeling in OpenPairings: koppelcodes, wat het kastje te horen krijgt, wat het meldt, de bordkolom, bewaarde partijen en PGN | gebouwd |
| Alnasl dat borden leest: gesimuleerde borden, en één echt bord met klok | eerste versie |
| De helft van Alnasl van de koppeling met OpenPairings | gepland |
| De koppeling van een desktopkopie naar een kastje op een andere machine | niet gebouwd, zie [Beperkingen](#limits) |

## Wat Alnasl is {#what-alnasl-is}

*Eerste versie.* Alnasl is een kastje in de speelzaal. Het leest de elektronische
borden, zet wat ze melden om in legale zetten, en stuurt de zetten en de
bedenktijden door terwijl de partij gespeeld wordt. Het blijft werken wanneer het
internet van de zaal wegvalt, en een bord dat hangt of een losse kabel kan het
paringsprogramma niet raken, want Alnasl is een apart programma naast
OpenPairings.

Het kastje belt altijd zelf. OpenPairings belt het kastje nooit, dus de zaal zet
geen poort open en heeft geen vast adres nodig.

Alnasl is niet gelieerd aan en niet goedgekeurd door DGT. De naam DGT wordt alleen
gebruikt om te zeggen met welke borden Alnasl praat.

## De hardware {#the-planned-hardware}

*Eerste versie.* Wat de Alnasl-repository beschrijft:

- **Borden:** elektronische DGT-borden, in de RS232- en USB-C-modellen. Beide
  komen neer op een seriële stroom, dus één stuurprogramma past op beide. Eén echt
  bord met klok is gelezen; een hele partij erop is nog niet gespeeld.
- **Eén lus:** een seriële lus van tot 12 borden, elk met een eigen adres op de
  bus, om beurten bevraagd. Het formaat op de lus is nog aangenomen, niet
  nagekeken.
- **Zetten:** afgeleid uit de posities die de borden melden, zodat een stuk dat
  opgetild en teruggezet wordt, een slag in twee stappen of een omgevallen stuk
  geen verkeerde zet wordt. Een zet die het kastje achteraf afleidde, of raadde,
  wordt als zodanig geteld, en dat aantal reist mee met de partij.
- **Klokken:** uit een DGT-klok op het bord, wanneer er een is.
- **Het kastje:** een Raspberry Pi met een scherm, toetsenbord en muis voor de
  arbiter, schermvullend in een kioskbrowser.
- **Offline:** zetten worden op het kastje bewaard en in volgorde verstuurd zodra
  de verbinding terug is.
- **Meerdere toernooien op één kastje:** tafels 1 tot 4 kunnen in het ene toernooi
  spelen en tafels 5 tot 8 in een ander. Welke tafel bij welk toernooi hoort,
  wordt op het kastje bepaald, niet in OpenPairings.

## Een kastje koppelen {#connecting-a-box}

*Gebouwd in OpenPairings; de kant van het kastje is gepland.* In OpenPairings:
Instellingen, **Live borden**.

### Een code voor het toernooi {#a-code-for-the-tournament}

Druk op **Nieuwe code**. De pagina toont een regel tekst en dezelfde regel als
QR-code. Scan ze met het kastje, of kopieer de regel naar de instelpagina van het
kastje. Meer instellen is er niet: de code bevat het adres van deze server en een
geheim, en het kastje verneemt de rest via de koppeling.

De code wordt **één keer** getoond. Wanneer u de pagina verlaat, kan ze niet
opnieuw getoond worden, want OpenPairings bewaart ze niet, alleen een
vingerafdruk. Bent u ze kwijt, maak dan een nieuwe: een code kost één klik.

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
arbiter, die u niet kunt openen, gaat ook niet naar uw kastje.

### Wie mag {#who-may}

Wie het toernooi mag bewerken: de eigenaar en de arbiters met wie het gedeeld is.
Niet op een gearchiveerd of overgedragen toernooi. Een code maken, een code
intrekken, de relaissleutel bewaren of verwijderen, en de eerste keer dat een
kastje een code gebruikt, staan allemaal in het auditlogboek.

### Wat het kastje te horen krijgt {#what-the-box-is-told}

De naam, plaats en data van het toernooi, het speeltempo, de rondes, en per ronde
de borden: wie wit heeft en wie zwart, met naam, titel, rating, federatie en
FIDE-ID, en bij een ploegentoernooi de wedstrijd en het bord daarbinnen. Verder
gaat er niets over een speler de deur uit: geen geboortedatum, geen club, geen
e-mailadres, geen telefoonnummer.

Het krijgt ook te horen welke ronde bezig is. OpenPairings heeft geen knop die een
ronde start: een ronde die gepaard is, is bezig. Wanneer u dus een ronde paart,
start het kastje ze zelf, binnen ongeveer vijf seconden. In een round-robin,
waar alle rondes in één keer gepaard worden, is de ronde die bezig is de eerste
die nog op een uitslag wacht.

Een wijziging daarna bereikt het kastje op dezelfde manier: een bord gewisseld,
een speler vervangen, een ronde opnieuw gepaard. Meldt het kastje nog een partij
voor een paring die niet meer bestaat, of waarvan de spelers veranderd zijn, dan
wordt de melding geweigerd en wordt er niets onder de verkeerde partij bewaard.

### De relaissleutel {#the-relay-key-for-the-box}

Om zetten naar de uitslagensite te sturen heeft het kastje een relaissleutel nodig
(zie [Relaissleutels](#relay-keys)). Een beheerder van de uitslagensite maakt er
een voor het toernooi. Plak hem één keer in **Relaissleutel** op Instellingen,
Live borden, en het kastje krijgt hem via de koppeling, samen met het adres van de
uitslagensite en de openbare korte naam van het toernooi. Op het kastje hoeft
niets getypt te worden.

De relaissleutel wordt op deze machine bewaard, zodat hij doorgegeven kan worden.
Hij wordt na het bewaren niet opnieuw getoond (alleen zijn laatste vier tekens),
en hij zit niet in een export. Het veld is er alleen zolang het toernooi
gepubliceerd is.

Zonder relaissleutel leest het kastje de borden nog wel en meldt het aan
OpenPairings. Het stuurt niets naar de uitslagensite.

## De bordkolom {#the-board-column}

*Gebouwd.* Op de pagina Paringen, rechts van de paringen, krijgt een toernooi met
live borden een kolom **Bord zag**. Een toernooi zonder kastje heeft de kolom
niet.

**Een bord voert nooit een uitslag in.** U voert de uitslagen in zoals voorheen.
De kolom toont wat het bord meldde, naast wat u invoerde:

| De kolom toont | Het betekent |
| --- | --- |
| `-` | Het bord meldde niets voor deze partij. |
| *bezig* | Er is een partij bezig. |
| een uitslag, vet | Het bord zag een uitslag en u hebt er nog geen ingevoerd. |
| een uitslag, onopvallend | Het bord zag de uitslag die u invoerde. |
| een uitslag in het rood, *wijkt af* | Het bord zag een andere uitslag dan die u invoerde. |
| *geen uitslag* | Het bord zag de partij eindigen en kon niet uitmaken hoe. |

Rood is een waarschuwing en niets meer. Het blokkeert niets: u kunt de volgende
ronde paren, publiceren en verzenden zoals gewoonlijk. Controleer de
notatieformulieren, en verbeter de uitslag als het de ingevoerde is die fout is.
Een forfait dat u invoerde, wordt vergeleken op wie het punt kreeg: een bord dat
`1-0` zag, komt overeen met `1-0FF`.

Op een telefoon staat de melding van het bord op een eigen regel onder de
uitslagknoppen. De kolom wordt niet afgedrukt en staat niet in de paringslijst
voor aan de muur: ze is de controle van de arbiter, geen deel van de paring.

## Partijen en PGN {#games-and-pgn}

*Gebouwd.* Elke vermelding in de kolom is een link naar de partij: de zetten, de
klokken bij de laatste melding, de uitslag van het bord naast de uwe, en hoeveel
zetten het kastje achteraf afleidde of raadde. Een geraden zet is de beste lezing
van een onduidelijk bord door het kastje, niet iets wat het zag.

De partijen worden bij het toernooi bewaard. Er zijn drie downloads:

- **één partij**, op de pagina van de partij;
- **één ronde** en **het hele toernooi**, op Instellingen, Live borden.

In elk bestand komen de kopregels uit het toernooi: evenement, plaats, datum,
ronde en bord (`3.12` is bord 12 van ronde 3), wit, zwart, ratings, FIDE-ID's en
het speeltempo. De **uitslag is die welke u invoerde**, of `*` zolang u dat niet
deed. Een bord dat `1-0` zag op een partij die u niet hebt ingevoerd, is in het
bestand nog steeds `*`. Kloktijden staan na de zetten als `{[%clk 1:29:58]}` waar
het kastje ze meldde.

De pagina van de partij biedt ook **De eigen PGN van het kastje**, het bestand
precies zoals het kastje het schreef, ter vergelijking.

De PGN-export op de pagina Paringen (**Meer**, PGN) is ongewijzigd en bevat nog
steeds geen zetten.

## Relaissleutels {#relay-keys}

*Gebouwd.* Een relais is een kastje tussen mensen in een zaal,
en het mag het hele toernooi niet kunnen herschrijven. Daarom krijgt elk relais een
eigen sleutel. Een beheerder van de uitslagensite maakt een relaissleutel voor één
toernooi, op de pagina Toernooien, het toernooi, Relaissleutels. De sleutel wordt
één keer getoond en alleen als vingerafdruk bewaard. De pagina toont per sleutel
wanneer ze voor het laatst gebruikt is, en een sleutel kan ingetrokken worden.

De sleutel gaat via OpenPairings naar het kastje: zie
[De relaissleutel](#the-relay-key-for-the-box).

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
de code). Een speler die onder de FIDE zelf staat, of een code heeft die geen land aanduidt,
houdt de code en krijgt geen plaatje.

## De livepagina's aanzetten {#turning-live-boards-on}

*Gebouwd.* In OpenPairings: Instellingen, OpenResults, de kaart *Elke ronde publiceren*, de
schakelaar **Live borden**. Dezelfde schakelaar staat op Instellingen, Live borden, als
**Live-link op de uitslagensite**. Hij staat uit voor elk toernooi tot u hem aanzet, en wordt
alleen aangeboden zolang het toernooi gepubliceerd is.

Aan: OpenPairings stuurt een woord mee in de momentopname (`live_boards: true` in het deel
over het toernooi) en publiceert het toernooi meteen opnieuw. De openbare pagina's linken dan
naar de live borden. Uit: het woord wordt niet gestuurd en de link verdwijnt met de volgende
kopie. De livepagina's zelf werken met of zonder dat woord, voor wie hun adres heeft.

De schakelaar is uw verklaring dat de borden worden doorgestuurd. Een kastje koppelen zet hem
niet aan, en de schakelaar start geen kastje: zonder iets dat zetten stuurt, leidt de link
naar borden in de beginstelling. De instelling zit in een JSON-back-up en komt in het
auditlogboek.

## Beperkingen {#limits}

- **Een desktopkopie bereikt alleen een kastje op dezelfde computer.** De desktopeditie
  antwoordt op haar eigen computer en nergens anders, dus haar koppelcode zegt
  `http://127.0.0.1` en werkt voor een kastjesprogramma dat op die computer draait. Een
  kastje elders op het netwerk van de zaal kan een desktopkopie niet bereiken. De gehoste
  editie heeft die beperking niet.
- **OpenPairings controleert de zetten niet.** Het heeft zelf geen schaakregels. Een zet
  wordt bewaard zoals het kastje hem schreef, mits hij de vorm van een zet heeft. Het
  kastje controleert de wettigheid, en de uitslagensite ook.
- **Een code is een sleutel.** Wie een code heeft, kan de paringen van het toernooi lezen
  en er partijen voor melden. Hij kan geen uitslag invoeren, geen paring wijzigen en niets
  anders lezen. Trek een code in die u niet meer gebruikt.
- **Wat meereist in een export.** De partijen die de borden meldden, zitten in de
  JSON-export en in een herstelpunt. De koppelcodes en de relaissleutel niet: een kopie op
  een andere machine maakt haar eigen.
- **Alleen gepubliceerde partijen worden op de uitslagensite getoond.** Een partij op een
  bord dat niet in de gepubliceerde momentopname staat, wordt bewaard maar niet getoond, tot
  de arbiter die ronde publiceert.
- **De klokken komen van het kastje.** Een lopende klok wordt in de browser afgeteld vanaf
  het laatste bericht, en bij elk bericht bijgesteld.
- **Onwettige zetten worden door de uitslagensite geweigerd.** De site controleert elke zet
  op de regels. Een zet die onwettig is, of op twee legale zetten past, weigert de update en
  noemt de zet, en er wordt uit die update niets bewaard.
- **Alleen twee stukkensets** worden aangeboden.
