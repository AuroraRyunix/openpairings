# Bruggen

Een brug is voor borden die ergens anders staan dan de computer waarop Alnasl draait: een Raspberry Pi in de kamer ernaast, of in een zaal in een andere stad. Het brugprogramma heet Arkab. Het leest de borden en stuurt ze via internet naar Alnasl. Dit hoofdstuk gaat over de kant van Alnasl. De brug heeft zelf een kleine pagina (poort 4050 op de brug) met een eigen korte help.

## Waarvoor een brug dient {#what-a-bridge-is}

De gehoste server heeft geen eigen borden, dus elk bord daar komt via een brug binnen. Een kastje in een zaal kan ook bruggen aannemen, voor een tweede zaal.

De brug belt zelf naar Alnasl. In het netwerk van de zaal hoeft niets open te staan: geen poort doorsturen, geen vast adres. Haar borden verschijnen tussen de andere, met de naam van de brug voor de poort, en worden genummerd, gepaard en hersteld zoals elk bord.

## Arkab, het brugprogramma {#arkab}

**Arkab** is de brug: het bordenlezen van Alnasl en niets anders - de stuurprogramma's, de seriële bus, een wachtrij die elke zet bijhoudt tot de server hem heeft, en de uitgaande lijn naar een of meer Alnasls. Geen rondes, geen aanmeldingen, geen eigen partijen. Het is een apart programma met een eigen repository, [github.com/AuroraRyunix/Arkab](https://github.com/AuroraRyunix/Arkab), Apache-2.0 zoals Alnasl, en het deelt zijn bordcode met Alnasl, zodat een bord op beide hetzelfde leest.

> [!NOTE] Arkab krijgen
> Download het van [zijn releasepagina](https://github.com/AuroraRyunix/Arkab/releases/latest): een installatieprogramma voor Windows, Linux-archieven voor een pc en voor een Raspberry Pi (met een installatie in één regel die er een dienst van maakt), en een Mac-app. Installeer het op de computer waaraan de borden hangen, en start het. Zijn pagina antwoordt dan op poort 4050 van die computer. De Installatiewizard (Instellingen, eerste onderdeel) zet deze stappen voor jouw zaal op een rij en vinkt ze af zodra de brug aansluit.

## Een brug laten aansluiten {#joining}

Eén handeling, op één plaats, en niemand typt een sleutel.

1. Open op Alnasl de pagina van de zaal waar de borden bij horen: Zalen, dan de zaal, dan haar tabblad **Bruggen** (Instellingen, Toegang - Deze server op de server - heeft een knop "Bruggen van deze zaal" die er voor de zaal waar je naar kijkt meteen heen leidt). Druk op "Een brug toevoegen".
2. Er verschijnt een link en hetzelfde als QR-code. De link is goed voor **één brug en vijftien minuten**, en zegt tot wanneer.
3. Op de pagina van de brug (op de computer naast de borden, poort 4050), "Aansluiten bij een server": plak de link, of scan de code met de camera. Druk op Aansluiten. (Een telefoon die de link in zijn eigen browser opent, krijgt een pagina die zegt dat de link voor een brug is, en waar je hem plakt.)
4. De brug toont "Aangesloten." en de server staat in haar lijst. Op Alnasl verschijnt de brug in de lijst van bruggen van de zaal, met haar naam en "verbonden".

Daarna heeft de brug een eigen sleutel, die ze zelf opgehaald heeft. Niemand ziet hem ooit, leest hem voor of kopieert hem, en Alnasl bewaart enkel een hash ervan. Is de link verlopen voor hij gebruikt werd, druk dan opnieuw op "Een brug toevoegen".

> [!NOTE] Wie een brug mag toevoegen
> Een brug toevoegen en verwijderen is voor de eigenaar van de zaal. Een arbiter kan de borden van de brug gebruiken, maar de brug niet toevoegen of verwijderen. Zie [Accounts, zalen en rollen](06-accounts-and-halls.md).

## Eén brug, meerdere servers {#several-servers}

Samenwerken is de bedoeling: één brug kan meerdere Alnasl's voeden, het kastje van de club en de gehoste server bijvoorbeeld. Dezelfde handeling nog eens sluit de volgende aan. De brug houdt een lijst bij, en elke server heeft zijn eigen sleutel en zijn eigen plaats in de wachtrij van de brug.

- Een server die uit de lucht is, houdt niemand anders op.
- Een gebeurtenis verlaat de wachtrij van de brug pas als elke server ze bevestigd heeft.
- Opdrachten van twee servers kunnen elkaar tegenspreken. De brug voert ze uit in de volgorde waarin ze binnenkomen, en alleen een server waarbij de brug als eigenaar is aangesloten, mag haar een bord of een poort laten vergeten.

## Wat je vanuit Alnasl met een brug kunt doen {#ports-and-commands}

Zolang een brug verbonden is, toont haar paneel de poorten die ze ziet en de borden erop.

| Knop | Wat hij doet |
| --- | --- |
| Lezen | Begint een poort op de brug te lezen |
| Opnieuw lezen | Vraagt de lijn opnieuw wie erop zit |
| Vergeten | Stopt met het lezen van een poort op de brug (vraagt eerst bevestiging) |
| Alle borden opnieuw sturen | De brug stuurt wat ze van elk bord heeft, van het begin af |

Kan een opdracht niet uitgevoerd worden, dan zegt het paneel het in woorden: "De brug is niet verbonden.", "Dat kent de brug niet.", of wat de brug zelf antwoordde.

## Als de lijn wegvalt {#line-drops}

Er gaat niets verloren. De brug schrijft elke gebeurtenis genummerd naar een wachtrij op haar eigen schijf voor ze die verstuurt, en haalt ze er pas uit als de server zegt dat hij ze heeft. Een brug die niet verbonden is, blijft de borden lezen en opnemen. Op de server staat de brug dan als "niet verbonden".

Is de lijn terug, dan stuurt de brug wat ze miste, in volgorde. De server negeert wat hij al heeft. Na een lange onderbreking speelt hij niet elke stelling af op het live beeld: hij voert de zetten in volgorde aan de tracker en toont dan waar de partij staat.

Een brug die per ongeluk uitgezet werd, werkt hetzelfde: zet ze aan en ze gaat verder waar haar wachtrij zegt dat ze was.

## Een brug verwijderen {#removing}

"Verwijderen" beëindigt de brug hier en op de brug zelf, en haar borden gaan mee. Deze server verwijderen op de pagina van de brug doet hetzelfde vanaf de andere kant: elke kant beëindigt de verbinding voor beide.

Een brug die verwijderd werd, kan met een nieuwe link opnieuw aansluiten. Ze komt terug als dezelfde brug, met een nieuwe sleutel. Een brug kwijt zijn is één keer Verwijderen op de server.

## Een brug naar een andere zaal verplaatsen {#moving}

Een beheerder kan een brug naar een andere zaal verplaatsen. Haar borden gaan mee, naar het eigen toernooi van die zaal, zonder tafelnummers: ze moeten opnieuw genummerd worden.
