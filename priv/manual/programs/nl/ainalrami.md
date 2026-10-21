# De paringsengine

Ainalrami is de engine die elke Zwitserse ronde in OpenPairings paart. Het
volgt het Nederlandse FIDE-systeem (C.04.3, zoals het geldt sinds 1 februari
2026), paart Zwitserse ploegentoernooien (C.04.6) en berekent de
FIDE-tiebreaks (C.07). Het is ook een programma op zich, dat je vanaf de
opdrachtregel gebruikt, dat TRF-bestanden leest en schrijft (TRF16 en FIDE's
TRF26) en dezelfde opdrachtregel aanneemt als JaVaFo.

**Wanneer je het nodig hebt.** Binnen OpenPairings nooit: er valt niets te
installeren of te kiezen, en de paringsknop noemt het bij naam. Deze pagina
is voor als je een TRF-bestand buiten OpenPairings wilt paren, een ronde met
een tweede programma wilt nakijken, of wilt lezen hoe de engine gecontroleerd
is en waar een vraag over de regels nog openstaat. Elke release bevat het
kant-en-klare bestand `ainalrami`, dat alleen Erlang/OTP 29 of nieuwer nodig
heeft.

**Waar het past.** [Een ronde paren](06-pairing.md) is de kant van de
arbiter; de engine staat bij *Zwitserse engine* in
[Een toernooi aanmaken en de instellingen](03-tournament-setup.md#options-page).
