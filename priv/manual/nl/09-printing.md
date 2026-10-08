# Afdrukken

Elk afdrukbaar document opent in een nieuw browsertabblad als gewone pagina die de
printdialoog van de browser start.

> [!TIP]
> Omdat het een gewone pagina is, kunt u die ook als PDF opslaan via de printdialoog.
> Het tabblad kan worden gesloten zonder het programma te verstoren.

## Waar u afdrukt {#where-to-print-from}

Het tabblad **Afdrukken** toont elk document met een korte beschrijving en een knop
**Afdrukken…**. Een document dat een gepaarde ronde nodig heeft, is grijs totdat de
eerste ronde is gepaard. Verschillende documenten zijn ook bereikbaar vanaf de pagina
waarbij ze horen: de pagina Paringen heeft een menu **Afdrukken**, de pagina Spelers
heeft **Spelerslijst afdrukken** en **Plaatskaartjes afdrukken**, de pagina Stand heeft
**Afdrukken**, en de lijst met uitgestelde partijen heeft de briefjes.

![Het tabblad Afdrukken met de documenten van een toernooi](screenshots/09-print-tab.png "Het tabblad Afdrukken")

Een toernooilogo (Instellingen, Toernooi, *Logo*) wordt op de documenten afgedrukt.
Documenten van een toernooi waarin nog een uitgestelde partij open staat, of waarin
een bord geen resultaat heeft, krijgen een regel die zegt dat de cijfers nog niet
definitief zijn.

De rating die naast een speler wordt afgedrukt (paringslijsten, klassement,
kruistabel, kaarten, scoreformulieren) is de **toernooirating**: de rating die de
instelling *Toernooirating* van het toernooi kiest (Instellingen, Opties; zie
[Spelers en ratinglijsten](04-players-and-ratings.md)). De kolom heet *Elo* wanneer de
FIDE-rating voorgaat, *Nat.* wanneer de nationale rating voorgaat, en *Rtg* bij
de methoden met de hoogste rating of een met de hand ingetypte rating.

## De documenten van een individueel toernooi {#the-documents-of-an-individual-tournament}

| Document | Wat het is |
| --- | --- |
| **Spelerslijst** | Alle ingeschreven spelers: titel, naam, ratings, federatie, club. |
| **Spelerskaarten** | Eén kaart per speler met elke ronde van het toernooi erop, om over het bord in te vullen. |
| **Paringenlijst** | De borden van een ronde, om op de locatie op te hangen. De pagina Paringen biedt ook *Paringen, met rubriek afwezigen*, die de spelers die niet spelen toevoegt, met de waarde van de ronde voor elk. Een speler met een vaste tafel is gemarkeerd, bijvoorbeeld `5 (table 5)`. |
| **Alfabetische paringenlijst** | "Waar zit ik": de spelers gesorteerd op naam, om uw bord te vinden. |
| **Stand** | De rangschikking met de punten en de tiebreaks. |
| **Resultaatkaartjes** | Eén kaartje per bord van een ronde, acht op een A4-pagina, met de namen, ratings, paringsnummers en de drie resultaten om aan te kruisen, een regel voor een ander resultaat, en handtekeningvakjes. Byes worden overgeslagen. |
| **Notatiebriefjes** | Eén voorbereid briefje per bord: namen, ratings, zetkolommen en handtekeningen. |
| **Kruistabel** | Het volledige resultatenrooster. Een Zwitsers of Keizer-toernooi krijgt één rij per speler in standvolgorde en één kolom per ronde; elke cel leest *paringsnummer van de tegenstander, kleur, resultaat* (`12w1`: wit tegen nummer 12, gewonnen). Een rondetoernooi krijgt het klassieke rooster speler tegen speler, met beide cycli in één cel bij een dubbel rondetoernooi. |
| **Plaatskaartjes** | Eén opgevouwen tentkaartje per speler op een volledige A4-pagina (zie hieronder). Vanaf de pagina Spelers. |
| **Briefjes voor uitgestelde partijen** | Eén briefje per speler van elke openstaande uitgestelde partij ([Resultaten invoeren](07-results.md)). |
| **Voorvertoning volgende ronde** | De borden die vast liggen, wat de openstaande resultaten ook zijn, met een lijst op naam voor de naamkaartjes ([Een ronde paren](06-pairing.md)). |

### Welke ronde {#which-round}

De paringenlijst, de resultaatkaartjes en de notatiebriefjes nemen een ronde: de
pagina Afdrukken gebruikt de laatst gepaarde ronde, en de pagina Paringen drukt de
ronde af waarnaar u kijkt. In het adres van een afdrukpagina kiest `?round=N` een
ronde. De paringenlijst valt standaard terug op ronde 1 en de resultaatkaartjes op de
laatst gepaarde ronde als u het weglaat. Een ronde die niet is gepaard, geeft het
antwoord *Ronde N is nog niet gepaard*, niet een andere ronde. De afdruk van de stand
neemt op dezelfde manier een ronde (`?round=N`) en toont dan de stand zoals die was
na die ronde.

### Resultaatkaartjes: testafdruk en stapelsnijden {#result-cards-test-print-and-stack-cutting}

- **Resultaatkaartjes: testafdruk (eerste 3)** drukt drie kaartjes af, om de uitlijning
  van uw printer te controleren voordat u een stapel afdrukt.
- **Resultaatkaartjes: volgorde voor stapelsnijden** ordent de kaartjes zo dat u, na
  het afdrukken van elke pagina, de uitdraai stapelt en in acht strepen snijdt met een
  guillotine; elke stapel staat dan in bordvolgorde. Plaatsen die aan het eind leeg
  blijven, worden leeg afgedrukt.

### Plaatskaartjes {#place-cards}

Elke speler krijgt een volledige A4-pagina, in het midden verdeeld door een vouwlijn.
De bovenhelft wordt rechtop afgedrukt en de onderhelft ondersteboven, zodat het blad,
gevouwen met de tekst naar buiten en rechtop gezet als tent, van beide kanten van het
bord goed leesbaar is. Het adres neemt schakelaars om velden te tonen of te verbergen:
`?title=`, `?rating=`, `?federation=`, `?club=`, `?board=` (elk accepteert `0` om het veld
uit te zetten). Standaard toont de kaart de naam, de titel, de rating en het bord van
de laatst gepaarde ronde; federatie en club staan uit. De regel met het bord wordt
weggelaten als er geen ronde is gepaard.

## De documenten van een teamtoernooi {#the-documents-of-a-team-tournament}

Teamparingen (een tabel per match met de borden, kleuren, ratings en het resultaat),
de teamstand, de **teamkruistabel** (rondetoernooi: ploeg tegen ploeg met de
partijpunten; Zwitsers: tegenstander, kleur van bord 1, matchscore en lopende
matchpunten per ronde), **matchresultaatbladen** (één A4-pagina per match met beide
opstellingen, resultaatvakjes, de matchscore en handtekeningregels voor beide
captains en de arbiter), **teamlijsten** en **bordprijzen** (per bordnummer, de
spelers gerangschikt op percentage, punten en prestatie, met een optioneel minimum
aantal partijen). Zie [Ploegen](12-teams.md).

## Accreditatiebadges {#accreditation-badges}

Badges van A6, twee op een A4-blad, worden gemaakt in een apart hulpmiddel: **Geavanceerd**,
**Badges**. Een badge heeft een naam, foto, titel, federatie, FIDE-ID, een gekleurde
rolbanner, tot twaalf genummerde ruimtes, logo's en een QR-code. Een evenement dat aan
een toernooi is gekoppeld, importeert zijn spelers en officials; persbadges, VIP- en
stafbadges worden met de hand toegevoegd. Zie [Categorieën en normen](13-categories-and-norms.md)
voor de andere hulpmiddelen onder Geavanceerd.

## De FIDE-formulieren afdrukken {#printing-the-fide-forms}

De formulieren IT3, FA1, IA1 en IT4 zijn ingevulde Excel-bestanden uit **Geavanceerd**,
**Normen**, geen afdrukpagina's ([Categorieën en normen](13-categories-and-norms.md)).
