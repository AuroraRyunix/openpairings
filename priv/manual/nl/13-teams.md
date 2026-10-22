# Teamtoernooien

Een teamtoernooi is een toernooi met als format **Zwitsers (teams)** of **Rondetoernooi
(teams)**: vink **Teamtoernooi** aan wanneer je het aanmaakt. Teams spelen wedstrijden; een
wedstrijd is een reeks individuele partijen, bord tegen bord. De individuele partijen
zijn overal elders gewone partijen (resultaten, spelerskaarten, het FIDE-ratingrapport), en
de teamlaag is erop gebouwd.

Keizer kan geen teamtoernooi zijn.

## Opzetten {#setting-up}

1. Maak het toernooi aan met *Teamtoernooi* aangevinkt.
2. **Teams** (een tabblad naast Spelers, alleen getoond bij teamtoernooien): voeg elk team toe met een
   naam, een optionele korte naam voor smalle kolommen (die staat bij de tiebreakberekening en
   wordt niet gepubliceerd) en een optionele captain. Een team kan worden verwijderd zolang het in geen
   enkele ronde zit; een team dat in een gepaarde wedstrijd zit, wordt in plaats daarvan teruggetrokken.
3. Registreer de spelers zoals gewoonlijk op de pagina Spelers, en zet dan elk van hen op een
   team vanaf de kaart van het team. **De volgorde van een opstelling is de bordvolgorde**:
   bord 1 eerst. De pijltjes verplaatsen een speler naar een hoger of lager bord; *Verwijderen*
   haalt hem van het team af. Spelers boven de wedstrijdgrootte worden gemarkeerd als *reserve*.
4. **Borden per wedstrijd** (op de pagina Teams; standaard 4) wordt vastgelegd wanneer ronde 1
   gepaard wordt.
5. **De volgorde van de teams.** De volgorde van de kaarten wordt de paringnummers van de teams
   wanneer ronde 1 gepaard wordt. Verplaats teams met de pijltjes of druk op **Rangschikken op rating**.
   Teams die je niet zelf verplaatst heeft, worden gerangschikt op rating wanneer ronde 1 gepaard wordt.
   Hoe de rating van een team berekend wordt, is de optie *Teamrating voor de volgorde van de teams* op de pagina Opties (geavanceerd):
   de standaard (olympiaderegel) is het gemiddelde van de hoogst gerate spelers, één per bord; de
   alternatieven zijn het gemiddelde van de eerste borden in bordvolgorde, het
   gemiddelde van de hele opstelling, of een rating die je per team intypt. De rating van een team
   kan ook op zijn kaart ingetypt worden, en die wint dan. Een ongerate speler telt mee met de rating
   ingesteld bij *Rating van een ongerate speler* (standaard 1400).
6. **Matchpunten** (Instellingen, Puntentelling): standaard 2, 1, 0. Een competitie die 3, 1, 0
   scoort, past ze hier aan. Partijpunten tellen de bordresultaten. In de FIDE-modus kun je ze
   niet meer wijzigen zodra ronde 1 gepaard is: het reglement van de competitie legt de
   puntentelling vooraf vast (C.04.6 art. 1.2.1).
7. **Tiebreaks** (Instellingen, Toernooi): een teamtoernooi krijgt de teamtiebreaks aangeboden. De
   FIDE-standaard is MP, GP, DE, BB, SB.

Elke actie op de pagina Teams is een gewone knop met een gesproken naam, en het
resultaat wordt aangekondigd.

### Opstellingen {#line-ups}

Opties, *Opstellingen*: **Verplicht** (de standaard en de FIDE-procedure): een team speelt met de
spelers van zijn opstelling in bordvolgorde, een reserve schuift op voor een afwezige speler, en een
bord dat een team niet kan bezetten is een forfaitoverwinning voor de tegenstander.

> [!NOTE] Optioneel: teams paren zonder spelers
> Sommige competities en schoolevenementen registreren alleen wedstrijdscores. De wedstrijden worden
> gepaard zonder spelers, en een wedstrijd kan gegeven worden als een *Wedstrijdscore* (bijvoorbeeld 2½-1½ op vier
> borden) die het programma op de borden schrijft. Een wedstrijd met lege plaatsen is geen
> gerate partij en wordt aan FIDE gerapporteerd met een waarschuwing op de pagina Exporteren.

> [!FIDE]
> In FIDE-modus liggen de opstellingen en bordvolgordes vast na ronde 1; een nieuwe speler kan
> nog wel onderaan een team als reserve worden toegevoegd.

## Paren {#pairing}

**Rondetoernooi (teams).** *Het hele toernooi paren* paart elke ronde in één keer vanuit de
Berger-tabel. Het team dat eerst genoemd wordt, heeft Wit op bord 1 en op elk oneven bord
en Zwart op de even borden; de kleur van een team in de wedstrijd is de kleur
van zijn bord 1.

**Zwitsers (teams).** Het programma paart elke ronde team tegen team volgens de regels van
FIDE C.04.6 (februari 2026).

> [!FIDE] C.04.6 (februari 2026)
> Wedstrijdpunten
> zijn de primaire score, partijpunten beslissen de kleuren, de eerste kleur wordt bij loting
> getrokken. De door de paring toegekende bye scoort een gelijkspel in de wedstrijd (wedstrijd- en partijpunten
> worden op de pagina Puntentelling ingesteld).

Een teams-Zwitsers dat al speler voor speler gepaard was in een eerdere versie, gaat op die manier verder.

Elke paring is een **wedstrijd**. De pagina Paringen toont boven de borden een tabel *Wedstrijden - ronde N*:
wedstrijdnummer, aantal borden, de teams, de partijpuntenscore tot nu toe, de wedstrijdpunten zodra elk bord
een resultaat heeft, een link naar de opstellingen van de wedstrijd (*Opstellingen*) en de bediening
**Forfait bij beslissing**.

- *Opstellingen*: de pagina van een wedstrijd bepaalt wie op welk bord speelt; een opstelling
  behoudt de bordvolgorde van het team; ze kan alleen gewijzigd worden voordat het eerste resultaat
  van de wedstrijd is ingevoerd.
- *Forfait bij beslissing*: *Aan team A* / *Aan team B* maakt elk bord van de wedstrijd het
  forfaitresultaat van dat team, en *Geen van beide* registreert een dubbel forfait (beide verliezen). *Beslissing intrekken* herstelt de oude
  resultaten. Eerst wordt een herstelpunt bewaard. De borden van een beslechte wedstrijd tonen het
  resultaat van de beslissing en krijgen geen eigen resultaat: trek eerst de beslissing in.
- Een dubbel forfait dat de paring zelf schreef (beide teams afwezig in de ronde, of geen van
  beide kan een speler opstellen) heeft geen oude resultaten om te herstellen. *Beslissing
  intrekken* stelt de wedstrijd dan opnieuw op, zoals de paring dat nu zou doen - markeer dus eerst
  het team of zijn spelers als beschikbaar. Zolang niemand opgesteld kan worden, wordt het
  geweigerd.
- Een bord dat met de hand is toegevoegd (twee spelers uit de lijst van niet-spelenden) sluit aan bij de
  wedstrijd van hun teams wanneer het tafelnummer, de kleuren en de bordvolgordes passen; past het niet,
  dan wordt het gemarkeerd als **geen team** en telt het voor geen enkel team totdat je het een bord van
  de wedstrijd maakt.

**Een wedstrijd die als geheel forfait is.** Instellingen - Puntentelling - *Een wedstrijd die als geheel
forfait is* bepaalt hoeveel partijpunten zo'n wedstrijd oplevert voor het team dat ze krijgt toegewezen:
*Eén per opgesteld bord* (de standaard: een team dat zeven van de acht borden bezette, wint met 7-0, en een
team zonder opstelling met 0-0 - de wedstrijdpunten kloppen in beide gevallen) of *Het volledige aantal
borden* (8-0 op acht borden, wat er ook was opgesteld, voor reglementen die het resultaat van een teamforfait
vastleggen). Het geldt voor een wedstrijd die bij beslissing forfait werd verklaard voordat er een partij
van gespeeld was, en voor een wedstrijd tegen een team dat als team niet aan de ronde deelneemt. Een
wedstrijd die forfait werd verklaard nadat er partijen gespeeld waren, behoudt de som van haar borden, en
één forfaitbord blijft altijd het punt van één bord. De extra partijpunten zijn van het team: geen enkel
bordresultaat verandert en de bordstatistieken van de spelers blijven wat ze waren. De instelling gaat mee
in de export van het toernooi; een TRF heeft er geen record voor, dus een toernooi dat uit een TRF wordt
ingelezen, staat weer op de standaard.

> [!FIDE] Een wedstrijd die als geheel forfait is
> Puntentelling: in FIDE-modus kan dit na ronde 1 niet meer gewijzigd worden. De standaard is C.07 art.
> 11.1.2 zoals het er staat (partijpunten zijn de som van de punten van de spelers); het volledige aantal is
> het eigen reglement van de competitie.

Een team kan op zijn kaart voor een ronde als **afwezig als team** gemarkeerd worden (vóór de ronde gepaard
is); een team dat zich terugtrekt, wordt in de rangschikking getoond als *teruggetrokken, resultaten niet
geteld* (rondetoernooi, minder dan 50% gespeeld, FIDE Algemeen Reglement 6.6). Trekken twee teams
die nog tegen elkaar moesten spelen zich allebei terug, dan is hun wedstrijd een dubbel forfait,
welk team zich ook eerst terugtrok; zet je een van beide terug, dan krijgt die de forfaitwinst
terug.

## Resultaten en rangschikking {#results-and-standings}

Resultaten worden per bord ingevoerd op de pagina Paringen, zoals in elk toernooi
([Resultaten](07-results.md)). De teamrangschikking (pagina Stand) toont de
rangschikking, het team, gespeelde wedstrijden, gewonnen-gelijk-verloren, wedstrijdpunten en de
teamtiebreaks, elk met zijn berekening (voor elke ronde de tegenstander en wat die waard was, een forfait,
een bye). De pagina toont ook **bordstatistieken**: per boordnummer de spelers die daar zaten, met
partijen, punten, percentage en prestatie.

### Teamtiebreaks {#team-tie-breaks}

MP (wedstrijdpunten), GP (partijpunten), DE (directe ontmoeting), BB (bordpunten gewogen per bord), SB, BH:GP, EMGSB, EGMSB, EGGSB, EDE (uitgebreide directe ontmoeting), TBR (resultaten op het topbord), BBE (eliminatie op het laagste bord), SSSC.
De behandeling van niet-gespeelde partijen van C.07 artikel 16 geldt voor byes, forfaitwedstrijden
en teruggetrokken teams in een teams-Zwitsers.

- **Gewonnen, gelijk, verloren** en de tiebreaks lezen een wedstrijd af aan zijn wedstrijdpunten:
  een wedstrijd toegekend aan een team dat niemand opstelde, staat 0-0 op de borden en is toch
  een (forfait)winst.
- **DE** telt een wedstrijd die zonder partij beslist werd - een forfait of een dubbel forfait -
  alleen in een rondetoernooi mee, waar C.07 art. 15.2 forfaits tot partijen maakt; in een
  teams-Zwitsers is het geen ontmoeting (art. 6.1.1). Het getoonde getal en de volgorde komen
  overeen.
- **BB** telt een bye in een teams-Zwitsers als een winst op elk bord, zoals Board Count dat doet
  (C.07 art. 12), al zijn de partijpunten die van een gelijkgespeelde wedstrijd.

## Afdrukken {#printing}

De pagina Afdrukken somt **teamparingen**, **teamrangschikkingen**, **teamkruistabel**,
**wedstrijdformulieren**, **teamopstellingen** en **bordprijzen** op
([Afdrukken](09-printing.md)). De pagina Stand heeft dezelfde als knoppen:
*Kruistabel*, *Wedstrijdformulieren*, *Opstellingen*, *Bordprijzen*.

## Rapporteren en publiceren {#reporting-and-publishing}

Het TRF26-rapport bevat de teams en hun bordvolgordes (records 310 en
013, 362, 320 voor de bye en 330 voor een forfaitwedstrijd), en een teambestand kan
opnieuw geïmporteerd worden, waarbij de wedstrijden worden herbouwd waar de borden dat
eenduidig aangeven. Teamtoernooien worden gepubliceerd op OpenResults net als andere
([Publiceren](14-publishing.md)).

> [!NOTE]
> Teamevenementen hebben uitgebreidere regels voor forfaits, opstellingen en terugtrekkingen
> dan hier vermeld. Als het programma iets weigert, zegt de melding waarom.
