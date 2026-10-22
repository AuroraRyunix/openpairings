# Accounts, delen, overdracht en back-ups

## Accounts (online) {#accounts-online}

Op een server heeft iedereen een account. Je meldt zich aan met een e-maillink (een eenmalige
link die naar je adres wordt gestuurd), een wachtwoord, of de single sign-on van de organisatie
waar de installatie die gebruikt. De aanmeldpagina registreert ook een nieuw account. Elk toernooi
hoort bij het account dat het heeft aangemaakt. De desktopversie heeft geen accounts: die meld je aan als de
eigenaar van die computer.

**Accountmenu** (je naam of adres, rechtsboven):

- **Instellingen** (alleen online): de accountpagina.
- **Functies**: de schakelaars van de nationale functies (hieronder).
- **Afmelden** (alleen online).

### De accountpagina {#the-account-page}

Account, **Instellingen** (`/users/settings`). Eén pagina met een sectie voor elk van:

| Sectie | Wat het doet |
| --- | --- |
| Profiel | Een weergavenaam, die in plaats van het adres getoond wordt in het auditlogboek, de geschiedenis, deellijsten en uitnodigingen. |
| Aanmelden en beveiliging | Het adres wijzigen (een bevestigingslink gaat naar het nieuwe), het wachtwoord instellen of wijzigen, de browsers bekijken die aangemeld zijn, en *Afmelden* voor één of *Overal elders afmelden*. |
| Voorkeuren | Taal, kleurthema en accent, bewaard op het account zodat ze je naar een andere computer volgen. |
| Nieuwe toernooien | Waarmee het formulier Nieuw toernooi begint: systeem, rondes, format, speeltempo, plaats, federatie, organisator en hoe rondes gepubliceerd worden. |
| Functies van de federatie | De schakelaars hieronder. |
| Je gegevens | Één zip met je accountgegevens en een back-up van elk toernooi dat je kunt openen. |
| Account verwijderen | Bevestiging door te typen; geweigerd zolang het account een toernooi bezit (in de lijst, gearchiveerd of in de prullenbak). |

Het wijzigen van het adres of wachtwoord, het beëindigen van sessies, alles downloaden en het verwijderen van het account vragen om een recente aanmelding (binnen de laatste twintig minuten);
je wordt naar de aanmeldpagina gebracht en weer teruggestuurd. Accounts op de single sign-on van een organisatie
bewaren het adres en wachtwoord bij de organisatie.

### Nationale functies {#national-features}

Account, **Functies**. De onderdelen van het programma die bij één federatie horen, zijn aparte schakelaars, allemaal standaard uit. Op dit moment horen ze bij het Belgische pakket: de synchronisatie van de nationale ratinglijst, de nationale spelerszoekfunctie, de bulkupdate van clubs, SWAR-import, SWAR-export, de SWAR-resultatenpagina, de voorvertoning van de volgende ronde en de bye-voorkeuren. Een arbiter buiten België ziet er nooit één van. Een functie uitschakelen verbergt alleen de bediening: een toernooi dat ze gebruikte, behoudt al zijn gegevens.

### Grenzen op een gedeelde server {#limits-on-a-shared-server}

Een server wordt gedeeld door elk account erop, dus voorkomt hij dat één account alles inneemt. De grenzen zijn ruim; een gewoon toernooi komt ze nooit tegen. De desktopversie heeft ze niet.

| Wat | Grens |
| --- | --- |
| Toernooien die één account bezit | 200 (de prullenbak telt niet mee) |
| Bestanden ingelezen op de pagina Toernooien (back-up, TRF, SWAR, overdracht, *Dupliceren*) | 20 per uur per account |
| Nieuwe telefooncodes ([Invoer per telefoon](07-results.md)) | 40 per uur per account |
| Rondes die tegelijk gepaard worden, op de hele server | 2 |
| Tijd die één paring mag duren | 3 minuten |

De beheerder van de server kan het aantal toernooien, het aantal rondes dat tegelijk gepaard wordt en de tijdslimiet aanpassen. Is de server al bezig met andere toernooien, dan wacht een ronde van een Zwitsers teamtoernooi op zijn beurt en meldt de knop dat ze in de wachtrij staat; een individuele ronde die niet binnen enkele seconden kan beginnen, meldt dat de engine bezig is, en wie de knop even later opnieuw indrukt, paart ze alsnog. Een ronde die al gepaard wordt, vanuit een ander tabblad of door een collega-arbiter, wordt geen tweede keer gepaard. Een paring die aan de tijdslimiet gestopt of geweigerd wordt, laat niets achter: de ronde wacht nog altijd om gepaard te worden.

## Een toernooi delen {#sharing-a-tournament}

De eigenaar kan andere arbiters uitnodigen. Instellingen, **Toernooi**, kaart
**Delen / Team**: voer een e-mailadres in en **Medewerker toevoegen**.

- De uitnodiging verleent op zich geen toegang. De persoon ontvangt een e-mail
  met een link (`/invites/…`) en moet aangemeld zijn met dat adres en op **Aanvaarden** (of **Weigeren**) drukken. Openstaande uitnodigingen worden ook op de pagina Toernooien getoond, met de rol waarvoor je uitgenodigd bent; weigeren vraagt eerst om bevestiging. Als de eigenaar het toernooi intussen verwijderd heeft, zegt de link dat en kan er niets aanvaard worden. Als de e-mail niet verstuurd kon worden, toont de pagina de link om met de hand door te geven. Heb je de uitnodiging al aanvaard, dan werkt de link niet meer - hij is goed voor een keer aanvaarden, en wie hem opnieuw opent leest dat hij gebruikt is - en staat het toernooi op je pagina Toernooien; ben je aangemeld met een ander adres dan het uitgenodigde, dan biedt de pagina **Afmelden en van account wisselen** aan.
- Een medewerker die als **Bewerker** is uitgenodigd, kan alles wat de eigenaar kan, behalve medewerkers beheren en het toernooi verwijderen. Wie als **Arbiter** is uitgenodigd, krijgt resultaten en incidenten op een telefoon en verder niets ([Arbiters met een eigen account](07-results.md#arbiters-with-their-own-account)). De eigenaar wijzigt de rol met de keuzelijst naast de naam, voor of na het aanvaarden, en kan **Uitnodiging opnieuw sturen** zolang ze openstaat (dezelfde link, hoogstens een keer per minuut).
- Iedereen ziet wijzigingen zodra ze gebeuren: wanneer een collega een ronde paart of een resultaat invoert, worden je pagina's vanzelf bijgewerkt. Ging het om een ronde (gepaard, ongedaan gemaakt, opnieuw gepaard, gepubliceerd of weer ingetrokken) dan meldt een kort bericht op de pagina Paringen of Spelers dat, bijvoorbeeld "Ronde 4 is zojuist elders gepaard"; wie het zelf deed hoort niets, en het bericht noemt nooit een persoon. Dat geldt ook voor het auditspoor: een regel die wordt weggeschreven terwijl je het open hebt staan verschijnt binnen een ogenblik, op de pagina en met het filter waar je naar keek, en elke medewerker ziet dezelfde regels als de eigenaar.
- De eigenaar kan een medewerker verwijderen; een medewerker kan een gedeeld toernooi **Verlaten** vanuit de lijst. Hoe dan ook worden de codes voor zaalboxen die die persoon voor het toernooi maakte samen met die persoon ingetrokken ([Live borden](17-live-boards.md)), en een code werkt alleen zolang wie hem maakte het toernooi nog kan openen.

## De lijst met toernooien {#the-tournament-list}

**Toernooien** toont elk toernooi met zijn paringssysteem, aantal spelers, data en status. Elke rij heeft één menu **Meer** met deze acties
(de naam opent nog steeds het toernooi; **Verwijderen** of **Verlaten** staat
onderaan, in het rood):

| Actie | Wat het doet |
| --- | --- |
| Exporteren | Het toernooi als JSON-bestand ([Importeren en exporteren](12-import-export.md)). |
| Kopiëren | Een heel nieuw toernooi met de naam *Kopie van …*, met alles erin (instellingen, spelers, rondes, resultaten), van jou als eigenaar. Het is niet gepubliceerd en heeft geen medewerkers. |
| Archiveren | Maakt het toernooi alleen-lezen (er kunnen geen rondes meer gepaard worden en er verandert niets); *Dearchiveren* maakt dat ongedaan. De pagina zegt hoeveel uitgestelde partijen nog niet gespeeld zijn. |
| Verwijderen | Verplaatst het toernooi naar de **Prullenbak** nadat je `DELETE` hebt getypt. |
| Overdragen / Teruggeven / Terughalen | Zie hieronder. |
| Verlaten | Voor een gedeeld toernooi dat niet van jou is. |

De tabel **Gearchiveerd** onder de lijst heeft per rij hetzelfde menu **Meer**, met *Exporteren*, *Dearchiveren* en, onderaan in het rood, *Verwijderen* of *Verlaten*.

De **Prullenbak** toont verwijderde toernooien, met de datum waarop ze verwijderd zijn; **Herstellen** brengt er één terug. Verwijderen, herstellen en definitief verwijderen tonen elk een melding met de naam van het toernooi.

> [!WARNING]
> **Definitief verwijderen** haalt een toernooi voorgoed uit de prullenbak (na bevestiging).

Een toernooi met nog openstaande uitgestelde partijen toont dat de standen voorlopig zijn.

## Overdracht: een toernooi verplaatsen tussen twee computers {#hand-off-moving-a-tournament-between-two-computers}

Een overdracht verplaatst een toernooi van de ene kopie van het programma naar de andere, bijvoorbeeld van een server naar de eigen laptop van de arbiter op de locatie, als een **uitcheck**: het toernooi is op precies één plek tegelijk live. Er wordt niets samengevoegd, omdat twee kopieën die allebei resultaten hebben ingevoerd, niet te verzoenen zijn.

1. Op de computer waar het toernooi staat, **Overdragen**: typ waar het naartoe gaat (*de clublaptop*), en druk op **Overdragen en het bestand downloaden**. Het toernooi op deze computer wordt **alleen-lezen**, met een banner op elke pagina die zegt waar het naartoe is gegaan en een knop **Terughalen**; je kunt het nog wel bekijken, afdrukken en exporteren. Het bestand wordt gedownload.
2. Op de andere computer, **Een overdracht ontvangen** en kies het bestand. Het toernooi is daar live en gemarkeerd als *in bruikleen*.
3. Wanneer het evenement voorbij is, op de tweede computer **Teruggeven**: het maakt een *retourbestand* aan en vergrendelt die kopie.
4. Op de eerste computer, **Terughalen** met het retourbestand: de kopie hier wordt vervangen door wat op de andere computer is gespeeld, en ontgrendeld. Eerst wordt een herstelpunt van de bevroren kopie bewaard; kan dat niet, dan wordt niets vervangen.

Wat meereist: de instellingen, spelers, rondes, resultaten, byes, teams, verboden paringen en paringsregels, het auditlogboek en de registratie van wat naar het ratingbureau is verstuurd.
Wat niet meereist: de herstelpunten, de telefoons die voor het invoeren van resultaten zijn ingeschreven, en de medewerkers, die aankomen als openstaande uitnodigingen. Een overdrachtsbestand kan ook geopend worden als een gewone back-up.

> [!WARNING]
> Terwijl een toernooi is overgedragen, wordt **Versturen…** voor het ratingrapport geweigerd op de vergrendelde kopie, zodat maar één computer kan versturen.

## Back-ups en herstelpunten {#backups-and-restore-points}

- **Herstelpunten** zijn kopieën van één toernooi, automatisch gemaakt vóór een actie die moeilijk ongedaan te maken is, en met de hand: Geavanceerd, **Geschiedenis** ([Categorieën, normen en de tools van Geavanceerd](11-categories-and-norms.md)).
- **Back-ups van de hele database** worden ongeveer één keer per dag door het programma gemaakt (de eerste enkele minuten nadat het programma start, als de nieuwste ouder is dan een dag) en 30 dagen bewaard. Ze bevatten de toernooien, spelers, resultaten, snapshots en instellingen, niet de gedownloade ratinglijsten (die worden opnieuw opgehaald). **Verbindingen**, sectie *Back-ups* toont ze (*Gemaakt*, *Grootte*, **Downloaden**) en heeft **Nu back-up maken**. De naam van de map met de oudere back-ups wordt daar ook getoond.
- Instellingen, **Exporteren** en de knop **Alles exporteren (JSON)** op de pagina Toernooien zijn back-ups die je bewaart waar je wilt.

> [!TIP]
> Zorg vóór een belangrijk evenement dat er een actuele back-up bestaat en dat je die kunt vinden.

## Verbindingen (de pagina van de beheerder) {#connections-the-administrator-s-page}

**Verbindingen** is voor de persoon die de installatie beheert (op een desktopkopie bent dat jij).
Ze toont de FIDE-database en de nationale lijst met hun update-knoppen, de versie, de back-ups, de updatecontrole (aan of uit) en de verbinding met de uitslagensite ([Spelers en ratinglijsten](04-players-and-ratings.md), [Publiceren](14-publishing.md)). Op een server kan de pagina door een ondersteuningsrol gelezen worden, maar wijzigingen worden alleen door een beheerder gedaan.
