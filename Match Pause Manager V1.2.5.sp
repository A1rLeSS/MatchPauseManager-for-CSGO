#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <cstrike>
#include <sdktools>

#define PLUGIN_VERSION "1.2.5"

#define PREFIX "[CM]"

#define TAC_WARNING_TIME 5

/*
 * A pending tactical pause is cancelled when:
 *
 * the game is already inside Freeze Time, but
 * CS:GO still has not entered the real pause state.
 *
 * 50 * 0.1s = 5 seconds.
 */
#define TAC_PENDING_GRACE_TICKS 50

/*
 * A running tactical countdown is released when
 * the game is no longer in the real pause state for
 * this many consecutive seconds.
 */
#define TAC_STALL_GRACE_TICKS 5

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

/*
 * CS:GO writes its own round backup when a round starts,
 * so the ConVar holding the last backup file may still
 * point to the previous round during the first ticks.
 */
#define VALVE_BACKUP_CAPTURE_DELAY 0.5

/*
 * Time CS:GO needs to apply a round backup restore
 * before the plugin may touch the restored round.
 */
#define REWIND_APPLY_DELAY 1.5

/*
 * How often the plugin checks that a technical pause
 * really reached the game's pause state.
 */
#define TECH_PAUSE_VERIFY_INTERVAL 1.0

#define TECH_PAUSE_VERIFY_TRIES 3



/* =========================================================
 * ENUMS
 * ========================================================= */

enum PauseState
{
    PAUSE_NONE = 0,
    PAUSE_TACTICAL,
    PAUSE_TECHNICAL,
    PAUSE_TECHNICAL_PENDING
};

/*
 * Team identity, not team side.
 *
 * Untagged on purpose: every use of these constants is
 * an array index or a plain counter, the same way the
 * plugin stores them in int variables, so a tag would
 * only add casts.
 */

enum
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

ConVar g_cvTechDamageGate;
ConVar g_cvRewindEnabled;

/*
 * Native CS:GO round backup ConVars.
 *
 * mp_backup_round_auto     = write a backup every round
 * mp_backup_round_file     = backup file base name
 * mp_backup_round_file_last = path of the newest backup
 */
ConVar g_cvBackupAuto;
ConVar g_cvBackupFile;
ConVar g_cvBackupLast;


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
 * CS:GO names its teams by roster, NOT by side:
 *
 * mp_teamname_1 = the team that FIRST plays CT
 * mp_teamname_2 = the team that FIRST plays T
 *
 * Valve changed these ConVars in 2012 precisely so
 * that "the names follow the teams after the switch".
 *
 * Initial:
 *
 * CT -> Team A (mp_teamname_1)
 * T  -> Team B (mp_teamname_2)
 *
 * After side switch:
 *
 * T  -> Team A (mp_teamname_1)
 * CT -> Team B (mp_teamname_2)
 *
 * The mapping is therefore a pure function of how many
 * halves the match has already played, and it is rebuilt
 * from the round counter CS:GO itself uses to trigger
 * halftime and overtime halves (m_totalRoundsPlayed).
 *
 * Deriving it from the round counter instead of from the
 * team scores keeps it correct when a round is invalidated
 * by a technical pause (a 0:0 round does not change the
 * score, but it DOES advance the round counter), which is
 * what made the displayed team name wrong after a side
 * switch before V1.2.4.
 * ========================================================= */

int g_iMatchTeamForSide[4];


/* =========================================================
 * TACTICAL TIMEOUT
 * ========================================================= */

int g_iTacRemaining[MATCH_TEAM_COUNT];

bool g_bTacUsedThisRound[MATCH_TEAM_COUNT];

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


/*
 * Consecutive ticks spent in Freeze Time without
 * CS:GO actually entering the pause state.
 *
 * Reaching TAC_PENDING_GRACE_TICKS means the native
 * mp_pause_match request was refused, so the pause is
 * cancelled and the timeout is refunded.
 */
int g_iTacPendingTicks = 0;


/*
 * Consecutive ticks the game spent outside the real
 * pause state while a tactical countdown was running.
 */
int g_iTacStallTicks = 0;


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

Handle g_hTechVerifyTimer = null;


/* =========================================================
 * ROUND DAMAGE / TECHNICAL PAUSE GATE
 *
 * A technical pause only invalidates the round when the
 * round has already produced damage. Without damage the
 * game is simply paused and the round continues after
 * the pause.
 * ========================================================= */

bool g_bRoundHasDamage = false;

/*
 * Technical pause requested during a round that already
 * has damage: play continues until that round is over.
 */
bool g_bTechNextRoundPending = false;

int g_iTechPauseChecks = 0;


/* =========================================================
 * ROUND SNAPSHOT / REWIND
 *
 * Taken at every round start.
 *
 * CS:GO itself writes a complete round backup (score,
 * economy, equipment, positions, round counter); the
 * plugin stores the player statistics that the native
 * backup does not cover, plus the score/round values
 * used to verify a restore.
 * ========================================================= */

bool g_bRoundInvalidated = false;

bool g_bRewindPending = false;

bool g_bRewindInProgress = false;

bool g_bRoundRestored = false;

int g_SnapshotTeamScore[4];

int g_iSnapshotRoundsPlayed = -1;

char g_sSnapshotBackup[PLATFORM_MAX_PATH];

int g_iSnapshotKills[MAXPLAYERS + 1];

int g_iSnapshotDeaths[MAXPLAYERS + 1];

int g_iSnapshotAssists[MAXPLAYERS + 1];

int g_iSnapshotMVPs[MAXPLAYERS + 1];

/*
 * User IDs survive a client slot change, reconnecting
 * players get a new ID and are simply not restored.
 */
int g_iSnapshotUserId[MAXPLAYERS + 1];

bool g_bSnapshotPlayerValid[MAXPLAYERS + 1];


/* =========================================================
 * MATCH STATE
 * ========================================================= */

bool g_bMatchStarted = false;

int g_iCurrentOTSegment = -1;


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
     * Damage detection: decides whether a technical
     * pause may freeze the round in place or has to
     * wait until the round is over.
     */

    HookEvent(
        "player_hurt",
        Event_PlayerHurt,
        EventHookMode_Post
    );


    /*
     * Referee round restore.
     */

    RegConsoleCmd(
        "sm_rewind",
        Command_Rewind
    );

    AddCommandListener(
        CommandListener_RewindMatch,
        "mp_rewind_match"
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


    g_cvTechDamageGate = CreateConVar(
        "sm_mp_technical_damage_gate",
        "1",
        "1 = a technical pause only invalidates the round when the round already produced damage (no damage: pause the round in place). 0 = always terminate the round immediately (V1.2.4 behaviour).",
        0,
        true,
        0.0,
        true,
        1.0
    );


    g_cvRewindEnabled = CreateConVar(
        "sm_mp_rewind_enabled",
        "1",
        "1 = after an invalidated round the referee may restore it with mp_rewind_match (CS:GO round backup + plugin statistics backup).",
        0,
        true,
        0.0,
        true,
        1.0
    );


    /*
     * Native CS:GO ConVars.
     */

    g_cvBackupAuto =
        FindConVar("mp_backup_round_auto");

    g_cvBackupFile =
        FindConVar("mp_backup_round_file");

    g_cvBackupLast =
        FindConVar("mp_backup_round_file_last");


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

public void OnConfigsExecuted()
{
    /*
     * The match config runs after the plugin starts, so
     * the native round backups are enforced here and not
     * in OnPluginStart().
     */

    EnsureRoundBackupsEnabled();
}


void EnsureRoundBackupsEnabled()
{
    if (g_cvBackupAuto != null &&
        !g_cvBackupAuto.BoolValue)
    {
        g_cvBackupAuto.SetInt(1);
    }


    if (g_cvBackupFile == null)
    {
        return;
    }


    /*
     * Never take over a backup name that another plugin
     * (for example Get5) already configured.
     */

    char baseName[64];

    baseName[0] = '\0';

    g_cvBackupFile.GetString(
        baseName,
        sizeof(baseName)
    );


    if (baseName[0] == '\0')
    {
        ServerCommand(
            "mp_backup_round_file \"mpm_backup\""
        );
    }
}


public void OnMapStart()
{
    ResetMatchState();


    /*
     * Game rules exist from this point on, so the
     * real side mapping can be derived immediately.
     */

    RefreshSideMapping();
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


    g_bMatchStarted =
        false;


    g_iCurrentOTSegment =
        -1;


    /*
     * Default identity. It is re-derived from the
     * round counter on every round start, so a late
     * plugin load in the second half is corrected as
     * soon as the next round begins.
     */

    SetInitialSideMapping();
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


    g_bTechNextRoundPending =
        false;


    g_iTechPauseChecks =
        0;


    g_bRoundInvalidated =
        false;


    g_bRewindPending =
        false;


    g_bRewindInProgress =
        false;


    g_bRoundRestored =
        false;


    g_bTacPauseConfirmed =
        false;


    g_iTacTimeLeft =
        0;


    g_iTacPendingTicks =
        0;


    g_iTacStallTicks =
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


    if (g_hTechVerifyTimer != null)
    {
        KillTimer(g_hTechVerifyTimer);

        g_hTechVerifyTimer = null;
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


    /*
     * Re-derive the side mapping before it is used.
     *
     * A pause is usually called during Freeze Time,
     * which is exactly when CS:GO has just switched
     * sides, so the mapping must never be a round
     * behind the game.
     */

    RefreshSideMapping();


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


/* =========================================================
 * SIDE MAPPING
 *
 * The mapping is DERIVED, never toggled, so it cannot drift:
 *
 *   swaps = regulation half already played
 *         + overtime halves already played
 *
 * Every odd number of swaps puts Team A back on CT.
 * ========================================================= */

void SetInitialSideMapping()
{
    g_iMatchTeamForSide[CS_TEAM_CT] =
        MATCH_TEAM_A;

    g_iMatchTeamForSide[CS_TEAM_T] =
        MATCH_TEAM_B;
}


int GetRoundsPlayed()
{
    return GameRules_GetProp(
        "m_totalRoundsPlayed"
    );
}


int GetMaxRounds()
{
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


    return maxRounds;
}


bool IsOvertimeEnabled()
{
    return (
        g_cvOvertimeEnable != null &&
        g_cvOvertimeEnable.BoolValue
    );
}


int CountSideSwaps(int roundsPlayed)
{
    int swaps = 0;


    int maxRounds =
        GetMaxRounds();


    int halfRounds =
        maxRounds / 2;


    if (halfRounds <= 0)
    {
        return 0;
    }


    /*
     * Regulation halftime.
     */

    if (roundsPlayed >= halfRounds)
    {
        swaps++;
    }


    if (!IsOvertimeEnabled())
    {
        return swaps;
    }


    int otRoundsPlayed =
        roundsPlayed - maxRounds;


    if (otRoundsPlayed <= 0)
    {
        return swaps;
    }


    int otRounds =
        GetOTSegmentRounds();


    int halfOT =
        otRounds / 2;


    if (halfOT <= 0)
    {
        return swaps;
    }


    /*
     * OT halves switch at otRoundsPlayed
     * = halfOT, otRounds + halfOT, ...
     *
     * A new OT segment itself starts WITHOUT a
     * side switch.
     */

    if (otRoundsPlayed >= halfOT)
    {
        swaps +=
            1 +
            (otRoundsPlayed - halfOT) / otRounds;
    }


    return swaps;
}


void RefreshSideMapping()
{
    int swaps =
        CountSideSwaps(
            GetRoundsPlayed()
        );


    if ((swaps % 2) == 0)
    {
        SetInitialSideMapping();


        return;
    }


    /*
     * Odd number of side switches:
     * Team A now plays T, Team B now plays CT.
     */

    g_iMatchTeamForSide[CS_TEAM_CT] =
        MATCH_TEAM_B;

    g_iMatchTeamForSide[CS_TEAM_T] =
        MATCH_TEAM_A;
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

bool IsFreezePeriodActive()
{
    return (
        GameRules_GetProp(
            "m_bFreezePeriod"
        ) != 0
    );
}


bool IsMatchWaitingForResume()
{
    return (
        GameRules_GetProp(
            "m_bMatchWaitingForResume"
        ) != 0
    );
}


bool IsCSGOActuallyPaused()
{
    int waitingForResume =
        GameRules_GetProp(
            "m_bMatchWaitingForResume"
        );


    return (
        waitingForResume != 0 &&
        IsFreezePeriodActive()
    );
}


/* =========================================================
 * ROUND SNAPSHOT
 *
 * Runs at every round start.
 *
 * The score/round values are stored so a later restore can
 * be verified, the backup path is captured shortly after
 * the round started (CS:GO writes the file during Freeze
 * Time) and the player statistics are stored because the
 * native CS:GO backup does not contain them.
 * ========================================================= */

void TakeRoundSnapshot()
{
    g_SnapshotTeamScore[CS_TEAM_T] =
        CS_GetTeamScore(CS_TEAM_T);

    g_SnapshotTeamScore[CS_TEAM_CT] =
        CS_GetTeamScore(CS_TEAM_CT);

    g_iSnapshotRoundsPlayed =
        GetRoundsPlayed();


    g_sSnapshotBackup[0] = '\0';


    CreateTimer(
        VALVE_BACKUP_CAPTURE_DELAY,
        Timer_CaptureRoundBackup,
        0,
        TIMER_FLAG_NO_MAPCHANGE
    );


    for (int i = 1; i <= MaxClients; i++)
    {
        g_bSnapshotPlayerValid[i] = false;
    }


    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) ||
            IsFakeClient(i))
        {
            continue;
        }


        int userId =
            GetClientUserId(i);


        if (userId <= 0)
        {
            continue;
        }


        g_iSnapshotUserId[i] =
            userId;

        g_iSnapshotKills[i] =
            GetClientFrags(i);

        g_iSnapshotDeaths[i] =
            GetClientDeaths(i);

        g_iSnapshotAssists[i] =
            CS_GetClientAssists(i);

        g_iSnapshotMVPs[i] =
            CS_GetMVPCount(i);

        g_bSnapshotPlayerValid[i] =
            true;
    }
}


public Action Timer_CaptureRoundBackup(
    Handle timer
)
{
    if (g_cvBackupLast == null)
    {
        return Plugin_Stop;
    }


    g_cvBackupLast.GetString(
        g_sSnapshotBackup,
        sizeof(g_sSnapshotBackup)
    );


    if (g_sSnapshotBackup[0] == '\0')
    {
        LogMessage("No native round backup found (mp_backup_round_file_last is empty).");
    }


    return Plugin_Stop;
}


/* =========================================================
 * SNAPSHOT LOOKUP
 * ========================================================= */

int FindSnapshotSlotById(int userId)
{
    if (userId <= 0)
    {
        return -1;
    }


    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bSnapshotPlayerValid[i])
        {
            continue;
        }


        if (g_iSnapshotUserId[i] == userId)
        {
            return i;
        }
    }


    return -1;
}


/* =========================================================
 * REWIND AVAILABILITY
 * ========================================================= */

bool IsRewindAvailable()
{
    if (g_cvRewindEnabled != null &&
        !g_cvRewindEnabled.BoolValue)
    {
        return false;
    }


    if (g_sSnapshotBackup[0] == '\0')
    {
        return false;
    }


    /*
     * The invalidated round must be exactly the round
     * that was snapshotted.
     */

    return (
        g_iSnapshotRoundsPlayed >= 0 &&
        GetRoundsPlayed() == g_iSnapshotRoundsPlayed + 1
    );
}


/* =========================================================
 * PLAYER STATISTICS RESTORE
 *
 * Only applied after CS:GO restored the round, so this
 * never fights the native restore.
 * ========================================================= */

void SetClientFragsSafe(int client, int value)
{
    if (HasEntProp(client, Prop_Send, "m_iFrags"))
    {
        SetEntProp(client, Prop_Send, "m_iFrags", value);


        return;
    }


    if (HasEntProp(client, Prop_Data, "m_iFrags"))
    {
        SetEntProp(client, Prop_Data, "m_iFrags", value);
    }
}


void SetClientDeathsSafe(int client, int value)
{
    if (HasEntProp(client, Prop_Send, "m_iDeaths"))
    {
        SetEntProp(client, Prop_Send, "m_iDeaths", value);


        return;
    }


    if (HasEntProp(client, Prop_Data, "m_iDeaths"))
    {
        SetEntProp(client, Prop_Data, "m_iDeaths", value);
    }
}


void RestorePlayerStatistics()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) ||
            IsFakeClient(i))
        {
            continue;
        }


        int slot =
            FindSnapshotSlotById(
                GetClientUserId(i)
            );


        if (slot <= 0)
        {
            continue;
        }


        SetClientFragsSafe(
            i,
            g_iSnapshotKills[slot]
        );

        SetClientDeathsSafe(
            i,
            g_iSnapshotDeaths[slot]
        );

        CS_SetClientAssists(
            i,
            g_iSnapshotAssists[slot]
        );

        CS_SetMVPCount(
            i,
            g_iSnapshotMVPs[slot]
        );
    }
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
        /*
         * =================================================
         * REJECTED PAUSE
         * =================================================
         *
         * Inside Freeze Time the native request applies
         * instantly. If the game is already freezing but
         * still has not paused, CS:GO refused the request
         * (for example because it was sent too early, or
         * the pause was already released).
         *
         * Without this check the plugin would wait
         * forever here, keeping the timeout consumed and
         * blocking every later pause.
         */

        if (IsFreezePeriodActive())
        {
            g_iTacPendingTicks++;


            if (g_iTacPendingTicks >
                TAC_PENDING_GRACE_TICKS)
            {
                CancelPendingTacticalPause();


                return Plugin_Stop;
            }
        }
        else
        {
            /*
             * Live round: the queued pause is applied
             * when the next Freeze Time begins.
             */

            g_iTacPendingTicks = 0;
        }


        ShowTacticalPauseUI();


        return Plugin_Continue;
    }


    g_iTacPendingTicks = 0;


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
 *
 * A referee pause and a team pause are different
 * situations and must not share the same wording:
 *
 * REFEREE: nobody in the server can resume it, only
 * the referee through mp_unpause_match.
 *
 * TEAM:    the calling team may resume it with
 * !unpause (and the referee may always override).
 * ========================================================= */

bool IsRefereeTechnicalPause()
{
    return (g_iTechCallerTeam < 0);
}


void GetTechnicalCallerName(
    char[] buffer,
    int maxlen
)
{
    if (IsRefereeTechnicalPause())
    {
        strcopy(
            buffer,
            maxlen,
            "REFEREE"
        );


        return;
    }


    GetMatchTeamName(
        g_iTechCallerTeam,
        buffer,
        maxlen
    );
}


void ShowTechnicalRoundWillFinishUI()
{
    char callerName[64];


    GetTechnicalCallerName(
        callerName,
        sizeof(callerName)
    );


    if (IsRefereeTechnicalPause())
    {
        PrintCenterTextAll(
            "TECHNICAL PAUSE REQUESTED\nCALLED BY THE REFEREE\nTHIS ROUND WILL FINISH FIRST\nTHE ROUND WILL THEN BE RESTORED"
        );


        return;
    }


    PrintCenterTextAll(
        "TECHNICAL PAUSE REQUESTED\nCALLED BY %s\nTHIS ROUND WILL FINISH FIRST\nTHE ROUND WILL THEN BE RESTORED",
        callerName
    );
}


void ShowTechnicalRestartUI()
{
    char callerName[64];


    GetTechnicalCallerName(
        callerName,
        sizeof(callerName)
    );


    if (IsRefereeTechnicalPause())
    {
        PrintCenterTextAll(
            "TECHNICAL PAUSE\nCALLED BY THE REFEREE\nCURRENT ROUND IS INVALID\nROUND IS RESTARTING..."
        );


        return;
    }


    PrintCenterTextAll(
        "TECHNICAL PAUSE\nCALLED BY %s\nCURRENT ROUND IS INVALID\nROUND IS RESTARTING...",
        callerName
    );
}


/*
 * Status line shared by both technical pause UIs.
 */

void GetTechnicalRoundStatus(
    char[] buffer,
    int maxlen
)
{
    if (!g_bRoundInvalidated)
    {
        strcopy(
            buffer,
            maxlen,
            "This round is still valid. Play resumes on unpause."
        );


        return;
    }


    if (g_bRewindPending)
    {
        strcopy(
            buffer,
            maxlen,
            "ROUND INVALID. Referee: mp_rewind_match to restore."
        );


        return;
    }


    if (g_bRoundRestored)
    {
        strcopy(
            buffer,
            maxlen,
            "Round restored. Ready to resume."
        );


        return;
    }


    strcopy(
        buffer,
        maxlen,
        "ROUND INVALID and not restored."
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
    char status[128];


    GetTechnicalCallerName(
        callerName,
        sizeof(callerName)
    );

    GetTechnicalRoundStatus(
        status,
        sizeof(status)
    );


    /*
     * Referee pause: no player command can end it.
     */

    if (IsRefereeTechnicalPause())
    {
        PrintCenterTextAll(
            "TECHNICAL PAUSE\nCALLED BY THE REFEREE\n%s\nOnly the referee can resume the match",
            status
        );


        return;
    }


    /*
     * Team pause: the calling team resumes it.
     */

    PrintCenterTextAll(
        "TECHNICAL PAUSE\nCALLED BY %s\n%s\nCalling team: type !unpause when ready",
        callerName,
        status
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
 * ROUND DAMAGE
 *
 * Any damage applied to a player marks the round as
 * "already fought", which decides whether a technical
 * pause may freeze the round in place.
 * ========================================================= */

public void Event_PlayerHurt(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    if (GameRules_GetProp("m_bWarmupPeriod") != 0)
    {
        return;
    }


    g_bRoundHasDamage =
        true;
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
     * =====================================================
     * SIDE MAPPING
     * =====================================================
     *
     * CS:GO has already performed its own halftime
     * (or overtime half) switch when this fires, so
     * re-derive which roster plays which side before
     * anything else uses the mapping.
     */

    RefreshSideMapping();


    /*
     * A new round starts with no damage in it.
     */

    g_bRoundHasDamage = false;


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
     * ROUND SNAPSHOT
     * =====================================================
     *
     * Skipped while the invalidated round is still
     * waiting to be restored, otherwise the snapshot
     * it needs would be overwritten.
     */

    if (!g_bTechNextRoundPending &&
        !g_bRewindPending &&
        !g_bRewindInProgress)
    {
        TakeRoundSnapshot();
    }


    /*
     * =====================================================
     * TECHNICAL PAUSE AFTER AN INVALIDATED ROUND
     * =====================================================
     *
     * The damaging round is over, so this new round is
     * paused and offered for a restore.
     */

    if (g_bTechNextRoundPending)
    {
        g_bTechNextRoundPending =
            false;


        /*
         * A new overtime segment may have started with
         * this round, refresh the timeouts before the
         * pause takes over.
         */

        HandleOvertimeCounts();


        BeginTechnicalPause(
            g_iTechCallerTeam,
            true
        );


        return;
    }


    /*
     * =====================================================
     * TECHNICAL RESTART (LEGACY, sm_mp_technical_damage_gate 0)
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
     * Overtime.
     *
     * Side switching itself is handled by
     * RefreshSideMapping(); only the per-OT-segment
     * tactical pause refresh is left here.
     */

    HandleOvertimeCounts();
}


/* =========================================================
 * NORMAL LIVE
 * ========================================================= */

public Action Timer_Live(
    Handle timer
)
{
    if (g_PauseState == PAUSE_NONE &&
        !g_bTechnicalRestartPending &&
        !g_bTechNextRoundPending)
    {
        PrintToChatAll(
            "%s \x04LIVE! LIVE! LIVE!",
            PREFIX
        );
    }


    return Plugin_Stop;
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


void HandleOvertimeCounts()
{
    if (!IsOvertimeEnabled())
    {
        return;
    }


    int maxRounds =
        GetMaxRounds();


    int roundsPlayed =
        GetRoundsPlayed();


    /*
     * Regulation is not over yet.
     */

    if (roundsPlayed < maxRounds)
    {
        return;
    }


    int otRounds =
        GetOTSegmentRounds();


    if (otRounds <= 0)
    {
        return;
    }


    /*
     * Only a draw can lead to overtime.
     */

    if (CS_GetTeamScore(CS_TEAM_T) !=
        CS_GetTeamScore(CS_TEAM_CT))
    {
        return;
    }


    /*
     * ==========================================
     * OT Segment Pause Refresh
     * ==========================================
     *
     * Once into a new OT Segment,
     * both teams get a new OT tactical pause.
     *
     * A new OT segment starts WITHOUT a side
     * switch, so this must not touch the mapping.
     */

    int otRoundsPlayed =
        roundsPlayed - maxRounds;


    int segment =
        otRoundsPlayed / otRounds;


    if (segment == g_iCurrentOTSegment)
    {
        return;
    }


    g_iCurrentOTSegment =
        segment;


    int count = 0;


    if (g_cvOTCount != null)
    {
        count =
            g_cvOTCount.IntValue;


        if (count < 0)
        {
            count = 0;
        }
    }


    g_iTacRemaining[MATCH_TEAM_A] = count;
    g_iTacRemaining[MATCH_TEAM_B] = count;

    g_bTacUsedThisRound[MATCH_TEAM_A] = false;
    g_bTacUsedThisRound[MATCH_TEAM_B] = false;


    PrintToChatAll(
        "%s \x04Overtime\x01 started. Tactical timeouts refreshed: \x04%d\x01 per team.",
        PREFIX,
        count
    );
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
     * Don't allow a tactical pause while a technical
     * pause is being prepared or restarted.
     */

    if (g_PauseState == PAUSE_TECHNICAL_PENDING ||
        g_bTechNextRoundPending)
    {
        PrintToChat(
            client,
            "%s A technical pause is already being prepared.",
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


    g_iTacPendingTicks =
        0;


    g_iTacStallTicks =
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
     *
     * A short hiccup is tolerated, but if the game
     * stays unpaused the pause really is over and the
     * plugin must not stay stuck in PAUSE_TACTICAL.
     */

    if (!IsCSGOActuallyPaused())
    {
        g_iTacStallTicks++;


        if (g_iTacStallTicks > TAC_STALL_GRACE_TICKS)
        {
            g_hTacTimer = null;


            ReleaseTacticalPause();


            return Plugin_Stop;
        }


        ShowTacticalPauseUI();


        return Plugin_Continue;
    }


    g_iTacStallTicks = 0;


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


    g_iTacPendingTicks =
        0;


    g_iTacStallTicks =
        0;


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
 * CANCEL PENDING TACTICAL PAUSE
 *
 * CS:GO never entered the real pause state, so the
 * timeout was never used. Refund it, clear the pause
 * state and let both teams call a pause again.
 * ========================================================= */

void CancelPendingTacticalPause()
{
    if (g_PauseState != PAUSE_TACTICAL ||
        g_bTacPauseConfirmed)
    {
        return;
    }


    int team =
        g_iPausingTeam;


    if (team >= 0 &&
        team < MATCH_TEAM_COUNT)
    {
        g_iTacRemaining[team]++;

        g_bTacUsedThisRound[team] = false;
    }


    KillTacticalTimer();

    KillTacticalPauseCheckTimer();


    g_PauseState =
        PAUSE_NONE;


    g_iPausingTeam =
        -1;


    g_bTacPauseConfirmed =
        false;


    g_iTacTimeLeft =
        0;


    g_iTacPendingTicks =
        0;


    g_iTacStallTicks =
        0;


    PrintToChatAll(
        "%s CS:GO did not enter the pause state. The tactical timeout was not used.",
        PREFIX
    );


    PrintCenterTextAll(
        "TACTICAL PAUSE FAILED\nTIMEOUT NOT USED"
    );
}


/* =========================================================
 * RELEASE TACTICAL PAUSE
 *
 * The game left the pause state on its own (for example
 * a round restart, a map vote or a native unpause that
 * the plugin did not originate).
 *
 * The plugin must not stay in PAUSE_TACTICAL forever,
 * otherwise every later pause would be rejected.
 * ========================================================= */

void ReleaseTacticalPause()
{
    if (g_PauseState != PAUSE_TACTICAL)
    {
        return;
    }


    KillTacticalTimer();

    KillTacticalPauseCheckTimer();


    g_PauseState =
        PAUSE_NONE;


    g_iPausingTeam =
        -1;


    g_bTacPauseConfirmed =
        false;


    g_iTacTimeLeft =
        0;


    g_iTacPendingTicks =
        0;


    g_iTacStallTicks =
        0;


    PrintToChatAll(
        "%s The tactical timeout was ended by the server.",
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
        g_PauseState == PAUSE_TECHNICAL_PENDING ||
        g_bTechNextRoundPending ||
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


        g_iTacPendingTicks =
            0;


        g_iTacStallTicks =
            0;


        InternalUnpauseMatch();
    }


    /*
     * =====================================================
     * CALLER ANNOUNCEMENT
     *
     * Referee and team pauses are announced
     * differently, because only a team pause can be
     * ended by the players themselves.
     * ===================================================== */

    AnnounceTechnicalPauseCaller(callerTeam);


    /*
     * =====================================================
     * ROUND DAMAGE GATE
     * =====================================================
     *
     * Sm_mp_technical_damage_gate 0 restores the old
     * V1.2.4 behaviour: the round is terminated at once.
     *
     * Otherwise a round that already produced damage is
     * played out first, because its result cannot be
     * thrown away safely, and only the following round
     * is paused (and offered for a restore).
     */

    if (!IsTechnicalPauseDamageGated())
    {
        StartLegacyRoundTermination(callerTeam);


        return;
    }


    if (g_bRoundHasDamage)
    {
        WaitForRoundEndBeforeTechnicalPause(callerTeam);


        return;
    }


    /*
     * No damage: freeze the round in place, no
     * invalidation and nothing to restore.
     */

    BeginTechnicalPause(callerTeam, false);
}


bool IsTechnicalPauseDamageGated()
{
    return (
        g_cvTechDamageGate == null ||
        g_cvTechDamageGate.BoolValue
    );
}


void AnnounceTechnicalPauseCaller(int callerTeam)
{
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


        return;
    }


    PrintToChatAll(
        "%s \x04Technical timeout\x01 called by the \x04REFEREE\x01.",
        PREFIX
    );
}


void PrintTechnicalResumeHint(int callerTeam)
{
    if (callerTeam >= 0)
    {
        char teamName[64];


        GetMatchTeamName(
            callerTeam,
            teamName,
            sizeof(teamName)
        );


        PrintToChatAll(
            "%s \x04%s\x01 may type \x04!unpause\x01 when the team is ready.",
            PREFIX,
            teamName
        );


        return;
    }


    PrintToChatAll(
        "%s Only the referee can resume the match.",
        PREFIX
    );
}


/* =========================================================
 * DAMAGING ROUND: WAIT FOR ROUND END
 * ========================================================= */

void WaitForRoundEndBeforeTechnicalPause(int callerTeam)
{
    g_iTechCallerTeam =
        callerTeam;


    g_bTechNextRoundPending =
        true;


    g_PauseState =
        PAUSE_TECHNICAL_PENDING;


    PrintToChatAll(
        "%s \x04This round already produced damage\x01, so it is played out first.",
        PREFIX
    );


    PrintToChatAll(
        "%s The technical pause starts when this round is over, and the round will be restored.",
        PREFIX
    );


    if (g_cvRewindEnabled != null &&
        g_cvRewindEnabled.BoolValue)
    {
        PrintToChatAll(
            "%s Referee: use \x04mp_rewind_match\x01 after the pause started to restore the round.",
            PREFIX
        );
    }


    PrintToChatAll(
        "%s Referee or calling team: type \x04!unpause\x01 to cancel this request.",
        PREFIX
    );


    ShowTechnicalRoundWillFinishUI();
}


/* =========================================================
 * CANCEL A PENDING TECHNICAL PAUSE
 *
 * Nothing was invalidated yet, so the match simply
 * continues as if the request never happened.
 * ========================================================= */

void CancelPendingTechnicalPause()
{
    if (g_PauseState != PAUSE_TECHNICAL_PENDING)
    {
        return;
    }


    g_bTechNextRoundPending =
        false;

    g_PauseState =
        PAUSE_NONE;

    g_iTechCallerTeam =
        -1;

    g_bRoundInvalidated =
        false;


    PrintToChatAll(
        "%s Technical timeout request cancelled. The round continues.",
        PREFIX
    );


    PrintCenterTextAll(
        "TECHNICAL PAUSE CANCELLED\nPLAY CONTINUES"
    );
}


/* =========================================================
 * TECHNICAL PAUSE START
 *
 * invalidRound = the round that was played is invalid and
 *                has to be restored by the referee.
 * ========================================================= */

void BeginTechnicalPause(
    int callerTeam,
    bool invalidRound
)
{
    g_iTechCallerTeam =
        callerTeam;

    g_PauseState =
        PAUSE_TECHNICAL;

    g_bTechnicalRoundActive =
        true;

    g_bTechnicalRestartPending =
        false;

    g_bRoundInvalidated =
        invalidRound;

    g_bRoundRestored =
        false;

    g_iTechPauseChecks =
        0;


    KillTechnicalTimers();


    if (invalidRound)
    {
        g_bRewindPending =
            IsRewindAvailable();


        LogMessage(
            "Technical pause after an invalid round: backup=\"%s\" snapshot_round=%d round_now=%d rewind_armed=%d",
            g_sSnapshotBackup,
            g_iSnapshotRoundsPlayed,
            GetRoundsPlayed(),
            g_bRewindPending
        );


        if (g_bRewindPending)
        {
            PrintToChatAll(
                "%s \x04This round is invalid.\x01 Referee: use \x04mp_rewind_match\x01 to restore it.",
                PREFIX
            );
        }
        else
        {
            PrintToChatAll(
                "%s \x07This round is invalid,\x01 but no CS:GO round backup is available to restore it.",
                PREFIX
            );


            if (g_cvRewindEnabled == null ||
                !g_cvRewindEnabled.BoolValue)
            {
                PrintToChatAll(
                    "%s Round restore is disabled (sm_mp_rewind_enabled 0).",
                    PREFIX
                );
            }
        }
    }
    else
    {
        g_bRewindPending =
            false;


        PrintToChatAll(
            "%s \x04No damage was done\x01, so the round is kept as it is.",
            PREFIX
        );
    }


    PrintToChatAll(
        "%s The match is now paused.",
        PREFIX
    );


    PrintTechnicalResumeHint(callerTeam);


    ShowTechnicalPauseUI();


    g_hTechUITimer = CreateTimer(
        1.0,
        Timer_TechnicalUI,
        0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );


    /*
     * Pause the game.
     */

    InternalPauseMatch();


    /*
     * Make sure CS:GO really reached the pause state.
     */

    g_hTechVerifyTimer = CreateTimer(
        TECH_PAUSE_VERIFY_INTERVAL,
        Timer_VerifyTechnicalPause,
        0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );
}


/* =========================================================
 * LEGACY: TERMINATE THE ROUND AT ONCE
 * ========================================================= */

void StartLegacyRoundTermination(int callerTeam)
{
    g_iTechCallerTeam =
        callerTeam;

    g_PauseState =
        PAUSE_TECHNICAL;

    g_bTechnicalRoundActive =
        false;

    g_bTechnicalRestartPending =
        true;

    g_bRoundInvalidated =
        true;

    g_bRewindPending =
        false;

    g_bRoundRestored =
        false;

    g_iTechPauseChecks =
        0;


    KillTechnicalTimers();


    PrintToChatAll(
        "%s The current round is invalid and will be restarted.",
        PREFIX
    );


    PrintTechnicalResumeHint(callerTeam);


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
 * TECHNICAL PAUSE VERIFICATION
 * ========================================================= */

public Action Timer_VerifyTechnicalPause(
    Handle timer
)
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        g_hTechVerifyTimer = null;


        return Plugin_Stop;
    }


    if (IsMatchWaitingForResume())
    {
        g_hTechVerifyTimer = null;


        return Plugin_Stop;
    }


    if (g_iTechPauseChecks >= TECH_PAUSE_VERIFY_TRIES)
    {
        g_hTechVerifyTimer = null;


        PrintToChatAll(
            "%s \x07CS:GO did not enter the pause state.\x01 Referee: use \x04mp_pause_match\x01.",
            PREFIX
        );


        return Plugin_Stop;
    }


    g_iTechPauseChecks++;


    InternalPauseMatch();


    return Plugin_Continue;
}


/* =========================================================
 * ROUND REWIND (REFEREE)
 *
 * Restores an invalidated round from the native CS:GO
 * round backup (score, economy, equipment, positions and
 * the round counter) and re-applies the player
 * statistics from the plugin snapshot.
 * ========================================================= */

public Action Command_Rewind(
    int client,
    int args
)
{
    if (client > 0 &&
        !CheckCommandAccess(
            client,
            "sm_rewind",
            ADMFLAG_GENERIC
        ))
    {
        PrintToChat(
            client,
            "%s Only a referee may restore a round.",
            PREFIX
        );


        return Plugin_Handled;
    }


    TryRewind(client);


    return Plugin_Handled;
}


public Action CommandListener_RewindMatch(
    int client,
    const char[] command,
    int argc
)
{
    /*
     * Server console / rcon = referee.
     */

    if (client > 0 &&
        !CheckCommandAccess(
            client,
            "sm_rewind",
            ADMFLAG_GENERIC
        ))
    {
        PrintToChat(
            client,
            "%s Only a referee may restore a round.",
            PREFIX
        );


        return Plugin_Handled;
    }


    TryRewind(client);


    return Plugin_Handled;
}


void ReplyToReferee(
    int client,
    const char[] message
)
{
    if (client > 0)
    {
        PrintToChat(
            client,
            "%s %s",
            PREFIX,
            message
        );


        return;
    }


    PrintToServer(
        "%s %s",
        PREFIX,
        message
    );
}


void TryRewind(int client)
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        ReplyToReferee(
            client,
            "There is no paused round to restore."
        );


        return;
    }


    if (g_bRewindInProgress)
    {
        ReplyToReferee(
            client,
            "A round restore is already in progress."
        );


        return;
    }


    if (!g_bRoundInvalidated)
    {
        ReplyToReferee(
            client,
            "This round was paused without damage and is still valid. Nothing to restore."
        );


        return;
    }


    if (g_bRoundRestored)
    {
        ReplyToReferee(
            client,
            "This round has already been restored."
        );


        return;
    }


    if (!g_bRewindPending)
    {
        ReplyToReferee(
            client,
            "There is no round restore available for this pause."
        );


        return;
    }


    if (g_sSnapshotBackup[0] == '\0')
    {
        g_bRewindPending =
            false;


        PrintToChatAll(
            "%s \x07Round restore FAILED:\x01 CS:GO did not create a round backup for this round.",
            PREFIX
        );


        PrintToChatAll(
            "%s Check that \x04mp_backup_round_auto 1\x01 and \x04mp_backup_round_file\x01 are set.",
            PREFIX
        );


        ShowTechnicalPauseUI();


        return;
    }


    g_bRewindInProgress =
        true;


    /*
     * Let CS:GO restore the round. The command is
     * asynchronous, the result is checked later.
     */

    ServerCommand(
        "mp_backup_restore_load_file \"%s\"",
        g_sSnapshotBackup
    );

    ServerExecute();


    PrintToChatAll(
        "%s Restoring the round from the CS:GO backup...",
        PREFIX
    );


    CreateTimer(
        REWIND_APPLY_DELAY,
        Timer_RewindApply,
        0,
        TIMER_FLAG_NO_MAPCHANGE
    );
}


public Action Timer_RewindApply(
    Handle timer
)
{
    if (!g_bRewindInProgress)
    {
        return Plugin_Stop;
    }


    g_bRewindInProgress =
        false;


    if (g_PauseState != PAUSE_TECHNICAL)
    {
        return Plugin_Stop;
    }


    int scoreT =
        CS_GetTeamScore(CS_TEAM_T);

    int scoreCT =
        CS_GetTeamScore(CS_TEAM_CT);

    int roundsNow =
        GetRoundsPlayed();


    bool scoreRestored = (
        scoreT == g_SnapshotTeamScore[CS_TEAM_T] &&
        scoreCT == g_SnapshotTeamScore[CS_TEAM_CT]
    );


    bool roundsRestored = (
        g_iSnapshotRoundsPlayed >= 0 &&
        roundsNow <= g_iSnapshotRoundsPlayed
    );


    /*
     * The native backup does not store player
     * statistics, so they are restored by the plugin.
     */

    RestorePlayerStatistics();


    /*
     * Keep the restored round paused.
     */

    InternalPauseMatch();


    /*
     * A failed restore keeps the restore arming, so the
     * referee may run the command again.
     */

    g_bRoundRestored =
        (scoreRestored || roundsRestored);

    g_bRewindPending =
        !g_bRoundRestored;


    LogMessage(
        "Round rewind: backup=%s score_restored=%d rounds_restored=%d rounds_before=%d rounds_now=%d",
        g_sSnapshotBackup,
        scoreRestored,
        roundsRestored,
        g_iSnapshotRoundsPlayed,
        roundsNow
    );


    if (g_bRoundRestored)
    {
        PrintToChatAll(
            "%s \x04Round restored.\x01 Score is back to \x04%d:%d\x01, player statistics were restored as well.",
            PREFIX,
            scoreT,
            scoreCT
        );

        PrintToChatAll(
            "%s Referee: use \x04mp_unpause_match\x01 to resume the restored round.",
            PREFIX
        );
    }
    else
    {
        PrintToChatAll(
            "%s \x07Round restore could not be verified.\x01 Score is %d:%d, round counter %d (snapshot %d).",
            PREFIX,
            scoreT,
            scoreCT,
            roundsNow,
            g_iSnapshotRoundsPlayed
        );

        PrintToChatAll(
            "%s The round stays invalid. Check the server console and the CS:GO backup settings.",
            PREFIX
        );
    }


    /*
     * The state that is now playing IS the snapshot,
     * so it becomes the snapshot of this round.
     */

    TakeRoundSnapshot();


    ShowTechnicalPauseUI();


    return Plugin_Stop;
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
        else if (g_PauseState == PAUSE_TECHNICAL_PENDING)
        {
            CancelPendingTechnicalPause();
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
     * TECHNICAL PAUSE WAITING FOR THE ROUND TO END
     * ===================================================== */

    if (g_PauseState == PAUSE_TECHNICAL_PENDING)
    {
        if (g_iTechCallerTeam >= 0 &&
            matchTeam == g_iTechCallerTeam)
        {
            CancelPendingTechnicalPause();


            return;
        }


        PrintToChat(
            client,
            "%s A technical pause is already being prepared.",
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


    /*
     * The referee resumes a round that is still marked
     * as invalid: say it out loud, the score keeps the
     * result of that round.
     */

    if (g_bRoundInvalidated &&
        g_bRewindPending)
    {
        PrintToChatAll(
            "%s \x07Resuming without a restore.\x01 The invalidated round keeps its result.",
            PREFIX
        );
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


    g_bRoundInvalidated =
        false;

    g_bRewindPending =
        false;

    g_bRewindInProgress =
        false;

    g_bRoundRestored =
        false;

    g_iTechPauseChecks =
        0;


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
     * A technical pause is already running
     * (or is being prepared): nothing to do.
     */

    if (g_PauseState == PAUSE_TECHNICAL ||
        g_PauseState == PAUSE_TECHNICAL_PENDING ||
        g_bTechNextRoundPending ||
        g_bTechnicalRestartPending)
    {
        return Plugin_Handled;
    }


    /*
     * =====================================================
     * EXTERNAL mp_pause_match = REFEREE
     * =====================================================
     *
     * From the console this is a referee technical pause.
     *
     * When a tactical pause is already active this call
     * is the documented upgrade path:
     *
     * tactical timeout refunded -> technical pause.
     *
     * StartTechnicalPause() handles that transition, so
     * the command must not be swallowed here.
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
     * =====================================================
     * NO PAUSE TRACKED
     * =====================================================
     *
     * Never swallow the native command in this case:
     * the referee must always be able to resume the
     * match, even when the plugin believes that
     * nothing is paused (out-of-sync state, another
     * plugin's pause, a manual pause, ...).
     */

    if (g_PauseState == PAUSE_NONE)
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
 * Technical pause:
 *
 * Chat is NOT blocked.
 * The player's message is still allowed to appear normally.
 *
 * The plugin only sends a warning to the player who chatted.
 *
 * IMPORTANT:
 *
 * Do NOT return Plugin_Handled.
 *
 * Plugin_Continue allows the original chat message
 * to continue normally.
 * ========================================================= */

public Action OnClientSayCommand(
    int client,
    const char[] command,
    const char[] sArgs
)
{
    if (g_PauseState != PAUSE_TECHNICAL)
    {
        return Plugin_Continue;
    }


    if (client <= 0 ||
        client > MaxClients ||
        !IsClientInGame(client))
    {
        return Plugin_Continue;
    }


    /*
     * Only players who are on a team are warned.
     * Spectators, coaches and HLTV are not part of
     * the match and may keep talking.
     */

    int side =
        GetClientTeam(client);


    if (side != CS_TEAM_T &&
        side != CS_TEAM_CT)
    {
        return Plugin_Continue;
    }


    /*
     * Skip empty messages and chat commands
     * (!pause, /unpause, .bp ...), so the warning
     * only fires for actual talk.
     */

    int start = 0;


    while (sArgs[start] == ' ' ||
           sArgs[start] == '\t')
    {
        start++;
    }


    if (sArgs[start] == '\0' ||
        sArgs[start] == '!' ||
        sArgs[start] == '/' ||
        sArgs[start] == '.')
    {
        return Plugin_Continue;
    }


    PrintToChat(
        client,
        "%s \x07WARNING:\x01 Communication is not allowed during technical timeouts.",
        PREFIX
    );


    return Plugin_Continue;
}
