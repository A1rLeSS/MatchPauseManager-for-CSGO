#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <cstrike>
#include <sdktools>

#define PLUGIN_VERSION "1.2.7"

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
 * BROADCAST TEXT
 *
 * Every [CM] message of the plugin lives in this table, so the
 * wording can be switched at runtime between the styles real
 * tournaments use:
 *
 * 0 = international broadcast (English, ESL/PGL style)
 * 1 = Chinese tournament
 * 2 = international broadcast + rule reminders
 *
 * The entries are format strings; the message sites supply the
 * same arguments they always did.
 * ========================================================= */

enum
{
    TEXT_HUD_TAC_PENDING = 0,
    TEXT_HUD_TAC_ACTIVE,
    TEXT_TAC_ACTIVE,
    TEXT_HUD_TAC_ENDED,
    TEXT_HUD_TAC_DECLINED,
    TEXT_TAC_DECLINED,
    TEXT_TAC_SERVER_ENDED,
    TEXT_TAC_CALLED,
    TEXT_TAC_PENDING,
    TEXT_TAC_TIMEOUTS,
    TEXT_TAC_WARN,
    TEXT_TAC_ENDED,
    TEXT_HUD_TECH_WILLFINISH_REF,
    TEXT_HUD_TECH_WILLFINISH_TEAM,
    TEXT_HUD_TECH_RESTART_REF,
    TEXT_HUD_TECH_RESTART_TEAM,
    TEXT_STATUS_VALID,
    TEXT_STATUS_INVALID,
    TEXT_STATUS_RESTORED,
    TEXT_STATUS_NOTRESTORED,
    TEXT_STATUS_RESTORING,
    TEXT_HUD_TECH_REF,
    TEXT_HUD_TECH_TEAM,
    TEXT_TECH_RESTARTED,
    TEXT_TECH_CALLED,
    TEXT_TECH_CALLED_REF,
    TEXT_TECH_UNPAUSE_HINT,
    TEXT_TECH_REF_ONLY,
    TEXT_TECH_DAMAGE,
    TEXT_TECH_AFTER_ROUND,
    TEXT_TECH_REWIND_HINT,
    TEXT_TECH_CANCEL_HINT,
    TEXT_TECH_CANCELLED,
    TEXT_HUD_TECH_CANCELLED,
    TEXT_TECH_INVALID,
    TEXT_TECH_NO_BACKUP,
    TEXT_TECH_REWIND_OFF,
    TEXT_TECH_NO_DAMAGE,
    TEXT_TECH_NO_DAMAGE_VOID,
    TEXT_TECH_PAUSED,
    TEXT_TECH_LEGACY_INVALID,
    TEXT_TECH_VERIFY_FAIL,
    TEXT_TECH_ENDED,
    TEXT_HUD_TECH_ENDED,
    TEXT_LIVE,
    TEXT_HUD_LIVE,
    TEXT_REW_FAIL,
    TEXT_REW_FAIL_HINT,
    TEXT_REW_START,
    TEXT_REW_OK,
    TEXT_REW_OK_HINT,
    TEXT_REW_UNVERIFIED,
    TEXT_REW_STAYS_INVALID,
    TEXT_RESUME_NO_RESTORE,
    TEXT_REW_REF_ONLY,
    TEXT_REW_NONE,
    TEXT_REW_BUSY,
    TEXT_REW_VALID,
    TEXT_REW_DONE,
    TEXT_REW_UNAVAILABLE,
    TEXT_TAC_PLAYER_ONLY,
    TEXT_TECH_PREPARING,
    TEXT_PAUSE_ACTIVE,
    TEXT_TAC_TEAM_ONLY,
    TEXT_TAC_USED,
    TEXT_TAC_NONE,
    TEXT_TECH_TEAM_ONLY,
    TEXT_RESTART_BUSY,
    TEXT_NO_PAUSE,
    TEXT_TEAM_ONLY,
    TEXT_TECH_PREPARING_LONG,
    TEXT_ONLY_REF_END,
    TEXT_ONLY_CALLING_TEAM,
    TEXT_TAC_NOT_STARTED,
    TEXT_OVERTIME,
    TEXT_SAY_WARNING,
    TEXT_COUNT
};

#define TEXT_STYLE_INTL  0
#define TEXT_STYLE_CN    1
#define TEXT_STYLE_RULES 2
#define TEXT_STYLE_COUNT 3

#define TEXT_LEN 160

char g_sText[TEXT_STYLE_COUNT][TEXT_COUNT][TEXT_LEN];

int g_iTextStyle = TEXT_STYLE_INTL;

ConVar g_cvTextStyle;

#define CMT(%1) g_sText[g_iTextStyle][%1]

void SetCMText(int style, int id, const char[] text)
{
    strcopy(g_sText[style][id], TEXT_LEN, text);
}

int ReadTextStyle()
{
    if (g_cvTextStyle == null)
    {
        return TEXT_STYLE_INTL;
    }

    int style = g_cvTextStyle.IntValue;

    if (style < TEXT_STYLE_INTL || style >= TEXT_STYLE_COUNT)
    {
        return TEXT_STYLE_INTL;
    }

    return style;
}

public void OnTextStyleChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_iTextStyle = ReadTextStyle();
}

void LoadBroadcastTexts()
{
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TAC_PENDING, "TACTICAL TIMEOUT\n%s\nPAUSE PENDING");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TAC_ACTIVE, "TACTICAL TIMEOUT\n%s\n%d SECONDS REMAINING\nTIMEOUTS LEFT %d");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_ACTIVE, "%s \x04TACTICAL TIMEOUT\x01 — \x04%d SECONDS\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TAC_ENDED, "TACTICAL TIMEOUT ENDED\nRESUME");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TAC_DECLINED, "TACTICAL TIMEOUT DECLINED\nTIMEOUT NOT USED");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_DECLINED, "%s \x07TACTICAL TIMEOUT DECLINED\x01 — THE SERVER DID NOT ENTER PAUSE. NO TIMEOUT USED.");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_SERVER_ENDED, "%s \x07TACTICAL TIMEOUT ENDED BY THE SERVER\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_CALLED, "%s \x04TACTICAL TIMEOUT\x01 — %s");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_PENDING, "%s PAUSE PENDING — WAITING FOR THE SERVER");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_TIMEOUTS, "%s TIME \x04%d SEC\x01 | TIMEOUTS LEFT \x04%d\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_WARN, "%s TACTICAL TIMEOUT ENDS IN \x04%d SEC%s\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_ENDED, "%s \x04TACTICAL TIMEOUT ENDED\x01 — RESUME");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_WILLFINISH_REF, "TECHNICAL PAUSE REQUESTED\nTHE REFEREE\nROUND IS PLAYED OUT FIRST\nTHE ROUND WILL BE RESTORED");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_WILLFINISH_TEAM, "TECHNICAL PAUSE REQUESTED\n%s\nROUND IS PLAYED OUT FIRST\nTHE ROUND WILL BE RESTORED");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_RESTART_REF, "TECHNICAL PAUSE\nTHE REFEREE\nROUND INVALID\nRESTARTING");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_RESTART_TEAM, "TECHNICAL PAUSE\n%s\nROUND INVALID\nRESTARTING");
    SetCMText(TEXT_STYLE_INTL, TEXT_STATUS_VALID, "ROUND IS VALID — RESUME ON UNPAUSE");
    SetCMText(TEXT_STYLE_INTL, TEXT_STATUS_INVALID, "ROUND INVALID — ADMIN: mp_rewind_match");
    SetCMText(TEXT_STYLE_INTL, TEXT_STATUS_RESTORED, "ROUND RESTORED — READY");
    SetCMText(TEXT_STYLE_INTL, TEXT_STATUS_NOTRESTORED, "ROUND INVALID — NOT RESTORED");
    SetCMText(TEXT_STYLE_INTL, TEXT_STATUS_RESTORING, "ROUND VOIDED — RESTORING ROUND START");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_REF, "TECHNICAL PAUSE\nTHE REFEREE\n%s\nONLY THE REFEREE CAN RESUME");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_TEAM, "TECHNICAL PAUSE\n%s\n%s\nCALLING TEAM: TYPE !unpause");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_RESTARTED, "%s TECHNICAL PAUSE — ROUND RESTARTED");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_CALLED, "%s \x04TECHNICAL PAUSE\x01 — %s");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_CALLED_REF, "%s \x04TECHNICAL PAUSE\x01 — REFEREE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_UNPAUSE_HINT, "%s %s MAY TYPE \x04!unpause\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_REF_ONLY, "%s ONLY THE REFEREE CAN RESUME");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_DAMAGE, "%s \x04ROUND ALREADY IN PROGRESS\x01 — DAMAGE DONE, THE ROUND IS PLAYED OUT FIRST");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_AFTER_ROUND, "%s TECHNICAL PAUSE STARTS AFTER THIS ROUND — THE ROUND WILL BE RESTORED");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_REWIND_HINT, "%s \x04ADMIN: mp_rewind_match\x01 TO RESTORE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_CANCEL_HINT, "%s \x04!unpause\x01 / \x04mp_unpause_match\x01 TO CANCEL");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_CANCELLED, "%s \x07TECHNICAL PAUSE CANCELLED\x01 — ROUND CONTINUES");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_CANCELLED, "TECHNICAL PAUSE CANCELLED\nPLAY CONTINUES");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_INVALID, "%s \x07ROUND INVALID\x01 — ADMIN: \x04mp_rewind_match\x01 TO RESTORE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_NO_BACKUP, "%s \x07ROUND INVALID\x01 — NO ROUND BACKUP AVAILABLE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_REWIND_OFF, "%s ROUND RESTORE DISABLED (\x04sm_mp_rewind_enabled 0\x01)");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_NO_DAMAGE, "%s \x04NO DAMAGE DONE\x01 — ROUND CONTINUES AFTER THE PAUSE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_NO_DAMAGE_VOID, "%s \x04NO DAMAGE DONE\x01 — ROUND VOIDED, RESTORING ROUND START");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_PAUSED, "%s \x04MATCH PAUSED\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_LEGACY_INVALID, "%s \x07ROUND INVALID\x01 — RESTARTING");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_VERIFY_FAIL, "%s \x07SERVER DID NOT ENTER PAUSE\x01 — USE \x04mp_pause_match\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_ENDED, "%s \x04TECHNICAL PAUSE ENDED\x01 — GET READY");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_TECH_ENDED, "TECHNICAL PAUSE ENDED\nGET READY");
    SetCMText(TEXT_STYLE_INTL, TEXT_LIVE, "%s \x04LIVE! LIVE! LIVE!");
    SetCMText(TEXT_STYLE_INTL, TEXT_HUD_LIVE, "LIVE\nPLAY RESUMING");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_FAIL, "%s \x07ROUND RESTORE FAILED:\x01 NO ROUND BACKUP FOR THIS ROUND");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_FAIL_HINT, "%s CHECK \x04mp_backup_round_auto 1\x01 AND \x04mp_backup_round_file\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_START, "%s \x04ROUND RESTORE IN PROGRESS\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_OK, "%s \x04ROUND RESTORED\x01 — SCORE \x04%d : %d\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_OK_HINT, "%s \x04ADMIN: mp_unpause_match\x01 TO RESUME");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_UNVERIFIED, "%s \x07ROUND RESTORE UNVERIFIED\x01 — SCORE %d:%d | ROUND %d (SNAPSHOT %d)");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_STAYS_INVALID, "%s THE ROUND STAYS INVALID — CHECK THE SERVER LOG AND BACKUP SETTINGS");
    SetCMText(TEXT_STYLE_INTL, TEXT_RESUME_NO_RESTORE, "%s \x07RESUMING WITHOUT A RESTORE\x01 — THE INVALID ROUND KEEPS ITS RESULT");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_REF_ONLY, "%s \x07ONLY THE REFEREE CAN RESTORE A ROUND\x01");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_NONE, "THERE IS NO PAUSED ROUND TO RESTORE.");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_BUSY, "A ROUND RESTORE IS ALREADY IN PROGRESS.");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_VALID, "THIS ROUND WAS PAUSED WITHOUT DAMAGE AND IS STILL VALID. NOTHING TO RESTORE.");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_DONE, "THIS ROUND HAS ALREADY BEEN RESTORED.");
    SetCMText(TEXT_STYLE_INTL, TEXT_REW_UNAVAILABLE, "NO ROUND RESTORE IS AVAILABLE FOR THIS PAUSE.");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_PLAYER_ONLY, "%s TACTICAL TIMEOUT MUST BE CALLED BY A PLAYER");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_PREPARING, "%s A TECHNICAL PAUSE IS BEING PREPARED");
    SetCMText(TEXT_STYLE_INTL, TEXT_PAUSE_ACTIVE, "%s A PAUSE IS ALREADY ACTIVE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_TEAM_ONLY, "%s JOIN T OR CT TO CALL A TIMEOUT");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_USED, "%s TIMEOUT ALREADY USED THIS ROUND");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_NONE, "%s NO TACTICAL TIMEOUTS LEFT");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_TEAM_ONLY, "%s JOIN T OR CT TO CALL A TECHNICAL PAUSE");
    SetCMText(TEXT_STYLE_INTL, TEXT_RESTART_BUSY, "%s THE ROUND RESTART IS STILL IN PROGRESS");
    SetCMText(TEXT_STYLE_INTL, TEXT_NO_PAUSE, "%s NO PAUSE IS ACTIVE");
    SetCMText(TEXT_STYLE_INTL, TEXT_TEAM_ONLY, "%s JOIN T OR CT FIRST");
    SetCMText(TEXT_STYLE_INTL, TEXT_TECH_PREPARING_LONG, "%s THE TECHNICAL PAUSE IS STILL BEING PREPARED");
    SetCMText(TEXT_STYLE_INTL, TEXT_ONLY_REF_END, "%s ONLY THE REFEREE CAN END THIS PAUSE");
    SetCMText(TEXT_STYLE_INTL, TEXT_ONLY_CALLING_TEAM, "%s ONLY THE CALLING TEAM MAY END THIS TIMEOUT");
    SetCMText(TEXT_STYLE_INTL, TEXT_TAC_NOT_STARTED, "%s THE PAUSE HAS NOT STARTED YET");
    SetCMText(TEXT_STYLE_INTL, TEXT_OVERTIME, "%s \x04OVERTIME\x01 — TACTICAL TIMEOUTS REFRESHED: \x04%d\x01 PER TEAM");
    SetCMText(TEXT_STYLE_INTL, TEXT_SAY_WARNING, "%s \x07WARNING:\x01 NO COMMUNICATION DURING A TECHNICAL PAUSE");

    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TAC_PENDING, "战术暂停\n%s\n等待暂停生效");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TAC_ACTIVE, "战术暂停\n%s\n剩余 %d 秒\n剩余次数 %d");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_ACTIVE, "%s \x04战术暂停\x01 — \x04%d 秒\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TAC_ENDED, "战术暂停结束\n比赛继续");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TAC_DECLINED, "战术暂停未生效\n次数未消耗");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_DECLINED, "%s \x07战术暂停未生效\x01 — 服务器未进入暂停状态，次数未消耗");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_SERVER_ENDED, "%s \x07战术暂停被服务器结束\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_CALLED, "%s \x04战术暂停\x01 — %s");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_PENDING, "%s 等待服务器进入暂停状态");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_TIMEOUTS, "%s 时长 \x04%d 秒\x01 | 剩余次数 \x04%d\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_WARN, "%s 战术暂停剩余 \x04%d 秒\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_ENDED, "%s \x04战术暂停结束\x01 — 比赛继续");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_WILLFINISH_REF, "技术暂停请求\n发起方：裁判\n本回合先打完\n随后回溯该回合");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_WILLFINISH_TEAM, "技术暂停请求\n%s\n本回合先打完\n随后回溯该回合");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_RESTART_REF, "技术暂停\n发起方：裁判\n本回合无效\n正在重开");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_RESTART_TEAM, "技术暂停\n%s\n本回合无效\n正在重开");
    SetCMText(TEXT_STYLE_CN, TEXT_STATUS_VALID, "本回合有效 — 解除暂停后继续");
    SetCMText(TEXT_STYLE_CN, TEXT_STATUS_INVALID, "本回合无效 — 裁判执行 mp_rewind_match");
    SetCMText(TEXT_STYLE_CN, TEXT_STATUS_RESTORED, "回合已回溯 — 可以继续");
    SetCMText(TEXT_STYLE_CN, TEXT_STATUS_NOTRESTORED, "本回合无效 — 未回溯");
    SetCMText(TEXT_STYLE_CN, TEXT_STATUS_RESTORING, "本回合已作废 — 正在回溯回合开始状态");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_REF, "技术暂停\n发起方：裁判\n%s\n只有裁判可以恢复比赛");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_TEAM, "技术暂停\n%s\n%s\n发起方可输入 !unpause");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_RESTARTED, "%s 技术暂停 — 回合已重开");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_CALLED, "%s \x04技术暂停\x01 — %s");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_CALLED_REF, "%s \x04技术暂停\x01 — 裁判");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_UNPAUSE_HINT, "%s %s 可输入 \x04!unpause\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_REF_ONLY, "%s 只有裁判可以恢复比赛");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_DAMAGE, "%s \x04本回合已产生伤害\x01 — 先打完整回合");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_AFTER_ROUND, "%s 回合一结束即技术暂停，随后回溯该回合");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_REWIND_HINT, "%s \x04裁判：暂停开始后执行 mp_rewind_match\x01 回溯");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_CANCEL_HINT, "%s 输入 \x04!unpause\x01 / \x04mp_unpause_match\x01 取消请求");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_CANCELLED, "%s \x07技术暂停已取消\x01 — 回合继续");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_CANCELLED, "技术暂停已取消\n比赛继续");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_INVALID, "%s \x07本回合无效\x01 — 裁判输入 \x04mp_rewind_match\x01 回溯");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_NO_BACKUP, "%s \x07本回合无效\x01 — 没有可用的回合备份");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_REWIND_OFF, "%s 回溯功能已关闭（\x04sm_mp_rewind_enabled 0\x01）");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_NO_DAMAGE, "%s \x04本回合尚无伤害\x01 — 解除暂停后继续");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_NO_DAMAGE_VOID, "%s \x04本回合尚无伤害\x01 — 已作废，正在回溯回合开始状态");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_PAUSED, "%s \x04比赛已暂停\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_LEGACY_INVALID, "%s \x07本回合无效\x01 — 正在重开");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_VERIFY_FAIL, "%s \x07服务器未进入暂停状态\x01 — 请使用 \x04mp_pause_match\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_ENDED, "%s \x04技术暂停结束\x01 — 准备");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_TECH_ENDED, "技术暂停结束\n准备");
    SetCMText(TEXT_STYLE_CN, TEXT_LIVE, "%s \x04比赛继续 — LIVE! LIVE! LIVE!");
    SetCMText(TEXT_STYLE_CN, TEXT_HUD_LIVE, "LIVE\n比赛继续");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_FAIL, "%s \x07回溯失败：\x01 本回合没有回合备份");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_FAIL_HINT, "%s 请检查 \x04mp_backup_round_auto 1\x01 与 \x04mp_backup_round_file\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_START, "%s \x04正在回溯回合\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_OK, "%s \x04回合已回溯\x01 — 比分 \x04%d : %d\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_OK_HINT, "%s \x04裁判：执行 mp_unpause_match\x01 继续比赛");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_UNVERIFIED, "%s \x07回溯未通过校验\x01 — 比分 %d:%d | 回合 %d（快照 %d）");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_STAYS_INVALID, "%s 本回合仍为无效 — 请检查服务器日志与备份设置");
    SetCMText(TEXT_STYLE_CN, TEXT_RESUME_NO_RESTORE, "%s \x07未回溯直接继续\x01 — 无效回合结果保留");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_REF_ONLY, "%s \x07只有裁判可以回溯回合\x01");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_NONE, "当前没有可回溯的暂停回合。");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_BUSY, "正在回溯，请稍候。");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_VALID, "本回合为无伤害暂停，仍然有效，无需回溯。");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_DONE, "本回合已经回溯过了。");
    SetCMText(TEXT_STYLE_CN, TEXT_REW_UNAVAILABLE, "本次暂停没有可用的回溯。");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_PLAYER_ONLY, "%s 战术暂停必须由玩家发起");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_PREPARING, "%s 技术暂停正在准备中");
    SetCMText(TEXT_STYLE_CN, TEXT_PAUSE_ACTIVE, "%s 已有暂停在进行中");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_TEAM_ONLY, "%s 需加入 T 或 CT 才能发起战术暂停");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_USED, "%s 本回合的暂停次数已用完");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_NONE, "%s 战术暂停次数已用完");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_TEAM_ONLY, "%s 需加入 T 或 CT 才能发起技术暂停");
    SetCMText(TEXT_STYLE_CN, TEXT_RESTART_BUSY, "%s 回合重开仍在进行中");
    SetCMText(TEXT_STYLE_CN, TEXT_NO_PAUSE, "%s 当前没有暂停");
    SetCMText(TEXT_STYLE_CN, TEXT_TEAM_ONLY, "%s 请先加入 T 或 CT");
    SetCMText(TEXT_STYLE_CN, TEXT_TECH_PREPARING_LONG, "%s 技术暂停仍在准备中");
    SetCMText(TEXT_STYLE_CN, TEXT_ONLY_REF_END, "%s 只有裁判可以结束本次技术暂停");
    SetCMText(TEXT_STYLE_CN, TEXT_ONLY_CALLING_TEAM, "%s 只有发起方队伍可以结束本次暂停");
    SetCMText(TEXT_STYLE_CN, TEXT_TAC_NOT_STARTED, "%s 暂停尚未开始");
    SetCMText(TEXT_STYLE_CN, TEXT_OVERTIME, "%s \x04加时赛\x01 — 战术暂停刷新为每队 \x04%d\x01 次");
    SetCMText(TEXT_STYLE_CN, TEXT_SAY_WARNING, "%s \x07警告：\x01 技术暂停期间禁止交流");

    /*
     * Style 2 starts as a copy of the international pack, then
     * adds the rule reminders tournaments display during a pause.
     */

    for (int id = 0; id < TEXT_COUNT; id++)
    {
        strcopy(g_sText[TEXT_STYLE_RULES][id], TEXT_LEN, g_sText[TEXT_STYLE_INTL][id]);
    }

    SetCMText(TEXT_STYLE_RULES, TEXT_TECH_PAUSED, "%s \x04MATCH PAUSED\x01 — NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_TECH_INVALID, "%s \x07ROUND INVALID\x01 — ADMIN: \x04mp_rewind_match\x01 TO RESTORE | NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_STATUS_INVALID, "ROUND INVALID — ADMIN RESTORE | NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_TECH_NO_DAMAGE, "%s \x04NO DAMAGE DONE\x01 — ROUND CONTINUES. NO COMMUNICATION DURING THE PAUSE.");
    SetCMText(TEXT_STYLE_RULES, TEXT_TECH_NO_DAMAGE_VOID, "%s \x04NO DAMAGE DONE\x01 — ROUND VOIDED AND RESTORED. NO COMMUNICATION DURING THE PAUSE.");
    SetCMText(TEXT_STYLE_RULES, TEXT_TECH_AFTER_ROUND, "%s TECHNICAL PAUSE AFTER THIS ROUND — THE ROUND WILL BE RESTORED. NO COMMUNICATION UNTIL THEN.");
    SetCMText(TEXT_STYLE_RULES, TEXT_TAC_CALLED, "%s \x04TACTICAL TIMEOUT\x01 — %s | NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_TAC_ACTIVE, "%s \x04TACTICAL TIMEOUT\x01 — \x04%d SECONDS\x01 | NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_HUD_TECH_REF, "TECHNICAL PAUSE\nTHE REFEREE\n%s\nONLY THE REFEREE CAN RESUME | NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_HUD_TECH_TEAM, "TECHNICAL PAUSE\n%s\n%s\nCALLING TEAM: TYPE !unpause | NO COMMUNICATION");
    SetCMText(TEXT_STYLE_RULES, TEXT_SAY_WARNING, "%s \x07WARNING:\x01 NO COMMUNICATION DURING A TECHNICAL PAUSE. YOU MAY BE PENALISED.");
}


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

/*
 * TRUE when the round has to be rolled back without a referee
 * confirmation, because it was voided before any damage was done.
 */
bool g_bRewindAuto = false;

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

    LoadBroadcastTexts();

    g_iTextStyle = ReadTextStyle();


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
    g_cvTextStyle = CreateConVar(
        "sm_mp_text_style",
        "0",
        "Broadcast text style. 0 = international (English), 1 = Chinese tournament, 2 = international + rule reminders.",
        0,
        true,
        0.0,
        true,
        2.0
    );

    HookConVarChange(g_cvTextStyle, OnTextStyleChanged);


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


    g_bRewindAuto =
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
            CMT(TEXT_HUD_TAC_PENDING),
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
        CMT(TEXT_HUD_TAC_ACTIVE),
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
        CMT(TEXT_TAC_ACTIVE),
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
            CMT(TEXT_HUD_TECH_WILLFINISH_REF)
        );


        return;
    }


    PrintCenterTextAll(
        CMT(TEXT_HUD_TECH_WILLFINISH_TEAM),
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
            CMT(TEXT_HUD_TECH_RESTART_REF)
        );


        return;
    }


    PrintCenterTextAll(
        CMT(TEXT_HUD_TECH_RESTART_TEAM),
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
            CMT(TEXT_STATUS_VALID)
        );


        return;
    }


    if (g_bRewindPending)
    {
        if (g_bRewindAuto)
        {
            strcopy(
                buffer,
                maxlen,
                CMT(TEXT_STATUS_RESTORING)
            );


            return;
        }


        strcopy(
            buffer,
            maxlen,
            CMT(TEXT_STATUS_INVALID)
        );


        return;
    }


    if (g_bRoundRestored)
    {
        strcopy(
            buffer,
            maxlen,
            CMT(TEXT_STATUS_RESTORED)
        );


        return;
    }


    strcopy(
        buffer,
        maxlen,
        CMT(TEXT_STATUS_NOTRESTORED)
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
            CMT(TEXT_HUD_TECH_REF),
            status
        );


        return;
    }


    /*
     * Team pause: the calling team resumes it.
     */

    PrintCenterTextAll(
        CMT(TEXT_HUD_TECH_TEAM),
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
        !g_bRewindInProgress &&
        !g_bRewindAuto)
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
            CMT(TEXT_TECH_RESTARTED),
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


        /*
         * Voided without damage: roll the round start state
         * back automatically.
         */

        if (g_bRewindAuto)
        {
            g_bRewindPending =
                IsRewindAvailable();


            LogMessage(
                "Automatic rewind after a voided round: backup=\"%s\" snapshot_round=%d round_now=%d armed=%d",
                g_sSnapshotBackup,
                g_iSnapshotRoundsPlayed,
                GetRoundsPlayed(),
                g_bRewindPending
            );


            if (g_bRewindPending)
            {
                CreateTimer(
                    1.0,
                    Timer_AutoRewind,
                    0,
                    TIMER_FLAG_NO_MAPCHANGE
                );
            }
            else
            {
                g_bRewindAuto =
                    false;


                PrintToChatAll(
                    CMT(TEXT_TECH_NO_BACKUP),
                    PREFIX
                );
            }
        }


        g_hTechVerifyTimer = CreateTimer(
            TECH_PAUSE_VERIFY_INTERVAL,
            Timer_VerifyTechnicalPause,
            0,
            TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
        );


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
 * AUTOMATIC REWIND AFTER A VOIDED ROUND
 * ========================================================= */

public Action Timer_AutoRewind(
    Handle timer
)
{
    if (!g_bRewindAuto ||
        g_PauseState != PAUSE_TECHNICAL)
    {
        return Plugin_Stop;
    }


    /*
     * Same restore path a referee would run, but without
     * the confirmation, because the round was voided
     * before any damage was done.
     */

    TryRewind(0);


    return Plugin_Stop;
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
            CMT(TEXT_LIVE),
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
        CMT(TEXT_OVERTIME),
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
            CMT(TEXT_TAC_PLAYER_ONLY),
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
            CMT(TEXT_TECH_PREPARING),
            PREFIX
        );


        return;
    }


    if (g_bTechnicalRestartPending)
    {
        PrintToChat(
            client,
            CMT(TEXT_TECH_PREPARING),
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
            CMT(TEXT_PAUSE_ACTIVE),
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
            CMT(TEXT_TAC_TEAM_ONLY),
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
            CMT(TEXT_TAC_USED),
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
            CMT(TEXT_TAC_NONE),
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
        CMT(TEXT_TAC_CALLED),
        PREFIX,
        teamName
    );


    PrintToChatAll(
        CMT(TEXT_TAC_PENDING),
        PREFIX
    );


    PrintToChatAll(
        CMT(TEXT_TAC_TIMEOUTS),
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
            CMT(TEXT_TAC_WARN),
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
        CMT(TEXT_TAC_ENDED),
        PREFIX
    );


    PrintCenterTextAll(
        CMT(TEXT_HUD_TAC_ENDED)
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
        CMT(TEXT_TAC_DECLINED),
        PREFIX
    );


    PrintCenterTextAll(
        CMT(TEXT_HUD_TAC_DECLINED)
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
        CMT(TEXT_TAC_SERVER_ENDED),
        PREFIX
    );


    PrintCenterTextAll(
        CMT(TEXT_HUD_TAC_ENDED)
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
                CMT(TEXT_TECH_TEAM_ONLY),
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
     * sm_mp_technical_damage_gate 0 restores the old
     * V1.2.4 behaviour: the round is terminated at once
     * and nothing is restored.
     *
     * Otherwise:
     *
     * - no damage yet: the round is voided immediately and
     *   the round start state is restored automatically;
     * - damage already done: the round is played out first,
     *   then paused and the referee decides whether the
     *   round is restored.
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


    StartVoidRoundTechnicalPause(callerTeam);
}


/* =========================================================
 * NO DAMAGE: VOID THE ROUND AND ROLL IT BACK
 *
 * Nothing happened in the round, so it is voided right away
 * (CS_TerminateRound grants a Freeze Time immediately), the
 * new round is paused and the pre-round state is restored
 * without waiting for a referee confirmation.
 * ========================================================= */

void StartVoidRoundTechnicalPause(int callerTeam)
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

    g_bRewindAuto =
        true;

    g_bRoundRestored =
        false;

    g_iTechPauseChecks =
        0;


    KillTechnicalTimers();


    PrintToChatAll(
        CMT(TEXT_TECH_NO_DAMAGE_VOID),
        PREFIX
    );


    PrintTechnicalResumeHint(callerTeam);


    ShowTechnicalRestartUI();


    /*
     * Remove any existing pause, then void the round: the
     * Freeze Time that follows is used to pause and restore.
     */

    InternalUnpauseMatch();


    CS_TerminateRound(
        0.1,
        CSRoundEnd_Draw
    );
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
            CMT(TEXT_TECH_CALLED),
            PREFIX,
            teamName
        );


        return;
    }


    PrintToChatAll(
        CMT(TEXT_TECH_CALLED_REF),
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
            CMT(TEXT_TECH_UNPAUSE_HINT),
            PREFIX,
            teamName
        );


        return;
    }


    PrintToChatAll(
        CMT(TEXT_TECH_REF_ONLY),
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
        CMT(TEXT_TECH_DAMAGE),
        PREFIX
    );


    PrintToChatAll(
        CMT(TEXT_TECH_AFTER_ROUND),
        PREFIX
    );


    if (g_cvRewindEnabled != null &&
        g_cvRewindEnabled.BoolValue)
    {
        PrintToChatAll(
            CMT(TEXT_TECH_REWIND_HINT),
            PREFIX
        );
    }


    PrintToChatAll(
        CMT(TEXT_TECH_CANCEL_HINT),
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
        CMT(TEXT_TECH_CANCELLED),
        PREFIX
    );


    PrintCenterTextAll(
        CMT(TEXT_HUD_TECH_CANCELLED)
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
                CMT(TEXT_TECH_INVALID),
                PREFIX
            );
        }
        else
        {
            PrintToChatAll(
                CMT(TEXT_TECH_NO_BACKUP),
                PREFIX
            );


            if (g_cvRewindEnabled == null ||
                !g_cvRewindEnabled.BoolValue)
            {
                PrintToChatAll(
                    CMT(TEXT_TECH_REWIND_OFF),
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
            CMT(TEXT_TECH_NO_DAMAGE),
            PREFIX
        );
    }


    PrintToChatAll(
        CMT(TEXT_TECH_PAUSED),
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
        CMT(TEXT_TECH_LEGACY_INVALID),
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
            CMT(TEXT_TECH_VERIFY_FAIL),
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
            CMT(TEXT_REW_REF_ONLY),
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
            CMT(TEXT_REW_REF_ONLY),
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
            CMT(TEXT_REW_NONE)
        );


        return;
    }


    if (g_bRewindInProgress)
    {
        ReplyToReferee(
            client,
            CMT(TEXT_REW_BUSY)
        );


        return;
    }


    if (!g_bRoundInvalidated)
    {
        ReplyToReferee(
            client,
            CMT(TEXT_REW_VALID)
        );


        return;
    }


    if (g_bRoundRestored)
    {
        ReplyToReferee(
            client,
            CMT(TEXT_REW_DONE)
        );


        return;
    }


    if (!g_bRewindPending)
    {
        ReplyToReferee(
            client,
            CMT(TEXT_REW_UNAVAILABLE)
        );


        return;
    }


    if (g_sSnapshotBackup[0] == '\0')
    {
        g_bRewindPending =
            false;


        PrintToChatAll(
            CMT(TEXT_REW_FAIL),
            PREFIX
        );


        PrintToChatAll(
            CMT(TEXT_REW_FAIL_HINT),
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
        CMT(TEXT_REW_START),
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


    /*
     * The automatic rollback is a one shot: after this the
     * referee decides if anything is retried.
     */

    g_bRewindAuto =
        false;


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
            CMT(TEXT_REW_OK),
            PREFIX,
            scoreT,
            scoreCT
        );

        PrintToChatAll(
            CMT(TEXT_REW_OK_HINT),
            PREFIX
        );
    }
    else
    {
        PrintToChatAll(
            CMT(TEXT_REW_UNVERIFIED),
            PREFIX,
            scoreT,
            scoreCT,
            roundsNow,
            g_iSnapshotRoundsPlayed
        );

        PrintToChatAll(
            CMT(TEXT_REW_STAYS_INVALID),
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
                CMT(TEXT_RESTART_BUSY),
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
                CMT(TEXT_NO_PAUSE),
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
            CMT(TEXT_TEAM_ONLY),
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
            CMT(TEXT_TECH_PREPARING),
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
                CMT(TEXT_TECH_PREPARING_LONG),
                PREFIX
            );


            return;
        }


        if (g_iTechCallerTeam < 0)
        {
            PrintToChat(
                client,
                CMT(TEXT_ONLY_REF_END),
                PREFIX
            );


            return;
        }


        if (matchTeam != g_iTechCallerTeam)
        {
            PrintToChat(
                client,
                CMT(TEXT_ONLY_CALLING_TEAM),
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
                CMT(TEXT_TAC_NOT_STARTED),
                PREFIX
            );


            return;
        }


        if (matchTeam != g_iPausingTeam)
        {
            PrintToChat(
                client,
                CMT(TEXT_ONLY_CALLING_TEAM),
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
            CMT(TEXT_RESUME_NO_RESTORE),
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
        CMT(TEXT_TECH_ENDED),
        PREFIX
    );


    PrintCenterTextAll(
        CMT(TEXT_HUD_TECH_ENDED)
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
            CMT(TEXT_LIVE),
            PREFIX
        );


        PrintCenterTextAll(
            CMT(TEXT_HUD_LIVE)
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
        CMT(TEXT_SAY_WARNING),
        PREFIX
    );


    return Plugin_Continue;
}
