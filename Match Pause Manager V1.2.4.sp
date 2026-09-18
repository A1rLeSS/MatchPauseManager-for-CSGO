#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <cstrike>
#include <sdktools>

#define PLUGIN_VERSION "1.2.4"

#define PREFIX "[CM]"

#define TAC_WARNING_TIME 5

/*
 * Tactical pause detection interval.
 *
 * We do NOT start the tactical countdown when
 * !pause is issued.
 *
 * We first wait until CS:GO is actually paused.
 */
#define TAC_PAUSE_CHECK_INTERVAL 0.1

#define TECH_LIVE_DELAY 2.0


/* =========================================================
 * ENUMS
 * ========================================================= */

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
    url = "https://github.com/A1rLeSS/MatchPauseManager-for-CSGO"
};


/* =========================================================
 * MATCH TEAM MAPPING
 *
 * CS:GO:
 *
 * mp_teamname_1 = CT
 * mp_teamname_2 = T
 *
 * Initial:
 *
 * CT -> Team A
 * T  -> Team B
 *
 * After side switch:
 *
 * T  -> Team A
 * CT -> Team B
 * ========================================================= */

int g_iMatchTeamForSide[4];

#define MATCH_TEAM_NAME_LENGTH 64

char g_sMatchTeamName[MATCH_TEAM_COUNT][MATCH_TEAM_NAME_LENGTH];

/* =========================================================
 * TACTICAL TIMEOUT
 * ========================================================= */

int g_iTacRemaining[MATCH_TEAM_COUNT];

bool g_bTacUsedThisRound[MATCH_TEAM_COUNT];

int g_iLastOTSideSwitchScore = -1;

/*
 * Actual tactical countdown timer.
 *
 * IMPORTANT:
 *
 * This timer is only created AFTER the actual
 * CS:GO pause state has been confirmed.
 */
Handle g_hTacTimer = null;


/*
 * Polling timer.
 *
 * This timer waits for:
 *
 * m_bMatchWaitingForResume == true
 * AND
 * m_bFreezePeriod == true
 *
 * Only then does the tactical countdown begin.
 */
Handle g_hTacPauseCheckTimer = null;


/*
 * TRUE only after CS:GO has actually entered
 * the paused freeze period.
 */
bool g_bTacPauseConfirmed = false;


/*
 * Remaining tactical pause time.
 */
int g_iTacTimeLeft = 0;


/* =========================================================
 * PAUSE STATE
 * ========================================================= */

PauseState g_PauseState = PAUSE_NONE;

int g_iPausingTeam = -1;

int g_iTechCallerTeam = -1;


/* =========================================================
 * TECHNICAL PAUSE STATE
 * ========================================================= */

bool g_bTechnicalRestartPending = false;

bool g_bTechnicalRoundActive = false;


/* =========================================================
 * TECHNICAL UI
 * ========================================================= */

Handle g_hTechUITimer = null;

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
     * Tactical pause commands.
     */

    RegConsoleCmd(
        "sm_pause",
        Command_TacticalPause
    );

    RegConsoleCmd(
        "sm_tac",
        Command_TacticalPause
    );

    RegConsoleCmd(
        "sm_p",
        Command_TacticalPause
    );


    /*
     * Technical pause.
     */

    RegConsoleCmd(
        "sm_tech",
        Command_Tech
    );


    /*
     * Unpause.
     */

    RegConsoleCmd(
        "sm_unpause",
        Command_Unpause
    );


    /*
     * Round events.
     */

    HookEvent(
        "round_start",
        Event_RoundStart,
        EventHookMode_Post
    );


    /*
     * Native pause commands.
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
     * Native CS:GO ConVars.
     */

    g_cvMaxRounds =
        FindConVar("mp_maxrounds");

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


        if (count < 0)
        {
            count = 0;
        }
    }


    g_iTacRemaining[MATCH_TEAM_A] =
        count;

    g_iTacRemaining[MATCH_TEAM_B] =
        count;


    g_bTacUsedThisRound[MATCH_TEAM_A] =
        false;

    g_bTacUsedThisRound[MATCH_TEAM_B] =
        false;


    /*
     * Initial team identity.
     *
     * mp_teamname_1 = CT = Team A
     * mp_teamname_2 = T  = Team B
     */

    g_iMatchTeamForSide[CS_TEAM_CT] =
        MATCH_TEAM_A;

    g_iMatchTeamForSide[CS_TEAM_T] =
        MATCH_TEAM_B;


    g_bMatchStarted =
        false;

    g_bNormalSideSwitched =
        false;


    g_iCurrentOTSegment =
        -1;

    g_iLastResetOTSegment =
        -1;

    g_iLastOTSideSwitchScore =
        -1;

    g_sMatchTeamName[MATCH_TEAM_A][0] = '\0';
    g_sMatchTeamName[MATCH_TEAM_B][0] = '\0';

    if (g_cvTeamName1 != null)
    {
        g_cvTeamName1.GetString(
            g_sMatchTeamName[MATCH_TEAM_A],
            MATCH_TEAM_NAME_LENGTH
        );
    }

    if (g_cvTeamName2 != null)
    {
        g_cvTeamName2.GetString(
            g_sMatchTeamName[MATCH_TEAM_B],
            MATCH_TEAM_NAME_LENGTH
        );
    }
}


/* =========================================================
 * RESET PAUSE STATE
 * ========================================================= */

void ResetPauseState()
{
    KillTacticalTimer();

    KillTacticalPauseCheckTimer();

    KillTechnicalTimers();


    g_PauseState =
        PAUSE_NONE;


    g_iPausingTeam =
        -1;


    g_iTechCallerTeam =
        -1;


    g_bTechnicalRestartPending =
        false;


    g_bTechnicalRoundActive =
        false;


    g_bTacPauseConfirmed =
        false;


    g_iTacTimeLeft =
        0;


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


void KillTacticalPauseCheckTimer()
{
    if (g_hTacPauseCheckTimer != null)
    {
        KillTimer(g_hTacPauseCheckTimer);

        g_hTacPauseCheckTimer = null;
    }
}


void KillTechnicalTimers()
{
    if (g_hTechUITimer != null)
    {
        KillTimer(g_hTechUITimer);

        g_hTechUITimer = null;
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

    if (matchTeam < 0 ||
        matchTeam >= MATCH_TEAM_COUNT)
    {
        strcopy(
            buffer,
            maxlen,
            "Unknown"
        );

        return;
    }

    strcopy(
        buffer,
        maxlen,
        g_sMatchTeamName[matchTeam]
    );

    if (buffer[0] != '\0')
    {
        return;
    }

    if (matchTeam == MATCH_TEAM_A)
    {
        strcopy(
            buffer,
            maxlen,
            "Team A"
        );
    }
    else
    {
        strcopy(
            buffer,
            maxlen,
            "Team B"
        );
    }
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
 * CHECK REAL CS:GO PAUSE STATE
 *
 * THIS IS THE IMPORTANT FIX.
 *
 * m_bMatchWaitingForResume alone is NOT enough.
 *
 * CS:GO may accept mp_pause_match as a pending
 * pause request before Freeze Time.
 *
 * Therefore:
 *
 * m_bMatchWaitingForResume == true
 *
 * AND
 *
 * m_bFreezePeriod == true
 *
 * are both required.
 *
 * This means the tactical countdown starts only
 * after the game has actually reached the pause
 * state during Freeze Time.
 * ========================================================= */

bool IsCSGOActuallyPaused()
{
    int waitingForResume =
        GameRules_GetProp(
            "m_bMatchWaitingForResume"
        );


    int freezePeriod =
        GameRules_GetProp(
            "m_bFreezePeriod"
        );


    return (
        waitingForResume != 0 &&
        freezePeriod != 0
    );
}


/* =========================================================
 * TACTICAL PAUSE UI
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


    /*
     * =====================================================
     * PAUSE REQUESTED
     *
     * The pause command has been sent, but CS:GO
     * has not entered the actual paused Freeze Time.
     * =====================================================
     */

    if (!g_bTacPauseConfirmed)
    {
        PrintCenterTextAll(
            "TACTICAL PAUSE\n%s\nPAUSE STARTING...",
            teamName
        );


        return;
    }


    /*
     * =====================================================
     * ACTUAL TACTICAL PAUSE
     * =====================================================
     */

    PrintCenterTextAll(
        "TACTICAL PAUSE\n%s\nTime Remaining: %d seconds\nTimeouts Remaining: %d",
        teamName,
        g_iTacTimeLeft,
        remaining
    );
}


/* =========================================================
 * WAIT FOR REAL TACTICAL PAUSE
 *
 * IMPORTANT:
 *
 * This timer does NOT consume tactical time.
 *
 * It only waits until:
 *
 * m_bMatchWaitingForResume == true
 *
 * AND
 *
 * m_bFreezePeriod == true
 *
 * Once both are true, the 30 second tactical
 * countdown is started.
 * ========================================================= */

public Action Timer_WaitForTacticalPause(
    Handle timer
)
{
    if (g_PauseState != PAUSE_TACTICAL)
    {
        g_hTacPauseCheckTimer = null;

        return Plugin_Stop;
    }


    /*
     * Already confirmed.
     */

    if (g_bTacPauseConfirmed)
    {
        g_hTacPauseCheckTimer = null;

        return Plugin_Stop;
    }


    /*
     * =====================================================
     * WAIT
     * =====================================================
     *
     * Do NOT start the tactical timer yet.
     *
     * In particular, if the command was issued
     * during an active round, CS:GO may only enter
     * the real pause on the next Freeze Time.
     */

    if (!IsCSGOActuallyPaused())
    {
        ShowTacticalPauseUI();

        return Plugin_Continue;
    }


    /*
     * =====================================================
     * ACTUAL PAUSE CONFIRMED
     * =====================================================
     */

    g_bTacPauseConfirmed =
        true;


    KillTacticalPauseCheckTimer();


    /*
     * Get configured tactical duration.
     */

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


    /*
     * =====================================================
     * THE TIMER STARTS HERE
     * =====================================================
     *
     * This is the exact point where:
     *
     * m_bMatchWaitingForResume = true
     *
     * AND
     *
     * m_bFreezePeriod = true
     *
     * are both true.
     */

    g_iTacTimeLeft =
        duration;


    PrintToChatAll(
        "%s Tactical pause is now active. %d seconds remaining.",
        PREFIX,
        g_iTacTimeLeft
    );


    /*
     * Create the actual countdown timer.
     */

    g_hTacTimer = CreateTimer(
        1.0,
        Timer_TacticalCountdown,
        0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );


    /*
     * Immediately display the full duration.
     */

    ShowTacticalPauseUI();


    return Plugin_Stop;
}


/* =========================================================
 * TECHNICAL PAUSE UI
 * ========================================================= */

void ShowTechnicalRestartUI()
{
    PrintCenterTextAll(
        "TECHNICAL PAUSE\nCURRENT ROUND INVALID\nRESTARTING ROUND..."
    );
}


void ShowTechnicalPauseUI()
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        return;
    }


    if (!g_bTechnicalRoundActive)
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
        "TECHNICAL PAUSE\nNEW ROUND IS PAUSED\nCalled by: %s\nCurrent round is invalid\nType !unpause when ready",
        callerName
    );
}


/* =========================================================
 * TECHNICAL UI REFRESH
 * ========================================================= */

public Action Timer_TechnicalUI(
    Handle timer
)
{
    if (g_PauseState != PAUSE_TECHNICAL ||
        !g_bTechnicalRoundActive)
    {
        g_hTechUITimer = null;

        return Plugin_Stop;
    }


    ShowTechnicalPauseUI();


    return Plugin_Continue;
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
     * Every actual new round resets
     * the per-round tactical usage.
     */

    g_bTacUsedThisRound[MATCH_TEAM_A] =
        false;

    g_bTacUsedThisRound[MATCH_TEAM_B] =
        false;


    /*
     * =====================================================
     * TECHNICAL RESTART
     * =====================================================
     */

    if (g_bTechnicalRestartPending)
    {
        g_bTechnicalRestartPending =
            false;


        g_bTechnicalRoundActive =
            true;


        if (g_hTechUITimer != null)
        {
            KillTimer(g_hTechUITimer);

            g_hTechUITimer = null;
        }


        PrintToChatAll(
            "%s New round started. Technical pause is now active.",
            PREFIX
        );


        ShowTechnicalPauseUI();


        g_hTechUITimer = CreateTimer(
            1.0,
            Timer_TechnicalUI,
            0,
            TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
        );


        /*
         * Pause the NEW round.
         */

        InternalPauseMatch();


        ShowTechnicalPauseUI();


        return;
    }


    /*
     * =====================================================
     * NORMAL MATCH START
     * =====================================================
     */

    if (!g_bMatchStarted)
    {
        g_bMatchStarted =
            true;


        CreateTimer(
            1.0,
            Timer_Live,
            0,
            TIMER_FLAG_NO_MAPCHANGE
        );
    }


    /*
     * Normal side switching.
     */

    HandleSideSwitch();


    /*
     * Overtime.
     */

    HandleOvertime();
}


/* =========================================================
 * NORMAL LIVE
 * ========================================================= */

public Action Timer_Live(
    Handle timer
)
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
 * SCORE
 * ========================================================= */

int GetTeamScoreSafe(int team)
{
    if (team != CS_TEAM_T &&
        team != CS_TEAM_CT)
    {
        return 0;
    }


    int entity =
        FindEntityByClassname(
            -1,
            "cs_team_manager"
        );


    while (entity != -1)
    {
        int teamNum =
            GetEntProp(
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


        entity =
            FindEntityByClassname(
                entity,
                "cs_team_manager"
            );
    }


    return 0;
}


/* =========================================================
 * SIDE SWITCH
 * ========================================================= */

void HandleSideSwitch()
{
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


    if (totalScore >= maxRounds / 2)
    {
        g_bNormalSideSwitched =
            true;


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
        maxRounds = g_cvMaxRounds.IntValue;

        if (maxRounds <= 0)
        {
            maxRounds = 30;
        }
    }

    int tScore = GetTeamScoreSafe(CS_TEAM_T);
    int ctScore = GetTeamScoreSafe(CS_TEAM_CT);

    int totalScore = tScore + ctScore;

    /*
     * Regular time didn't end
     */
    if (totalScore < maxRounds)
    {
        return;
    }

    /*
     * Only a draw can lead to OT
     */
    if (tScore != ctScore)
    {
        return;
    }

    int otRounds = GetOTSegmentRounds();

    if (otRounds <= 0)
    {
        return;
    }

    /*
     * Rounds passed during OT
     *
     * eg.
     *
     * MR15:
     * 15:15 -> OT start，otScore = 0
     */
    int otScore = totalScore - maxRounds;

    /*
     * for a MR3 OT：
     * otRounds = 6
     * halfOT = 3
     */
    int halfOT = otRounds / 2;

    if (halfOT <= 0)
    {
        return;
    }

    /*
     * ==========================================
     * OT Half Round Switch
     * ==========================================
     *
     * OT Segment Start：
     *     No Switch
     *
     * OT Segment Half：
     *     Switch
     *
     * OT Segment End：
     *     No Switch for into a new Segment 
     *
     * eg. MR3 OT：
     *
     * OT1:
     * 0, 1, 2
     * --------
     * 3 -> Switch
     * 4, 5
     *
     * OT2:
     * 6 -> No Switch
     * 7, 8
     * --------
     * 9 -> Switch
     */
    int segmentPosition = otScore % otRounds;

    if (segmentPosition == halfOT)
    {
        if (g_iLastOTSideSwitchScore != totalScore)
        {
            g_iLastOTSideSwitchScore = totalScore;

            SwapMatchTeams();
        }
    }

    /*
     * ==========================================
     * OT Segment Pause Refresh
     * ==========================================
     *
     * Once into a new OT Segment，
     * Two teams get a new OT tactical pause opportunit。
     *
     * But don't SwapMatchTeams()。
     */
    int segment = otScore / otRounds;

    if (segment != g_iCurrentOTSegment)
    {
        g_iCurrentOTSegment = segment;

        int count = 0;

        if (g_cvOTCount != null)
        {
            count = g_cvOTCount.IntValue;

            if (count < 0)
            {
                count = 0;
            }
        }

        g_iTacRemaining[MATCH_TEAM_A] = count;
        g_iTacRemaining[MATCH_TEAM_B] = count;

        g_bTacUsedThisRound[MATCH_TEAM_A] = false;
        g_bTacUsedThisRound[MATCH_TEAM_B] = false;
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
 *
 * IMPORTANT:
 *
 * There is NO tactical countdown timer here.
 *
 * The plugin:
 *
 * 1. validates the timeout
 * 2. consumes the timeout
 * 3. sets tactical pause state
 * 4. sends mp_pause_match
 * 5. waits for actual CS:GO pause state
 *
 * The 30 second countdown only starts inside
 * Timer_WaitForTacticalPause() after:
 *
 * m_bMatchWaitingForResume == true
 * AND
 * m_bFreezePeriod == true
 * ========================================================= */

void StartTacticalPause(int client)
{
    /*
     * Don't allow tactical pause during
     * technical restart.
     */

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
     * Any active pause blocks another pause.
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
     * =====================================================
     * CONSUME TIMEOUT
     * =====================================================
     */

    g_iTacRemaining[matchTeam]--;

    g_bTacUsedThisRound[matchTeam] =
        true;


    g_iPausingTeam =
        matchTeam;


    /*
     * Reset confirmation.
     */

    g_bTacPauseConfirmed =
        false;


    /*
     * IMPORTANT:
     *
     * Do not start the 30 second countdown here.
     */

    g_iTacTimeLeft =
        0;


    g_PauseState =
        PAUSE_TACTICAL;


    /*
     * Make absolutely sure there are no
     * old tactical timers.
     */

    KillTacticalTimer();

    KillTacticalPauseCheckTimer();


    /*
     * =====================================================
     * ANNOUNCEMENT
     * ===================================================== */

    char teamName[64];


    GetMatchTeamName(
        matchTeam,
        teamName,
        sizeof(teamName)
    );


    PrintToChatAll(
        "%s \x04%s\x01 called a tactical timeout.",
        PREFIX,
        teamName
    );


    PrintToChatAll(
        "%s Pause requested. Waiting for the game to enter pause state.",
        PREFIX
    );


    PrintToChatAll(
        "%s Time: \x04%d seconds\x01 | Remaining timeouts: \x04%d\x01.",
        PREFIX,
        g_cvTacTime != null ? g_cvTacTime.IntValue : 30,
        g_iTacRemaining[matchTeam]
    );


    /*
     * =====================================================
     * UI
     *
     * This only shows PAUSE STARTING.
     * No time is being consumed yet.
     * ===================================================== */

    ShowTacticalPauseUI();


    /*
     * =====================================================
     * SEND NATIVE CS:GO PAUSE COMMAND
     * ===================================================== */

    InternalPauseMatch();


    /*
     * =====================================================
     * WAIT FOR ACTUAL PAUSE
     * =====================================================
     */

    g_hTacPauseCheckTimer = CreateTimer(
        TAC_PAUSE_CHECK_INTERVAL,
        Timer_WaitForTacticalPause,
        0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );
}


/* =========================================================
 * TACTICAL COUNTDOWN
 *
 * This function is ONLY reached after:
 *
 * m_bMatchWaitingForResume == true
 * AND
 * m_bFreezePeriod == true
 *
 * Therefore the tactical timer cannot start merely
 * because !pause was typed during an active round.
 * ========================================================= */

public Action Timer_TacticalCountdown(
    Handle timer
)
{
    if (g_PauseState != PAUSE_TACTICAL)
    {
        g_hTacTimer = null;

        return Plugin_Stop;
    }


    /*
     * Safety:
     *
     * If CS:GO is somehow no longer in the actual
     * paused state, stop consuming tactical time.
     *
     * This prevents the timeout from being consumed
     * while the game is actually running.
     */

    if (!IsCSGOActuallyPaused())
    {
        ShowTacticalPauseUI();

        return Plugin_Continue;
    }


    /*
     * Show current time BEFORE decreasing.
     */

    ShowTacticalPauseUI();


    /*
     * Warning.
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
     * Decrease.
     */

    g_iTacTimeLeft--;


    /*
     * Automatic resume.
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


    /*
     * Stop both tactical timers.
     */

    KillTacticalTimer();

    KillTacticalPauseCheckTimer();


    g_bTacPauseConfirmed =
        false;


    g_PauseState =
        PAUSE_NONE;


    g_iPausingTeam =
        -1;


    /*
     * Resume CS:GO.
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
 * TECHNICAL COMMAND
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
     * Prevent duplicate technical pause.
     */

    if (g_PauseState == PAUSE_TECHNICAL ||
        g_bTechnicalRestartPending)
    {
        return;
    }


    /*
     * =====================================================
     * TACTICAL -> TECHNICAL
     *
     * Refund tactical timeout.
     * =====================================================
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

        KillTacticalPauseCheckTimer();


        g_bTacPauseConfirmed =
            false;


        g_PauseState =
            PAUSE_NONE;


        g_iPausingTeam =
            -1;


        InternalUnpauseMatch();
    }


    /*
     * =====================================================
     * TECHNICAL STATE
     * ===================================================== */

    g_iTechCallerTeam =
        callerTeam;


    g_PauseState =
        PAUSE_TECHNICAL;


    g_bTechnicalRestartPending =
        true;


    g_bTechnicalRoundActive =
        false;


    KillTechnicalTimers();


    /*
     * =====================================================
     * CHAT
     * ===================================================== */

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
        "%s Restarting current round immediately.",
        PREFIX
    );


    /*
     * Phase 1 UI.
     */

    ShowTechnicalRestartUI();


    /*
     * Remove any existing pause.
     */

    InternalUnpauseMatch();


    /*
     * Terminate current round.
     */

    CS_TerminateRound(
        0.1,
        CSRoundEnd_Draw
    );
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
     * Technical restart still happening.
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
     * =====================================================
     * TECHNICAL PAUSE
     * ===================================================== */

    if (g_PauseState == PAUSE_TECHNICAL)
    {
        if (!g_bTechnicalRoundActive)
        {
            PrintToChat(
                client,
                "%s The technical pause is still being prepared.",
                PREFIX
            );


            return;
        }


        if (g_iTechCallerTeam < 0)
        {
            PrintToChat(
                client,
                "%s Only the referee can end this technical pause.",
                PREFIX
            );


            return;
        }


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


    /*
     * =====================================================
     * TACTICAL PAUSE
     * ===================================================== */

    if (g_PauseState == PAUSE_TACTICAL)
    {
        /*
         * If the pause command has been issued but
         * CS:GO has not yet entered actual pause,
         * !unpause cannot end it yet.
         */

        if (!g_bTacPauseConfirmed)
        {
            PrintToChat(
                client,
                "%s The tactical pause has not started yet.",
                PREFIX
            );


            return;
        }


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
}


/* =========================================================
 * END TECHNICAL PAUSE
 * ========================================================= */

void EndTechnicalPause()
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        return;
    }


    KillTechnicalTimers();


    g_PauseState =
        PAUSE_NONE;


    g_bTechnicalRestartPending =
        false;


    g_bTechnicalRoundActive =
        false;


    g_iTechCallerTeam =
        -1;


    InternalUnpauseMatch();


    PrintToChatAll(
        "%s Technical timeout ended. Get ready.",
        PREFIX
    );


    PrintCenterTextAll(
        "TECHNICAL PAUSE ENDED\nGET READY"
    );


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
     * Our own internal mp_pause_match.
     */

    if (g_bInternalPauseCmd)
    {
        return Plugin_Continue;
    }


    /*
     * Don't create another pause if one already exists.
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
     * Our own internal mp_unpause_match.
     */

    if (g_bInternalUnpauseCmd)
    {
        return Plugin_Continue;
    }


    /*
     * External native command =
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
    g_bInternalPauseCmd =
        true;


    ServerCommand(
        "mp_pause_match"
    );


    ServerExecute();


    g_bInternalPauseCmd =
        false;
}


/* =========================================================
 * INTERNAL UNPAUSE
 * ========================================================= */

void InternalUnpauseMatch()
{
    g_bInternalUnpauseCmd =
        true;


    ServerCommand(
        "mp_unpause_match"
    );


    ServerExecute();


    g_bInternalUnpauseCmd =
        false;
}


/* =========================================================
 * CHAT
 *
 * Normal chat remains untouched.
 * ========================================================= */

public Action OnClientSayCommand(
    int client,
    const char[] command,
    const char[] sArgs
)
{
    return Plugin_Continue;
}
