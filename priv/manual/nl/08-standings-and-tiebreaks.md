# Stand en tiebreaks

## De pagina Stand {#the-standings-page}

**Stand** toont de rangschikking na de gespeelde rondes. Bij een Zwitsers toernooi
heeft de tabel de plaats, de naam, de rating, de punten en één kolom voor elke
tiebreak van het toernooi, in de volgorde waarin ze worden toegepast. De kop van de
pagina zegt *Stand na ronde N*. Spelers die na elke tiebreak nog gelijk staan,
worden gerangschikt op rating en naam, of delen een plaats, al naar gelang de
instelling *Spelers die nog gelijk staan delen een plaats* (zie hieronder).

![De pagina Stand van een Zwitsers toernooi met de tiebreakkolommen](screenshots/08-standings-swiss.png "Stand na ronde 5")

- Het filter **Categorie** boven de tabel toont één categorie tegelijk
  ([Categorieën en normen](13-categories-and-norms.md)).
- De kolom *Rds* (aanwezige rondes) en de kolommen voor extra punten verschijnen
  als ze aan staan (pagina Spelers, *Weergave*).
- **W-We** en **We** (de verwachte score van FIDE en het verschil met de werkelijke
  score, tabel 8.1.2) kunnen worden getoond.
- Een Keizer-toernooi toont de Keizer-tabel (plaats, naam, rating, waarde,
  Keizer-punten) in plaats van de tiebreaktabel.
- Onder een kop *Niet definitief* waarschuwt de pagina wanneer een partij is
  uitgesteld en nog moet worden gespeeld, of wanneer borden geen resultaat hebben.
- Een speler die zich heeft teruggetrokken, houdt zijn rij, met de punten die tot
  dan zijn behaald, en is naast de naam gemarkeerd als *teruggetrokken* (ook in de
  afgedrukte stand). In een rondetoernooi kan de regel hieronder die resultaten van
  zo'n speler buiten spel zetten.
- **Afdrukken** opent de stand als document; **Publieke pagina** opent de
  gepubliceerde pagina van een gepubliceerd toernooi.

De stand wordt elke keer opnieuw berekend uit de partijen wanneer dat nodig is, dus
ze loopt altijd gelijk met de resultaten.

### Stand na een eerdere ronde {#standings-after-an-earlier-round}

De pagina toont altijd de stand na de laatst gepaarde ronde. De afgedrukte stand kan
voor een eerdere ronde worden gemaakt door `?round=N` toe te voegen aan het adres
van de afdrukpagina ([Afdrukken](09-printing.md)): alleen de partijen van de rondes
1 tot en met N tellen mee, met de byes van die rondes.

## Punten en puntentelling {#points-and-scoring}

Een overwinning telt 1, een remise ½ en een nederlaag 0, tenzij de pagina
Puntentelling iets anders zegt (elke waarde kan worden ingesteld, ook het 3-1-0
systeem, maar niet vóór de eerste ronde in de FIDE-modus: zie
[Toernooi-instellingen](03-tournament-setup.md)). Een door de paring toegekende bye
scoort zoals ingesteld op de pagina Puntentelling; een afwezigheid scoort daar ook
zoals ingesteld ([Byes en afwezigheden](05-byes-and-absences.md)). Extra punten
(administratieve bonuspunten) worden alleen opgeteld als het toernooi ze telt.

> [!FIDE] C.07
> De tiebreaks van C.07 gebruiken altijd de partijpunten van de tegenstanders, nooit
> de extra punten.

## Tiebreaks {#tie-breaks}

De tiebreaks bepalen de volgorde van spelers met hetzelfde aantal punten. Ze worden
ingesteld bij Instellingen, **Toernooi**, sectie *Tiebreaks*. Het programma volgt
het C.07-reglement van FIDE (Tie-Break Regulations, 1 maart 2026), en de
berekeningen worden gedaan door dezelfde engine die de Zwitserse rondes paart.

### Kiezen {#choosing}

- **Voorinstelling.** Een voorinstelling vult de lijst in één keer: *FIDE
  Round Robin* (DE, WIN, SB, KS), *Disparate Swiss (wide rating range)* (BHC1, BH,
  SB), *Regular Swiss* (BHC1, BH, PS), *Old Swiss (classic)* (PS, BH, SB), of
  *Eigen* voor elke lijst die u zelf samenstelt. Een nieuw toernooi begint met de
  standaard van FIDE voor het type: individueel Zwitsers BHC1, BH, SB, DE, WIN, PS;
  individueel rondetoernooi DE, WIN, SB, KS; teamevenementen MP, GP, DE, BB, SB.
- **Tiebreak toevoegen…** voegt er een toe uit de onderstaande lijst; **Omhoog
  verplaatsen** en **Omlaag verplaatsen** wijzigen de volgorde (de eerste past als
  eerste toe); **Verwijderen** haalt er een weg. Zonder tiebreak delen gelijke
  spelers een plaats.
- De lijst kan worden gewijzigd tot de eerste ronde is gepaard.

> [!FIDE]
> In de FIDE-modus is de lijst daarna vergrendeld, omdat de tiebreaks vóór de start
> moeten worden aangekondigd ([FIDE-modus](02-fide-mode.md)).

### De beschikbare tiebreaks {#the-available-tie-breaks}

Alle individuele tiebreaks van C.07 kunnen worden gekozen. De lijst *Tiebreak
toevoegen…* is hieronder gegroepeerd; de codes zijn die van C.07 zelf. Waar een
tiebreak op de rating is gebaseerd, wordt een ongerate speler geteld zoals beschreven
onder *Regels die het programma toepast*.

**Resultaten en partijen**

| Code | Naam | Betekenis |
| --- | --- | --- |
| DE | Onderlinge ontmoeting | Het resultaat (de resultaten) tussen de spelers die gelijk staan. |
| DE/P | Onderlinge ontmoeting, forfaits meegeteld | Onderlinge ontmoeting waarbij forfaitoverwinningen en -nederlagen als gespeelde partijen tellen. |
| WIN | Aantal overwinningen | Gewonnen partijen, inclusief forfaits. |
| WON | Aantal over het bord gewonnen partijen | Zonder forfaits en byes. |
| BPG | Partijen gespeeld met zwart | |
| BWG | Partijen gewonnen met zwart | Over het bord. |
| REP | Effectief gespeelde rondes | Rondes min halvepuntsbyes, byes van nul punten en forfaitnederlagen. |
| STD | Standaardpunten | Één punt per ronde waarin meer wordt gescoord dan de tegenstander, een halfpunt bij gelijke score. |
| TPN | Paringsnummer van het toernooi | Het lagere nummer staat hoger. |
| TPN/R | Paringsnummer van het toernooi, omgekeerd | Het hogere nummer staat hoger. |
| EXT | Externe waarde | Een waarde die buiten het programma wordt berekend: zie hieronder. |

**Buchholz**

| Code | Naam | Betekenis |
| --- | --- | --- |
| BH | Buchholz | Som van de scores van de tegenstanders. |
| BHC1 | Buchholz Cut-1 | Buchholz zonder de laagste tegenstanderscore. |
| BHC2 | Buchholz Cut-2 | Buchholz zonder de twee laagste. |
| MBH | Mediaan-Buchholz | Buchholz zonder de hoogste en laagste. |
| BH/M2 | Mediaan-Buchholz, Mediaan-2 | Buchholz zonder de twee hoogste en de twee laagste. |
| FB | Fore-Buchholz | Buchholz zoals die was vóór de laatste ronde: de laatste ronde telt voor elke tegenstander als remise. |
| FB/C1, FB/C2 | Fore-Buchholz Cut-1, Cut-2 | Fore-Buchholz zonder de laagste één of twee. |
| FB/M1, FB/M2 | Fore-mediaan-Buchholz, Mediaan-2 | Fore-Buchholz zonder de hoogste en laagste, of zonder de twee hoogste en twee laagste. |
| AOB | Gemiddelde Buchholz van de tegenstanders | Gemiddelde Buchholz van de tegenstanders die over het bord zijn ontmoet. |
| AOB/F | Gemiddelde Fore-Buchholz van de tegenstanders | Hetzelfde met Fore-Buchholz. |

**Sonneborn-Berger en Koya**

| Code | Naam | Betekenis |
| --- | --- | --- |
| SB | Sonneborn-Berger | Scores van de verslagen tegenstanders plus de helft van de scores van de remises. |
| SB/C1, SB/C2 | Sonneborn-Berger Cut-1, Cut-2 | Zonder de bijdrage van de laagste één of twee tegenstanders. |
| KS | Koya-systeem | Score tegen tegenstanders die 50% of meer hebben gescoord. |
| KS/L1, KS/L2 | Koya-systeem, grens 50% + ½ of + 1 | De kwalificatiegrens met een halve of een hele punt verhoogd. |
| KS/L-1, KS/L-2 | Koya-systeem, grens 50% - ½ of - 1 | De kwalificatiegrens met een halve of een hele punt verlaagd. |

**Progressieve score**

| Code | Naam | Betekenis |
| --- | --- | --- |
| PS | Progressieve score | Som van de lopende score na elke ronde. |
| PS/C1, PS/C2 | Progressieve score Cut-1, Cut-2 | Zonder de lopende score van de eerste één of twee rondes. |

**Op rating gebaseerd**

| Code | Naam | Betekenis |
| --- | --- | --- |
| ARO | Gemiddelde rating van de tegenstanders | |
| AROC1, ARO/C2 | ARO Cut-1, Cut-2 | Zonder de laagst geratete één of twee tegenstanders. |
| ARO/M1, ARO/M2 | ARO Mediaan-1, Mediaan-2 | Zonder de hoogste en laagste, of zonder de twee hoogste en twee laagste. |
| TPR | Prestatierating van het toernooi | Uit de ratings van de tegenstanders en de score. |
| PTP | Perfecte toernooiprestatie | De laagste rating waarbij de score wordt verwacht of beter. |
| APRO | Gemiddelde prestatierating van de tegenstanders | Gemiddelde TPR van de tegenstanders die over het bord zijn ontmoet. |
| APPO | Gemiddelde perfecte prestatie van de tegenstanders | Gemiddelde PTP van de tegenstanders die over het bord zijn ontmoet. |
| RTNG | Toernooirating | De rating van de speler; hoe hoger, hoe beter. |
| RTNG/R | Toernooirating, omgekeerd | Hoe lager, hoe beter. |

Teamevenementen hebben een eigen lijst: MP (matchpunten), GP (partijpunten), EMGSB,
EGMSB, EGGSB, BH:GP, EDE, TBR, BBE, SSSC, BB (zie [Ploegen](12-teams.md)). Zij
vormen de laatste groep van de lijst.

### Regels die het programma toepast {#rules-the-program-applies}

- **Niet-gespeelde partijen (C.07 artikel 16).** De eigen niet-gespeelde rondes van
  een speler leveren een "virtuele tegenstander" op voor sommen van het Buchholz-type,
  en de score van een tegenstander wordt aangepast voor de partijen die die
  tegenstander niet heeft gespeeld. Het programma past dit volledig toe, voor byes,
  forfaits en afwezigheden. Een instelling op de pagina Puntentelling (*Een ronde
  waarin wordt uitgerust, behandelen als een vrijwillig niet-gespeelde ronde*) kiest
  hoe afwezigheden tellen.
- **Op rating gebaseerde tiebreaks en ongeratete spelers.** De op rating gebaseerde
  tiebreaks (ARO en zijn cuts en medianen, TPR, PTP, APRO, APPO, RTNG) vallen weg
  wanneer een ongerate speler in het veld zit, tenzij het reglement van het toernooi
  zegt hoe een ongerate speler wordt geteld. Zeg dat in Instellingen, Toernooi, *Hoe
  een ongerate speler in de tiebreaks wordt geteld*, vóór de eerste ronde:
  - *Vaste rating*: elke ongerate speler telt als de rating die is ingevuld bij
    *Rating van een ongerate speler in de tiebreaks*; zolang dat leeg is, vallen de
    op rating gebaseerde tiebreaks weg.
  - *Laagste rating in het veld*: elke ongerate speler telt als de laagste rating
    van het toernooi.
  - *Gemiddelde rating van de geratete spelers*: elke ongerate speler telt als dat
    gemiddelde.

  De pagina zegt welke tiebreak is weggevallen en waarom. Het berekende getal is
  hetzelfde als dat op de tiebreakregel van de TRF, zodat een controleur dezelfde
  waarden uitrekent.
- **Op rating gebaseerde tiebreaks als een speler meer dan één rating heeft.** In
  een toernooi dat langer dan 30 dagen duurt (Instellingen, Toernooi, *Toernooi
  duurt langer dan 30 dagen*) kan een speler tijdens het toernooi een nieuwe rating
  krijgen. C.07 artikel 10 raadt op rating gebaseerde tiebreaks dan af, en als ze
  toch gebruikt worden telt elke speler met zijn **eerste** rating, tenzij het
  reglement van het toernooi iets anders zegt. Dat is de standaard. Het reglement
  kan op twee manieren iets anders zeggen, allebei in Instellingen, Toernooi:
  - *Op rating gebaseerde tiebreaks gebruiken de rating geldig in ronde*: elke
    speler telt het hele toernooi met de ene rating die in die ronde geldig was.
  - *Op rating gebaseerde tiebreaks gebruiken de rating van elke ronde*: elke
    tegenstander telt met de rating die hij had in de ronde waarin de partij
    gespeeld werd - een partij in ronde 2 met de oude lijst, een in ronde 7 met de
    nieuwe. ARO (en zijn cuts), TPR, PTP, APRO en APPO volgen dat allemaal, en de
    berekening per ronde in de publieke stand toont met welke rating elke partij
    telde. RTNG sorteert nog altijd op de eerste rating, en die beslist ook nog
    altijd of een speler als ongerate telt. Deze instelling gaat voor op de ronde
    hierboven.

  Boven de stand staat een regel die zegt welke van de drie geldt.
- **Spelers die na elke tiebreak nog gelijk staan.** *Spelers die nog gelijk staan delen een plaats*
  (Instellingen, Toernooi): uitgeschakeld (de standaard), dan worden de overgebleven
  gelijke spelers gerangschikt op rating en daarna op naam, en één na één genummerd;
  ingeschakeld, dan delen ze allemaal dezelfde plaats, zoals 2=, en wordt de volgende
  plaats overgeslagen. Een loting (hieronder) kan zulke gelijke standen ook beslissen.
- **Rondetoernooi.** Buchholz en de tiebreaks die erop zijn gebaseerd (de
  Buchholz-groep hierboven) worden niet gebruikt in een rondetoernooi (C.07 artikel
  8); de pagina meldt dat.
- **Rondetoernooi, een speler die vroeg is teruggetrokken (C.05 6.6).** Een speler
  van een individueel rondetoernooi die zich heeft teruggetrokken of is uitgesloten
  na minder dan de helft van zijn partijen te hebben gespeeld (over het bord;
  forfaits en nog niet gespeelde uitgestelde partijen tellen niet mee), wordt uit de
  stand gehaald: zijn resultaten blijven in de kruistabel en tellen mee voor de
  rating, maar niet voor de score of de tiebreaks van wie dan ook. De speler wordt na
  de anderen getoond, met *-* voor de plaats en de opmerking *teruggetrokken, niet
  meegeteld*. Bij precies de helft of meer blijven de resultaten staan en tellen ze
  mee. Het TRF-verslag bewaart altijd elke partij.

Een tiebreak die voor een toernooi niet kan worden berekend, wordt niet getoond als
kolom met nullen: hij valt weg, met een opmerking.

### De werking van een tiebreak {#the-working-of-a-tie-break}

Bij teamevenementen somt de regel *Werking* onder elke waarde de bijdrage van elke
ronde op (de tegenstander, wat die waard was, een forfait, een bye). Voor individuele
standen wordt dezelfde informatie gepubliceerd op de uitslagensite (zie
[Publiceren](14-publishing.md)), waar een lezer kan nagaan waarom iemand staat waar
hij staat.

## Handmatige rangschikking (een met de hand vastgestelde volgorde) {#manual-ranking-a-hand-set-order}

Een arbiter kan een volgorde met de hand moeten vaststellen, bijvoorbeeld na een
barrage die aan het bord is beslist. Op de pagina Stand zet **Handmatige rangschikking
inschakelen** de volgorde van het toernooi om in een lijst die u kunt wijzigen:

- de volgorde wordt eerst gezet op de huidige stand;
- elke rij heeft knoppen om hem omhoog of omlaag te verplaatsen (*Herschikken*);
- **Opnieuw plaatsen volgens de huidige volgorde** begint opnieuw vanaf de berekende
  stand;
- **Handmatige rangschikking uitschakelen** keert terug naar de berekende volgorde.

Zolang ze aan staat, toont een banner *Handmatige rangschikking staat AAN.* op elke
pagina en op de afdruk en de publieke pagina die een plaats toont. Wanneer een
resultaat of een bye verandert nadat de volgorde is vastgesteld, zegt de banner dat
de volgorde mogelijk niet meer klopt.

> [!NOTE]
> Handmatige rangschikking verandert alleen de getoonde volgorde: ze raakt nooit de
> punten, de tiebreaks of het TRF-verslag aan, zodat een ratingcontroleur die het
> bestand narekent de berekende stand ziet.

## Loting {#drawing-of-lots}

Wanneer spelers na elke tiebreak nog gelijk staan, zet **Loten bij gelijke stand** op
de pagina Stand de spelers van elke gelijke plaats in een willekeurige volgorde, en
legt het resultaat vast als handmatige rangschikking hierboven. De knop wordt alleen
getoond zolang iemand gelijk staat; ze vraagt eerst om een bevestiging. Opnieuw
loten geeft dezelfde volgorde: de volgorde hangt af van de spelers en van een getal
dat één keer wordt getrokken, de eerste keer dat er geloot wordt, en bij het
toernooi wordt bewaard, zodat een loting niet kan worden herhaald tot ze bevalt.
Spelers die later in een gelijke stand terechtkomen, of gelijke standen die ontstaan
doordat een resultaat wijzigt, worden met hetzelfde getal geordend. De loting wordt
in het auditlogboek vastgelegd. Ze wordt niet aangeboden voor Keizer- of
teamtoernooien.

## Externe tiebreakwaarden {#external-tie-break-values}

Een toernooi dat een tiebreak gebruikt die het programma niet berekent, kan de code
**EXT** (*Externe waarde*) aan zijn tiebreaklijst toevoegen. De pagina Stand toont
dan een kolom waarin u per speler de buiten het programma berekende waarde invult (een
getal, met komma of punt als decimaalteken; leeg wist de waarde). Een hogere waarde
staat hoger. EXT is geen tiebreak van C.07 en wordt niet in de TRF geschreven. De
waarden kunnen worden ingevuld tot het toernooi wordt gearchiveerd.

## Prijsplaatsen {#prize-places}

Als categorieën een **aantal prijzen** hebben (pagina Categorieën), worden de plaatsen
binnen een categorie die een prijs krijgen, gemarkeerd in de stand van die categorie.
Dit is informatief: het programma kent geen prijzen toe.
