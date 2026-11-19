**语言：**
[English](README_en.md) | [中文](README.md) 
# MatchPauseManager for CS:GO
MatchPauseManager 是一个用于 CS:GO 竞技服务器的 SourceMod 插件，帮助队伍和裁判按比赛规则管理战术暂停与技术暂停，并处理回合无效和回溯。

源码支持 SourceMod 1.11.0 和 1.12.x；V1.2.7 使用 SourceMod 1.12.0 编译。

插件用于管理竞技比赛中的**战术暂停**和**技术暂停**，并按配置处理暂停次数、时长以及技术暂停期间的回合判定与回溯。

## 安装
从 [Releases](https://github.com/A1rLeSS/MatchPauseManager-for-CSGO/releases) 下载最新的 `Match Pause Manager VX.X.X.zip`，将其中的 `Match Pause Manager.smx` 放入 `csgo/addons/sourcemod/plugins/`。本地客户端测试时，需要在 CS:GO 启动选项中添加 `-insecure`；专用服务器请将插件安装到服务器的 SourceMod 插件目录。

## 功能特性
### 暂停UI
目前插件已初步实现调用游戏内警告UI以展示暂停相关信息，并且能够正确读取比赛自定义队伍名，而非默认的“TEAM A（B）”或“TEAM CT（T）”

队伍名按 CS:GO 的规则（`mp_teamname_1` 为开局打 CT 的队伍）与回合计数器推导，**换边（含加时赛半场换边）后仍然显示正确的队伍名**

技术暂停的警告UI与聊天提示按**发起方**区分：裁判发起时显示 `CALLED BY THE REFEREE` 并提示只有裁判可以恢复比赛；选手发起时显示 `CALLED BY <队伍名>` 并提示发起方可用 `!unpause` 恢复比赛
### 战术暂停
玩家可以通过下列任意命令发起一次战术暂停
```
!pause
!tac
!p
```
默认情况下，每支队伍在常规赛期间拥有**3次**暂停，每次持续**30秒**，且在倒计时结束前**5**秒会给出暂停即将结束的提示
#### 每回合战术暂停次数限制
除限制每队拥有的总战术暂停次数外，本插件限制同一回合最多只能生效一次战术暂停（即使双方队伍剩余战术暂停数大于0），限制的时间范围为**回合开始前的冻结时间——回合结束瞬间**，在进入下一回合后，该限制将被清除并重新计算
#### 加时赛的战术暂停次数限制
当进入加时赛后，无论常规赛剩余多少次战术暂停未使用，双方队伍战术暂停次数都将被重新设置为**1次**，并在一个加时赛阶段双方战平并进入下一个加时赛阶段时刷新双方的**1次**战术暂停机会（每次刷新都会在聊天框提示）
### 技术暂停
本插件设置技术暂停优先级高于战术暂停，且战术暂停可直接通过指令```!tech```升级为技术暂停
玩家可使用```!tech```或游戏内控制台```mp_pause_match```发起一次技术暂停,其中游戏内控制台通过```mp_pause_match```发起的技术暂停将被视作由**无所属队伍**的**赛事方裁判**发起

裁判发起与选手发起的技术暂停，在警告UI与聊天提示中使用**不同的文案**：裁判发起时提示只有裁判可以恢复比赛，选手发起时提示发起方队伍可使用```!unpause```恢复比赛

技术暂停无倒计时限制，只有```!unpause```或游戏内控制台```mp_unpause_match```才会解除技术暂停状态
#### 技术暂停时的回合处理（V1.2.7 起按“是否已产生伤害”判定）
技术暂停发起时，插件会先判断**当前回合是否已经产生伤害**（任意玩家受到伤害即视为已产生）：

- **尚未产生伤害**：立即执行 ```CS_TerminateRound()``` **作废当前回合**，在随之而来的冻结时间内暂停，并**自动回溯到回合开始前的状态**（比分、经济、装备、站位、回合计数由 CS:GO 原生回合备份恢复，选手数据由插件写回）——这一步**不需要裁判确认**；
- **已经产生伤害**：不强行作废回合，而是**先打完整回合**（保证结果公平），随后在下一回合冻结时间暂停，由**裁判确认**后再回溯该回合并重打。

若需要恢复旧行为（技术暂停只作废回合并重开、不做任何回溯），设置 ```sm_mp_technical_damage_gate 0``` 即可。

#### 回合回溯 / Rewind（V1.2.5 新增）
每回合开始时插件都会做一次快照，并借助 CS:GO 自带的回合备份完成回溯：

- **比分、经济、装备、站位、回合计数**：由 CS:GO 原生回合备份（```mp_backup_round_auto``` / ```mp_backup_round_file```）恢复。插件会在比赛配置执行后确保这两个 ConVar 可用（若已被 Get5 等插件设置，则不会覆盖原有值）；
- **选手数据（击杀 / 死亡 / 助攻 / MVP）**：由插件自己备份，并在回溯后写回（CS:GO 原生备份不含这些数据）。

回溯的执行方式分两种：**无伤害作废的回合会自动回溯**（见上一节）；**已有伤害的回合由裁判确认回溯**——在回合被判定无效并暂停后，于控制台（rcon / 服务器控制台）执行
```
mp_rewind_match
```
或由管理员在游戏内执行 ```!rewind```。**无论回溯成功与否都会在聊天框给出明确提示**；恢复成功后由裁判执行 ```mp_unpause_match``` 开始重打该回合。

| ConVar | 默认值 | 说明 |
| --- | --- | --- |
| ```sm_mp_technical_damage_gate``` | ```1``` | 1 = 按伤害判定（无伤害：作废回合并自动回溯；有伤害：等回合结束、裁判确认回溯）；0 = 只作废回合并重开、不回溯（V1.2.4 行为） |
| ```sm_mp_rewind_enabled``` | ```1``` | 1 = 无效回合允许裁判回溯 |

#### 战术暂停转换至技术暂停
当比赛已经处于战术暂停状态，并有玩家发起```!tech```或管理员在游戏内控制台发起```mp_pause_match```时，本插件将先执行战术暂停次数返还并解除暂停状态后再发起技术暂停，以避免战术暂停次数的意外消耗

同时，被返还的战术暂停次数与“本回合已用战术暂停”标记都会被清空，允许在该回合内重新发起战术暂停
#### 技术暂停发言警告
当比赛进入技术暂停后，插件将监控 T/CT 玩家的```say```和```say_team```操作，并自动发送技术暂停期间禁止交流的警告，但不会对聊天内容进行拦截（旁观者/HLTV 不警告，`!` `/` `.` 开头的指令也不警告）
### 取消暂停
玩家可通过```!unpause```指令立即解除暂停，但**仅限发起暂停的一方队伍成员**执行时立即解除，对方队伍或旁观者尝试时会被拒绝并收到``` [CM] Only the calling team may end their tactical timeout.```（战术暂停）或 ```[CM] Only the calling team may end their technical timeout.```（技术暂停）的警告，暂停状态保持不变；

若技术暂停由裁判通过控制台发起（视为无对应队伍），任何玩家的 !unpause 都会被拒绝。裁判则可通过游戏内控制台执行 ```mp_unpause_match```以取消暂停，该命令将被视为由赛事管理方发起，会绕过一切队伍限制，无论暂停由哪一方发起、属于战术还是技术类型，均可直接解除，也是裁判在比赛中推荐的唯一解除方式。
### 比赛体验及广播程序
插件对比赛的处理和指令反馈主要由 **"[CM]"** 来进行状态指示。V1.2.6 起所有文案都集中在插件内的文案表里，通过 ConVar ```sm_mp_text_style``` 切换三套**参照真实赛事转播/裁判台**的用词：

| 值 | 风格 | 说明 |
| --- | --- | --- |
| ```0``` | 国际赛事（默认） | ESL / PGL / BLAST 式全大写关键词 + 队名 + 数字 |
| ```1``` | 中文赛事 | 中文播报式，适合国内赛事 |
| ```2``` | 国际赛事 + 规则提醒 | 在风格 0 上追加“暂停期间禁止交流”等规则提示 |

**风格 0（国际赛事，默认）**
```
[CM] TACTICAL TIMEOUT — Team A
[CM] TIME 30 SEC | TIMEOUTS LEFT 2
[CM] TACTICAL TIMEOUT ENDS IN 5 SEC
[CM] TACTICAL TIMEOUT ENDED — RESUME
[CM] TECHNICAL PAUSE — REFEREE
[CM] NO DAMAGE DONE — ROUND VOIDED, RESTORING ROUND START
[CM] ROUND ALREADY IN PROGRESS — DAMAGE DONE, THE ROUND IS PLAYED OUT FIRST
[CM] ROUND INVALID — ADMIN: mp_rewind_match TO RESTORE
[CM] ROUND RESTORED — SCORE 7 : 7
[CM] LIVE! LIVE! LIVE!
```

**风格 1（中文赛事）**
```
[CM] 战术暂停 — Team A
[CM] 时长 30 秒 | 剩余次数 2
[CM] 战术暂停剩余 5 秒
[CM] 战术暂停结束 — 比赛继续
[CM] 技术暂停 — 裁判
[CM] 本回合尚无伤害 — 解除暂停后继续
[CM] 本回合已产生伤害 — 先打完整回合
[CM] 本回合无效 — 裁判输入 mp_rewind_match 回溯
[CM] 回合已回溯 — 比分 7 : 7
[CM] 比赛继续 — LIVE! LIVE! LIVE!
```

**风格 2（国际赛事 + 规则提醒）**：与风格 0 相同，但暂停类提示会追加规则提醒，例如
```
[CM] MATCH PAUSED — NO COMMUNICATION
[CM] ROUND INVALID — ADMIN: mp_rewind_match TO RESTORE | NO COMMUNICATION
```

HUD（屏幕中央）也使用同一套风格，例如战术暂停：
```
TACTICAL TIMEOUT
Team A
30 SECONDS REMAINING
TIMEOUTS LEFT 2
```
技术暂停（回合无效、等待裁判回溯）：
```
TECHNICAL PAUSE
Team A
ROUND INVALID — ADMIN: mp_rewind_match
CALLING TEAM: TYPE !unpause
```

当发送的原生暂停请求没有被服务器接受时，插件不会永久停留在暂停状态：会提示 `TACTICAL TIMEOUT DECLINED — THE SERVER DID NOT ENTER PAUSE. NO TIMEOUT USED.`（风格 1 为“战术暂停未生效 — 服务器未进入暂停状态，次数未消耗”）并**返还**该次战术暂停次数

