# Match-Pause-Manager-for-CSGO
适用于CSGO竞技比赛服务器，基于Source Mod 1.11.0编译的仿比赛风格的游戏暂停处理插件

此插件主要用于竞技比赛时的战术暂停（Tactical Pause）和技术暂停（Technical Pause），尽量按照职业比赛中的暂停规则对暂停次数、时长、回合有效性（技术暂停触发）及暂停后的回合重启进行处理

## 功能特性
### 战术暂停
玩家可以通过下列任意命令发起一次战术暂停
```
!pause
!tac
!p
```
默认情况下，每支队伍在常规赛期间拥有**3次**暂停，每次持续**30秒**，且在倒计时结束前**5**秒会给出暂停即将结束的提示
#### 每回合战术暂停次数限制
除限制每队拥有的战术暂停次数外，本插件限制同一回合最多只能使用一次战术暂停（即使双方队伍剩余战术暂停数大于0），在进入下一回合后，该限制将重新计算
#### 加时赛的战术暂停次数限制
当进入加时赛后，无论常规赛剩余多少次战术暂停未使用，双方队伍战术暂停次数都将被重新设置为**1次**，且第一段加时赛打平进入第二段加时赛后双方不会重新获得战术暂停次数
### 技术暂停
本插件设置技术暂停优先级高于战术暂停
玩家可使用```!tech```或游戏内控制台```mp_pause_match```发起一次技术暂停

技术暂停无倒计时限制，只有```!unpause```或游戏内控制台```mp_unpause_match```才会解除技术暂停状态
#### 技术暂停时的回合处理
当一次技术暂停发起时，当前回合会被判定无效，并执行```mp_restartround 1```,并进入战术暂停阶段
#### 战术暂停转换至技术暂停
当比赛已经处于战术暂停状态，并有玩家发起```!tech```或管理员在游戏内控制台发起```mp_pause_match```时，本插件将先执行战术暂停次数返还并解除暂停状态后再发起技术暂停，以避免战术暂停次数的意外消耗

同时，本回合已使用的战术暂停限制也会因回合无效而重新计算
### 技术暂停发言警告
当比赛进入技术暂停后，插件将监控```say```和```say_team```操作，并自动发送```[CM] Communication is not allowed during a technical pause!```，但不会对聊天内容进行拦截
### 比赛体验及广播程序
插件对比赛的处理主要由 **"[CM]"** 来进行状态指示，如:
```
[CM] Team （Team Name） called a tactical timeout. 2 remaining.
```
指示战术暂停的发起
```
[CM] Tactical timeout ends in 5...
[CM] Tactical timeout ends in 4...
[CM] Tactical timeout ends in 3...
[CM] Tactical timeout ends in 2...
[CM] Tactical timeout ends in 1...

[CM] Tactical timeout ended. Get ready.
```
指示战术暂停的结束
```
[CM] Technical timeout called by referee.
[CM] Current round is invalid.
[CM] The round will restart and remain paused.

[CM] Technical pause: new round is ready and will remain paused.
```
指示技术暂停的发起
```
[CM] Technical timeout ended. Get ready.

[CM] LIVE! LIVE! LIVE!
```
指示技术暂停的结束

其中
```
[CM] LIVE! LIVE! LIVE!
```
为比赛开始和技术暂停结束时触发，战术暂停结束不会触发
