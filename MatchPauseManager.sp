#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <cstrike>
#include <sdktools>

#define PLUGIN_VERSION "1.1.1"

#define PREFIX "[CM]"

#define TAC_WARNING_TIME 5
#define TECH_RESTART_DELAY 1.2
#define TECH_LIVE_DELAY 2.0

enum PauseState
{
    PAUSE_NONE = 0,
    PAUSE_TACTICAL,
    PAUSE_TECHNICAL
};

enum MatchTeam
{
    MATCH_TEAM_A = 0,
    MATCH_TEAM_B,
    MATCH_TEAM_COUNT
};

/*
 * ConVars
 */
ConVar g_cvTacTime;
ConVar g_cvTacCount;
ConVar g_cvOTCount;

ConVar g_cvMaxRounds;
ConVar g_cvOvertimeEnable;
ConVar g_cvOTMaxRounds;

ConVar g_cvTeamName1;
ConVar g_cvTeamName2;

/*
 * Match team state
 *
 * CS:GO:
 * mp_teamname_1 = CT
 * mp_teamname_2 = T
 *
 * Therefore at match start:
 *
 * CT -> Team A -> mp_teamname_1
 * T  -> Team B -> mp_teamname_2
 *
 * After side switch the mapping is swapped.
 */
int g_iMatchTeamForSide[4];

int g_iTacRemaining[MATCH_TEAM_COUNT];
bool g_bTacUsedThisRound[MATCH_TEAM_COUNT];

/*
 * Pause state
 */
PauseState g_PauseState = PAUSE_NONE;

int g_iPausingTeam = -1;
int g_iTechCallerTeam = -1;

/*
 * Tactical timer
 */
Handle g_hTacTimer = null;
int g_iTacTimeLeft = 0;

/*
 * Technical restart timer
 */
Handle g_hTechRestartTimer = null;
bool g_bTechnicalRestartPending = false;

/*
 * Technical live timer
 */
Handle g_hTechLiveTimer = null;

/*
 * Match state
 */
bool g_bMatchStarted = false;
bool g_bNormalSideSwitched = false;

int g_iCurrentOTSegment = -1;
int g_iLastResetOTSegment = -1;

/*
 * Prevent our own commands from being interpreted
 * as external referee commands.
 */
bool g_bInternalPauseCmd = false;
bool g_bInternalUnpauseCmd = false;


/* =========================================================
 * PLUGIN
 * ========================================================= */

public Plugin myinfo =
{
    name = "Match Pause Manager",
    author = "A1rLeSS",
    description = "Competitive tactical and technical pause manager for CS:GO",
    version = PLUGIN_VERSION,
    url = "https://github.com/A1rLeSS/MatchPauseManager-for-CSGO"
};


/* =========================================================
 * START
 * ========================================================= */

public void OnPluginStart()
{
    CreateConVars();

    RegConsoleCmd("sm_pause", Command_TacticalPause);
    RegConsoleCmd("sm_tac", Command_TacticalPause);
    RegConsoleCmd("sm_p", Command_TacticalPause);

    RegConsoleCmd("sm_tech", Command_Tech);
    RegConsoleCmd("sm_unpause", Command_Unpause);

    HookEvent("round_start", Event_RoundStart, EventHookMode_Post);

    AddCommandListener(CommandListener_PauseMatch, "mp_pause_match");
    AddCommandListener(CommandListener_UnpauseMatch, "mp_unpause_match");

    ResetMatchState();
}


void CreateConVars()
{
    g_cvTacTime = CreateConVar(
        "sm_mp_tactical_time",
        "30",
        "Tactical timeout duration in seconds.",
        FCVAR_PLUGIN,
        true,
        1.0,
        true,
        300.0
    );

    g_cvTacCount = CreateConVar(
        "sm_mp_tactical_count",
        "3",
        "Number of tactical timeouts per team during regulation.",
        FCVAR_PLUGIN,
        true,
        0.0,
        true,
        20.0
    );

    g_cvOTCount = CreateConVar(
        "sm_mp_overtime_tactical_count",
        "1",
        "Number of tactical timeouts per team per overtime segment.",
        FCVAR_PLUGIN,
        true,
        0.0,
        true,
        20.0
    );

    g_cvMaxRounds = FindConVar("mp_maxrounds");
    g_cvOvertimeEnable = FindConVar("mp_overtime_enable");
    g_cvOTMaxRounds = FindConVar("mp_overtime_maxrounds");

    g_cvTeamName1 = FindConVar("mp_teamname_1");
    g_cvTeamName2 = FindConVar("mp_teamname_2");
}


/* =========================================================
 * MAP
 * ========================================================= */

public void OnMapStart()
{
    ResetMatchState();
}


public void OnMapEnd()
{
    ResetPauseState();
}


public void OnPluginEnd()
{
    if (g_PauseState != PAUSE_NONE || g_bTechnicalRestartPending)
    {
        InternalUnpauseMatch();
    }

    ResetPauseState();
}


/* =========================================================
 * STATE RESET
 * ========================================================= */

void ResetMatchState()
{
    ResetPauseState();

    int defaultCount = g_cvTacCount.IntValue;

    g_iTacRemaining[MATCH_TEAM_A] = defaultCount;
    g_iTacRemaining[MATCH_TEAM_B] = defaultCount;

    g_bTacUsedThisRound[MATCH_TEAM_A] = false;
    g_bTacUsedThisRound[MATCH_TEAM_B] = false;

    /*
     * IMPORTANT:
     *
     * CS:GO mp_teamname_1 = CT
     * CS:GO mp_teamname_2 = T
     *
     * Team A = mp_teamname_1
     * Team B = mp_teamname_2
     */
    g_iMatchTeamForSide[CS_TEAM_CT] = MATCH_TEAM_A;
    g_iMatchTeamForSide[CS_TEAM_T] = MATCH_TEAM_B;

    g_bMatchStarted = false;
    g_bNormalSideSwitched = false;

    g_iCurrentOTSegment = -1;
    g_iLastResetOTSegment = -1;
}


void ResetPauseState()
{
    KillTacticalTimer();
    KillTechnicalTimers();

    g_PauseState = PAUSE_NONE;

    g_iTacTimeLeft = 0;

    g_iPausingTeam = -1;
    g_iTechCallerTeam = -1;

    g_bTechnicalRestartPending = false;

    g_bInternalPauseCmd = false;
    g_bInternalUnpauseCmd = false;
}


void KillTacticalTimer()
{
    if (g_hTacTimer != null)
    {
        KillTimer(g_hTacTimer);
        g_hTacTimer = null;
    }

    g_iTacTimeLeft = 0;
}


void KillTechnicalTimers()
{
    if (g_hTechRestartTimer != null)
    {
        KillTimer(g_hTechRestartTimer);
        g_hTechRestartTimer = null;
    }

    if (g_hTechLiveTimer != null)
    {
        KillTimer(g_hTechLiveTimer);
        g_hTechLiveTimer = null;
    }
}


/* =========================================================
 * TEAM
 * ========================================================= */

int GetMatchTeamFromClient(int client)
{
    if (client < 1 || client > MaxClients)
        return -1;

    if (!IsClientInGame(client))
        return -1;

    int team = GetClientTeam(client);

    if (team != CS_TEAM_T && team != CS_TEAM_CT)
        return -1;

    return g_iMatchTeamForSide[team];
}


void GetMatchTeamName(int matchTeam, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (matchTeam == MATCH_TEAM_A)
    {
        if (g_cvTeamName1 != null)
        {
            g_cvTeamName1.GetString(buffer, maxlen);
        }

        if (buffer[0] == '\0')
        {
            strcopy(buffer, maxlen, "Team A");
        }

        return;
    }

    if (matchTeam == MATCH_TEAM_B)
    {
        if (g_cvTeamName2 != null)
        {
            g_cvTeamName2.GetString(buffer, maxlen);
        }

        if (buffer[0] == '\0')
        {
            strcopy(buffer, maxlen, "Team B");
        }

        return;
    }

    strcopy(buffer, maxlen, "Unknown");
}


void SwapMatchTeams()
{
    int temp = g_iMatchTeamForSide[CS_TEAM_T];

    g_iMatchTeamForSide[CS_TEAM_T] =
        g_iMatchTeamForSide[CS_TEAM_CT];

    g_iMatchTeamForSide[CS_TEAM_CT] = temp;
}


/* =========================================================
 * ROUND START
 * ========================================================= */

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    /*
     * Every new round allows each team to use one tactical
     * timeout again.
     */
    g_bTacUsedThisRound[MATCH_TEAM_A] = false;
    g_bTacUsedThisRound[MATCH_TEAM_B] = false;

    if (!g_bMatchStarted)
    {
        g_bMatchStarted = true;

        CreateTimer(
            1.0,
            Timer_Live,
            0,
            TIMER_FLAG_NO_MAPCHANGE
        );
    }

    HandleSideSwitch();
    HandleOvertime();
}


public Action Timer_Live(Handle timer)
{
    if (g_PauseState == PAUSE_NONE &&
        !g_bTechnicalRestartPending)
    {
        PrintToChatAll(
            "%s \x04LIVE! LIVE! LIVE!",
            PREFIX
        );
    }

    return Plugin_Stop;
}


/* =========================================================
 * SIDE SWITCH
 * ========================================================= */

void HandleSideSwitch()
{
    if (g_cvOvertimeEnable != null &&
        g_cvOvertimeEnable.BoolValue)
    {
        return;
    }

    if (g_bNormalSideSwitched)
        return;

    int maxRounds = 30;

    if (g_cvMaxRounds != null)
    {
        maxRounds = g_cvMaxRounds.IntValue;

        if (maxRounds <= 0)
            maxRounds = 30;
    }

    int tScore = GetTeamScore(CS_TEAM_T);
    int ctScore = GetTeamScore(CS_TEAM_CT);

    int totalScore = tScore + ctScore;

    if (totalScore >= maxRounds)
    {
        g_bNormalSideSwitched = true;

        SwapMatchTeams();
    }
}


/* =========================================================
 * OVERTIME
 * ========================================================= */

int GetOTSegmentRounds()
{
    if (g_cvOTMaxRounds != null)
    {
        int rounds = g_cvOTMaxRounds.IntValue;

        if (rounds > 0)
            return rounds;
    }

    return 6;
}


void HandleOvertime()
{
    if (g_cvOvertimeEnable == null ||
        !g_cvOvertimeEnable.BoolValue)
    {
        return;
    }

    int maxRounds = 30;

    if (g_cvMaxRounds != null)
    {
        maxRounds = g_cvMaxRounds.IntValue;

        if (maxRounds <= 0)
            maxRounds = 30;
    }

    int tScore = GetTeamScore(CS_TEAM_T);
    int ctScore = GetTeamScore(CS_TEAM_CT);

    int totalScore = tScore + ctScore;

    if (totalScore < maxRounds)
        return;

    if (tScore != ctScore)
        return;

    int otRounds = GetOTSegmentRounds();

    int segment =
        (totalScore - maxRounds) / otRounds;

    if (segment != g_iCurrentOTSegment)
    {
        g_iCurrentOTSegment = segment;

        SwapMatchTeams();
    }

    if (g_iLastResetOTSegment != segment)
    {
        g_iLastResetOTSegment = segment;

        int otCount = g_cvOTCount.IntValue;

        g_iTacRemaining[MATCH_TEAM_A] = otCount;
        g_iTacRemaining[MATCH_TEAM_B] = otCount;

        g_bTacUsedThisRound[MATCH_TEAM_A] = false;
        g_bTacUsedThisRound[MATCH_TEAM_B] = false;
    }
}


/* =========================================================
 * TACTICAL PAUSE COMMAND
 * ========================================================= */

public Action Command_TacticalPause(int client, int args)
{
    if (client <= 0)
    {
        PrintToServer(
            "%s Tactical pause must be called by a player.",
            PREFIX
        );

        return Plugin_Handled;
    }

    StartTacticalPause(client);

    return Plugin_Handled;
}


void StartTacticalPause(int client)
{
    if (g_PauseState != PAUSE_NONE)
    {
        PrintToChat(
            client,
            "%s A pause is already active.",
            PREFIX
        );

        return;
    }

    if (g_bTechnicalRestartPending)
    {
        PrintToChat(
            client,
            "%s Technical pause is being prepared.",
            PREFIX
        );

        return;
    }

    int matchTeam = GetMatchTeamFromClient(client);

    if (matchTeam < 0)
    {
        PrintToChat(
            client,
            "%s You must be on T or CT to call a tactical pause.",
            PREFIX
        );

        return;
    }

    if (g_bTacUsedThisRound[matchTeam])
    {
        PrintToChat(
            client,
            "%s Your team has already used a tactical timeout this round.",
            PREFIX
        );

        return;
    }

    if (g_iTacRemaining[matchTeam] <= 0)
    {
        PrintToChat(
            client,
            "%s Your team has no tactical timeouts remaining.",
            PREFIX
        );

        return;
    }

    /*
     * Consume the timeout.
     */
    g_iTacRemaining[matchTeam]--;
    g_bTacUsedThisRound[matchTeam] = true;

    g_iPausingTeam = matchTeam;

    char teamName[64];
    GetMatchTeamName(matchTeam, teamName, sizeof(teamName));

    int duration = g_cvTacTime.IntValue;

    if (duration <= 0)
        duration = 30;

    g_iTacTimeLeft = duration;

    g_PauseState = PAUSE_TACTICAL;

    /*
     * IMPORTANT:
     * Start our SourceMod timer BEFORE issuing the
     * game pause command.
     */
    KillTacticalTimer();

    g_iTacTimeLeft = duration;

    g_hTacTimer = CreateTimer(
        1.0,
        Timer_TacticalCountdown,
        0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );

    /*
     * Pause the actual CS:GO match.
     */
    InternalPauseMatch();

    PrintToChatAll(
        "%s \x04Tactical timeout\x01 called by \x04%s\x01.",
        PREFIX,
        teamName
    );

    PrintToChatAll(
        "%s Tactical timeout: \x04%d seconds\x01.",
        PREFIX,
        duration
    );
}


/* =========================================================
 * TACTICAL COUNTDOWN
 * ========================================================= */

public Action Timer_TacticalCountdown(Handle timer)
{
    /*
     * Make sure this is still the active tactical timer.
     */
    if (g_PauseState != PAUSE_TACTICAL)
    {
        g_hTacTimer = null;
        return Plugin_Stop;
    }

    if (g_iTacTimeLeft <= 0)
    {
        g_hTacTimer = null;

        EndTacticalPause();

        return Plugin_Stop;
    }

    /*
     * Warning at 5 seconds.
     */
    if (g_iTacTimeLeft <= TAC_WARNING_TIME)
    {
        PrintToChatAll(
            "%s Tactical timeout ends in \x04%d\x01 second%s.",
            PREFIX,
            g_iTacTimeLeft,
            g_iTacTimeLeft == 1 ? "" : "s"
        );
    }

    /*
     * Decrement AFTER displaying the current value.
     */
    g_iTacTimeLeft--;

    /*
     * At zero, immediately terminate the pause.
     */
    if (g_iTacTimeLeft <= 0)
    {
        g_hTacTimer = null;

        EndTacticalPause();

        return Plugin_Stop;
    }

    return Plugin_Continue;
}


void EndTacticalPause()
{
    if (g_PauseState != PAUSE_TACTICAL)
        return;

    KillTacticalTimer();

    g_PauseState = PAUSE_NONE;

    g_iPausingTeam = -1;

    /*
     * Resume the CS:GO match.
     */
    InternalUnpauseMatch();

    PrintToChatAll(
        "%s Tactical timeout ended. Play will resume.",
        PREFIX
    );
}


/* =========================================================
 * TECHNICAL PAUSE
 * ========================================================= */

public Action Command_Tech(int client, int args)
{
    int matchTeam = -1;

    if (client > 0)
    {
        matchTeam = GetMatchTeamFromClient(client);

        if (matchTeam < 0)
        {
            PrintToChat(
                client,
                "%s You must be on T or CT to call a technical pause.",
                PREFIX
            );

            return Plugin_Handled;
        }
    }

    StartTechnicalPause(matchTeam);

    return Plugin_Handled;
}


void StartTechnicalPause(int callerTeam)
{
    /*
     * Already technical.
     */
    if (g_PauseState == PAUSE_TECHNICAL ||
        g_bTechnicalRestartPending)
    {
        return;
    }

    /*
     * If a tactical timeout is currently active,
     * refund that timeout because technical pause
     * replaces it.
     */
    if (g_PauseState == PAUSE_TACTICAL)
    {
        if (g_iPausingTeam >= 0 &&
            g_iPausingTeam < MATCH_TEAM_COUNT)
        {
            g_iTacRemaining[g_iPausingTeam]++;
            g_bTacUsedThisRound[g_iPausingTeam] = false;
        }

        KillTacticalTimer();

        g_PauseState = PAUSE_NONE;
        g_iPausingTeam = -1;

        InternalUnpauseMatch();
    }

    g_iTechCallerTeam = callerTeam;

    g_bTechnicalRestartPending = true;

    g_PauseState = PAUSE_TECHNICAL;

    char teamName[64];

    if (callerTeam >= 0)
    {
        GetMatchTeamName(
            callerTeam,
            teamName,
            sizeof(teamName)
        );

        PrintToChatAll(
            "%s \x04Technical timeout\x01 called by \x04%s\x01.",
            PREFIX,
            teamName
        );
    }
    else
    {
        PrintToChatAll(
            "%s \x04Technical timeout\x01 called by referee.",
            PREFIX
        );
    }

    PrintToChatAll(
        "%s Current round is invalid.",
        PREFIX
    );

    PrintToChatAll(
        "%s The round will restart and remain paused.",
        PREFIX
    );

    /*
     * Restart the current round.
     */
    ServerCommand("mp_restartround 1");
    ServerExecute();

    /*
     * After restart, pause the match.
     */
    if (g_hTechRestartTimer != null)
    {
        KillTimer(g_hTechRestartTimer);
        g_hTechRestartTimer = null;
    }

    g_hTechRestartTimer = CreateTimer(
        TECH_RESTART_DELAY,
        Timer_TechnicalPauseAfterRestart,
        0,
        TIMER_FLAG_NO_MAPCHANGE
    );
}


public Action Timer_TechnicalPauseAfterRestart(Handle timer)
{
    g_hTechRestartTimer = null;

    if (!g_bTechnicalRestartPending ||
        g_PauseState != PAUSE_TECHNICAL)
    {
        return Plugin_Stop;
    }

    /*
     * The new round exists now.
     */
    InternalPauseMatch();

    g_bTechnicalRestartPending = false;

    PrintToChatAll(
        "%s Technical pause: new round is ready and will remain paused.",
        PREFIX
    );

    return Plugin_Stop;
}


/* =========================================================
 * UNPAUSE
 * ========================================================= */

public Action Command_Unpause(int client, int args)
{
    TryUnpause(client, false);

    return Plugin_Handled;
}


void TryUnpause(int client, bool fromNativeCommand)
{
    if (g_PauseState == PAUSE_NONE)
    {
        if (client > 0)
        {
            PrintToChat(
                client,
                "%s No pause is currently active.",
                PREFIX
            );
        }

        return;
    }

    /*
     * Server console / referee can always end a pause.
     */
    if (client <= 0 || fromNativeCommand)
    {
        if (g_PauseState == PAUSE_TACTICAL)
        {
            EndTacticalPause();
        }
        else if (g_PauseState == PAUSE_TECHNICAL)
        {
            EndTechnicalPause();
        }

        return;
    }

    int matchTeam = GetMatchTeamFromClient(client);

    if (matchTeam < 0)
    {
        PrintToChat(
            client,
            "%s You are not on a valid team.",
            PREFIX
        );

        return;
    }

    /*
     * Technical pause called by referee:
     * only referee/server can end it.
     */
    if (g_PauseState == PAUSE_TECHNICAL &&
        g_iTechCallerTeam < 0)
    {
        PrintToChat(
            client,
            "%s Only the referee can end this technical pause.",
            PREFIX
        );

        return;
    }

    /*
     * Only the team that called the pause may end it.
     */
    if (g_PauseState == PAUSE_TACTICAL)
    {
        if (matchTeam != g_iPausingTeam)
        {
            PrintToChat(
                client,
                "%s Only the calling team may end their tactical timeout.",
                PREFIX
            );

            return;
        }

        EndTacticalPause();
        return;
    }

    if (g_PauseState == PAUSE_TECHNICAL)
    {
        if (matchTeam != g_iTechCallerTeam)
        {
            PrintToChat(
                client,
                "%s Only the calling team may end their technical timeout.",
                PREFIX
            );

            return;
        }

        EndTechnicalPause();
        return;
    }
}


void EndTechnicalPause()
{
    if (g_PauseState != PAUSE_TECHNICAL)
        return;

    KillTechnicalTimers();

    g_PauseState = PAUSE_NONE;

    g_bTechnicalRestartPending = false;

    g_iTechCallerTeam = -1;

    InternalUnpauseMatch();

    PrintToChatAll(
        "%s Technical timeout ended. Get ready.",
        PREFIX
    );

    g_hTechLiveTimer = CreateTimer(
        TECH_LIVE_DELAY,
        Timer_TechnicalLive,
        0,
        TIMER_FLAG_NO_MAPCHANGE
    );
}


public Action Timer_TechnicalLive(Handle timer)
{
    g_hTechLiveTimer = null;

    if (g_PauseState == PAUSE_NONE)
    {
        PrintToChatAll(
            "%s \x04LIVE! LIVE! LIVE!",
            PREFIX
        );
    }

    return Plugin_Stop;
}


/* =========================================================
 * NATIVE PAUSE COMMAND LISTENER
 * ========================================================= */

public Action CommandListener_PauseMatch(
    int client,
    const char[] command,
    int argc
)
{
    /*
     * This command was issued internally by our plugin.
     */
    if (g_bInternalPauseCmd)
    {
        return Plugin_Continue;
    }

    /*
     * Someone used the actual CS:GO command.
     * Treat it as a referee technical pause.
     */
    StartTechnicalPause(-1);

    return Plugin_Handled;
}


public Action CommandListener_UnpauseMatch(
    int client,
    const char[] command,
    int argc
)
{
    /*
     * Internal command.
     */
    if (g_bInternalUnpauseCmd)
    {
        return Plugin_Continue;
    }

    /*
     * External mp_unpause_match is treated as
     * referee override.
     */
    TryUnpause(client, true);

    return Plugin_Handled;
}


/* =========================================================
 * INTERNAL GAME COMMANDS
 * ========================================================= */

void InternalPauseMatch()
{
    g_bInternalPauseCmd = true;

    ServerCommand("mp_pause_match");
    ServerExecute();

    g_bInternalPauseCmd = false;
}


void InternalUnpauseMatch()
{
    g_bInternalUnpauseCmd = true;

    ServerCommand("mp_unpause_match");
    ServerExecute();

    g_bInternalUnpauseCmd = false;
}


/* =========================================================
 * TECHNICAL CHAT WARNING
 * ========================================================= */

public Action OnClientSayCommand(
    int client,
    const char[] command,
    const char[] sArgs
)
{
    if (client <= 0 ||
        !IsClientInGame(client))
    {
        return Plugin_Continue;
    }

    if (g_PauseState != PAUSE_TECHNICAL &&
        !g_bTechnicalRestartPending)
    {
        return Plugin_Continue;
    }

    if (sArgs[0] == '\0')
        return Plugin_Continue;

    /*
     * Commands such as !unpause / !tech are allowed
     * to reach SourceMod.
     */
    if (sArgs[0] == '!' ||
        sArgs[0] == '/')
    {
        return Plugin_Continue;
    }

    PrintToChat(
        client,
        "%s Technical pause is active. Please wait for the round to resume.",
        PREFIX
    );

    /*
     * Do NOT block normal chat.
     */
    return Plugin_Continue;
}
