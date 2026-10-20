# De Manubrium-app

Manubrium is een telefoonapp om een toernooi vanuit de speelzaal te leiden. Het
beginscherm is de lopende ronde: tik op een bord, tik op de uitslag. De app
blijft werken als het bereik in de zaal wegvalt, en verstuurt wat je invoerde
zodra dat kan. De organisator en bewerkers kunnen er ook de volgende ronde mee
paren, publiceren, de stand bekijken en spelers wijzigen. Een arbiter van het
toernooi voert uitslagen in en noteert incidenten, zoals op de computer.

Eén app kan meerdere servers bevatten - pairings.cloud, de eigen server van een
club, de desktopkopie op de laptop in de zaal - en ertussen wisselen.

> [!NOTE] Manubrium of Manubrium Lite?
> Manubrium Lite is de uitslagenpagina die een telefoon opent vanuit een
> Telefoon-QR-code ([Uitslagen](07-results.md)), in de browser, zonder account
> en zonder iets te installeren. De app is voor wie het toernooi leidt: je hebt
> een account op de server nodig en ze doet meer dan uitslagen.

> [!WARNING] Een eerste versie
> De serverkant is gebouwd en getest. De app zelf is nog niet door de App Store
> of Google Play gegaan; tot dan installeer je ze met de hand vanuit haar eigen
> build.

## De app verbinden {#connecting}

1. Open op de server je accountpagina (je naam, rechtsboven, dan **Account**)
   en ga naar **Manubrium-app**.
2. Klik op **Een telefoon verbinden**. Er verschijnt een QR-code, met
   hetzelfde als link eronder.
3. Tik in de app op **Een server toevoegen** en scan de code. Kan de camera
   niet gebruikt worden, kopieer dan de link en plak die erin.
4. De telefoon verschijnt in de lijst op de accountpagina, met zijn naam en de
   laatste vier tekens van zijn token.

De code werkt één keer, tien minuten lang, en wordt maar die ene keer getoond.
Is hij verlopen, klik dan opnieuw op **Een telefoon verbinden**. Elke telefoon
krijgt een eigen code: twee telefoons kunnen er geen delen.

Een verbonden telefoon kan wat jouw account kan, in de toernooien waaraan je
werkt, en niets meer. Haalt iemand je van een toernooi af, dan verliest de
telefoon het op hetzelfde moment.

## Op een desktopkopie {#desktop}

De desktopversie heeft geen accounts en luistert alleen op de computer zelf,
waar een telefoon niet bij kan. Verbinden vraagt daarom één stap meer:

1. Open in een willekeurig toernooi **Telefoon-QR** en zet **Telefoons op dit
   netwerk laten verbinden** aan. Kies het adres van de computer op het netwerk
   van de zaal.
2. Maak daarna de code op de accountpagina zoals hierboven. De code stuurt de
   app naar dat adres, niet naar dat van de computer zelf.

De telefoon moet op hetzelfde netwerk zitten (de wifi van de zaal). Zonder de
schakelaar weigert de accountpagina een code te maken en zegt ze waarom.

## Wat de app kan {#what-it-does}

| | Organisator, bewerker | Arbiter |
| --- | --- | --- |
| De ronde zien, uitslagen invoeren en wissen | ja | ja |
| Incidenten noteren | ja | ja |
| De volgende ronde paren, de laatste ronde ongedaan maken | ja | nee |
| Een ronde publiceren (paringen, uitslagen, stand) | ja | nee |
| Stand, met de tiebreaks van het toernooi | ja | nee |
| Late inschrijvingen, terugtrekken en terugkeren, vrije rondes, basisgegevens van spelers | ja | nee |
| Instellingen | alleen lezen | nee |

Uitslagen die je zonder bereik invoert, wachten op de telefoon en gaan weg
zodra het kan. Heeft iemand anders intussen hetzelfde bord gewijzigd, dan
overschrijft de app het niet: ze toont wat het bord nu zegt en laat de
beslissing aan jou. Al de rest - paren, publiceren, spelers - heeft een
verbinding nodig, en de app zegt dat.

Sommige vragen beantwoord je op de computer, nooit vanaf een telefoon: de vraag
over de paringsnummers, de FIDE-modus verlaten, bye-uitsluitingen, handmatige
wijzigingen aan een ronde, het schema van een round robin en teamtoernooien. De
app zegt welke en laat de ronde ongepaard.

## Een telefoon afmelden {#signing-out}

Klik op de accountpagina, onder **Manubrium-app**, op **Afmelden** naast de
telefoon. Vanaf zijn volgende verzoek wordt hij geweigerd; uitslagen die hij
nog niet verstuurd had, blijven onverstuurd op de telefoon staan. De app kan
zichzelf ook afmelden. Doe dit voor een telefoon die verloren, verkocht of aan
iemand anders gegeven is.
