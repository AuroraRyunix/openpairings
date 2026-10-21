# Privacybeleid van Manubrium

*Geldig vanaf 2026-10-21. Geldt voor de Manubrium-app voor iOS en Android.*

Manubrium is een app om een schaaktoernooi te leiden dat op een
[OpenPairings](https://pairings.cloud)-server staat. De app is een client:
ze heeft geen eigen servers, geen eigen accounts en geen analytics.

## Waarmee de app praat {#what-the-app-talks-to}

Alleen met de OpenPairings-servers die je zelf toevoegt, door een
koppellink van je accountpagina op die server te scannen of te plakken.
Er gaat niets naar ergens anders. Er zit geen software van derden in de
app, geen reclame en geen crashrapportage.

Verbindingen lopen over HTTPS. Gewone HTTP wordt alleen aanvaard voor een
server op een privaat netwerkadres (het eigen netwerk van de speelzaal,
waar een kopie van OpenPairings op een laptop in dezelfde zaal draait),
omdat zo'n server geen certificaat heeft; naar een publiek adres weigert
de app gewone HTTP.

## Wat de app op de telefoon bewaart {#what-the-app-stores-on-the-phone}

- **Een apparaattoken per server die je toevoegde**, uitgegeven door die
  server toen je koppelde, in de iOS-sleutelhanger of de Android Keystore.
  Het identificeert deze telefoon bij die server en verder niets. Verwijder
  je de server in de app, dan is het weg; de accountpagina op de server
  kan het altijd intrekken, waarna de telefoon afgemeld is.
- **De naam en het adres van de server, en de naam en rol van je account
  daar**, zoals de server ze doorgaf, zodat de app ze kan tonen.
- **Een outbox** met uitslagen en incidenten die je invoerde zonder
  verbinding, tot de server ze aanvaard heeft.
- **De huidige ronde en de stand** van het toernooi dat je open hebt, als
  cache.

Verwijder je de app, dan is dat allemaal weg.

## Wat de app naar een server stuurt {#what-the-app-sends-to-a-server}

Wat je invoert: uitslagen, incidenten met hun tekst en, als je er een
toevoegt, een foto; wijzigingen aan paringen, publicatie, spelers, byes en
instellingen, nieuwe toernooien, en de namen die je in de ratinglijsten
zoekt, voor zover je rol dat toelaat. Alles gaat naar de ene server waar
het toernooi op staat, onder je account daar. De beheerder van die server
is verantwoordelijk voor die gegevens; het privacybeleid van die server
geldt ervoor (voor de gehoste dienst op pairings.cloud: de
voorwaardenpagina daar).

## Camera en foto's {#camera-and-photos}

De camera dient om de QR-code te scannen die de app aan een server koppelt
en, als je dat kiest, om een incident te fotograferen (een notatieformulier,
een klok) voor het logboek van de arbiter. De fotobibliotheek wordt alleen
gelezen als je een bestaande foto voor een incident kiest. Geen enkele
afbeelding verlaat de telefoon, behalve als die bijlage bij dat incident,
naar die server.

## Lokaal netwerk {#local-network}

Op iOS vraagt het systeem één keer of de app met apparaten op het lokale
netwerk mag praten. De app heeft dat alleen nodig om een kopie van
OpenPairings op het netwerk van de speelzaal te bereiken. Weiger je, dan
blijft de gehoste dienst gewoon bereikbaar.

## Kinderen {#children}

De app is gemaakt voor arbiters en organisatoren van toernooien en is niet
op kinderen gericht.

## Wijzigingen en contact {#changes-and-contact}

Wijzigingen aan dit beleid staan in de geschiedenis van de repository op
[github.com/teapot-chess/Manubrium](https://github.com/teapot-chess/Manubrium)
en op deze pagina, met een nieuwe datum. Vragen: het contactadres op
[pairings.cloud](https://pairings.cloud).
