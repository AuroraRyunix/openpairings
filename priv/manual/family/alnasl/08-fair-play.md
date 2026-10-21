# Fair play: the numbers

Alnasl can compare the moves in the games its boards record with a strong chess engine, and show the hall's owner which players' moves matched the engine more often, and lost less, than their rating predicts. It is a reason to look closer at a game. It is not evidence, not an accusation, and not visible to anybody but the owner and whoever the owner shares a report with.

## What it is, and what it is not {#what-it-is}

It is a screening: a number per player per tournament, with the counts behind it, so that an owner who has doubts has something to look at besides a feeling.

It is **not** the method FIDE has approved. The FIDE Fair Play Regulations (approved by the Council in November 2024) say in Art. 1.6 that currently only the methodology of Prof. Kenneth W. Regan is approved, and Art. 1.5 says a presumption of cheating can only come from an approved algorithm. Alnasl's number is built on the same ideas, but it is a different program with its own calibration, and it must never be quoted as if it were FIDE's. Every page of the report says so.

It does not look at anything but the moves. It does not watch the players, the boards, the phones or the clock, and it does not say why a player played as they did.

It only flags unusually strong play. Weak play is nobody's business.

## Who sees it {#who-sees-it}

**The hall's owner, and the people the owner shares it with. Nobody else.** Not the arbiters, not the viewers, and not the administrator of the Alnasl server either: an administrator can run every hall, and still sees nothing of another hall's fair play. The page is not in anybody else's menu and answers anybody else as a page that is not there.

The owner can **share** (below) one report, or all of the hall's, with named people of the hall: the Chief Arbiter, a fair-play officer. They can look, until a date the owner chose, and nothing else: they change no setting, upload nothing, keep nothing longer and share nothing further. Being the administrator gives nobody a share.

A box without accounts has no owners to tell apart: everybody on the hall's network is the owner there, as for everything else, so the settings and the report are open to all of them. Make the first account (Setup, Access) before you switch fair play on, if that matters in your hall.

Every time the owner, or somebody it was shared with, opens a report or a player's page, Alnasl writes down who and when, and the report lists the latest openings. Sharing, stopping a share, uploading, deleting an upload and having a round analysed are written down too.

Fair-play data is never in the results pages, the PGN files, what is sent to OpenResults or Lichess, the arbiter's log or the queue of results. It is in the database of the hall's copy of Alnasl and on the owner's screen.

## Switching it on, and the engine {#installing-the-engine}

Press **Fair play** in the menu on the left, under Manage, and then **Settings** at the hall. The item is there only if you own a hall; anybody else does not see it. It is **off** until you switch it on, hall by hall.

Alnasl needs the engine to do the work: Stockfish 19, the official release. Alnasl does not come with it. The page shows whether it is installed.

1. Press **Download Stockfish 19**. Alnasl fetches the official file from GitHub, checks that it is exactly the file that was published, takes the program out of it and runs Stockfish's own test (`bench`) to make sure it is the build the numbers were calibrated for.
2. Wait a minute or so. The status says **Installed**, with the version.
3. Switch fair play on.

**No internet in the hall?** Download the file on another computer, from the Stockfish 19 release page on GitHub (`official-stockfish/Stockfish`, tag `sf_19`): `stockfish-windows-x86-64-universal.zip` for Windows, `stockfish-macos-universal.tar.gz` for a Mac, `stockfish-linux-x86-64-universal.tar.gz` for Linux (the arm64 versions for ARM computers). Carry it in on a USB stick, press **Choose a file** and pick it. The same checks are made. A file that is not the official one is refused with a sentence that says why.

> [!NOTE] Older Macs
> Stockfish 19's Mac build needs macOS 10.15 or newer. On a Mac with macOS 10.13 or 10.14 the settings page says so, with the version it found, and offers neither the download nor the file; nothing is downloaded. Everything else in Alnasl works as before.

From then on Alnasl analyses each move as soon as the tracker is sure of it, in the background and at the lowest priority the computer offers, with a few engines at once (the number of cores less one; one on the Alnasl server). Nothing about it slows the boards down: when the queue is full, a game waits, and the next move of that game queues it again.

Stockfish is free software (GPL-3.0), from stockfishchess.org. Alnasl runs it as a separate program and never passes it on.

## The report {#the-report}

Under **Reports** on the same page, open the report of a tournament. It lists the players, highest score first, through the round you pick (or for that round alone). For each player:

- **Counted moves**: how many moves went into the numbers (below, what is left out).
- **Matches the engine**, and what was **expected** for that player's rating in those positions.
- **Average loss**, and what was expected. The loss is how much worse the move played was than the engine's best, scaled so that a pawn thrown away in an even position counts for more than one thrown away when you are two pawns up.
- **Score**, with its interval, and one of the two wordings below.
- **Left out**: how many moves did not count, and why.

Press a player's name for the **positions to look at**: the moves the player made that were the engine's first choice, where that choice stood out most from the second, each on a board with the move played and the engine's four best.

### Moves that do not count {#left-out}

A move says nothing about the player, or Alnasl is not sure it was played, in these cases. Each is counted and shown:

| Left out | Why |
| --- | --- |
| no rating | Without a rating there is nothing to compare with. Ratings come from the pairing |
| guessed by the tracker | The tracker was not sure what was played, and neither is any move after it in that game |
| rewritten, result not yet confirmed | The tracker corrected it, and the arbiter has not yet confirmed the result |
| opening (moves 1 to 8) | Book, not thought |
| repeated position | The same position stood on the board before |
| forced move | Only one legal move, or the best one is two pawns better than the second |
| under a minute on the clock | When the clock is known |
| decided position | The engine puts one side more than three pawns ahead before the move |
| not analysed | The engine gave no answer |

A player gets a score only with at least 40 counted moves in the event; below that the report says **too few moves**.

## What the numbers mean {#what-the-numbers-mean}

The **expected** values come from a model fitted on real games from over-the-board events (Lichess broadcasts, with FIDE ratings and clocks): for a player of that rating, in a position with that many good moves, how often does the engine's first choice get played, and how much is lost on average. The **score** is how far the player is from that expectation, in units of standard deviation, taking the three measures (matching the first choice, matching an equally good move, loss) together. Zero means as expected. Higher means stronger than the rating predicts.

- **From 2: "worth a closer look".** Such scores come up by chance in a few of every hundred honest players. Look at the games, not at the number.
- **Above 5: "statistically very unusual".** Honest players almost never have such a score in a model that fits. It is still not proof of anything, and the next section says what you may do with it.

Those two words and those two numbers are Alnasl's own, for its own score. They are not FIDE's thresholds (FIDE's 5.00 for over-the-board play belongs to the approved method, and its 2.50 only supports other evidence), and a 5 here is not a 5 there.

The interval beside the score is the range the player's true standing probably lies in: a score of 2.4 from 40 moves is not very different from a score of 0.5.

### How often an honest player scores this high {#false-positives}

Beside a score of 2 or more the report says how rare it is: **"about 1 in N normal player-events score this high"**, with a range. A player-event is one player's games in one event. The number is measured, not computed from a formula: when the model is made, part of the games (whole events, never used to fit the model) are kept aside, every player in them is scored, and Alnasl counts how many reach 2.0, 2.5, 3.0 and so on up to 5.0. The range is the 95% exact (Clopper-Pearson) interval of that count.

- When none of the kept-aside player-events reached that score, the page says **"fewer than about 1 in N"**: with a few thousand player-events, a zero only proves so much.
- Those games are mostly honest, not certainly honest. A real cheater among them makes the rate a little higher, which errs on the careful side.
- The rate is for the population the model was made from (rated players at standard time controls, games of 40 counted moves or more). A junior event with ratings that lag far behind the players' strength will produce more high scores than the table says.

**Not calibrated** means what it says: there is no model for the installed engine, so there is no score, and there is no rate either. Alnasl does not make one up.

> [!IMPORTANT] No calibration, no score
> The model is a file that belongs to one engine build. Until Alnasl has one for the engine you installed, the report shows the counts and says plainly that there is **no score**. The counts are real. They are not a score, and they should not be read as one. The model is made for standard time controls; rapid and blitz are not calibrated.

What the screening cannot see: a game played without the boards (unless you upload it, below), a move the tracker could not read, opening knowledge, a player who is simply much stronger than their rating, a player who prepared one line very well. Strong, simple, forced-looking positions give high matching without anybody doing anything wrong.

## Games from a PGN file {#pgn-upload}

Games played without the boards, or a whole event from elsewhere, can be screened too. On the fair-play settings of the hall, under **Games from a PGN file**:

1. Choose the `.pgn` file (plain text, at most 10 MB and 2,000 games; unpack a zipped one first).
2. Pick the tournament it belongs to, or **None** for a report of its own. Attached to a tournament, its players are matched with the tournament's (by FIDE ID, then by name, whichever way round it is written) and its games count in the tournament's report.
3. Give it a name if the file's event name will not do, and press **Upload and analyse**.

The ratings come from the `WhiteElo` and `BlackElo` tags. A player without one is not scored, and the upload says so; Alnasl never guesses a rating. Clocks (`[%clk]`) are used when the file has them. The round comes from the `Round` tag ("5" or "5.12" for round 5, board 12).

Each game is checked first. A game with an illegal move, a starting position that cannot be read, or a variant other than standard chess is refused, and a game that appears twice is taken once; the upload lists each one with its number in the file and the reason. A game of an attached tournament that the boards already recorded is not analysed a second time.

The games are analysed in the background, after the live games: an upload never slows the analysis of the round being played. The upload's report shows how many are done and how many wait, and fills itself in as they finish. If Alnasl was restarted in the meantime, it picks up where it left off; **Queue the waiting games again** is there in case it did not.

The file itself is not kept: only its name, size and fingerprint (to recognise it if it is uploaded again), its games and their analysis. Nothing of it is ever served to anybody but the owner and the people the owner shares the report with. **Delete this upload** deletes its games, their analysis and its audit at once.

## A round on demand {#round-on-demand}

A round played while fair play was off, before the engine was installed, or that the queue could not keep up with, can be analysed afterwards. On the tournament's report, under **Analyse a round on demand**, pick the round and press **Analyse this round**. The round's games wait behind the live games. Moves already analysed with the same engine are kept, so asking twice costs nothing.

## Sharing {#sharing}

The owner decides who else sees fair play, by name and until a date:

- **One report**: on the report, under **Shared with**.
- **All of the hall's reports**: on the fair-play settings, under **Sharing**.

Pick the person and the number of days (at most 365), and press **Share**. Only people of the hall can be picked, as arbiter or viewer; invite the person to the hall first. **Stop sharing** ends it at once. A share also ends by itself on its date, and when the person is taken off the hall.

The person finds the reports under **Fair play** in their menu, under **Shared with you**. They see the report, its rounds and its players' pages, with a line saying it was shared with them and is confidential. They do not see who else opened it, how long it is kept, or who else it is shared with, and they cannot change or share anything.

## The rules you are bound by {#the-rules}

From the FIDE Fair Play Regulations 2024:

- **Art. 1.6**: only the approved methodology (Regan's) can support a presumption; for over-the-board play its threshold is 5.00, and 2.50 or more only in support of other evidence. Alnasl's screening is not that, and says so.
- **Art. 1.7**: a reckless or manifestly unfounded accusation is itself an offence. Telling a player, a parent, the organiser or the room that "the computer says" is exactly that, when all you have is this screen. Reporting a suspicion privately to an arbiter is allowed.
- **Art. 3.1.2 a**: the Chief Arbiter (or the Chief Fair Play Officer) may report a case to the FIDE Fair Play Commission.
- **Art. 3.2.12**: strict confidentiality. This report is confidential. Do not print it, send it round or show it to anybody who is not part of the procedure.

## What to do with an unusual score {#unusual-score}

1. **Check the data first.** Open the player's page. Are the counted moves many or few? Were many left out as guessed or rewritten by the tracker? Were the games played on the boards the whole way? Do the positions listed look like positions where only a good move is sensible?
2. **Do not tell the player, and do not tell anybody else.** Not yet and not in the hall. That is Art. 1.7 and Art. 3.2.12.
3. **If you still have a reason to worry**, tell the Chief Arbiter, privately. The Chief Arbiter may report the case to the FIDE Fair Play Commission (Art. 3.1.2 a), and **asks for a proper analysis there**, by the approved method. That analysis, not this screen, is what counts.
4. **Keep the data while the case is open** (below), and write down why.

An owner who is not the Chief Arbiter of the event should hand the matter to them, not decide anything.

## How long it is kept {#retention}

The analysis of a tournament, and the list of who opened its reports, are deleted **30 days after the tournament's last round** (the last time any game of it was finished or changed). A job removes them once a day. The administrator of the installation can change the number of days (`ALNASL_FAIR_PLAY_RETENTION_DAYS`).

A case that is going to the FIDE Fair Play Commission may need the data longer. On the tournament's report, under **How long this is kept**, give a number of days after the last round, **at most 365**, and **a reason**. The reason is kept with it. When that date has passed, everything goes.

An uploaded PGN attached to a tournament is kept as long as the tournament. One on its own counts its 30 days from the moment it was uploaded, and can be kept longer in the same way. A share of one report goes with the report. Shares of the whole hall, and the lines about them in the hall's own record, are deleted a year after they ended.

Switching fair play off stops the analysis of new moves. It does not delete what is there; the retention does that.
