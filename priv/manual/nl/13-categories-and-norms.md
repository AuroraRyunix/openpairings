# Categorieën, normen en de tools van Geavanceerd

## Categorieën {#categories}

Categorieën verdelen de spelers van een toernooi in groepen voor prijzen, voor aparte
rangschikkingen en, optioneel, voor aparte paring (ratinggroepen zoals U1800,
leeftijdsgroepen zoals 65+, vrouwen).

Instellingen, **Categorieën**:

- **Nieuwe categorienaam** (bijvoorbeeld `U1800` of `65+`) voegt een categorie toe.
- Elke categorie kan een **regel** hebben, elke combinatie van vijf voorwaarden: *rating vanaf*, *rating lager dan*, *leeftijd vanaf*, *jonger dan* en *alleen vrouwen*. Een categorie zonder regel is **handmatig toegewezen**. Geneste, gebande en gecombineerde categorieën kunnen allemaal zo geschreven worden. Leeftijd wordt geteld volgens de FIDE-conventie, per 1 januari van het jaar: de editor toont het geboortejaar dat een grens betekent ("jonger dan 16 = geboren in 2010 of later").
- De knop die categorieën toewijst, vult elke categorie op basis van haar regel en zegt hoeveel spelers het heeft toegewezen, of dat niemand aangepast hoeft te worden.
- Een speler kan in meerdere categorieën zitten. Op de pagina Spelers wijst de categoriecel (rechtsklik of <kbd>Space</kbd>) categorieën één voor één toe, en de kop van die kolom wijst iedereen toe.
- **Prijzen**: een optioneel aantal prijzen per categorie. De rangschikking van die categorie markeert de plaatsen die een prijs winnen. Dit is informatief; het programma verdeelt geen prijzen en past geen regel "één prijs per speler" toe.

Twee schakelaars op de pagina:

- **Elke categorie apart rangschikken**: de pagina Stand krijgt een filter en elke categorie heeft haar eigen rangschikking.
- **Elke categorie apart paren (bèta)**: elke categorie wordt gepaard met haar eigen engine-run en de resultaten worden samengevoegd tot één ronde met doorlopende bordnummers en één paringsformulier. In een rondetoernooi krijgt elke categorie haar eigen Berger-tabel. Na ronde 1 is het vergrendeld.

> [!FIDE] Afwijking van de FIDE-modus
> Elke categorie apart paren behandelt elke categorie als een
> apart toernooi, wat een afwijking is van de FIDE-modus
> ([FIDE-modus](02-fide-mode.md)).

![De instellingenpagina Categorieën met de categorieregels, prijzen en de twee schakelaars](screenshots/13-categories-settings.png "Categorieregels en schakelaars")

## Normen en FIDE-formulieren {#norms-and-fide-forms}

**Geavanceerd**, **Normen** maakt de officiële FIDE-formulieren als Excel-bestanden, ingevuld vanuit het toernooi:

| Formulier | Doel |
| --- | --- |
| **IT3** | het toernooirapport; altijd beschikbaar |
| **FA1 / IA1** | het rapport voor een arbitersnorm (FIDE Arbiter / International Arbiter) voor één kandidaat |
| **IT4** | het titelnormrapport voor de spelers die een titelnorm claimen (tot 40) |

De pagina toont eerst de **FIDE-instellingen** en **Officials & FIDE-rapportgegevens**: hoofdarbiter, organisator, persoon verantwoordelijk voor de paringen, het IT4-evenementtype, link naar de paringspagina op het web, plaatsvervangende arbiters en extra arbiters met e-mailadressen, en speciale opmerkingen voor de IT3. Een banner zegt *Nog niet klaar om bij FIDE in te dienen* zolang iets vereists ontbreekt.

- Voor **FA1/IA1** neemt *Kies een arbiter* de kandidaat uit de officials van het evenement, of typ de naam, het FIDE-ID en de federatie van elke arbiter; er wordt niets opgeslagen.
- Voor **IT4** wordt een speler opgenomen zodra een geclaimde titel voor hem is ingesteld (*Normgegevens bewerken*: de geclaimde titel, de normomschrijving, medaillepercentage, groep, deelnemende federaties, opmerkingen).
- Een **gecombineerd rapport** (festival) voegt meerdere van uw toernooien samen tot één rapport: kies de andere toernooien, één ervan als *hoofdtoernooi* (het levert de kop, het schema en de naam) en download de gecombineerde IT3, FA1 of IA1. Dubbele spelers over toernooien heen worden gedetecteerd.

De formulieren gebruiken de FIDE-huisstijl voor namen (voornaam, ACHTERNAAM in hoofdletters).

![De pagina Normen met de IT3-, FA1/IA1- en IT4-formulieren en de banner Nog niet klaar om bij FIDE in te dienen](screenshots/13-norms-forms.png "Geavanceerd, Normen")

### Normen zonder account {#norms-without-an-account}

Het tabblad **Hulpmiddelen** in de bovenbalk opent een openbare pagina voor arbiters zonder account: upload `.swar`- of `.trf`-bestanden (tot tien, elk 5 MB), vul de officials in, en download de IT3-, FA1- en IA1-formulieren, gecombineerd over de bestanden.
Niets wordt opgeslagen: de bestanden leven alleen in het geheugen zolang u werkt.

## Geschiedenis (herstelpunten) {#history-restore-points}

**Geavanceerd**, **Geschiedenis**. Een herstelpunt is een volledige kopie van het toernooi op één moment. Het programma maakt er automatisch één aan vóór een actie die moeilijk ongedaan te maken is (een ronde paren of ontpaaren, uitslagen uit een bestand importeren, een forfait of score van een wedstrijd, een gewijzigde opstelling, een teruggetrokken ploeg, een overdracht); de nieuwste vijftig worden bewaard. Druk op **Herstelpunt opslaan** (met een optionele naam, bijvoorbeeld *Einde dag 1*) om zelf een punt aan te maken.

**Terug naar dit punt** herstelt het toernooi naar dat moment.

> [!WARNING] Overschrijft live-uitslagen
> Elke uitslag, paring en spelerwijziging die na het punt gemaakt is, verdwijnt, en u moet `RESTORE` intypen om te bevestigen. De pagina somt elke partij op die al naar het ratingbureau is verstuurd en in de hersteld staat niet meer zou voorkomen, en vraagt om een vinkje om toch te herstellen. Herstellen wijzigt alleen de inhoud: niet de eigenaar, niet of het toernooi gearchiveerd is, niet wat gepubliceerd is.

## Auditlogboek {#audit-trail}

**Geavanceerd**, **Auditlogboek**. Elke handeling die iets wijzigt, wordt vastgelegd: wie, wanneer, wat, met de oude en de nieuwe waarde voor een instellingswijziging. De rijen kunnen gefilterd worden (spelers, paringen, instellingen, standen, importen, medewerkers, het toernooi). Het auditlogboek reist mee met een overdracht.

## Paringsverantwoording {#pairing-rationale}

**Geavanceerd**, **Paringsverantwoording** is de uitleg van een gepaarde ronde ([Een ronde paren](06-pairing.md)).

## Badges {#badges}

**Geavanceerd**, **Badges** opent de editor voor accreditatiebadges voor dit toernooi ([Afdrukken](09-printing.md)).
