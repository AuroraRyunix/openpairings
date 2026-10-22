# Publiceren: de uitslagensite en de live-pagina

Een toernooi kan gepubliceerd worden op **OpenResults**, een aparte alleen-lezen
uitslagensite. Het publiek ziet de paringen, de resultaten en de standen, en een kaart voor
elke speler, op hun eigen telefoon, zonder account.
OpenPairings serveert zelf geen openbare pagina's: de computer van de arbiter is de
bron van de gegevens en stuurt ze naar de uitslagensite, en een drukke openbare pagina
kan een paringssessie niet verstoren.

Publiceren is optioneel en standaard uit. Er wordt niets verstuurd totdat je het voor een
toernooi aanzet.

## Een uitslagensite verbinden {#connecting-a-results-site}

**Verbindingen** (bovenbalk op de pagina Toernooien), sectie *Publieke uitslagensite (OpenResults)*. Voer het **Adres** van de uitslagensite in (en, waar een token nodig is, het **Token**; dat wordt nooit meer getoond nadat het is bewaard), en druk dan op **Verbinding testen**. **Opnieuw registreren** en **Opnieuw proberen** verschijnen wanneer een verbinding is mislukt. De pagina zegt of de uitslagensite heeft geantwoord. Een desktopkopie kan zichzelf bij de uitslagensite registreren; is dat mislukt, dan probeert **Opnieuw registreren** het nog eens. Zolang er geen adres is ingesteld, doet de schakelaar voor een toernooi niets.

## Een toernooi publiceren {#publishing-a-tournament}

Instellingen, **OpenResults**.

**Op de uitslagensite:** drie keuzes.

| Keuze | Betekenis |
| --- | --- |
| Uit | er wordt niets verstuurd. Terug naar Uit vraagt eerst om bevestiging; een kopie die al op de site staat, blijft tot je ze verwijdert (zie *Het adres*). |
| Alleen link | gepubliceerd, maar niet vermeld: iedereen met het adres kan het volgen. |
| Op de voorpagina | gepubliceerd en op de voorpagina van de uitslagensite. |

> [!WARNING] Alleen link is geen privacy
> Het adres is lang en kan niet geraden worden, maar
> wie het toegestuurd krijgt, kan het doorgeven.

### Wat het publiek ziet, ronde per ronde {#what-the-public-sees-round-by-round}

Op de pagina Paringen stelt een bediening **Toeschouwers zien:** in hoeveel van elke ronde openbaar is, in vier cumulatieve niveaus:

| Niveau | Openbaar |
| --- | --- |
| Niets | de ronde wordt niet getoond |
| Paringen | wie tegen wie speelt |
| + Resultaten | de resultaten naarmate ze binnenkomen |
| + Standen | de standen na de ronde ook |

Een nieuw gepubliceerde ronde begint bij *Paringen*: live resultaten zijn een bewuste keuze. Naar beneden gaan vraagt eerst om bevestiging en noemt wat er verdwijnt.

### Automatisch publiceren {#automatic-publishing}

Instellingen, OpenResults, **Automatisch**: één instelling voor hoe ver de ladder het programma elke ronde zelf omhoog gaat:

- **Met de hand**: er beweegt niets vanzelf.
- **Paringen zodra gepaard**: de paringen van de ronde worden openbaar wanneer ze gepaard is; een optionele vertraging *Paringen worden publiek na N minuten* (0: meteen).
- **+ resultaten live**: de resultaten worden openbaar naarmate ze worden ingevoerd.
- **+ standen wanneer de ronde klaar is**: de standen worden openbaar zodra de ronde en elke ronde ervoor klaar zijn.

*Klaar* betekent dat elk bord een uitslag heeft of een uitgestelde partij is. In een round robin houdt een bord dat niemand ingevuld heeft de stand niet meer tegen zodra een latere ronde klaar is: het telt dan als een uitgestelde partij, en de stand zegt dat (zie [Uitgestelde partijen](07-results.md#postponed-games)).

De automatisering verplaatst een ronde alleen omhoog; je kunt een ronde altijd met de hand terugzetten, en ze blijft staan waar je haar zet.

**Vóór ronde 1 ziet het publiek de startrangschikking** (standaard uit). Zonder die ziet het publiek, zodra een ronde openbaar is, alleen de lijst van spelers. Zodra een ronde openbaar is, is de instelling niet meer van toepassing en zegt de pagina dat; wat het publiek dan ziet, bepaalt het niveau van elke ronde op de pagina Paringen. Stond ze aan nadat een ronde openbaar werd, dan kun je ze nog uitzetten.

**Live borden** (standaard uit, en alleen aangeboden zolang het toernooi gepubliceerd is). Zet dit aan wanneer een relais in de zaal de zetten van de partijen naar de uitslagensite stuurt: de gepubliceerde pagina's krijgen dan een link **Live borden** naast de rondes. De schakelaar zet alleen de link. Hij start geen relais en controleert niet of er een draait, dus zonder iets dat zetten stuurt, leidt de link naar borden die in de beginstelling blijven staan. Aan- of uitzetten stuurt het toernooi opnieuw naar de uitslagensite. Zie [De livepagina's aanzetten](17-live-boards.md#turning-live-boards-on). Om de borden in de zaal in te richten, zie [Elektronische borden installeren](18-setting-up-boards.md).

### Wat de openbare pagina toont {#what-the-public-page-shows}

Schakelaars (geavanceerd) bepalen welke details een gepubliceerde pagina mag tonen (ratings, titels, federaties, clubs, categorieën, spelerskaarten, de standpagina, de paringspagina's, de kolommen van de stand en welke tiebreaks), en apart of de berekening van de tiebreaks gepubliceerd wordt. Een detail dat je verbergt, wordt helemaal niet naar de uitslagensite gestuurd. Een tiebreakkolom verbergen verandert de volgorde die ze beslist niet, en de pagina zegt wanneer de volgorde een verborgen tiebreak heeft gebruikt. De berekening van de tiebreak beantwoordt de vraag van een toeschouwer *waarom sta ik vierde* (de tegenstander van elke ronde en de waarde ervan). De kolom *Aanwezig in rondes* is alleen openbaar als je haar aanvinkt. Dat geldt ook voor *Geslacht*: de M of F van elke speler op de stand en de startlijst is persoonlijke informatie, dus het staat bij elk toernooi, nieuw of oud, standaard uit en er gaat niets naar de uitslagensite tot je het aanvinkt. Aangevinkt toont een speler zonder ingevuld geslacht gewoon een streepje. *Prestatie* werkt net zo: het prestatiecijfer van elke speler, zoals op je spelerspagina, komt op de openbare stand, per ronde berekend, en het staat uit tot je het aanvinkt. Een speler zonder afgewerkte partij heeft er geen. *Links naar projectorweergave en zaalscherm* bepaalt de twee kaartjes onder de stand, de paringen en de kruistabel die de projectorweergave en het zaalscherm openen; het staat aan tot je het uitvinkt. Uitvinken verbergt alleen de kaartjes; de schermen zelf blijven bereikbaar via hun eigen adres. *Federation flags* tekent een vlaggetje naast de naam en de federatiecode van elke speler; het staat aan tot je het uitvinkt. Het hoort bij *Federations*: het vinkje hangt daaraan vast en wordt alleen aangeboden zolang *Federations* aangevinkt is. Vink je *Federations* uit, dan worden er ook geen vlaggen gepubliceerd; vink je het weer aan, dan staat het vlaggenvinkje terug zoals je het had achtergelaten. Een speler die onder de FIDE zelf staat, of een code heeft die geen land aanduidt, krijgt geen plaatje.

> [!WARNING]
> Namen, bordnummers, resultaten en plaatsen worden altijd getoond: een toernooi dat ze niet mag tonen, moet niet gepubliceerd worden.

### Het zaalscherm {#the-hall-display}

Een schermvullende pagina voor een televisie of beamer in de speelzaal, op een adres dat op de instellingenpagina getoond wordt zodra het toernooi gepubliceerd is. De kaart **Zaalscherm** (geavanceerd) kiest wat er wordt doorlopen (paringen, de lijst *Zoek je bord* op naam, resultaten, standen), seconden per pagina, hoeveel plaatsen van de stand getoond worden, of de paringen vastgehouden worden tot het eerste resultaat van een nieuwe ronde binnen is, en een **Mededeling** (gewone tekst, tot 500 tekens) die op het scherm getoond wordt. Bewaren verstuurt die meteen.

### Het adres {#the-address}

*Deellink* is het openbare adres (een QR-code ernaartoe staat in het venster **Telefoon-QR** op de pagina Paringen). **Naar een nieuw adres verplaatsen** haalt de oude kopie neer, maakt een nieuw adres en publiceert opnieuw (gebruik het als een link is uitgelekt). **Van de uitslagensite verwijderen** haalt het toernooi van de site. Wanneer een toernooibestand of een back-up een publicatiesleutel bevat, word je gevraagd of je *De publicatie overnemen* of *Opnieuw beginnen* kiest. Op een gehoste server vraagt overnemen eerst aan de uitslagensite of dat adres echt bij die sleutel hoort; is dat niet zo, dan wordt er niets overgenomen en is *Opnieuw beginnen* de weg verder.

Als de beheerder van de uitslagensite het toernooi daar verwijdert, stopt het programma met proberen: publiceren wordt ervoor uitgeschakeld en de pagina meldt dat de uitslagensite het verwijderd heeft. Opnieuw inschakelen helpt pas als die beheerder het toestaat. Antwoordt de uitslagensite dat ze *verhuisd* is, dan wordt er niets vanzelf naar het nieuwe adres gestuurd: controleer het en vul het in onder **Verbindingen**.

### Teams {#teams}

Teamtoernooien worden ook gepubliceerd, met teamstanden en wedstrijden.

> [!NOTE]
> Wat de uitslagensite toont, wordt op die site beschreven; deze handleiding behandelt alleen het deel in OpenPairings.

## Inschrijvingen via de uitslagensite {#entries-through-the-results-site}

**Inschrijvingsformulier** op de instellingenpagina van OpenResults (geavanceerd tot het open is) laat spelers zich inschrijven op de uitslagensite: zet **Inschrijvingen open** aan, stel in wanneer het opent en sluit, een maximum aantal spelers, en of de lijst van inschrijvers op het formulier getoond wordt. **Inschrijfgeld** vermeldt wat meespelen kost: een bedrag en een munt, een vrije opmerking ("gratis voor jeugd"), of allebei. Het is enkel een regel op het formulier; er wordt niets via betaald. Niemand die inschrijft krijgt een e-mail van het programma of de uitslagensite: laat het zelf weten via het adres in de nakijklijst.

Staat de lijst van inschrijvers aan, dan voegt **Ook inschrijvingen tonen die op je beslissing wachten** (standaard aan) de inschrijvingen toe waarover je nog niet beslist hebt, enkel met naam en elk gemarkeerd als *onbevestigd*. Namen worden door vreemden getypt, dus de lijst is aan jou om te bewaken: **Verwerp** een inschrijving en haar naam verdwijnt van de publieke lijst zodra de uitslagensite de volgende kopie van het toernooi heeft, een paar seconden later. Zet de optie uit om alleen aanvaarde spelers te tonen. **Inschrijvingen nakijken** opent de pagina met inschrijvingen, waar je nieuwe ophaalt, ze als spelers aanvaardt of verwerpt ([Spelers en ratinglijsten](04-players-and-ratings.md)).

## De pagina Live (beamerweergave) {#the-live-page-projector-view}

Pagina **Paringen**, **Meer**, **Lokale weergave** (de pagina `/t/:id/live` van dit programma): de huidige ronde schermvullend voor een beamer, die doorloopt tussen paringen, resultaten en standen, met een pauzeknop, een knop om te verlaten en een optie voor hoog contrast. Ze bevat geen QR-codes; die staan onder **Meer**, **Telefoon-QR** ([Resultaten](07-results.md)). De pagina werkt zichzelf bij wanneer een resultaat verandert. Ze wordt door dit programma geserveerd, dus het scherm moet op dezelfde computer staan, of op een computer die er kan bij komen; de openbare pagina (hierboven) is voor iedereen anders.

## Als er geen netwerk is {#if-there-is-no-network}

> [!NOTE]
> Publiceren blokkeert nooit het paren of het invoeren van resultaten.

Een wijziging wordt enkele seconden nadat je ze maakt verstuurd; het label in de bovenbalk zegt intussen *Bezig met versturen*. Als er voor toeschouwers niets veranderd is (een dialoogvenster bevestigd terwijl er niets te doen was, een resultaat ingevoerd en meteen teruggenomen), wordt er niets verstuurd en blijft het label zoals het was. **Opnieuw proberen**, publiceren uit- en weer aanzetten, en het programma opnieuw starten versturen altijd.

Wat niet aankomt, wordt bewaard en opnieuw geprobeerd met steeds langere pauzes; de status van de verbinding wordt getoond als een klein label in de bovenbalk, en de pagina zegt wat er mis is. De openbare pagina haalt de zaal in wanneer de verbinding terug is.
