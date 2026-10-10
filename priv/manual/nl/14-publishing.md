# Publiceren: de uitslagensite en de live-pagina

Een toernooi kan gepubliceerd worden op **OpenResults**, een aparte alleen-lezen
uitslagensite. Het publiek ziet de paringen, de uitslagen en de standen, en een kaart voor
elke speler, op hun eigen telefoon, zonder account.
OpenPairings serveert zelf geen openbare pagina's: de computer van de arbiter is de
bron van de gegevens en stuurt ze naar de uitslagensite, en een drukke openbare pagina
kan een paringssessie niet verstoren.

Publiceren is optioneel en standaard uit. Er wordt niets verstuurd totdat u het voor een
toernooi aanzet.

![De instellingenpagina van OpenResults met de keuze Op de uitslagensite, Toeschouwers zien en Automatisch](screenshots/14-openresults-settings.png "Instellingen, OpenResults")

## Een uitslagensite verbinden {#connecting-a-results-site}

**Verbindingen** (bovenbalk op de pagina Toernooien), sectie *Publieke uitslagensite (OpenResults)*. Voer het **Adres** van de uitslagensite in (en, waar een token nodig is, het **Token**; dat wordt nooit meer getoond nadat het is opgeslagen), en druk dan op **Verbinding testen**. **Opnieuw registreren** en **Opnieuw proberen** verschijnen wanneer een verbinding is mislukt. De pagina zegt of de uitslagensite heeft geantwoord. Een desktopkopie kan zichzelf bij de uitslagensite registreren; is dat mislukt, dan probeert **Opnieuw registreren** het nog eens. Zolang er geen adres is ingesteld, doet de schakelaar voor een toernooi niets.

## Een toernooi publiceren {#publishing-a-tournament}

Instellingen, **OpenResults**.

**Op de uitslagensite:** drie keuzes.

| Keuze | Betekenis |
| --- | --- |
| Uit | er wordt niets verstuurd. Terug naar Uit vraagt eerst om bevestiging; een kopie die al op de site staat, blijft tot u ze verwijdert (zie *Het adres*). |
| Alleen link | gepubliceerd, maar niet vermeld: iedereen met het adres kan het volgen. |
| Op de voorpagina | gepubliceerd en op de voorpagina van de uitslagensite. |

> [!WARNING] Alleen link is geen privacy
> Het adres is lang en kan niet geraden worden, maar
> wie het toegestuurd krijgt, kan het doorgeven.

### Wat het publiek ziet, ronde per ronde {#what-the-public-sees-round-by-round}

Op de pagina Paringen stelt een bediening **Toeschouwers zien:** (ook in het rechtsklikmenu van de ronde) in hoeveel van elke ronde openbaar is, in vier cumulatieve niveaus:

| Niveau | Openbaar |
| --- | --- |
| Niets | de ronde wordt niet getoond |
| Paringen | wie tegen wie speelt |
| + Uitslagen | de uitslagen naarmate ze binnenkomen |
| + Standen | de standen na de ronde ook |

Een nieuw gepubliceerde ronde begint bij *Paringen*: live uitslagen zijn een bewuste keuze. Naar beneden gaan vraagt eerst om bevestiging en noemt wat er verdwijnt.

### Automatisch publiceren {#automatic-publishing}

Instellingen, OpenResults, **Automatisch**: één instelling voor hoe ver de ladder het programma elke ronde zelf omhoog gaat:

- **Met de hand**: er beweegt niets vanzelf.
- **Paringen zodra gepaard**: de paringen van de ronde worden openbaar wanneer ze gepaard is; een optionele vertraging *Paringen worden publiek na N minuten* (0: meteen).
- **+ uitslagen live**: de uitslagen worden openbaar naarmate ze worden ingevoerd.
- **+ standen wanneer de ronde klaar is**: de standen worden openbaar zodra de ronde en elke ronde ervoor klaar zijn.

De automatisering verplaatst een ronde alleen omhoog; u kunt een ronde altijd met de hand terugzetten, en ze blijft staan waar u haar zet.

**Vóór ronde 1 ziet het publiek de startrangschikking** (standaard uit). Zonder die ziet het publiek, zodra een ronde openbaar is, alleen de lijst van spelers.

### Wat de openbare pagina toont {#what-the-public-page-shows}

Schakelaars bepalen welke details een gepubliceerde pagina mag tonen (ratings, titels, federaties, clubs, categorieën, spelerskaarten, de standpagina, de paringspagina's, de kolommen van de stand en welke tiebreaks), en apart of de berekening van de tiebreaks gepubliceerd wordt. Een detail dat u verbergt, wordt helemaal niet naar de uitslagensite gestuurd. Een tiebreakkolom verbergen verandert de volgorde die ze beslist niet, en de pagina zegt wanneer de volgorde een verborgen tiebreak heeft gebruikt. De berekening van de tiebreak beantwoordt de vraag van een toeschouwer *waarom sta ik vierde* (de tegenstander van elke ronde en de waarde ervan). De kolom *Aanwezig in ronden* is alleen openbaar als u haar aanvinkt. *Federation flags* tekent een vlaggetje naast elke federatiecode; het staat aan tot u het uitvinkt, toont niets waar *Federations* uit staat, en een speler onder de FIDE-vlag krijgt de code zonder vlag.

> [!WARNING]
> Namen, bordnummers, uitslagen en plaatsen worden altijd getoond: een toernooi dat ze niet mag tonen, moet niet gepubliceerd worden.

### Het zaalscherm {#the-hall-display}

Een schermvullende pagina voor een televisie of beamer in de speelzaal, op een adres dat op de instellingenpagina getoond wordt zodra het toernooi gepubliceerd is. De kaart **Zaalscherm** kiest wat er wordt doorlopen (paringen, de lijst *Zoek je bord* op naam, uitslagen, standen), seconden per pagina, hoeveel plaatsen van de stand getoond worden, of de paringen vastgehouden worden tot de eerste uitslag van een nieuwe ronde binnen is, en een **Mededeling** (gewone tekst, tot 500 tekens) die op het scherm getoond wordt. Opslaan verstuurt die meteen.

### Het adres {#the-address}

*Deellink* is het openbare adres (een QR-code ernaartoe verschijnt op de pagina Live). **Naar een nieuw adres verplaatsen** haalt de oude kopie neer, maakt een nieuw adres en publiceert opnieuw (gebruik het als een link is uitgelekt). **Van de uitslagensite verwijderen** haalt het toernooi van de site. Wanneer een toernooibestand of een back-up een publicatiesleutel bevat, wordt u gevraagd of u *De publicatie overnemen* of *Opnieuw beginnen* kiest.

### Ploegen {#teams}

Ploegentoernooien worden ook gepubliceerd, met ploegstanden en wedstrijden.

> [!NOTE]
> Wat de uitslagensite toont, wordt op die site beschreven; deze handleiding behandelt alleen het deel in OpenPairings.

## Inschrijvingen via de uitslagensite {#entries-through-the-results-site}

**Inschrijvingsformulier** op de instellingenpagina van OpenResults laat spelers zich inschrijven op de uitslagensite: zet **Inschrijvingen open** aan, stel in wanneer het opent en sluit, een maximum aantal spelers, en of de lijst van inschrijvers op het formulier getoond wordt. **Inschrijvingen nakijken** opent de pagina met inschrijvingen, waar u nieuwe ophaalt, ze als spelers aanvaardt of verwerpt ([Spelers en ratinglijsten](04-players-and-ratings.md)).

## De pagina Live (beamerweergave) {#the-live-page-projector-view}

Pagina **Paringen**, **Meer**, **Lokale weergave & telefoon-QR** (de pagina `/t/:id/live` van dit programma): de huidige ronde schermvullend voor een beamer, die doorloopt tussen paringen, uitslagen en standen, met een pauzeknop, een knop om te verlaten en een optie voor hoog contrast. Ze toont een QR-code voor het openbare adres als het toernooi gepubliceerd is. Ze bevat ook de kaart **Een telefoon inschrijven om uitslagen in te voeren** ([Uitslagen](07-results.md)). De pagina werkt zichzelf bij wanneer een uitslag verandert. Ze wordt door dit programma geserveerd, dus het scherm moet op dezelfde computer staan, of op een computer die er kan bij komen; de openbare pagina (hierboven) is voor iedereen anders.

## Als er geen netwerk is {#if-there-is-no-network}

> [!NOTE]
> Publiceren blokkeert nooit het paren of het invoeren van uitslagen.

Een verzending die niet aankomt, wordt bewaard en opnieuw geprobeerd met steeds langere pauzes; de status van de verbinding wordt getoond als een klein label in de bovenbalk, en de pagina zegt wat er mis is. De openbare pagina haalt de zaal in wanneer de verbinding terug is.
