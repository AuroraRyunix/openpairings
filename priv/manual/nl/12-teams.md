# Ploegentoernooien

Een ploegentoernooi is een toernooi met als format **Zwitsers (ploegen)** of **Rondetoernooi
(ploegen)**: vink **Ploegentoernooi** aan wanneer u het aanmaakt. Ploegen spelen wedstrijden; een
wedstrijd is een reeks individuele partijen, bord tegen bord. De individuele partijen
zijn overal elders gewone partijen (uitslagen, spelerskaarten, het FIDE-ratingrapport), en
de ploegenlaag is erop gebouwd.

Keizer kan geen ploegentoernooi zijn.

## Opzetten {#setting-up}

1. Maak het toernooi aan met *Ploegentoernooi* aangevinkt.
2. **Ploegen** (een tabblad naast Spelers, alleen getoond bij ploegentoernooien): voeg elke ploeg toe met een
   naam, een optionele korte naam voor smalle kolommen (die staat bij de tiebreakberekening en
   wordt niet gepubliceerd) en een optionele captain. Een ploeg kan worden verwijderd zolang ze in geen
   enkele ronde zit; een ploeg die in een gepaarde wedstrijd zit, wordt in plaats daarvan teruggetrokken.
3. Registreer de spelers zoals gewoonlijk op de pagina Spelers, en zet dan elk van hen op een
   ploeg vanaf de kaart van de ploeg. **De volgorde van een opstelling is de bordvolgorde**:
   bord 1 eerst. De pijltjes verplaatsen een speler naar een hoger of lager bord; *Verwijderen*
   haalt hem van de ploeg af. Spelers boven de wedstrijdgrootte worden gemarkeerd als *reserve*.
4. **Borden per wedstrijd** (op de pagina Ploegen; standaard 4) wordt vastgelegd wanneer ronde 1
   gepaard wordt.
5. **De volgorde van de ploegen.** De volgorde van de kaarten wordt de paringnummers van de ploegen
   wanneer ronde 1 gepaard wordt. Verplaats ploegen met de pijltjes of druk op **Rangschikken op rating**.
   Ploegen die u niet zelf verplaatst heeft, worden gerangschikt op rating wanneer ronde 1 gepaard wordt.
   Hoe de rating van een ploeg berekend wordt, is de optie *Ploegrating voor de volgorde van de ploegen* op de pagina Opties:
   de standaard (olympiaderegel) is het gemiddelde van de hoogst gerate spelers, één per bord; de
   alternatieven zijn het gemiddelde van de eerste borden in bordvolgorde, het
   gemiddelde van de hele opstelling, of een rating die u per ploeg intypt. De rating van een ploeg
   kan ook op haar kaart ingetypt worden, en die wint dan. Een ongerate speler telt mee met de rating
   ingesteld bij *Rating van een ongerate speler* (standaard 1400).
6. **Wedstrijdpunten** (Instellingen, Puntentelling): standaard 2, 1, 0. Een competitie die 3, 1, 0
   scoort, past ze hier aan. Partijpunten tellen de bordresultaten.
7. **Tiebreaks** (Instellingen, Toernooi): een ploegentoernooi krijgt de ploegtiebreaks aangeboden. De
   FIDE-standaard is MP, GP, DE, BB, SB.

![De pagina Ploegen met ploegkaarten, opstellingen in bordvolgorde en de instelling Borden per wedstrijd](screenshots/12-teams-page.png "De pagina Ploegen: opstellingen in bordvolgorde")

Elke actie op de pagina Ploegen is een gewone knop met een gesproken naam, en het
resultaat wordt aangekondigd.

### Opstellingen {#line-ups}

Opties, *Opstellingen*: **Verplicht** (de standaard en de FIDE-procedure): een ploeg speelt met de
spelers van haar opstelling in bordvolgorde, een reserve schuift op voor een afwezige speler, en een
bord dat een ploeg niet kan bezetten is een forfaitoverwinning voor de tegenstander.

> [!NOTE] Optioneel: ploegen paren zonder spelers
> Sommige competities en schoolevenementen registreren alleen wedstrijdscores. De wedstrijden worden
> gepaard zonder spelers, en een wedstrijd kan gegeven worden als een *Wedstrijdscore* (bijvoorbeeld 2½-1½ op vier
> borden) die het programma op de borden schrijft. Een wedstrijd met lege plaatsen is geen
> gerate partij en wordt aan FIDE gerapporteerd met een waarschuwing op de pagina Exporteren.

> [!FIDE]
> In FIDE-modus liggen de opstellingen en bordvolgordes vast na ronde 1; een nieuwe speler kan
> nog wel onderaan een ploeg als reserve worden toegevoegd.

## Paren {#pairing}

**Rondetoernooi (ploegen).** *Het hele toernooi paren* paart elke ronde in één keer vanuit de
Berger-tabel. De ploeg die eerst genoemd wordt, heeft Wit op bord 1 en op elk oneven bord
en Zwart op de even borden; de kleur van een ploeg in de wedstrijd is de kleur
van haar bord 1.

**Zwitsers (ploegen).** Het programma paart elke ronde ploeg tegen ploeg volgens de regels van
FIDE C.04.6 (februari 2026).

> [!FIDE] C.04.6 (februari 2026)
> Wedstrijdpunten
> zijn de primaire score, partijpunten beslissen de kleuren, de eerste kleur wordt bij loting
> getrokken. De door de paring toegekende bye scoort een gelijkspel in de wedstrijd (wedstrijd- en partijpunten
> worden op de pagina Puntentelling ingesteld).

Een ploegen-Zwitsers dat al speler voor speler gepaard was in een eerdere versie, gaat op die manier verder.

Elke paring is een **wedstrijd**. De pagina Paringen toont boven de borden een tabel *Wedstrijden - ronde N*:
wedstrijdnummer, aantal borden, de ploegen, de partijpuntenscore tot nu toe, de wedstrijdpunten zodra elk bord
een uitslag heeft, een link naar de opstellingen van de wedstrijd (*Opstellingen*) en de bediening
**Forfait bij beslissing**.

- *Opstellingen*: de pagina van een wedstrijd bepaalt wie op welk bord speelt; een opstelling
  behoudt de bordvolgorde van de ploeg; ze kan alleen gewijzigd worden voordat het eerste resultaat
  van de wedstrijd is ingevoerd.
- *Forfait bij beslissing*: *Aan ploeg A* / *Aan ploeg B* maakt elk bord van de wedstrijd het
  forfaitresultaat van die ploeg, en *Geen van beide* registreert een dubbel forfait (beide verliezen). *Beslissing intrekken* herstelt de oude
  resultaten. Eerst wordt een herstelpunt bewaard.
- Een bord dat met de hand is toegevoegd (twee spelers uit de lijst van niet-spelenden) sluit aan bij de
  wedstrijd van hun ploegen wanneer het tafelnummer, de kleuren en de bordvolgordes passen; past het niet,
  dan wordt het gemarkeerd als **geen ploeg** en telt het voor geen enkele ploeg totdat u het een bord van
  de wedstrijd maakt.

Een ploeg kan op haar kaart voor een ronde als **afwezig als ploeg** gemarkeerd worden (vóór de ronde gepaard
is); een ploeg die zich terugtrekt, wordt in de rangschikking getoond als *teruggetrokken, uitslagen niet
geteld* (rondetoernooi, minder dan 50% gespeeld, FIDE Algemeen Reglement 6.6).

## Uitslagen en rangschikking {#results-and-standings}

Uitslagen worden per bord ingevoerd op de pagina Paringen, zoals in elk toernooi
([Uitslagen](07-results.md)). De ploegenrangschikking (pagina Stand) toont de
rangschikking, de ploeg, gespeelde wedstrijden, gewonnen-gelijk-verloren, wedstrijdpunten en de
ploegtiebreaks, elk met zijn berekening (voor elke ronde de tegenstander en wat die waard was, een forfait,
een bye). De pagina toont ook **bordstatistieken**: per boordnummer de spelers die daar zaten, met
partijen, punten, percentage en prestatie.

![De ploegenrangschikking met wedstrijdpunten, partijpunten en de berekening van een ploegtiebreak](screenshots/12-team-standings.png "Ploegenrangschikking met de berekening van de tiebreak")

### Ploegtiebreaks {#team-tie-breaks}

MP (wedstrijdpunten), GP (partijpunten), DE (directe ontmoeting), BB (bordpunten gewogen per bord), SB, BH:GP, EMGSB, EGMSB, EGGSB, EDE (uitgebreide directe ontmoeting), TBR (resultaten op het topbord), BBE (eliminatie op het laagste bord), SSSC.
De behandeling van niet-gespeelde partijen van C.07 artikel 16 geldt voor byes, forfaitwedstrijden
en teruggetrokken ploegen in een ploegen-Zwitsers.

## Afdrukken {#printing}

De pagina Afdrukken somt **ploegparingen**, **ploegrangschikkingen**, **ploegkruistabel**,
**wedstrijdformulieren**, **ploegopstellingen** en **bordprijzen** op
([Afdrukken](09-printing.md)). De pagina Stand heeft dezelfde als knoppen:
*Kruistabel*, *Wedstrijdformulieren*, *Opstellingen*, *Bordprijzen*.

## Rapporteren en publiceren {#reporting-and-publishing}

Het TRF26-rapport bevat de ploegen en hun bordvolgordes (records 310 en
013, 362, 320 voor de bye en 330 voor een forfaitwedstrijd), en een ploegenbestand kan
opnieuw geïmporteerd worden, waarbij de wedstrijden worden herbouwd waar de borden dat
eenduidig aangeven. Ploegentoernooien worden gepubliceerd op OpenResults net als andere
([Publiceren](14-publishing.md)).

> [!NOTE]
> Ploegevenementen hebben uitgebreidere regels voor forfaits, opstellingen en terugtrekkingen
> dan hier vermeld. Als het programma iets weigert, zegt de melding waarom.
