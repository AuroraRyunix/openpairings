# Spelers en ratinglijsten

Dit hoofdstuk behandelt de ratinglijsten die het programma bijhoudt, het
toevoegen en wijzigen van spelers, het spelersrooster, het vernieuwen van
ratings en late inschrijvingen. Byes, afwezigheden en terugtrekkingen staan in
[Byes en afwezigheid](05-byes-and-absences.md).

## Ratinglijsten {#rating-lists}

Het programma houdt een lokale kopie van ratinglijsten bij, zodat spelers
gevonden en hun ratings ingevuld kunnen worden zonder internettoegang in de
speelzaal.

**De FIDE-ratinglijst.** Ongeveer 1,9 miljoen spelers: FIDE-ID, naam,
federatie, titel, geboortejaar, en de standaard-, rapid- en blitzratings. Open
**Verbindingen** (bovenbalk op de pagina Toernooien), sectie *FIDE-databank*, en
druk de eerste keer op **Ratinglijst downloaden**. **Bijwerken vanaf FIDE**
downloadt de huidige lijst opnieuw (FIDE publiceert elke maand een nieuwe lijst).
Het programma houdt bij welke maand de lijst is die het heeft. Eén keer per dag,
terwijl het draait, vraagt het ook aan FIDE of er een nieuwere lijst is en
downloadt die alleen als die er is (ongeveer één keer per maand); offline gebeurt
er niets. Dit staat standaard aan en heeft een vinkvakje onder Verbindingen om
het uit te schakelen. De pagina toont hoeveel spelers de lokale databank bevat
en wanneer die voor het laatst is bijgewerkt. Op een desktopversie bent u de
beheerder van uw eigen installatie. Op een server mag alleen de beheerder
bijwerken. Een speler die niet in de lijst staat, heeft geen FIDE-rating (ongeveer
twee derde van de rijen in de lijst zijn ongerate spelers): dat betekent "geen
FIDE-ID of geen rating", niet een mislukte download.

> [!NOTE]
> De download is groot (ongeveer 40 MB) en vervangt de hele lokale kopie; er is
> een verbinding met de FIDE-ratingsite nodig.

**De nationale ratinglijst.** De Belgische lijst (KBSB/FRBE) is een ingebouwde
nationale lijst. Ze hoort bij het *Belgische pakket* van functies, dat voor elk
account uitstaat tenzij u het aanzet: accountmenu, **Functies**. Met *Synchronisatie
van de nationale ratinglijst* aan, toont Verbindingen de sectie *Belgische
nationale ratinglijst*, waar **Synchroniseren vanaf de KBSB** het openbare
maandbestand van de federatie downloadt (ongeveer 36.000 spelers: nationaal ID,
naam, club, FIDE-ID, nationale rating). *KBSB-spelerzoekopdracht* voegt de lijst
toe aan de spelerszoekfunctie. *Clubs in bulk bijwerken* voegt de knop **Clubs
bijwerken** toe aan de pagina Spelers. Een arbiter buiten België ziet niets
hiervan. De synchronisatie kopieert alleen het bestand van de federatie; ze
schrijft nooit zelf ratings in uw toernooien.

**Andere nationale lijsten** zijn niet ingebouwd. Voor een speler van een andere
federatie typt u het nationale ID en de nationale rating met de hand in, of laadt
u de lijst zelf als CSV-bestand.

**Uw eigen ratinglijsten (CSV).** Verbindingen heeft een link naar **Ratinglijsten**
(`/rating-lists`), waar u een eigen lijst laadt, bijvoorbeeld een nationale of
clublijst. De eerste rij van het CSV-bestand benoemt de kolommen: `id`, `name` en
`rating` zijn verplicht; `federation`, `title`, `birth_year` en `fide_id` zijn
optioneel. Het scheidingsteken kan een komma, puntkomma of tab zijn, en een rating
die leeg is of 0 is, betekent ongerate. *Bestand controleren* toont wat er is
gevonden; *Lijst laden* slaat het op, en er wordt niets geladen tenzij elke rij
geldig is. Een lijst met dezelfde naam wordt vervangen. Op een server laadt alleen
een beheerder lijsten. De lijsten worden door elk toernooi op de machine gedeeld,
verschijnen wanneer een speler wordt toegevoegd, en kunnen in de
ratinglijstvolgorde van een toernooi worden opgenomen.

**De volgorde van de ratinglijsten.** Instellingen, **FIDE**, sectie *Ratinglijsten*,
bepaalt de lijsten waaruit de rating van een speler wordt gehaald wanneer de
speler wordt toegevoegd of de ratings worden vernieuwd, in volgorde: FIDE
Standard, FIDE Rapid, FIDE Blitz, Effectief Rapid (Rapid, anders Standard),
Effectief Blitz, de nationale lijst, en uw eigen lijsten. Gebruik de pijltjes om
een lijst te verplaatsen, **Weglaten** om er een te verwijderen, en **Aan de
volgorde toevoegen** om er een toe te voegen; **Terug naar de standaardvolgorde**
herstelt de volgorde die bij het speeltempo van het toernooi past. De eerste lijst
is de *hoofdlijst*: haar rating wordt automatisch ingevoerd. De ratings die de
speler in de andere lijsten heeft, staan naast het zoekresultaat, en een klik op
een ervan (*Deze rating in de plaats gebruiken*) kiest die. Een FIDE-lijst vult de
FIDE-rating; de nationale lijst en uw eigen lijsten vullen de nationale rating.

**Welke rating wordt gebruikt.** De *Gebruikte Elo* van een speler is de
**toernooirating**, die de instelling *Toernooirating* van het toernooi bepaalt
(Instellingen, Opties): alleen de FIDE-rating, alleen de nationale rating, de
FIDE-rating anders de nationale (de standaard), de nationale anders de FIDE, de
hoogste van FIDE, nationaal en een met de hand ingetypte rating, of alleen de
ingetypte rating (zie [Een toernooi instellen](03-tournament-setup.md)). Het is de
rating waarop het programma de spelers sorteert wanneer het de paringsnummers
toekent, die de op rating gebaseerde tiebreaks lezen, en die het afdrukt. Een met
de hand ingetypte rating is het veld *Toernooirating* op het formulier van de
speler; alleen de laatste twee methoden lezen dat veld. De FIDE-rating die wordt
ingevuld, is die van het formaat van het toernooi: standaard voor een
standaardtoernooi, rapid voor een rapidtoernooi, blitz voor een blitztoernooi (of
de standaardrating wanneer de speler nog geen rapid- of blitzrating heeft).

**Ratings met de hand invoeren.** Elk ratingveld (FIDE-rating, nationale rating,
toernooirating) kan op het formulier van de speler met de hand worden ingetypt of
gewijzigd; het programma verbiedt een waarde niet omdat die afwijkt van de lijst.
Het formulier toont wat de lijst zegt en vraagt of het die moet toepassen wanneer
ze verschilt.

**Waar een rating vandaan komt.** Een rating die uit een lijst is gelezen, houdt
zijn bron bij: het formulier van de speler zegt bijvoorbeeld dat ze uit de
FIDE-standaardlijst van een bepaalde maand komt, dat ze met de hand is gewijzigd
(en wat ze op de lijst was), of dat ze met de hand is ingevoerd zonder bronlijst.

## De pagina Spelers {#the-players-page}

Bovenbalk, **Spelers**. Bovenaan: het aantal ingeschreven spelers en de knoppen

- **Speler toevoegen** (ook <kbd>Ctrl</kbd>+<kbd>I</kbd>),
- **Ratings vernieuwen**,
- **Clubs bijwerken** (alleen met het Belgische pakket aan),
- **Spelerslijst afdrukken** en **Plaatskaartjes afdrukken**,
- **Resultaten invoeren**, dat naar de pagina Paringen leidt.

Daaronder staat het spelersrooster: één rij per speler.

![De pagina Spelers met het spelersrooster en de knoppen erboven](screenshots/04-players-grid.png "De pagina Spelers")

### Een speler toevoegen {#adding-a-player}

Druk op **Speler toevoegen**. Het formulier biedt eerst een zoekvak aan:

- *Doorzoek de FIDE-databank (naam of FIDE-ID)*. Met de Belgische opzoeking aan:
  *Doorzoek de KBSB- en FIDE-lijsten (naam, nationaal ID of FIDE-ID)*.
- Begin een achternaam te typen (`Achternaam, Voornaam`) of een nummer; kies de
  speler uit de resultaten en het formulier wordt ingevuld: naam, titel,
  federatie, FIDE-ID, ratings, geboortejaar en (België) nationaal ID en club.
- Of vul de gegevens onder het zoekvak met de hand in.

![Het formulier Speler toevoegen met het zoekvak en de zoekresultaten](screenshots/04-add-player-form.png "Een speler toevoegen")

De velden van het formulier: volledige naam (verplicht), titel, FIDE-rating,
nationaal ID, nationale rating, federatie, geboortejaar, club, en verder naar
beneden de vaste tabel, de extra punten, categoriekoppelingen, inschrijfstatus
(*Niet betaald*, *Betaald*, *Gratis*), *Speelt mee vanaf ronde*, en de
aanwezigheidsinstellingen ([Byes en afwezigheid](05-byes-and-absences.md)). Een
speler met een FIDE-ID die al in het toernooi zit, wordt geweigerd. De
**FIDE-opzoeking** van het inschrijfformulier (en, met het Belgische pakket, de
**KBSB-opzoeking**) zoekt de speler opnieuw op in de lokale lijst. Als de lijst iets
anders zegt dan wat op bestand staat, toont het formulier wat FIDE zegt en vraagt
*dit toepassen?* voor elk verschil.

Registreer de spelers vóórdat ronde 1 is gepaard. Hun **paringsnummers** (de
startrangen) worden gegeven wanneer de eerste ronde wordt gepaard.

> [!FIDE] C.04.2 2
> De paringsnummers gaan eerst naar de hoogste toernooirating, dan naar de
> FIDE-titel (GM, IM, WGM, FM, WIM, CM, WFM, WCM, geen titel), dan naar het
> aangekondigde criterium van het toernooi (standaard alfabetisch; Instellingen,
> Opties, *Gelijke rating en titel*).

Een speler die later wordt toegevoegd, krijgt wanneer de volgende ronde wordt
gepaard het nummer dat zijn rating oplevert, waarbij iedereen daaronder één
plaats omlaag schuift (alleen Zwitsers), of het eerstvolgende vrije nummer als
de instelling *Paringsnummers van laatkomers* op *Achter het veld* staat.

**Paringsnummers van een Zwitsers toernooi wijzigen.** De knop **Paringsnummers**
op de pagina Spelers opent de lijst in paringsvolgorde. Twee spelers met dezelfde
rating kunnen hun nummers **wisselen** (de knop *Wisselen* tussen hun rijen, om ze
op een andere regel te ordenen), en **Opnieuw aanmaken volgens rating** nummert
iedereen opnieuw op de huidige ratings, met behoud van de volgorde die u aan
spelers met gelijke rating hebt gegeven. Gebruik dit om een ratingwijziging te
volgen of een fout te corrigeren.

> [!FIDE] C.04.2
> Beide zijn alleen mogelijk tot en met het paren van ronde 4.

Elke wijziging vraagt om uw bevestiging; bij een regeneratie komt eerst een lijst
van de spelers wier nummer verandert. Rondes die al gepaard waren, gebruikten de
oude nummers, dus een paringscontroleur zal ze niet langer reproduceren; het
dialoogvenster zegt dat. Elke wijziging wordt in het auditlogboek geschreven.

Tot ronde 4 gepaard is, waarschuwt de pagina Paringen boven *Ronde N paren*
wanneer de nummers de ratings niet meer volgen - een rating die na ronde 1 is
gecorrigeerd, een laatkomer die achter het veld is genummerd, of nummers die
met een geïmporteerd bestand zijn meegekomen. Ze noemt elke speler met rating,
nummer en het nummer dat de rating oplevert, en **Opnieuw aanmaken volgens
rating…** opent deze lijst. Spelers met gelijke rating in om het even welke
volgorde worden nooit gemeld: daar dient een wissel voor. Wie voor ronde 2 tot
en met 4 op *Ronde N paren* drukt, krijgt dan eerst een vraag
([Een ronde paren](06-pairing.md), *Wanneer de paringsnummers de ratings niet
volgen*).

**Startnummers van een rondetoernooi.** Vóór ronde 1 opent de knop
**Startnummers** de lijst waarop de Berger-tabellen paren. Voer het resultaat van
een loting met de hand in (een nummer per speler, of verplaats een speler omhoog
of omlaag), of druk op **Loten** (het programma loot, na een bevestiging), of op
**Rangschikken op rating** om terug te gaan naar de ratingvolgorde. De nummers
worden gebruikt wanneer ronde 1 wordt gepaard en kunnen daarna niet meer worden
gewijzigd; een later ingeschreven speler krijgt het volgende nummer.

### Het rooster {#the-grid}

De kolommen kunnen worden gesorteerd door op de kop te klikken. Afgekorte koppen
hebben een tooltip in gewone taal. Het paneel **Weergave** kiest welke kolommen
worden getoond, per gebruiker; de standaardset bevat het paringsnummer, de titel,
de naam, de rating, de federatie, de club, het aantal gespeelde partijen, de
punten en de aanwezigheid. Verdere kolommen zijn onder meer het geboortejaar, het
nationale en FIDE-ID, beide ratings, *Gebruikte Elo*, de categorieën, de
inschrijfstatus (Betaald), het vaste bord, de extra punten en de kolom met het
aantal aanwezige rondes (*Rds*). Dezelfde kolommen kunnen op de pagina Stand worden
getoond.

Sommige cellen openen een klein menu (rechtsklik, of <kbd>Space</kbd> /
<kbd>Shift</kbd>+<kbd>F10</kbd> / de contextmenutoets op het toetsenbord): de
aanwezigheidscel zet een speler aanwezig of afwezig, de cel *Betaald* zet de
inschrijfstatus, de categoriecel kent categorieën toe, en de kop van de
aanwezigheidskolom zet iedereen in één keer aanwezig of afwezig. De pijltjestoetsen
bewegen tussen de cellen; het celmenu wordt aan schermlezers aangekondigd met een
zin die zegt wat de letter in de cel betekent.

**Aanwezigheidscel.** Dit betekenen de letters in de cel:

| Cel | Betekenis |
| --- | --- |
| `F` | forfait / teruggetrokken |
| `A` | afwezig voor het hele evenement |
| `A(3,5)` | slaat die rondes over, en de ronde die op het punt staat gepaard te worden is er een van (nu afwezig) |
| `a(3,5)` | heeft die rondes overgeslagen, maar is beschikbaar in de ronde die op het punt staat gepaard te worden |

Dubbelklik op de naam van een speler (of druk op <kbd>Enter</kbd> of
<kbd>Space</kbd> erop) om het formulier **Spelersinschrijving** te openen.
Klik met de rechtermuisknop op de naam (of druk op de contextmenutoets) om de
**Spelerskaart** te openen: de tegenstanders, kleuren en resultaten van de speler
ronde voor ronde, met een afdrukknop en knoppen voor vorige en volgende.

### Een speler verwijderen {#removing-a-player}

> [!WARNING]
> **Verwijderen** wist een speler. Een speler die al heeft gespeeld kan in de
> FIDE-modus niet worden verwijderd als dat een ronde zou veranderen die niet meer
> open is; zo'n speler wordt in plaats daarvan teruggetrokken (forfait).

## Ratings vernieuwen {#refreshing-ratings}

**Ratings vernieuwen** zoekt elke speler op in de lokale FIDE-lijst (op FIDE-ID)
en toont een tabel van wat zou veranderen: de speler, het veld, de oude en de
nieuwe waarde, met een regel zoals *12 gecontroleerd, 5 wijzigingen, 3 zonder
ID-match*. Alleen de **FIDE-rating** en de **titel** worden voorgesteld, en een
titel wordt alleen voorgesteld wanneer de FIDE-lijst er echt een bevat. Een speler
zonder FIDE-ID wordt niet aangeraakt. Er wordt niets geschreven tot u op
**Toepassen** drukt; **Annuleren** schrijft niets. Het is alles-of-niets, en het is
een handmatige handeling: het programma schrijft nooit zelf ratings.

**De controle op zichzelf.** Terwijl de pagina Spelers of Paringen open is (en na
een voltooide update van de lijst), vergelijkt het programma de ratings en titels
op bestand met de FIDE-lijst die geldig was in de maand waarin het toernooi begon,
en toont, wanneer ze verschillen, een melding: *De FIDE-lijst (maand) geeft een
andere rating of titel voor N spelers*, met een knop **Bekijken** die dezelfde
tabel opent. Het schrijft niets. De maand van de lijst moet overeenkomen met de
startmaand van het toernooi; anders stelt het programma niets voor en zegt het
waarom (alleen de huidige lijst wordt bewaard). De melding kan per toernooi worden
uitgeschakeld (Instellingen, **FIDE**, *Consistentiecontroles*); de knop
**Ratings vernieuwen** werkt nog steeds op verzoek. Vóór een gevraagde controle
vraagt het programma aan FIDE of de lijst op deze machine actueel is en werkt die
eerst bij, of meldt dat dat niet lukte.

In de tabel met voorgestelde wijzigingen heeft elke regel een vinkje, en is er
**Alles selecteren**: **Geselecteerde toepassen** schrijft alleen de aangevinkte.

**Clubs bijwerken** (Belgisch pakket) werkt op dezelfde manier voor de club en het
clubnummer, met matching op nationaal ID, en daarna op FIDE-ID. Het maakt nooit een
club leeg.

> [!TIP]
> Vernieuw de ratings vóórdat ronde 1 is gepaard. Een rating later wijzigen
> verandert de paringsnummers die al zijn gegeven niet.

## Late inschrijvingen {#late-entries}

Een speler die wordt toegevoegd nadat rondes zijn gepaard, kan een ronde krijgen
waarin hij meedoet (**Speelt mee vanaf ronde** op het formulier; de volgende te
paren ronde wordt aangeboden). In een Zwitsers toernooi volgt hun paringsnummer de
instelling *Paringsnummers van laatkomers* (volgens rating, of achter het veld). Een
toernooi dat ze nog achter het veld nummert omdat het ouder is dan de standaard,
zegt dat één keer, op de pagina Paringen en op de pagina Opties, en biedt aan om
over te schakelen ([Een toernooi instellen](03-tournament-setup.md)). Het
formulier zegt wat de rondes ervoor tellen. Wanneer afwezigheid punten oplevert
(pagina Puntentelling), tellen de rondes vóór de inschrijving als afwezigheid, zoals
ingesteld op de pagina Puntentelling. In een Zwitsers toernooi wordt de nieuwe
speler in de ronde waarin hij meedoet met de anderen gepaard. In een
rondetoernooi valt een speler die wordt toegevoegd nadat ronde 1 is gepaard niet
in het schema: de Berger-tabel ligt vast zodra die bestaat.

## Inschrijvingen van de uitslagensite {#entries-from-the-results-site}

Wanneer een toernooi is gepubliceerd (zie [Publiceren](14-publishing.md)) en
inschrijvingen openstaan, kunnen spelers zich op de uitslagensite zelf
inschrijven. De pagina **Inschrijvingen van de uitslagensite** toont ze;
**Inschrijvingen ophalen** controleert op nieuwe, en elke inschrijving wordt
geaccepteerd (ze wordt een speler) of verwijderd. Een geaccepteerde inschrijving
kan worden teruggezet.

> [!NOTE]
> Het inschrijfformulier zelf wordt ingesteld op de instellingenpagina van
> OpenResults.

## Export van de spelerslijst {#export-of-the-player-list}

Instellingen, **Exporteren**, *Spelers exporteren (CSV)*: de kolommen die u kiest,
in de volgorde die u kiest, met een scheidingsteken (komma, puntkomma, tab of
pipe), gesorteerd op startrang of op naam, eventueel zonder afwezige spelers en
met een markering voor Excel. Zie [Importeren en exporteren](10-import-export.md).
