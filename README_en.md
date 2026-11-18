**Read this in other languages:**
[English](README_en.md) | [中文](README.md) 
# Match-Pause-Manager-for-CSGO
A tournament-style game pause management plugin for CS:GO competitive match servers, compiled based on Source Mod 1.11.0 (the source also builds on SourceMod 1.12.x; V1.2.4 was built with the 1.12.0 compiler)

This plugin is primarily used for **Tactical Pauses** and **Technical Pauses** during competitive matches. It handles the number of pauses, duration, round validity (triggering technical pauses), and round restarts after a pause in accordance with professional tournament rules as closely as possible
## How to Use
Download the **Match Pause Manager VX.X.X.zip** from the latest release. Extract the Match Pause Manager.smx file from the archive to: **\Counter-Strike Global Offensive\csgo\addons\sourcemod\plugins**. Ensure that the ```-insecure``` option has been added to the CS:GO launch options to allow the game to load third-party software
## Features
### Pause UI
The plugin currently supports displaying pause-related information via the in-game warning UI and correctly reads custom team names instead of the default “TEAM A (B)” or “TEAM CT (T).”

Team names follow CS:GO’s own rule (`mp_teamname_1` is the team that starts on CT) and are derived from the round counter, so the correct team name is still shown **after a side switch, including overtime half switches**

The technical pause warning UI and chat messages are worded according to **who called the pause**: a referee pause shows `CALLED BY THE REFEREE` and states that only the referee can resume the match, while a team pause shows `CALLED BY <team>` and states that the calling team may resume with `!unpause`
### Tactical Pause
Players can initiate a tactical pause using any of the following commands:
```
!pause
!tac
!p
```
By default, each team has **3** tactical pauses during the regular season, each lasting **30 seconds**, with a warning that the pause is about to end **5** seconds before the countdown finishes
#### Tactical Pause Limit per Round
In addition to limiting the total number of tactical pauses each team has, this plugin restricts each round to a maximum of one active tactical pause (even if both teams have more than 0 remaining tactical pauses). This restriction applies from **the freeze period before the round starts until the exact moment the round ends**. Upon entering the next round, this limit is reset and recalculated
#### Tactical Time-Out Limit in Overtime
Upon entering overtime, regardless of how many unused tactical time-outs remain from the regular game, both teams’ tactical time-out counts will be reset to **1**. Additionally, when the score is tied at the end of one overtime period and the game proceeds to the next overtime period, both teams’ **1** tactical time-out opportunity will be refreshed (each refresh is announced in chat)
### Technical Time-Out
This plugin sets technical pauses to have higher priority than tactical pauses, and tactical pauses can be directly upgraded to technical pauses using the command ```!tech```.
Players can initiate a technical pause using ```!tech``` or the in-game console command ```mp_pause_match```. Technical pauses initiated via the in-game console using ```mp_pause_match``` will be treated as having been initiated by a **tournament referee** **not affiliated with either team**

A referee pause and a team pause use **different wording** in the warning UI and chat messages: a referee pause states that only the referee can resume the match, while a team pause states that the calling team may resume with ```!unpause```

Technical timeouts have no time limit; only the command ```!unpause``` or the in-game console command ```mp_unpause_match``` can end a technical timeout.
#### Round Handling During a Technical Timeout (damage-based since V1.2.5)
When a technical timeout is requested, the plugin first checks whether the **current round has already produced damage** (any player taking damage counts):

- **No damage yet**: the round is paused in place. It is **not invalidated and not restarted**; play resumes from the same point when the pause ends.
- **Damage already done**: the round is no longer voided while live. It is **played out first** (so the result stays fair), the next round is paused during its freeze time, and the referee can then **restore** the previous round before it is replayed.

Setting ```sm_mp_technical_damage_gate 0``` restores the previous behaviour (```CS_TerminateRound()``` immediately when the command is issued).

#### Round Rewind (new in V1.2.5)
The plugin takes a snapshot at every round start and uses the native CS:GO round backups for the restore:

- **Score, economy, equipment, positions and the round counter** are restored by the native CS:GO round backup (```mp_backup_round_auto``` / ```mp_backup_round_file```). The plugin makes sure both ConVars are usable after the match config ran, and never overwrites a value another plugin (for example Get5) already set.
- **Player statistics (kills / deaths / assists / MVPs)** are backed up and written back by the plugin, because the native backup does not contain them.

The restore is confirmed by the referee: once the invalid round is over and the next round is paused, the referee runs
```
mp_rewind_match
```
from the console (rcon / server console), or ```!rewind``` from in-game as an administrator. **Every attempt reports its result in chat, successful or not.** After a successful restore the referee runs ```mp_unpause_match``` to replay the round.

| ConVar | Default | Description |
| --- | --- | --- |
| ```sm_mp_technical_damage_gate``` | ```1``` | 1 = damage based (no damage: pause in place; damage: wait for the round to end); 0 = always terminate the round immediately (V1.2.4 behaviour) |
| ```sm_mp_rewind_enabled``` | ```1``` | 1 = allow the referee to restore an invalidated round |
#### Transition from Tactical Pause to Technical Pause
When the match is already in a tactical pause state and a player issues ```!tech``` or an administrator issues ```mp_pause_match``` via the in-game console, this plugin will first restore the tactical pause count and end the tactical pause before initiating the technical pause, to prevent unintended consumption of tactical pause counts

The refunded timeout and the "timeout used this round" flag are both cleared, so a tactical pause may be called again during that round
#### Technical Pause Chat Warnings
Once the match enters a technical pause, the plugin will monitor ```say``` and ```say_team``` from T/CT players and automatically send warnings that communication is prohibited during the technical pause; however, it will not block chat content (spectators/HLTV are not warned, and commands starting with `!` `/` `.` are skipped)
### Unpause
Players can immediately end a pause using the ```!unpause``` command, but **only members of the team that initiated the pause** can do so. Attempts by the opposing team or spectators will be rejected, and they will receive the warning ```[CM] Only the calling team may end their tactical timeout.``` (tactical timeout) or ```[CM] Only the calling team may end their technical timeout.``` (technical timeout), and the pause will remain in effect;

If a technical timeout is initiated by a referee via the console (which is treated as having no corresponding team), any player’s ```!unpause``` command will be rejected. Referees may use the in-game console to execute ```mp_unpause_match``` to cancel the timeout. This command is treated as initiated by the tournament organizers and bypasses all team restrictions. Regardless of which side initiated the timeout or whether it is tactical or technical, it can be lifted immediately. This is also the only recommended method for referees to end a timeout during a match.
### Match Experience and Broadcast Procedures
The plugin’s handling of matches and command feedback primarily uses **“[CM]”** to indicate status, such as:

```
[CM] Technical timeout ended. Get ready.
[CM] LIVE! LIVE! LIVE!
[CM] Overtime started. Tactical timeouts refreshed: 1 per team.
[CM] This round already produced damage, so it is played out first.
[CM] Round restored. Score is back to 7:7, player statistics were restored as well.
```
etc.

If the native pause request is not accepted by the server, the plugin never stays stuck in the pause state: it prints `[CM] CS:GO did not enter the pause state. The tactical timeout was not used.` in chat and **refunds** that tactical timeout
