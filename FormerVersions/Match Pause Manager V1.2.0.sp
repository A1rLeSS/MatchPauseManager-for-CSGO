#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <cstrike>
#include <sdktools>

#define PLUGIN_VERSION "1.2.0"

#define PREFIX "[CM]"

#define TAC_WARNING_TIME 5
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


/* =========================================================
 * CONVARS
 * ========================================================= */

ConVar g_cvTacTime;
ConVar g_cvTacCount;
ConVar g_cvOTCount;

ConVar g_cvMaxRounds;
ConVar g_cvOvertimeEnable;
ConVar g_cvOTMaxRounds;

ConVar g_cvTeamName1;
ConVar g_cvTeamName2;


/* =========================================================
 * PLUGIN INFO
 * ========================================================= */

public Plugin myinfo =
{
    name = "Match Pause Manager",
    author = "A1rLeSS",
    description = "Competitive tactical and technical pause manager for CS:GO",
    version = PLUGIN_VERSION,
    url = ""
};


/* =========================================================
 * MATCH TEAM MAPPING
 *
 * CS:GO:
 *
 * mp_teamname_1 = CT
 * mp_teamname_2 = T
 *
 * Therefore:
 *
 * Team A = mp_teamname_1 = initial CT
 * Team B = mp_teamname_2 = initial T
 *
 * After side switch:
 *
 * Team A = T
 * Team B = CT
 * ========================================================= */

int g_iMatchTeamForSide[4];


/* =========================================================
 * TACTICAL TIMEOUT
 * ========================================================= */

int g_iTacRemaining[MATCH_TEAM_COUNT];

bool g_bTacUsedThisRound[MATCH_TEAM_COUNT];

Handle g_hTacTimer = null;

int g_iTacTimeLeft = 0;


/* =========================================================
 * PAUSE STATE
 * ========================================================= */

PauseState g_PauseState = PAUSE_NONE;

int g_iPausingTeam = -1;

int g_iTechCallerTeam = -1;


/* =========================================================
 * TECHNICAL PAUSE
 * ========================================================= */

/*
 * When true:
 *
 * !tech
 *   ->
 * mp_restartround 1
 *   ->
 * round_start
 *   ->
 * mp_pause_match
 */
bool g_bTechnicalRestartPending = false;


/* =========================================================
 * TECHNICAL LIVE TIMER
 * ========================================================= */

Handle g_hTechLiveTimer = null;


/* =========================================================
 * MATCH STATE
 * ========================================================= */

bool g_bMatchStarted = false;

bool g_bNormalSideSwitched = false;

int g_iCurrentOTSegment = -1;

int g_iLastResetOTSegment = -1;


/* =========================================================
 * INTERNAL COMMAND FLAGS
 *
 * Prevent our own mp_pause_match /
 * mp_unpause_match commands from being
 * treated as external referee commands.
 * ========================================================= */

bool g_bInternalPauseCmd = false;

bool g_bInternalUnpauseCmd = false;


/* =========================================================
 * PLUGIN START
 * ========================================================= */

public void OnPluginStart()
{
    CreatePluginConVars();

    /*
     * Tactical pause
     */
    RegConsoleCmd("sm_pause", Command_TacticalPause);
    RegConsoleCmd("sm_tac", Command_TacticalPause);
    RegConsoleCmd("sm_p", Command_TacticalPause);

    /*
     * Technical pause
     */
    RegConsoleCmd("sm_tech", Command_Tech);

    /*
     * Unpause
     */
    RegConsoleCmd("sm_unpause", Command_Unpause);

    /*
     * Round state
     */
    HookEvent(
        "round_start",
        Event_RoundStart,
        EventHookMode_Post
    );

    /*
     * Native CS:GO pause commands.
     */
    AddCommandListener(
        CommandListener_PauseMatch,
        "mp_pause_match"
    );

    AddCommandListener(
        CommandListener_UnpauseMatch,
        "mp_unpause_match"
    );

    ResetMatchState();
}


/* =========================================================
 * CONVARS
 * ========================================================= */

void CreatePluginConVars()
{
    /*
     * Do NOT use FCVAR_PLUGIN.
     * It is deprecated in modern SourceMod.
     */

    g_cvTacTime = CreateConVar(
        "sm_mp_tactical_time",
        "30",
        "Tactical timeout duration in seconds.",
        0,
        true,
        1.0,
        true,
        300.0
    );

    g_cvTacCount = CreateConVar(
        "sm_mp_tactical_count",
        "3",
        "Number of tactical timeouts per team during regulation.",
        0,
        true,
        0.0,
        true,
        20.0
    );

    g_cvOTCount = CreateConVar(
        "sm_mp_overtime_tactical_count",
        "1",
        "Number of tactical timeouts per team per overtime segment.",
        0,
        true,
        0.0,
        true,
        20.0
    );

    /*
     * CS:GO native ConVars.
     */
    g_cvMaxRounds = FindConVar("mp_maxrounds");

    g_cvOvertimeEnable =
        FindConVar("mp_overtime_enable");

    g_cvOTMaxRounds =
        FindConVar("mp_overtime_maxrounds");

    g_cvTeamName1 =
        FindConVar("mp_teamname_1");

    g_cvTeamName2 =
        FindConVar("mp_teamname_2");
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
    if (g_PauseState != PAUSE_NONE)
    {
        InternalUnpauseMatch();
    }

    ResetPauseState();
}


/* =========================================================
 * RESET MATCH
 * ========================================================= */

void ResetMatchState()
{
    ResetPauseState();

    int count = 3;

    if (g_cvTacCount != null)
    {
        count = g_cvTacCount.IntValue;
    }

    if (count < 0)
    {
        count = 0;
    }


    g_iTacRemaining[MATCH_TEAM_A] = count;
    g_iTacRemaining[MATCH_TEAM_B] = count;


    g_bTacUsedThisRound[MATCH_TEAM_A] = false;
    g_bTacUsedThisRound[MATCH_TEAM_B] = false;


    /*
     * IMPORTANT:
     *
     * CS:GO:
     *
     * mp_teamname_1 = CT
     * mp_teamname_2 = T
     */

    g_iMatchTeamForSide[CS_TEAM_CT] =
        MATCH_TEAM_A;

    g_iMatchTeamForSide[CS_TEAM_T] =
        MATCH_TEAM_B;


    g_bMatchStarted = false;

    g_bNormalSideSwitched = false;

    g_iCurrentOTSegment = -1;

    g_iLastResetOTSegment = -1;
}


/* =========================================================
 * RESET PAUSE
 * ========================================================= */

void ResetPauseState()
{
    KillTacticalTimer();

    KillTechnicalLiveTimer();


    g_PauseState =
        PAUSE_NONE;


    g_iPausingTeam = -1;

    g_iTechCallerTeam = -1;


    g_bTechnicalRestartPending =
        false;


    g_iTacTimeLeft = 0;


    g_bInternalPauseCmd =
        false;

    g_bInternalUnpauseCmd =
        false;
}


/* =========================================================
 * TIMER CLEANUP
 * ========================================================= */

void KillTacticalTimer()
{
    if (g_hTacTimer != null)
    {
        KillTimer(g_hTacTimer);

        g_hTacTimer = null;
    }

    g_iTacTimeLeft = 0;
}


void KillTechnicalLiveTimer()
{
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
    if (client <= 0 ||
        client > MaxClients)
    {
        return -1;
    }

    if (!IsClientInGame(client))
    {
        return -1;
    }

    int side =
        GetClientTeam(client);

    if (side != CS_TEAM_T &&
        side != CS_TEAM_CT)
    {
        return -1;
    }

    return g_iMatchTeamForSide[side];
}


void GetMatchTeamName(
    int matchTeam,
    char[] buffer,
    int maxlen
)
{
    buffer[0] = '\0';


    if (matchTeam == MATCH_TEAM_A)
    {
        if (g_cvTeamName1 != null)
        {
            g_cvTeamName1.GetString(
                buffer,
                maxlen
            );
        }

        if (buffer[0] == '\0')
        {
            strcopy(
                buffer,
                maxlen,
                "Team A"
            );
        }

        return;
    }


    if (matchTeam == MATCH_TEAM_B)
    {
        if (g_cvTeamName2 != null)
        {
            g_cvTeamName2.GetString(
                buffer,
                maxlen
            );
        }

        if (buffer[0] == '\0')
        {
            strcopy(
                buffer,
                maxlen,
                "Team B"
            );
        }

        return;
    }


    strcopy(
        buffer,
        maxlen,
        "Unknown"
    );
}


void SwapMatchTeams()
{
    int temp =
        g_iMatchTeamForSide[CS_TEAM_T];

    g_iMatchTeamForSide[CS_TEAM_T] =
        g_iMatchTeamForSide[CS_TEAM_CT];

    g_iMatchTeamForSide[CS_TEAM_CT] =
        temp;
}


/* =========================================================
 * PAUSE UI
 * ========================================================= */

void ShowTacticalPauseUI()
{
    if (g_PauseState != PAUSE_TACTICAL)
    {
        return;
    }

    if (g_iPausingTeam < 0 ||
        g_iPausingTeam >= MATCH_TEAM_COUNT)
    {
        return;
    }


    char teamName[64];

    GetMatchTeamName(
        g_iPausingTeam,
        teamName,
        sizeof(teamName)
    );


    int remaining =
        g_iTacRemaining[g_iPausingTeam];


    PrintCenterTextAll(
        "TACTICAL PAUSE\n%s\nTime Remaining: %d seconds\nTimeouts Remaining: %d",
        teamName,
        g_iTacTimeLeft,
        remaining
    );
}


void ShowTechnicalPauseUI()
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        return;
    }


    char callerName[64];


    if (g_iTechCallerTeam >= 0)
    {
        GetMatchTeamName(
            g_iTechCallerTeam,
            callerName,
            sizeof(callerName)
        );
    }
    else
    {
        strcopy(
            callerName,
            sizeof(callerName),
            "REFEREE"
        );
    }


    PrintCenterTextAll(
        "TECHNICAL PAUSE\nCalled by: %s\nCurrent round is invalid\nWaiting for technical issue to be resolved\nType !unpause when ready",
        callerName
    );
}


void ShowTechnicalRestartUI()
{
    PrintCenterTextAll(
        "TECHNICAL PAUSE\nCurrent round is INVALID\nRestarting round...\nThe new round will remain paused"
    );
}


/* =========================================================
 * ROUND START
 * ========================================================= */

public void Event_RoundStart(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    /*
     * Every new round resets the
     * per-round tactical usage.
     */
    g_bTacUsedThisRound[MATCH_TEAM_A] = false;
    g_bTacUsedThisRound[MATCH_TEAM_B] = false;


    /*
     * =====================================================
     * TECHNICAL RESTART HANDLER
     * =====================================================
     *
     * This is deliberately the FIRST thing handled.
     *
     * !tech
     *   ->
     * mp_restartround 1
     *   ->
     * round_start
     *   ->
     * mp_pause_match
     *
     * Therefore the new round gets paused immediately.
     */

    if (g_bTechnicalRestartPending)
    {
        g_bTechnicalRestartPending =
            false;


        g_PauseState =
            PAUSE_TECHNICAL;


        /*
         * Now that the new round has started,
         * execute the actual native pause.
         */
        InternalPauseMatch();


        PrintToChatAll(
            "%s Technical pause: new round is ready and paused.",
            PREFIX
        );


        ShowTechnicalPauseUI();


        return;
    }


    /*
     * Match first-round notification.
     */
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
    {
        return;
    }


    int maxRounds = 30;


    if (g_cvMaxRounds != null)
    {
        maxRounds =
            g_cvMaxRounds.IntValue;

        if (maxRounds <= 0)
        {
            maxRounds = 30;
        }
    }


    int tScore =
        GetTeamScoreSafe(CS_TEAM_T);

    int ctScore =
        GetTeamScoreSafe(CS_TEAM_CT);


    int totalScore =
        tScore + ctScore;


    if (totalScore >= maxRounds)
    {
        g_bNormalSideSwitched =
            true;

        SwapMatchTeams();
    }
}

int GetTeamScoreSafe(int team)
{
    if (team != CS_TEAM_T && team != CS_TEAM_CT)
    {
        return 0;
    }

    int entity = FindEntityByClassname(-1, "cs_team_manager");

    while (entity != -1)
    {
        int teamNum = GetEntProp(
            entity,
            Prop_Send,
            "m_iTeamNum"
        );

        if (teamNum == team)
        {
            return GetEntProp(
                entity,
                Prop_Send,
                "m_iScore"
            );
        }

        entity = FindEntityByClassname(
            entity,
            "cs_team_manager"
        );
    }

    return 0;
}

/* =========================================================
 * OVERTIME
 * ========================================================= */

int GetOTSegmentRounds()
{
    if (g_cvOTMaxRounds != null)
    {
        int rounds =
            g_cvOTMaxRounds.IntValue;

        if (rounds > 0)
        {
            return rounds;
        }
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
        maxRounds =
            g_cvMaxRounds.IntValue;

        if (maxRounds <= 0)
        {
            maxRounds = 30;
        }
    }


    int tScore =
        GetTeamScoreSafe(CS_TEAM_T);

    int ctScore =
        GetTeamScoreSafe(CS_TEAM_CT);


    int totalScore =
        tScore + ctScore;


    if (totalScore < maxRounds)
    {
        return;
    }


    if (tScore != ctScore)
    {
        return;
    }


    int otRounds =
        GetOTSegmentRounds();


    int segment =
        (totalScore - maxRounds) / otRounds;


    if (segment != g_iCurrentOTSegment)
    {
        g_iCurrentOTSegment =
            segment;

        SwapMatchTeams();
    }


    if (g_iLastResetOTSegment != segment)
    {
        g_iLastResetOTSegment =
            segment;


        int count =
            g_cvOTCount.IntValue;

        if (count < 0)
        {
            count = 0;
        }


        g_iTacRemaining[MATCH_TEAM_A] =
            count;

        g_iTacRemaining[MATCH_TEAM_B] =
            count;


        g_bTacUsedThisRound[MATCH_TEAM_A] =
            false;

        g_bTacUsedThisRound[MATCH_TEAM_B] =
            false;
    }
}


/* =========================================================
 * TACTICAL PAUSE COMMAND
 * ========================================================= */

public Action Command_TacticalPause(
    int client,
    int args
)
{
    /*
     * One command -> one function call.
     *
     * No mp_pause_match listener recursion.
     */

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


/* =========================================================
 * START TACTICAL PAUSE
 * ========================================================= */

void StartTacticalPause(int client)
{
    /*
     * State check.
     */
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
            "%s A technical pause is being prepared.",
            PREFIX
        );

        return;
    }


    /*
     * Determine match team.
     */
    int matchTeam =
        GetMatchTeamFromClient(client);


    if (matchTeam < 0)
    {
        PrintToChat(
            client,
            "%s You must be on T or CT to call a tactical pause.",
            PREFIX
        );

        return;
    }


    /*
     * One tactical timeout per team per round.
     */
    if (g_bTacUsedThisRound[matchTeam])
    {
        PrintToChat(
            client,
            "%s Your team has already used a tactical timeout this round.",
            PREFIX
        );

        return;
    }


    /*
     * Remaining timeout check.
     */
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
     * Consume timeout.
     */
    g_iTacRemaining[matchTeam]--;

    g_bTacUsedThisRound[matchTeam] =
        true;


    g_iPausingTeam =
        matchTeam;


    int duration = 30;


    if (g_cvTacTime != null)
    {
        duration =
            g_cvTacTime.IntValue;

        if (duration <= 0)
        {
            duration = 30;
        }
    }


    g_iTacTimeLeft =
        duration;


    g_PauseState =
        PAUSE_TACTICAL;


    /*
     * Create timer BEFORE issuing native pause.
     */
    KillTacticalTimer();


    g_iTacTimeLeft =
        duration;


    g_hTacTimer = CreateTimer(
        1.0,
        Timer_TacticalCountdown,
        0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );


    char teamName[64];


    GetMatchTeamName(
        matchTeam,
        teamName,
        sizeof(teamName)
    );


    /*
     * ONE announcement.
     */
    PrintToChatAll(
        "%s \x04%s\x01 called a tactical timeout.",
        PREFIX,
        teamName
    );


    PrintToChatAll(
        "%s Time: \x04%d seconds\x01 | Remaining timeouts: \x04%d\x01.",
        PREFIX,
        duration,
        g_iTacRemaining[matchTeam]
    );


    /*
     * Center UI.
     */
    ShowTacticalPauseUI();


    /*
     * Actual CS:GO pause.
     */
    InternalPauseMatch();
}


/* =========================================================
 * TACTICAL COUNTDOWN
 * ========================================================= */

public Action Timer_TacticalCountdown(
    Handle timer
)
{
    /*
     * Timer no longer belongs to
     * an active tactical pause.
     */
    if (g_PauseState != PAUSE_TACTICAL)
    {
        g_hTacTimer = null;

        return Plugin_Stop;
    }


    /*
     * Display current time.
     */
    ShowTacticalPauseUI();


    /*
     * Last five seconds.
     */
    if (g_iTacTimeLeft <= TAC_WARNING_TIME &&
        g_iTacTimeLeft > 0)
    {
        PrintToChatAll(
            "%s Tactical timeout ends in \x04%d\x01 second%s.",
            PREFIX,
            g_iTacTimeLeft,
            g_iTacTimeLeft == 1 ? "" : "s"
        );
    }


    /*
     * Decrease timer.
     */
    g_iTacTimeLeft--;


    /*
     * Zero = automatic resume.
     */
    if (g_iTacTimeLeft <= 0)
    {
        g_hTacTimer = null;

        EndTacticalPause();

        return Plugin_Stop;
    }


    return Plugin_Continue;
}


/* =========================================================
 * END TACTICAL
 * ========================================================= */

void EndTacticalPause()
{
    if (g_PauseState != PAUSE_TACTICAL)
    {
        return;
    }


    KillTacticalTimer();


    g_PauseState =
        PAUSE_NONE;


    g_iPausingTeam =
        -1;


    /*
     * Resume match.
     */
    InternalUnpauseMatch();


    PrintToChatAll(
        "%s Tactical timeout ended. Play will resume.",
        PREFIX
    );


    PrintCenterTextAll(
        "TACTICAL PAUSE ENDED\nPLAY WILL RESUME"
    );
}


/* =========================================================
 * TECH COMMAND
 * ========================================================= */

public Action Command_Tech(
    int client,
    int args
)
{
    int matchTeam = -1;


    if (client > 0)
    {
        matchTeam =
            GetMatchTeamFromClient(client);


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


/* =========================================================
 * START TECHNICAL PAUSE
 * ========================================================= */

void StartTechnicalPause(int callerTeam)
{
    /*
     * Prevent duplicate !tech.
     */
    if (g_PauseState == PAUSE_TECHNICAL ||
        g_bTechnicalRestartPending)
    {
        return;
    }


    /*
     * If tactical pause is currently active,
     * refund it.
     */
    if (g_PauseState == PAUSE_TACTICAL)
    {
        if (g_iPausingTeam >= 0 &&
            g_iPausingTeam < MATCH_TEAM_COUNT)
        {
            g_iTacRemaining[g_iPausingTeam]++;

            g_bTacUsedThisRound[
                g_iPausingTeam
            ] = false;
        }


        KillTacticalTimer();


        g_PauseState =
            PAUSE_NONE;


        g_iPausingTeam =
            -1;


        InternalUnpauseMatch();
    }


    /*
     * Record technical caller.
     */
    g_iTechCallerTeam =
        callerTeam;


    /*
     * Lock state BEFORE restarting.
     */
    g_PauseState =
        PAUSE_TECHNICAL;


    g_bTechnicalRestartPending =
        true;


    /*
     * Announcement.
     */
    if (callerTeam >= 0)
    {
        char teamName[64];


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
            "%s \x04Technical timeout\x01 called by \x04REFEREE\x01.",
            PREFIX
        );
    }


    PrintToChatAll(
        "%s Current round is invalid.",
        PREFIX
    );


    PrintToChatAll(
        "%s Restarting the round. The new round will remain paused.",
        PREFIX
    );


    ShowTechnicalRestartUI();


    /*
     * =====================================================
     * IMPORTANT
     * =====================================================
     *
     * We deliberately DO NOT call mp_pause_match here.
     *
     * First make sure any existing native pause is removed.
     *
     * Then restart the round.
     *
     * round_start will execute InternalPauseMatch().
     */


    InternalUnpauseMatch();


    /*
     * Execute the requested restart.
     */
    ServerCommand(
        "mp_restartround 1"
    );

    ServerExecute();
}


/* =========================================================
 * UNPAUSE COMMAND
 * ========================================================= */

public Action Command_Unpause(
    int client,
    int args
)
{
    TryUnpause(
        client,
        false
    );

    return Plugin_Handled;
}


/* =========================================================
 * TRY UNPAUSE
 * ========================================================= */

void TryUnpause(
    int client,
    bool refereeOverride
)
{
    /*
     * The technical restart hasn't reached
     * round_start yet.
     */
    if (g_bTechnicalRestartPending)
    {
        if (client > 0)
        {
            PrintToChat(
                client,
                "%s The technical round restart is still in progress.",
                PREFIX
            );
        }

        return;
    }


    /*
     * Nothing paused.
     */
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
     * Server console / referee override.
     */
    if (client <= 0 || refereeOverride)
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


    int matchTeam =
        GetMatchTeamFromClient(client);


    if (matchTeam < 0)
    {
        PrintToChat(
            client,
            "%s You must be on T or CT.",
            PREFIX
        );

        return;
    }


    /*
     * Referee technical pause.
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
     * Tactical pause.
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


    /*
     * Technical pause.
     */
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


/* =========================================================
 * END TECHNICAL
 * ========================================================= */

void EndTechnicalPause()
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        return;
    }


    g_PauseState =
        PAUSE_NONE;


    g_bTechnicalRestartPending =
        false;


    g_iTechCallerTeam =
        -1;


    /*
     * Resume.
     */
    InternalUnpauseMatch();


    PrintToChatAll(
        "%s Technical timeout ended. Get ready.",
        PREFIX
    );


    PrintCenterTextAll(
        "TECHNICAL PAUSE ENDED\nGET READY"
    );


    KillTechnicalLiveTimer();


    g_hTechLiveTimer = CreateTimer(
        TECH_LIVE_DELAY,
        Timer_TechnicalLive,
        0,
        TIMER_FLAG_NO_MAPCHANGE
    );
}


/* =========================================================
 * TECHNICAL LIVE
 * ========================================================= */

public Action Timer_TechnicalLive(
    Handle timer
)
{
    g_hTechLiveTimer = null;


    if (g_PauseState == PAUSE_NONE)
    {
        PrintToChatAll(
            "%s \x04LIVE! LIVE! LIVE!",
            PREFIX
        );


        PrintCenterTextAll(
            "LIVE!\nPLAY RESUMING"
        );
    }


    return Plugin_Stop;
}


/* =========================================================
 * NATIVE mp_pause_match
 * ========================================================= */

public Action CommandListener_PauseMatch(
    int client,
    const char[] command,
    int argc
)
{
    /*
     * Plugin itself called mp_pause_match.
     *
     * Do NOT process it again.
     */
    if (g_bInternalPauseCmd)
    {
        return Plugin_Continue;
    }


    /*
     * Already processing a pause.
     */
    if (g_PauseState != PAUSE_NONE ||
        g_bTechnicalRestartPending)
    {
        return Plugin_Handled;
    }


    /*
     * External mp_pause_match =
     * referee technical pause.
     */
    StartTechnicalPause(-1);


    return Plugin_Handled;
}


/* =========================================================
 * NATIVE mp_unpause_match
 * ========================================================= */

public Action CommandListener_UnpauseMatch(
    int client,
    const char[] command,
    int argc
)
{
    /*
     * Plugin itself called mp_unpause_match.
     */
    if (g_bInternalUnpauseCmd)
    {
        return Plugin_Continue;
    }


    /*
     * External command =
     * referee override.
     */
    TryUnpause(
        client,
        true
    );


    return Plugin_Handled;
}


/* =========================================================
 * INTERNAL PAUSE
 * ========================================================= */

void InternalPauseMatch()
{
    /*
     * Protect our own command from
     * CommandListener_PauseMatch.
     */
    g_bInternalPauseCmd = true;


    ServerCommand(
        "mp_pause_match"
    );

    ServerExecute();


    g_bInternalPauseCmd = false;
}


/* =========================================================
 * INTERNAL UNPAUSE
 * ========================================================= */

void InternalUnpauseMatch()
{
    /*
     * Protect our own command from
     * CommandListener_UnpauseMatch.
     */
    g_bInternalUnpauseCmd = true;


    ServerCommand(
        "mp_unpause_match"
    );

    ServerExecute();


    g_bInternalUnpauseCmd = false;
}


/* =========================================================
 * CHAT
 *
 * IMPORTANT:
 *
 * Normal chat is NOT intercepted.
 *
 * Therefore:
 *
 * Player: ready?
 * Player: wait
 * Player: okay
 *
 * all remain visible.
 * ========================================================= */

public Action OnClientSayCommand(
    int client,
    const char[] command,
    const char[] sArgs
)
{
    /*
     * Deliberately do nothing.
     *
     * Chat remains fully visible.
     *
     * SourceMod automatically handles:
     *
     * !pause
     * !tac
     * !p
     * !tech
     * !unpause
     *
     * through their registered console commands.
     */

    return Plugin_Continue;
}
