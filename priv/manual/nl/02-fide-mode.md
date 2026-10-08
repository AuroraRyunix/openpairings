# FIDE-modus

FIDE-modus betekent dat het toernooi wordt behandeld zoals de reglementen van
FIDE voor paring en rapportage voorschrijven. Er is geen schakelaar om hem aan
te zetten: **elk nieuw toernooi staat in de FIDE-modus**, en blijft daarin tot
de arbiter er bewust uit gaat of een instelling wijzigt die de FIDE-regels niet
toestaan.

## Wat de FIDE-modus u geeft {#what-fide-mode-gives-you}

Een nieuw toernooi begint met de instellingen die de FIDE-regels beschrijven:

- Zwitserse paring volgens het FIDE Dutch-systeem, rondetoernooi volgens
  Berger-tabellen.
- De beginkleur wordt door loting bepaald (C.04.3 5.1), tenzij u die zelf
  instelt.
- Puntentelling 1 - ½ - 0, waarbij de door de paring toegekende bye als winst
  telt.
- De standaard tiebreaks van FIDE voor het type toernooi (zie
  [Rangschikking en tiebreaks](08-standings-and-tiebreaks.md)).
- De regels van [artikel 16 van C.07](08-standings-and-tiebreaks.md) voor
  partijen die niet zijn gespeeld.

## Wat de FIDE-modus weigert {#what-fide-mode-refuses}

Zodra de eerste ronde is gepaard, **vergrendelt** de FIDE-modus de instellingen
die bepalen wat al is gebeurd. De vergrendelde instellingen zijn: het aantal
rondes (en het aantal cycli van een rondetoernooi), de punten voor winst, remise
en verlies, de matchpunten van een ploegentoernooi, de waarde van de door de
paring toegekende bye, de acceleratie, het paringssysteem en de tiebreaklijst.
Hun velden op de instellingenpagina's zijn grijs. Er is in de FIDE-modus geen
knop *Ontgrendelen* voor deze velden (buiten de FIDE-modus heeft de andere
instellingen die na ronde 1 vergrendelen die wel).

De FIDE-modus sluit ook oude rondes af.

> [!FIDE] C.04.2 4.3
> Een fout resultaat, een foute paring of een foute kleur kan alleen worden
> gecorrigeerd in de laatste twee gespeelde rondes.

Met ronde 7 gespeeld en ronde 8 gepaard, kunnen de rondes 6, 7 en 8 worden
gewijzigd. Ronde 5 en eerder worden geweigerd, met de melding dat een later
ontdekte fout na het toernooi wordt gecorrigeerd, en alleen in het
ratingrapport. Het resultaat van een uitgestelde partij kan altijd worden
ingevoerd.

In een ploegentoernooi liggen de selecties van de ploegen en de bordvolgorden
vast zodra ronde 1 is gepaard (een nieuwe speler kan nog wel als reserve
onderaan een ploeg worden toegevoegd).

De FIDE-modus maakt **geen TRF en geen eindstand zolang een uitgestelde partij
geen resultaat heeft**. Elke TRF-download, het bestand van *Versturen…* en de
stand na de laatste ronde worden geweigerd, met de openstaande partijen erbij.
Voer hun resultaten in, of leg een partij vast als **niet gespeeld in dit
toernooi** (Instellingen, Exporteren); dat haalt het toernooi uit de
FIDE-modus. Zie [Uitgestelde partijen](07-results.md).

## Instellingen die een toernooi uit de FIDE-modus halen {#settings-that-take-a-tournament-out-of-fide-mode}

> [!FIDE] Afwijkingen van FIDE
> Enkele instellingen veranderen wie tegen wie speelt, of wat een partij waard
> is, op een manier die de FIDE-regels niet beschrijven. Als u er een kiest,
> verlaat het toernooi de modus.

De instellingen zijn:

- het paringssysteem **Keizer** (het is geen FIDE-systeem);
- **Elke categorie apart paren**, waarbij elke categorie als afzonderlijk
  toernooi wordt gepaard;
- het **Zwitserse matchformaat** (elke paring twee keer achter elkaar gespeeld,
  met omgekeerde kleuren);
- **uitgestelde partijen** die voor beide spelers iets anders tellen dan remise;
- een puntentelling waarbij een remise meer waard is dan een winst, of de bye
  meer dan een winst.

De instellingenpagina's zeggen welke instellingen dit doen, met een link naar
de instelling. Er wordt niets geweigerd, maar zolang het toernooi in de
FIDE-modus zit, **vraagt het programma altijd eerst** (zie *De FIDE-modus
verlaten* hieronder). De ronde waarin het toernooi voor het eerst de modus
verliet, wordt voor het rapport vastgelegd.

Andere keuzes van de organisator die de paring veranderen zonder een FIDE-regel
te zijn (een uitsluiting of voorkeur voor een bye, wensen voor paringen "enkel
indien mogelijk", extra punten die in de paring meetellen), worden ook
vastgelegd voor de ronde waarin ze veranderden, en het FIDE-rapport somt die
rondes op. Ze stellen dezelfde vraag wanneer een paring daardoor daadwerkelijk
zou verschuiven. Zie [Byes en afwezigheid](05-byes-and-absences.md) en
[Een ronde paren](06-pairing.md).

Zaken die de eigen FIDE-regels toestaan, zijn geen afwijkingen en veranderen de
modus niet: andere puntwaarden voor winst, remise en verlies (zolang geen
partij minder oplevert dan een lager resultaat), een halvepuntsbye, extra
punten, de keuze van tiebreaks, een met de hand vastgestelde rangschikking, en
het met de hand wijzigen van de borden van een ronde ([Een ronde paren](06-pairing.md):
handmatige wijzigingen zijn een handmatige aanpassing van de paring die de
reglementen voorzien, dus ze beëindigen de FIDE-modus niet; een verschil met de
paringscontroleur wordt in het rapport vastgelegd).

## De FIDE-modus verlaten {#leaving-fide-mode}

Er zijn twee manieren om eruit te gaan, en beide stellen dezelfde twee vragen.

- **Bewust:** Instellingen, **FIDE**, **FIDE-modus verlaten…**
- **Door een handeling die in de FIDE-modus niet is toegestaan.** Dat zijn: een
  instellingenpagina (Opties, Puntentelling) opslaan met een instelling uit de
  lijst hierboven (Keizer, het Zwitserse matchformaat, uitgestelde partijen
  anders geteld, een remise of de bye meer waard dan een winst); het inschakelen
  van *Elke categorie apart paren* op de pagina Categorieën; en op een knop
  paren drukken wanneer de ronde, zoals ze zou worden gepaard, wordt verschoven
  door een zachte regel (een wens "enkel indien mogelijk"), door een uitsluiting
  of voorkeur voor een bye, of door extra punten die in de paring meetellen; en
  een uitgestelde partij vastleggen als *niet gespeeld in dit toernooi* op de
  pagina Exporteren.

Voordat er iets wordt geschreven, toont het programma het dialoogvenster
*FIDE-modus verlaten?* in twee stappen (dit is de dubbele bevestiging die de
FIDE-checklist voor toernooibehandelaars Niveau 4 noemt):

1. *Dit voldoet niet aan de FIDE-reglementen.* Het somt op wat het toernooi uit
   de FIDE-modus haalt en vraagt of u wilt doorgaan. **Ja, doorgaan** gaat naar
   de tweede vraag; **Annuleren** (of <kbd>Escape</kbd>) sluit het
   dialoogvenster.
2. *In de FIDE-modus blijven?* **Ja, in de FIDE-modus blijven** sluit het
   dialoogvenster; **Nee, FIDE-modus verlaten** voert uit wat u vroeg: de
   instellingen worden opgeslagen, de schakelaar wordt aangezet, of de ronde
   wordt gepaard.

![Het dialoogvenster FIDE-modus verlaten bij de eerste stap, met een lijst van wat het toernooi uit de FIDE-modus haalt](screenshots/02-leave-fide-mode-dialog.png "De eerste vraag van het dialoogvenster FIDE-modus verlaten")

Annuleren bij beide stappen verandert niets: de instellingen worden niet
opgeslagen en de ronde wordt niet gepaard. De tweede vraag somt op wat verlaten
doet:

- **Het is definitief.** Het toernooi kan nooit meer terug naar de FIDE-modus,
  ook niet als u elke instelling terugzet.
- Het toernooi legt vast vanaf welke ronde het niet in de FIDE-modus zat, en de
  TRF26-kopieën van het rapport zeggen dat in een commentaarregel (`FIDE mode
  exited @ Round N`), zodat wie het bestand controleert weet waar hij nauwkeuriger
  moet kijken. (Het bestand dat *Versturen…* maakt, bevat alleen records, geen
  commentaarregels; zie [Versturen naar FIDE](11-fide-report.md).)
- De vergrendelde instellingen en de afgesloten rondes kunnen daarna worden
  gewijzigd, en het programma stopt niet langer een wijziging die de FIDE-regels
  verbieden.
- Elke pagina van het toernooi toont een regel *Niet in de FIDE-modus*, met een
  link die uitlegt wat dat betekent.

> [!WARNING]
> Verlaat de FIDE-modus alleen voor een evenement dat niemand naar FIDE stuurt:
> een clubkampioenschap met eigen regels, een Keizeravond, of een evenement
> waarbij u iets moet veranderen wat de regels verbieden.

## De FIDE-pagina van de instellingen {#the-fide-page-of-the-settings}

Instellingen, **FIDE** bevat ook de identificaties die het rapport aan FIDE
nodig heeft: het FIDE-toernooi-ID (één voor het hele toernooi, of een ander voor
reeksen rondes), de evenementcode, en het vakje *Dit toernooi is
FIDE-gehomologeerd (gerate/rapporteerbaar)*. Wanneer dat vakje is aangevinkt,
worden door de organisator ingestelde byevoorkeuren niet toegepast (het zijn
geen FIDE-regels), en wordt het toernooi-ID een verplicht veld. De
functionarissen (hoofdarbiter, hulparbiters) en de normgegevens worden ingevoerd
op de pagina Toernooi; zie [Een toernooi instellen](03-tournament-setup.md) en
[Versturen naar FIDE](11-fide-report.md).

![De FIDE-pagina van de instellingen met het toernooi-ID, de evenementcode en het vakje voor homologatie](screenshots/02-settings-fide-page.png "Instellingen, FIDE")
