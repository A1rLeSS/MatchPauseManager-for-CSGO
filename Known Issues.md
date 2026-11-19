# Historical release notes

This file records changes and fixes from earlier versions; it is not a list of current known issues. For current installation and usage instructions, see [README](README.md) or [README in English](README_en.md).

~~1.玩家发出指令时可能会多次检查暂停状态并返回控制台提示~~（V1.2.0已修复）

~~2.缺少战术暂停剩余次数的提示~~ （V1.2.0已修复）

~~3.计划在聊天框显示暂停信息时同时调用游戏自带的警告UI修改战术暂停和技术暂停信息~~ （V1.2.0初步完成）、（V1.2.1已优化）、（V1.2.4已按发起方区分文案）

~~4.技术暂停时暂无法做到指令发出后立即重启对局并进入暂停状态~~ （V1.2.1已修复）

~~5.技术暂停调用游戏警告UI无法常驻，且较杂乱~~ （V1.2.1已修复）

~~6.（需要优化）裁判发起/选手发起技术暂停，技术暂停流程调用游戏内警告UI显示暂停提示词时，应当为两种不同情况显示不同的提示内容~~ （V1.2.4已修复）

~~7.换边后发起暂停会显示换边前的队伍名~~ （V1.2.4已修复）

## V1.2.8 复查修复

1. **`g_bRewindAuto` 漏清理导致快照停摆**：`EndTechnicalPause`、`BeginTechnicalPause`、`StartLegacyRoundTermination` 都补上了 `g_bRewindAuto = false;`。此前若在作废回合后 1 秒内解除暂停（或之后再次进入技术暂停），该标志会残留为 true，使 `Event_RoundStart` 永久跳过回合快照，整张图之后都无法回溯；旧模式下还可能误触发自动回溯。
2. **关闭回溯时不再白丢回合**：`sm_mp_rewind_enabled 0` 时，"未产生伤害"分支改为就地暂停并保留回合（`BeginTechnicalPause(callerTeam, false)`），不会再出现"作废了却无法回退"的情况；该分支同时会提示回溯已关闭。
3. **技术暂停缺少外部解除看门狗**：`Timer_TechnicalUI` 现在每秒检查 `IsCSGOActuallyPaused()`，连续 5 秒不在暂停状态就调用新增的 `AbortTechnicalPauseExternally()` 释放全部状态并提示 `TECHNICAL PAUSE ENDED BY THE SERVER`，不会卡在"已暂停"。
4. **回合备份可能抓错回合**：`Timer_CaptureRoundBackup` 现在校验 `GetRoundsPlayed()` 与快照回合一致，若回合作废后 ConVar 已指向下一回合，则放弃抓取并写日志，避免回溯到错误的回合。
5. **热身阶段拦截**：`StartTacticalPause` / `StartTechnicalPause` 在 `m_bWarmupPeriod` 时直接拒绝，不会再把热身回合作废。
6. 新增文案 `TEXT_TECH_SERVER_ENDED`、`TEXT_GUARD_WARMUP`（三套风格均已补齐）。

编译：SourceMod 1.12.0.7230，`-E`（警告即错误）严格模式 **0 error / 0 warning**。

## V1.2.7 技术暂停流程调整

统一了两个版本的技术暂停流程：

1. **未产生伤害**：指令一发出就执行 `CS_TerminateRound()` **作废当前回合**（毫秒级生效），在随之而来的冻结时间内 `mp_pause_match` 暂停，然后**自动回溯到回合开始前的状态**（比分/经济/装备/站位/回合计数由 CS:GO 原生回合备份恢复，选手 K/D/A/MVP 由插件写回）。此路径**不需要裁判确认**，回溯完成后再由裁判 `mp_unpause_match` 开始重打。
2. **已产生伤害**：不强行作废回合，先把本回合打完整，在下一回合冻结时间暂停，由**裁判执行 `mp_rewind_match`（或 `!rewind`）确认是否回溯**；不回溯直接解除时会有明确警告。

配套改动：

- 新增状态变量 `g_bRewindAuto`：无伤害作废路径自动回溯用，一轮只触发一次（失败后保留“等待回溯”状态，裁判可手动重试）；
- 新增文案 `TEXT_TECH_NO_DAMAGE_VOID`（“本回合尚无伤害 — 已作废，正在回溯回合开始状态”）与 HUD 状态 `TEXT_STATUS_RESTORING`（“本回合已作废 — 正在回溯回合开始状态”），三套风格均已补齐；
- 作废路径同样会创建暂停校验定时器（每秒检查 `m_bMatchWaitingForResume`），避免“插件认为已暂停、服务器还在跑”；
- `sm_mp_technical_damage_gate 0` 仍保留 V1.2.4 的旧行为（只作废重开、不回溯）。

编译：SourceMod 1.12.0.7230，`-E`（警告即错误）严格模式下 **0 error / 0 warning**。

## V1.2.6 文案（参照真实赛事）

### 1. 所有 `[CM]` 文案集中成一张表
74 条文案（聊天 + 屏幕中央 HUD + 裁判提示 + 玩家报错）全部收进插件内的文案表 `g_sText[][]`，消息点只保留文案 ID（`CMT(...)`）。以后改措辞只动文案表，不用碰流程逻辑。

### 2. 三套风格，运行时可切换
新增 ConVar `sm_mp_text_style`，切换即时生效（ConVar 变更钩子），聊天与 HUD 同步：

| 值 | 风格 | 参照 |
| --- | --- | --- |
| `0` | 国际赛事（默认） | ESL / PGL / BLAST 的“全大写关键词 + 队名 + 数字”写法 |
| `1` | 中文赛事 | 中文播报式 |
| `2` | 国际赛事 + 规则提醒 | 风格 0 上追加“暂停期间禁止交流”等规则提示 |

### 3. 文案对照（节选）

| 情形 | 风格 0（国际） | 风格 1（中文） |
| --- | --- | --- |
| 战术暂停开始 | `TACTICAL TIMEOUT — Team A` | `战术暂停 — Team A` |
| 时长与剩余次数 | `TIME 30 SEC | TIMEOUTS LEFT 2` | `时长 30 秒 | 剩余次数 2` |
| 结束前 5 秒 | `TACTICAL TIMEOUT ENDS IN 5 SEC` | `战术暂停剩余 5 秒` |
| 战术暂停结束 | `TACTICAL TIMEOUT ENDED — RESUME` | `战术暂停结束 — 比赛继续` |
| 技术暂停发起（裁判） | `TECHNICAL PAUSE — REFEREE` | `技术暂停 — 裁判` |
| 无伤害直接暂停 | `NO DAMAGE DONE — ROUND CONTINUES AFTER THE PAUSE` | `本回合尚无伤害 — 解除暂停后继续` |
| 有伤害等回合结束 | `ROUND ALREADY IN PROGRESS — DAMAGE DONE, THE ROUND IS PLAYED OUT FIRST` | `本回合已产生伤害 — 先打完整回合` |
| 回合无效待回溯 | `ROUND INVALID — ADMIN: mp_rewind_match TO RESTORE` | `本回合无效 — 裁判输入 mp_rewind_match 回溯` |
| 回溯成功 | `ROUND RESTORED — SCORE 7 : 7` | `回合已回溯 — 比分 7 : 7` |
| 回溯校验失败 | `ROUND RESTORE UNVERIFIED — SCORE 7:8 | ROUND 15 (SNAPSHOT 14)` | `回溯未通过校验 — 比分 7:8 | 回合 15（快照 14）` |
| 恢复比赛 | `LIVE! LIVE! LIVE!` | `比赛继续 — LIVE! LIVE! LIVE!` |
| 暂停期间发言 | `WARNING: NO COMMUNICATION DURING A TECHNICAL PAUSE` | `警告：技术暂停期间禁止交流` |

### 4. 编译
V1.2.6 使用 SourceMod 1.12.0.7230 编译器构建，`-E`（警告即错误）严格模式下 **0 error / 0 warning**。

## V1.2.5 新增功能与变更

### 1. 技术暂停按“是否已产生伤害”判定
`player_hurt` 会标记当前回合是否已产生伤害（每回合开始清空，热身阶段不计）：

- **未产生伤害**：直接 `mp_pause_match` 暂停当前回合，回合**不判定无效、不重开**，解除暂停后原地继续；
- **已产生伤害**：进入“等待回合结束”状态（新状态 `PAUSE_TECHNICAL_PENDING`），本回合打完后在下一回合冻结时间暂停，然后等待裁判回溯。

暂停状态新增了**暂停确认检测**：暂停后每 1 秒检查一次 `m_bMatchWaitingForResume`，最多重试 3 次仍无法进入暂停状态时，会在聊天框明确提示裁判改用 `mp_pause_match`，避免插件显示“已暂停”而服务器还在跑。

等待期间裁判（或发起方队伍）可以用 `!unpause` / `mp_unpause_match` 取消这次请求。

### 2. 回合回溯（Rewind）
实现方式是 **CS:GO 原生回合备份 + 插件补备份选手数据**：

| 数据 | 备份/恢复方 |
| --- | --- |
| 比分、经济、装备、站位、回合计数 | CS:GO 原生回合备份（`mp_backup_round_auto` / `mp_backup_round_file` / `mp_backup_restore_load_file`） |
| 击杀、死亡、助攻、MVP | 插件（每回合开始快照，回溯后按用户 ID 写回） |

流程：

1. 每回合开始：插件记录比分与 `m_totalRoundsPlayed`，0.5 秒后读取 `mp_backup_round_file_last` 取得该回合的备份文件，同时快照所有玩家的 K/D/A/MVP；
2. 回合作废后，在下一回合冻结时间暂停，并置为“等待回溯”；
3. 裁判执行 `mp_rewind_match`（控制台/rcon）或 `!rewind`（管理员游戏内）；
4. 插件执行 `mp_backup_restore_load_file "<该回合备份>"`，1.5 秒后校验比分/回合计数是否回到快照值，把选手数据写回，并保持暂停；
5. 成功或失败都会在聊天框明确提示，服务器日志额外记录 `Round rewind: ...` 便于排查；
6. 成功后由裁判执行 `mp_unpause_match` 重打该回合。

补充说明：

- 插件会在比赛配置执行后（`OnConfigsExecuted`）确保 `mp_backup_round_auto 1`；若 `mp_backup_round_file` 为空则设置为 `mpm_backup`，**不会覆盖** Get5 等插件已经设置的文件名；
- 若服务器始终没有生成回合备份，回溯会明确失败并提示检查备份 ConVar，不会假装成功；
- 选手数据按**用户 ID**匹配，因此暂停期间重连换了 ID 的玩家其 K/D/A 不会被写回（比分/经济/装备仍由游戏备份恢复）；
- 回溯校验失败时“等待回溯”状态会保留，裁判修正备份设置后可以重试。

### 3. 新增 ConVar 与指令

| 名称 | 默认 | 说明 |
| --- | --- | --- |
| `sm_mp_technical_damage_gate` | `1` | 1=按伤害判定（无伤害直接暂停，有伤害等回合结束）；0=总是立即作废回合并重开（V1.2.4 行为） |
| `sm_mp_rewind_enabled` | `1` | 1=允许裁判回溯无效回合 |
| `mp_rewind_match` | - | 控制台/rcon 回溯指令（裁判） |
| `sm_rewind`（`!rewind`） | - | 游戏内指令，需要 `ADMFLAG_GENERIC` 权限 |

### 4. 编译
V1.2.5 使用 SourceMod 1.12.0.7230 编译器构建：**0 error / 0 warning**。

## V1.2.4 修复说明

### 6. 技术暂停提示按“裁判发起 / 选手发起”区分

技术暂停的警告UI与聊天提示现在完全分成两套文案：

- **裁判发起**（控制台 `mp_pause_match`）：`CALLED BY THE REFEREE`，并明确提示“只有裁判可以恢复比赛”，因为此时任何玩家的 `!unpause` 都会被拒绝；
- **选手发起**（`!tech`）：`CALLED BY <队伍名>`，并提示“发起方队伍可使用 `!unpause` 恢复比赛”。

重启阶段（回合作废、正在重启）与正式暂停阶段也各自使用对应文案，不再出现“裁判发起却提示输入 `!unpause`”这种错误引导。

### 7. 换边后显示换边前的队伍名

**原因**：CS:GO 的 `mp_teamname_1/2` 是按“队伍”而不是按“阵营”命名的（`mp_teamname_1` 永远是开局打 CT 的那支队伍）。插件在换边时需要把“阵营 → 队伍”的映射翻转，但 V1.2.3 是用**两队得分之和**是否达到 `mp_maxrounds / 2` 来判断换边的：

```sourcepawn
int totalScore = tScore + ctScore;
if (totalScore >= maxRounds / 2) { SwapMatchTeams(); }
```

技术暂停会让当前回合作废（平局结束）：**这一回合会推进游戏内的回合计数，却不增加任何一方的得分**。因此只要上半场出现过一次技术暂停，得分之和就会永远比实际回合数少 1，插件就会在换边后少翻一次（或晚翻一次）映射，把对手的队伍名显示成自己的队伍名。

**修复**：不再用得分推算，改用 CS:GO 自己触发换边和对局加时的回合计数器 `m_totalRoundsPlayed` 推导映射，并且做成**纯函数**（每次使用前重新计算，而不是靠事件去翻转状态）：

```
换边次数 = 常规赛半场已结束 ? 1 : 0
         + 加时赛已越过的半场数
```

这样就同时满足了：

- 作废回合会让回合计数器前进，与游戏自己的换边时机完全一致；
- 不再依赖 `cs_team_manager` 的 `m_iScore`（该属性在 CS:GO 中并不可靠，读取失败时映射就永远不会翻转）；
- 加时赛换边同样按 `mp_overtime_maxrounds / 2` 推导，`g_iLastOTSideSwitchScore` 之类的“去重状态”不再需要；
- 即使插件在中场休息后才加载，下一次回合开始 / 下一次暂停指令时也会自动纠正。

### 复查时一并修复的问题

1. **控制台 `mp_pause_match` 无法把战术暂停升级为技术暂停**
   README 中写明“战术暂停可由控制台 `mp_pause_match` 升级为技术暂停并返还次数”，但监听器在 `g_PauseState != PAUSE_NONE` 时直接 `Plugin_Handled`，把这条指令吞掉了。现在只有在“技术暂停已在进行中”时才拦截，战术暂停会正确走 `StartTechnicalPause()` 的返还流程。

2. **暂停请求被服务器拒绝时插件会永久卡死**
   发送 `mp_pause_match` 后，插件可能一直等不到真正的暂停状态（例如请求在不可暂停的时机被丢弃）。此时状态一直是 `PAUSE_TACTICAL`、次数已经被扣、任何新的暂停都被“A pause is already active.”拒绝。现在增加了看门狗：在冻结时间内连续 5 秒仍未进入暂停状态，就判定请求失败，**返还次数**并恢复空闲状态。

3. **倒计时中途服务器自行解除暂停后，插件仍停留在暂停状态**
   现在连续 5 秒检测不到真正的暂停状态即释放暂停状态并广播提示，不再永久锁死。

4. **裁判可能无法用 `mp_unpause_match` 解救服务器**
   当插件认为“没有暂停”时（状态不同步、其他插件的暂停等），曾经会吞掉裁判的原生解除指令。现在这种情况会放行给 CS:GO 原生处理，裁判永远可以把服务器恢复运行。

5. **技术暂停聊天警告的误报**
   以前对 spectators / HLTV 也会警告（他们并不属于比赛），且以空格开头的指令会被当成聊天内容。现在只警告 T/CT 玩家，并跳过空消息与 `!` `/` `.` 开头的指令。

6. **编译警告**
   `MatchTeam` 枚举改为无标签枚举，消除了 V1.2.3 中 5 条 tag mismatch 警告；V1.2.4 使用 SourceMod 1.12.0 编译器编译为 0 error / 0 warning。
