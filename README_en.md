**Read this in other languages:**
[English](README_en.md) | [中文](README.md) 
# Match-Pause-Manager-for-CSGO
A tournament-style game pause management plugin for CS:GO competitive match servers, compiled based on Source Mod 1.11.0

This plugin is primarily used for **Tactical Pauses** and **Technical Pauses** during competitive matches. It handles the number of pauses, duration, round validity (triggering technical pauses), and round restarts after a pause in accordance with professional tournament rules as closely as possible
## How to Use
Download the **Match Pause Manager VX.X.X.zip** from the latest release. Extract the Match Pause Manager.smx file from the archive to: **\Counter-Strike Global Offensive\csgo\addons\sourcemod\plugins**. Ensure that the ```-insecure``` option has been added to the CS:GO launch options to allow the game to load third-party software
## Features
### Pause UI
The plugin currently supports displaying pause-related information via the in-game warning UI and correctly reads custom team names instead of the default “TEAM A (B)” or “TEAM CT (T).”
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
Upon entering overtime, regardless of how many unused tactical time-outs remain from the regular game, both teams’ tactical time-out counts will be reset to **1**. Additionally, when the score is tied at the end of one overtime period and the game proceeds to the next overtime period, both teams’ **1** tactical time-out opportunity will be refreshed
### Technical Time-Out
This plugin sets technical pauses to have higher priority than tactical pauses, and tactical pauses can be directly upgraded to technical pauses using the command ```!tech```.
Players can initiate a technical pause using ```!tech``` or the in-game console command ```mp_pause_match```. Technical pauses initiated via the in-game console using ```mp_pause_match``` will be treated as having been initiated by a **tournament referee** **not affiliated with either team**

Technical timeouts have no time limit; only the command ```!unpause``` or the in-game console command ```mp_unpause_match``` can end a technical timeout.
#### Round Handling During a Technical Timeout
When a technical timeout is initiated, the current round is deemed invalid. The function ```CS_TerminateRound()``` is then executed to immediately void the round, and ```mp_pause_match``` is executed during the freeze period to enter the technical timeout phase.
#### Transition from Tactical Pause to Technical Pause
When the match is already in a tactical pause state and a player issues ```!tech``` or an administrator issues ```mp_pause_match``` via the in-game console, this plugin will first restore the tactical pause count and end the tactical pause before initiating the technical pause, to prevent unintended consumption of tactical pause counts

Additionally, the tactical pause limit used in the current round will be reset since the round is invalidated, meaning both teams may initiate tactical pauses after the technical pause ends
#### Technical Pause Chat Warnings
Once the match enters a technical pause, the plugin will monitor players’ ```say``` and ```say_team``` commands and automatically send warnings that communication is prohibited during the technical pause; however, it will not block chat content
### Unpause
Players can immediately end a pause using the ```!unpause``` command, but **only members of the team that initiated the pause** can do so. Attempts by the opposing team or spectators will be rejected, and they will receive the warning ```[CM] Only the calling team may end their tactical timeout.``` (tactical timeout) or ```[CM] Only the calling team may end their technical timeout.``` (technical timeout), and the pause will remain in effect;

If a technical timeout is initiated by a referee via the console (which is treated as having no corresponding team), any player’s ```!unpause``` command will be rejected. Referees may use the in-game console to execute ```mp_unpause_match``` to cancel the timeout. This command is treated as initiated by the tournament organizers and bypasses all team restrictions. Regardless of which side initiated the timeout or whether it is tactical or technical, it can be lifted immediately. This is also the only recommended method for referees to end a timeout during a match.
### Match Experience and Broadcast Procedures
The plugin’s handling of matches and command feedback primarily uses **“[CM]”** to indicate status, such as:

```
[CM] Technical timeout ended. Get ready.
[CM] LIVE! LIVE! LIVE!
```
etc.
