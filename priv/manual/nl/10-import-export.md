# Importeren en exporteren

OpenPairings leest en schrijft verschillende formaten. Ze verschillen in doel:

| Formaat | Doel | Richting |
| --- | --- | --- |
| TRF26 / TRF16 | Het TRF-rapportbestand van FIDE, voor het ratingkantoor en voor andere paringsprogramma's | exporteren en importeren |
| JSON-back-up | Een getrouwe kopie van een heel toernooi, voor OpenPairings zelf | exporteren en importeren |
| SWAR (`.swar`) | Het opslagbestand van het Belgische SWAR-programma | importeren en exporteren (Belgisch pakket) |
| CSV-resultaten | De resultaten van een ronde, getypt in een spreadsheet | importeren |
| CSV-spelers | De spelerslijst | exporteren |
| PGN | De partijen van het toernooi, zonder zetten | exporteren |
| FIDE-formulieren (Excel) | IT3, FA1, IA1, IT4 | exporteren |

> [!NOTE]
> Importeren overschrijft nooit een bestaand toernooi: elke import maakt een nieuw
> toernooi.

## Importeren {#importing}

Op de pagina **Toernooien** openen de importknoppen een paneel met een bestandskiezer
of een gebied waarin u een bestand kunt slepen.

### TRF-bestand {#trf-file}

**Een TRF-toernooi importeren** leest een `.trf`-bestand in TRF26- of TRF16-formaat en
maakt een volledig toernooi: de kopgegevens (naam, plaats, federatie, datums,
bedenktijd, arbiters, rondedatums), de spelers met hun FIDE-ID's, ratings, titels en
geboortedata, de rondes, de paringen, de resultaten en de byes. De startrangschikking
van het bestand wordt het paringsnummer. Het type van het toernooi wordt uit het
bestand overgenomen (Zwitsers, rondetoernooi, ploegen). Het onbekende resultaat `?`
komt terug als uitgestelde partij. Ploegenbestanden geven de ploegen en hun
bordvolgorden, en de matches van elke ronde die uit de borden kunnen worden afgeleid
(een ronde waarvan de matches onduidelijk zijn, wordt benoemd, niet geraden).

Het programma vertrouwt het bestand niet: het herberekent de punten en somt elke
speler op wier totaal afwijkt van het bestand, en elke ronde van een Zwitsers toernooi
wordt **gecontroleerd op de paringsregels**: een herhaalde partij, twee spelers die
beiden dezelfde kleur verschuldigd waren, een paar dat de eigen verbodsregistratie van
het bestand verbiedt, een tweede door de paring toegekende bye.

**De controlestap.** Er wordt niets geschreven tot u de controle hebt gezien die volgt
op de keuze van het bestand:

- *De versie.* De controle zegt of het bestand als TRF26 of als TRF16 is gelezen. TRF16
  heeft geen records voor het puntensysteem, het type toernooi of de tiebreaks; de
  controle somt dan op wat de import in plaats daarvan heeft gebruikt.
- *De aanpassingen.* Elke plek waar de import iets moest beslissen, wordt vermeld: de
  standaard puntentelling die is gebruikt wanneer het bestand geen puntensysteem heeft,
  het type toernooi dat is overgenomen wanneer de code ontbreekt of onbekend is,
  een Zwitsers toernooi waarvan de code zegt dat het met de editie van 2017 van het
  Nederlandse systeem is gepaard (de rondes blijven zoals gespeeld; de rondes die hier
  worden gepaard, volgen de huidige),
  rondetoernooi-cycli die zijn teruggebracht tot wat het programma speelt, tiebreaks die
  niet in het bestand stonden of die het programma niet berekent, een aantal rondes dat
  is overgenomen uit de rondes die het bestand bevat, deputy-arbiters boven de vierde,
  forfait- en bye-punten van ploegen, extra punten buiten de puntentelling, partijen
  zonder tegenstander die als byes zijn geïmporteerd, en rondes die niet zijn
  gecontroleerd omdat alleen een Zwitsers volgens het Nederlandse systeem dat kan.
- *Symbolen die geen resultaatcode zijn.* Een symbool in een resultaatkolom dat geen
  resultaatcode is (een `5`, een `x`, een `%`) wordt gelezen als een partij met onbekende
  uitslag en geïmporteerd als uitgestelde partij, net als `?`. Elk symbool wordt vermeld
  met de speler, het startnummer, de ronde en het gevonden symbool. Het resultaat van de
  tegenstander in die ronde wordt ook op onbekend gezet, en de lijst zegt dat, omdat beide
  kanten van een partij moeten overeenkomen. Een symbool in een ronde zonder tegenstander
  (`0000`) is geen partij en het bestand wordt nog steeds geweigerd; de melding
  noemt de speler, de ronde en het symbool. Annuleren importeert niets.
- *Uitslagen aangenomen voor de controle.* De rondes na een partij met een onbekende
  uitslag (`?`, of een symbool dat zo gelezen wordt) worden toch getoetst aan de
  paringsregels, met die partij geteld als remise voor beide spelers - wat de import
  ervan maakt, een uitgestelde partij. De controle zegt welke rondes zo getoetst zijn
  en somt elke aangenomen partij op, met de ronde en de twee spelers.
- *Rondes die een paringsregel breken.* Als een ronde van het bestand een regel breekt,
  krijgt de controle de kop *Deze rondes van het bestand breken de FIDE-paringsregels*
  en zegt dat het importeren niet in overeenstemming is met de paringsregels. Dit is
  een waarschuwing die uw uitdrukkelijke bevestiging vraagt (niveau 3). De knop luidt
  dan **Toch importeren**; anders luidt hij **Importeren**. **Annuleren** importeert
  niets.

![De controle van de TRF-import met de kop over rondes die de FIDE-paringsregels breken en de knop Toch importeren](screenshots/10-trf-import-review.png "De controlestap van een TRF-import")

Een bevestigde import maakt het toernooi met de rondes precies zoals het bestand ze
vastlegt. Wat de import heeft aangepast en elke regel die is gebroken, wordt bij het
toernooi en in het auditlogboek bewaard. Voor elke zo'n ronde krijgen de TRF-kopieën
van het verslag een commentaarregel, `### Import @ Round r: ...`, zodat wie het bestand
controleert, ziet waar de paringen niet die van het programma zelf waren. (Het bestand
dat *Versturen…* maakt, bevat alleen records en geen zo'n regel.)

### JSON-back-up {#json-backup}

**Een OpenPairings-back-up importeren** leest een bestand dat is gemaakt met **Volledige
back-up exporteren (JSON)** (hieronder), tot 10 MB. Het geeft een nieuw toernooi, dat
van u is, met de instellingen, officials, ploegen, elk spelerveld, rondes, resultaten,
byes, verboden paringen, paringsregels en de registratie van wat er naar het ratingkantoor is
verzonden. Het origineel wordt nooit aangeraakt, ook niet wanneer u uw eigen bestand
opnieuw importeert. Gaat er iets mis, dan blijft er niets achter.

Wat niet meereist: herstelpunten, het logo, de telefoons die zijn ingeschreven voor het
invoeren van resultaten, de vergrendeling van een overdracht, en alles wat vanzelf zou
werken: de publicatieschakelaar en het adres en het open inschrijfformulier (publiceren
moet voor de kopie opnieuw worden ingeschakeld, [Publiceren](14-publishing.md)). Het
auditlogboek en de medewerkers reizen alleen mee in een overdrachtsbestand, en de
medewerkers komen terug als openstaande uitnodigingen die elke persoon moet
aanvaarden.

Een toernooi in een groep ([Toernooigroepen](03-tournament-setup.md#tournament-groups))
neemt de naam van de groep, zijn label en zijn plaats mee in het bestand, ter
informatie. De import gebruikt ze niet: de kopie komt in geen enkele groep aan, en u
voegt ze op haar pagina Instellingen aan een groep toe als u ze daar wilt.

### SWAR-bestand {#swar-file}

Met de functie *SWAR-import* aan (menu Account, **Functies**, Belgisch pakket) leest
**Een SWAR-toernooi importeren** een `.swar`-bestand met spelers, rondes, resultaten,
byes, puntentelling (met de 3-2-1 clubpuntentelling inbegrepen), afwezigheden en de
categorieën. Spelers zonder FIDE-ID worden in de FIDE-lijst opgezocht, en u bevestigt de
overeenkomsten in een stap *FIDE-ID's oplossen*. Bestaat er al een toernooi dat er
hetzelfde uitziet, dan zegt het paneel dat en biedt het aan het te openen of een andere
kopie te importeren. Een SWAR-teamcompetitie kan worden geïmporteerd als individueel
toernooi (de partijen), niet als teamevenement.

### Resultaten uit een CSV-bestand {#results-from-a-csv-file}

Op de pagina Paringen, **Meer**, **Resultaten importeren (CSV)**. Zie
[Uitslagen](07-results.md).

### Een overdracht ontvangen {#receive-a-hand-off}

**Een overdracht ontvangen** neemt een toernooi op dat een andere kopie van het programma
heeft overgedragen. Zie [Accounts, delen en overdracht](15-accounts-and-handoff.md).

## Exporteren {#exporting}

Instellingen, **Exporteren** (de pagina *Export / back-up*):

### TRF (FIDE-ratingverslag) {#trf-fide-rating-report}

Het TRF26-bestand voor het ratingkantoor. Een tabel toont elke gepaarde ronde met de
stand (wordt gespeeld, klaar om te verzenden, verzonden) en een vinkje.
**Een kopie downloaden (niet voor rating)** en **Alle rondes (TRF-kopie, niet voor
rating)** maken kopieën, en **Versturen…** maakt het bestand voor het ratingkantoor en
markeert de partijen als verzonden. Dit maakt deel uit van de rapportageprocedure en
wordt uitgelegd in [Verzenden naar FIDE](11-fide-report.md).

Het geschreven bestand is TRF26, het rapportformaat van 2026. Het heeft de spelerregels
in de TRF16-indeling, en de toernooirecords: het aantal rondes (142), de startkleur
(152), het puntensysteem als dat niet 1, ½, 0 is (162), het programma (182), het type
toernooi (192, bijvoorbeeld `FIDE_DUTCH_2025` voor een Zwitsers toernooi, `_BAKU` met versnelling,
`BERGER_ROUNDROBIN_Gn`, `FIDE_TEAM_TYPEA_MP_GP`, of `CUSTOM_SWISS` voor Keizer), de
tiebreaks (202), het speeltempo (222), de virtuele Baku-punten (250), de verboden
paringen (260), een bye die voor een nog niet gepaarde ronde is toegekend (240) en de
administratieve extra punten (299). Aantekeningen die het programma voor een menselijke
lezer van het bestand wil tonen, worden in kopieën geschreven als `###`-commentaarregels.
Elke gepaarde ronde kan ook worden geselecteerd met `?rounds=1-5` in het adres van de
download (bereiken en losse rondes, zoals `1-3,6`).

De oudere TRF16-schrijfwijze van de uitbreidingsregels, die TRF-paringsprogramma's zoals
bbpPairings lezen, is beschikbaar door `?dialect=engine` toe te voegen aan het adres van
de download.

### Back-up en kopie {#backup-and-copy}

- **Volledige back-up exporteren (JSON)** - het hierboven beschreven bestand, voor dit
  toernooi. Op de pagina Toernooien exporteert **Alles exporteren (JSON)** elk toernooi
  dat u bezit in één bestand.
- **.swar exporteren (v7, experimenteel)** (Belgisch pakket) schrijft een SWAR-bestand.
  Een regel somt op wat het SWAR-formaat van dit toernooi niet kan bevatten.
- **SWAR-resultatenpagina exporteren (.html)** (Belgisch pakket) schrijft de
  resultatenpagina in SWAR-stijl.
- **Publiceren op de uitslagensite van de federatie** (Belgisch pakket, beheerder).

### Spelers (CSV) {#players-csv}

**Spelers exporteren (CSV)**: u kiest de kolommen (toevoegen, verwijderen, omhoog of
omlaag verplaatsen), het kolomscheidingsteken (komma, puntkomma voor Excel op een Belgische
of Nederlandse computer, tab, pipe), de volgorde van de rijen (startrangschikking en
rating, of naam), of afwezige spelers worden weggelaten, en of de UTF-8-markering wordt
toegevoegd die ervoor zorgt dat Excel de accenten goed leest.

### PGN {#pgn}

Pagina Paringen, **Meer**, **PGN (alleen metadata - er worden geen zetten opgeslagen)**:
deze ronde of alle rondes, met of zonder bordnummers, of een bereik van borden. Het
programma slaat geen zetten op; elke partij in het PGN-bestand heeft de spelers, de
ronde, de datum, het resultaat en een resultaatteken als zettekst. Het is een geldig
PGN-bestand, maar een partij die niet opnieuw kan worden afgespeeld.

### De FIDE-formulieren {#the-fide-forms}

**Geavanceerd**, **Normen** ([Categorieën en normen](13-categories-and-norms.md)).

## Back-ups die het programma maakt {#backups-made-by-the-program}

Een back-up van de toernooidatabase wordt automatisch ongeveer eens per dag geschreven
(zie [Accounts, delen en overdracht](15-accounts-and-handoff.md)), en vóór elke
handeling die moeilijk ongedaan te maken is, wordt een herstelpunt opgeslagen. Deze zijn
los van de bestanden hierboven.
