# Borden en poorten

Alles om de borden herkend te krijgen: aansluiten, meerdere borden op één kabel, en twaalf identieke borden uit elkaar houden. Het gebeurt allemaal op de pagina Borden.

## Wat de pagina Borden toont {#the-boards-page}

Eén rij per bord: zijn live plaatje, het signaal, zijn serienummer en firmware, de klok ernaast (beide tijden, de lopende donker; "Geen klok gemeld" als er nog geen klok iets gezegd heeft), de controle van de beginstelling, zijn tafelnummer en zijn bord van de ronde. Bovenaan: "Klaar voor ronde N?", het adres en de QR-code voor een telefoon, en een vel etiketten om af te drukken. Een bord dat niet aangesloten is, houdt zijn rij en zegt "Geen signaal" en waarom.

## Een bord toevoegen {#adding-a-board}

Borden, "Een bord toevoegen": kies de poort waarop het bord hangt en druk op Toevoegen. Elektronische borden, in hun RS232- en USB-C-uitvoering, komen allebei neer op een seriële stroom, dus één stuurprogramma volstaat. Een elektronisch bord op usb is een poort als `COM3` op Windows, `/dev/ttyUSB0` of `/dev/ttyACM0` op Linux, `/dev/cu.usbserial-...` of `/dev/cu.usbmodem...` op een Mac. Op Linux moet de gebruiker die Alnasl draait in de groep `dialout` zitten; de geïnstalleerde dienst is zo ingesteld. Een Mac toont elke adapter twee keer, als `tty.` en `cu.`; Alnasl biedt alleen de `cu.` aan.

> [!WARNING] Eén programma per poort
> Een poort kan maar door één programma tegelijk gelezen worden. Sluit de eigen software van de bordenmaker voor je het bord hier toevoegt, anders krijgt het kastje geen antwoord.

De usb-adapter van een RS232-bord heeft op een Mac of Windows-pc soms het stuurprogramma van de maker nodig voor hij verschijnt (FTDI werkt zoals het is; Prolific, CH340 en CP210x misschien niet).

Een simulatorbord staat in dezelfde lijst. Het speelt zelf een partij en dient om te oefenen: voeg er een toe en de pagina Live heeft iets om te tonen.

## Meerdere borden op één kabel {#loop}

Elektronische borden kunnen aan elkaar geschakeld worden op één seriële kabel, zoals in de eigen software van de bordenmaker. Voor het kastje is dat één poort. Borden, "Een bord toevoegen": kies de poort en druk op Toevoegen. Het kastje vraagt de poort wie erop zit, dat duurt een paar seconden, en elk bord dat antwoordt krijgt een eigen rij. Je hoeft niets te typen of te kiezen: één bord wordt als één bord gelezen, twee of meer als een lus. Een lus telt tot twaalf borden.

Een bord dat later in de keten wordt gestoken, krijgt binnen een tiental seconden vanzelf zijn rij, en het Logboek zegt het. Een bord dat uit de keten gehaald wordt, houdt zijn rij, die "Geen signaal" zegt en waarom; het is terug als het bord terug is. Zegt een bord midden in de keten "Geen signaal" en de andere niet, dan is zijn kabel in de keten eruit, of heeft het geen stroom. De borden ervoor blijven gewoon werken.

De oudere borden zeggen hun serienummer op een lus en worden erop herkend, zoals elk bord. De nieuwere (firmware 4) doen dat niet: zo'n bord wordt getoond met het nummer waarop het op de lus antwoordt, in kleine letters, en houdt zijn tafelnummer daaronder. Steek het één keer in een eigen poort en het kastje kent vanaf dan zijn serienummer, ook op een lus.

Als een poort toegevoegd is toen er één bord op zat, en er nu meer op zitten, zegt de rij "Meer dan één bord antwoordt op deze poort: het is een lus". Druk op "Als lus lezen": elk bord krijgt een eigen rij.

> [!NOTE] Wat op echte borden gecontroleerd is
> Het vinden van de borden, wie ze zijn en wat erop staat, met twee borden op één kabel. Nog niet gezien op een echte lus: een zet terwijl hij gespeeld wordt, een klok, en meer dan twee borden. Het kastje leest ook om de paar seconden het hele bord, dus op een lus kan een zet te laat komen, maar niet fout zijn.

## Welk bord is welk {#which-board-is-which}

Twaalf borden lijken op elkaar, en twaalf kabels ook. Het kastje houdt drie dingen uit elkaar.

- **Welk bord het is.** Een elektronisch bord vertelt het kastje zijn serienummer (het staat ook op een etiket onder het bord). Daaraan kent het kastje het, niet aan de usb-poort. Haal het los, steek het elders in, herstart het kastje: het is nog altijd hetzelfde bord en houdt zijn nummer. Komt het terug op een andere poort, voeg het dan op die poort toe: het kastje herkent het serienummer en zet het terug op zijn oude plaats. Een bord dat het kastje nooit gezien heeft, krijgt de markering "Nieuw bord" en vraagt om een nummer.
- **Zijn tafelnummer.** De sticker op het bord: "dit is tafel 7". Je stelt het één keer in voor de zaal en het blijft. "Etiketten" op de pagina Borden drukt een vel stickers af met het tafelnummer en het serienummer.
- **Zijn bord van de ronde.** Normaal hetzelfde nummer als de tafel. Voor één ronde kun je iets anders zeggen in de kolom "Bord van ronde N" ("tafel 7 speelt vandaag bord 3"), twee borden omwisselen, of alles terugzetten. De volgende ronde begint weer bij de tafelnummers. Op de pagina Live is het bordnummer het grote; "tafel 7 · serienummer 06310" is de kleine letter.

### De tafelnummers geven {#giving-numbers}

Drie manieren:

- **Nummeren door aan te raken.** Druk op Start, til dan een stuk op het bord van tafel 1, dan op dat van tafel 2, enzovoort. Elk bord krijgt het volgende nummer op het moment dat het het stuk voelt weggaan. Ongedaan maken neemt het laatste terug, Overslaan laat een nummer weg, Stop beëindigt het.
- **Alles nummeren in aansluitvolgorde.** Eén klik, wanneer de borden in de volgorde van de tafels aangesloten zijn.
- **Met de hand.** Typ het nummer in de kolom "Tafel".

### Welk bord is dit? {#which-board-is-this}

Druk op "Welk bord is dit?" op de pagina Borden en til een stuk op het bord dat je bedoelt: zijn rij licht een paar seconden op. Omgekeerd zegt "Toon mij" op een rij naar welk serienummer je moet zoeken, en of het bord dat je dan aanraakt het juiste is. Het kastje kan een bord niet laten piepen of knipperen; een aanraking is het signaal.

## Nummeren met je telefoon {#phone-numbering}

Met een telefoon in je hand langs de tafels lopen is makkelijker dan heen en weer naar het kastje.

1. Instellingen, Toegang, "Toegang vanaf andere machines": stel een pincode in, laat dan andere machines in de zaal de site openen, en start Alnasl opnieuw. Doe het voor de zaal volloopt.
2. Open op het kastje Borden (of Instellingen, Toegang): "Open deze site op je telefoon" toont het adres en een QR-code. Richt de camera van de telefoon erop en geef de pincode. (Op een kastje met accounts meldt de code je aan; zie [Accounts, zalen en rollen](06-accounts-and-halls.md).)
3. Op de telefoon: Borden, "Nummeren door aan te raken", Start. Het volgende tafelnummer vult het scherm. Loop naar die tafel en til een willekeurig stuk op; de telefoon laat het nummer en het serienummer van het bord oplichten, trilt (alleen Android) en piept eenmaal zodra "Geluid uit" aangetikt is tot "Geluid aan". Een telefoon wil per bezoek één tik voor hij geluid maakt, en een iPhone op stil speelt niets af.
4. Ongedaan maken, Overslaan en Stop staan onderaan het scherm. Valt het netwerk van de telefoon tussen twee tafels weg, dan gaat er niets verloren: de ronde wordt op het kastje bewaard.

> [!WARNING] Nooit zonder pincode
> Iedereen op het netwerk van de zaal die het adres vindt, kan je borden hernummeren.

Een pincode heeft minstens zes tekens; een kortere van voor die regel blijft werken, en Instellingen, Toegang vraagt je haar te vervangen. Gokken wordt afgeremd: vanaf de vijfde foute pincode moet een adres wachten, eerst vijf seconden en bij elke volgende mislukking dubbel zo lang (hoogstens een kwartier), ook als de volgende poging juist is, en het hele kastje neemt hoogstens veertig foute pincodes per minuut aan.

Doe dit voor de ronde, met de stukken opgesteld en niemand aan de borden. De ronde stopt vanzelf als elk bord een nummer heeft, of na een kwartier zonder aanraking.

## De controle van de beginstelling {#start-position}

De kolom "Beginstelling" vergelijkt wat op het bord staat met de beginstelling en zegt in woorden wat anders is ("zwarte dame en zwarte koning staan omgewisseld (d8, e8)"). Met een klok controleert ze ook de klok: die moet rechts van het bord staan, het scherm van wit naar wit, met de hendel omhoog aan de kant van wit. De kabel reikt nergens anders, en het kastje kan niet anders ingesteld worden. Draai de klok om of tik de hendel om; de melding verdwijnt vanzelf.

"Klaar voor ronde N?" brengt dit per bord samen. Het zegt "Klaar", of somt op wat er mis is, bord per bord.

## Tafels die in geen enkel toernooi spelen {#unlinked-tables}

Een bord dat in geen gekoppeld toernooi speelt, blijft nooit stil: de regel onder de balk, de pagina Borden, de pagina Live en "Klaar voor ronde N?" zeggen allemaal "Bord 1 speelt niet in ...", met een knop om het daar te zetten. Hoe toernooien en tafels samengaan, staat in [OpenPairings, OpenResults en Lichess](05-openpairings-and-openresults.md).
