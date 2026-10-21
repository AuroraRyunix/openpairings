# De Manubrium-app

Manubrium is een telefoonapp om een toernooi vanuit de speelzaal te leiden. Het
beginscherm is de lopende ronde: tik op een bord, tik op de uitslag. De app
blijft werken als het bereik in de zaal wegvalt, en verstuurt wat je invoerde
zodra dat kan. De organisator en bewerkers kunnen er ook de volgende ronde mee
paren, de paringen met de hand wijzigen, publiceren, de stand bekijken, spelers
wijzigen en de instellingen aanpassen die een arbiter tijdens het toernooi
aanraakt. Een arbiter van het toernooi voert uitslagen in, noteert incidenten
(met een foto als je wilt) en bevestigt of weigert wat Manubrium Lite-telefoons
invoerden.

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
| Een uitslag van een Manubrium Lite-telefoon bevestigen of weigeren | ja | ja |
| Incidenten noteren, met een foto | ja | ja |
| Foto's van incidenten bekijken, er een toevoegen aan een genoteerd incident | ja | nee |
| De volgende ronde paren, de laatste ronde ongedaan maken | ja | nee |
| De paringen met de hand wijzigen, handmatige wijzigingen afronden | ja | nee |
| Een ronde publiceren (paringen, uitslagen, stand) | ja | nee |
| Stand, met de tiebreaks van het toernooi | ja | nee |
| Late inschrijvingen, terugtrekken en terugkeren, vrije rondes, basisgegevens van spelers | ja | nee |
| Instellingen tijdens het toernooi | wijzigen | nee |

Uitslagen die je zonder bereik invoert, wachten op de telefoon en gaan weg
zodra het kan. Heeft iemand anders intussen hetzelfde bord gewijzigd, dan
overschrijft de app het niet: ze toont wat het bord nu zegt en laat de
beslissing aan jou. Al de rest - paren, handmatige wijzigingen, publiceren,
spelers, instellingen - heeft een verbinding nodig, en de app zegt dat.

Sommige vragen beantwoord je op de computer, nooit vanaf een telefoon: de vraag
over de paringsnummers, de FIDE-modus verlaten, bye-uitsluitingen, paren
terwijl de handmatige wijzigingen van een ronde nog openstaan, het schema van
een round robin en teamtoernooien. De app zegt welke en laat de ronde
ongepaard.

## De paringen met de hand wijzigen {#hand-edits}

Dezelfde handmatige wijzigingen als op de pagina Paringen
([Een ronde paren](06-pairing.md)), vanuit het rondescherm:

- **Twee spelers wisselen.** Tik op een bord, **Change the pairing**,
  **Swap with another player**, en kies de andere: op een ander bord, op
  hetzelfde bord (de kleuren omdraaien), of iemand die op geen bord zit (een
  vervanging).
- **Een speler speelt niet.** **Not playing this round** maakt de plaats vrij.
  Vraagt het toernooi de soort bye, kies die dan; anders is de speler afwezig.
- **Een lege plaats.** Tik op het bord: geef de overgebleven speler de bye,
  vul de plaats met iemand die op geen bord zit, of wissel hem elders.
- **Niet op een bord.** Vink onder de borden twee spelers aan om ze op een
  nieuw bord te paren, of één om hem de bye te geven. Een leeg laatste bord kan
  weg.
- **Finish hand edits** controleert de ronde, zoals op de
  computer. Zou de paringscontrole de ronde anders paren, dan toont de app haar
  borden en houdt ze de jouwe alleen als je dat zegt; het verschil wordt bij de
  ronde bewaard.

Waar de computer eerst iets vraagt - het is niet de laatste ronde, ze is al
verstuurd voor rating, de nieuwe borden breken een paringsregel, een tweede
bye van een half punt - stelt de app dezelfde vraag met dezelfde zinnen, en
verandert ze niets tot je antwoordt. Teamtoernooien wijzig je op de computer.

## Uitslagen van Manubrium Lite-telefoons {#lite-results}

Een uitslag die op een Manubrium Lite-telefoon werd ingevoerd, staat op zijn
bord met **Phone**, en een regel boven de borden telt hoeveel er op een blik
wachten. Tik op het bord: je ziet welke telefoon wat invoerde. **Confirm**
houdt de uitslag en markeert ze als nagekeken; **Reject** wist het bord, en het
auditlog zegt van welke telefoon je de uitslag weigerde. Is het bord intussen
gewijzigd, dan zegt de app wat er nu staat en doet ze niets. Uitslagen die jij,
of een andere arbiter met de app, invoert, zijn je eigen en hoef je niet te
bevestigen.

## Foto's bij incidenten {#photos}

Als je een incident noteert, voegt **Take a photo** er een foto aan toe: de
camera van de telefoon, verkleind voor ze vertrekt. Zonder bereik wacht ze
samen met het incident. De organisator en bewerkers kunnen een foto toevoegen
aan een eerder genoteerd incident (**More**, **Incidents**, **Add photo**) en
er een bekijken (**Photo**). Een incident heeft hoogstens één foto; alleen
JPEG's van een redelijke grootte worden aangenomen. Foto's zijn nooit
openbaar, en de telefoon van een arbiter kan er een versturen maar die van
anderen niet openen.

## Instellingen vanaf de telefoon {#settings}

**More**, **Settings**, **Change the mid-event settings**: het tempo, de
hoofdarbiter en de adjunct, de speelzaal en de stad, het aantal rondes, wat de
bye van de paring oplevert, of de soort bye gevraagd wordt, gedeelde plaatsen
en de tiebreaks. Wat het toernooi intussen vergrendeld heeft - in de
FIDE-modus de rondes, de waarde van de bye en de tiebreaks zodra ronde 1
gepaard is - staat grijs, en de server weigert het met dezelfde zin als de
pagina Instellingen. Al de rest van de instellingen blijft op de computer.

## Een telefoon afmelden {#signing-out}

Klik op de accountpagina, onder **Manubrium-app**, op **Afmelden** naast de
telefoon. Vanaf zijn volgende verzoek wordt hij geweigerd; uitslagen die hij
nog niet verstuurd had, blijven onverstuurd op de telefoon staan. De app kan
zichzelf ook afmelden. Doe dit voor een telefoon die verloren, verkocht of aan
iemand anders gegeven is.
