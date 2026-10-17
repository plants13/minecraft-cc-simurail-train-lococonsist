# 机车重联控制系统 —— 配置与部署说明

> 本说明对应**合并版**：单文件 `startup.lua`，换向拉杆选主从；驱动/制动/换向走 **Simurail 物理转向架的 CC 外设**（唯一输出通道，无红石回退），冒进防护读**转向架探针**。
> 所有脚本/配置必须**纯 ASCII**——CC:Tweaked 加载不了中文注释（这份文档给人看，放本地，别复制进游戏电脑）。

---

## 0. 架构总览

每台机车电脑上放 3 个文件：

| 文件 | 作用 | 每车是否相同 |
| --- | --- | --- |
| `startup.lua` | 控制程序（主机+从机合一，拉杆决定角色） | 相同 |
| `config_locomodel.lua` | 本车硬件/PID/外设配置 | 每车一份，按接线可不同 |
| `mu_config.lua` | 重联配置（协议名 + 其他车相对本车方向） | 每车一份，视角不同 |
| `door_ctrl.lua` | 车门集控（独立电脑，接线面写在脚本顶部，见第六节） | 相同 |

- 电脑身份用 `label set <名称>` 设置（大小写敏感，重启不丢）。
- **接线角色分工**：

| 功能 | 通道 |
| --- | --- |
| 驱动（油门） | Simurail 转向架 CC 外设 `setMaxStress`（±128，应力=网络消耗） |
| 制动 | Simurail 转向架 CC 外设 `setBrakeStrengthOverride`（0..1） |
| 换向 | 驱动应力符号（负 = 反向），不再用倒挡齿轮箱红石 |
| 红灯（冒进防护） | **Simurail 转向架探针** `getProbeOccupiedSignalDistance`（固定轴，读轨道距离） |
| 重联通信 | 无线 modem（rednet） |

---

## 一、模式选择（换向拉杆）

`sideReverse` 接的拉杆是**模拟量**，三个区间决定角色与方向：

| 模拟值 | 角色 | 方向 |
| --- | --- | --- |
| 0-4 | 主机 | 前进 |
| 5-10 | 从机 | — |
| 11-15 | 主机 | 后退 |

- 拉杆运行中可实时切换；从机不读自己的拉杆方向，方向跟随主机（按 mu_config 取反）。
- **全网安全**：同一协议组内**恰好 1 台主机**才正常；0 台或多台主机 → 全列切断牵引 + EB（全制动）。

---

## 二、config_locomodel.lua —— 本车配置

```lua
return {
    maxSpeed = 50.0,               -- 最高速度 (m/s)，档位设定速度上限

    -- 输入面（红灯已改为转向架探针读取，不再占红石输入）
    sideSetSpeed  = "top",         -- 输入：RHI 手柄 0-15（档位）
    sideReverse   = "right",       -- 输入：模式拉杆 0-4前进 / 5-10中立 / 11-15后退
    sideMonitor   = "left",        -- 输出：显示器（可无）
    sideModem     = "front",       -- 外设：无线调制解调器面（rednet）

    -- Simurail 转向架 CC 外设（驱动/制动/换向，唯一输出通道，无回退）
    bogeyDriveMax = 128.0,         -- 驱动应力范围：油门满档 → ±128（应力=动力网络消耗）

    visualMaxSpeed = 10.0,         -- 目视行车限速 (m/s = 36 km/h，运行中可开)

    -- 冒进防护（转向架探针，替代原红石电平输入）
    redProbeFront    = true,       -- 固定轴：true=前端轴（默认），false=后端轴
    redProbeWindow   = 128.0,      -- 探针扫描长度（格），启动时写入每个转向架
    redEbDistance    = 4.0,        -- 红灯进入这个距离（格）内直接 EB

    -- 控制循环周期
    pidDt = 0.05,                  -- 循环节奏 20Hz（>红石刻 10Hz，利于平顺）

    -- PID 参数（统一 PID：输出 = 驱动应力 0..128 / 制动强度 0..1）
    pidKi = 4.3,                   -- 积分（0..128 刻度，原 0..15 刻度 0.5 ×8.53）
    pidKd = 4.3,                   -- 微分（同上换算）
    pidKpNear = 6.8, pidKpMid = 10.2, pidKpFar = 21.3,   -- 分段增益（0..128 刻度）
    nearThreshold = 0.8, farThreshold = 5.0,           -- 增益分段边界 (m/s)
    pidDeadband = 0.15,            -- 死区：设定点附近不动作
    noBrakeWindow = 0.5,           -- 略超速不制动（滑行窗口）
    maxOutputDelta = 17.0,         -- 输出斜坡（每 0.1s 参考应力变化，0..128 刻度）
    brakeScale = 0.2,              -- 制动强度上限：满驱动输出时制动 = 0.2
    emergencyBrakeKp = 0.1,        -- 急停：制动强度 = 速度(m/s) × 0.1 × brakeScale

    -- 性能标定参数（Calibrate 命令）
    calibAccelDur       = 3.0,     -- 全油门加速测量时长 (s)
    calibBrakeStrength  = 0.5,     -- 制动段使用的制动强度（0.5 = 50%）
    calibPlateauTime    = 2.0,     -- 速度多久不再增长就算到顶 (s)
    calibPlateauEps     = 0.1,     -- 单次速度增量超过此值算"还在加速" (m/s)
    calibMinTopSpeed    = 5.0,     -- 最高速度低于此值判定标定失败 (m/s)
    calibStartClearance = 64.0,    -- 开始标定所需的前方清空距离 (格)
    calibRunTimeout     = 120.0,   -- 爬升阶段兜底超时 (s)
    calibBrakeTimeout   = 60.0,    -- 制动段超时下限 (s)，实际按最高速度放大
    calibSettle         = 0.5,     -- 输出切换后的稳定时间 (s)
}
```

**要点**：
- **红石输出面已彻底移除**：`sideBrake` / `sideThrottle` / `sideRevGearbox` 三个键与对应代码都已删除，驱动/制动/换向只走转向架外设，**没有回退通道**（外设找不到就只打印错误并保持无输出）。⚠️ `sideThrottle` 原来是给变速箱供转速（驱动前提是转向架有转速 `getSpeed`）——现在**变速箱必须由常亮红石（红石火把/拉杆）直接供能**，否则车不动。
- **冒进防护（转向架探针）**：主机读**固定轴的探针数据**（`redProbeFront`，默认 `true` = 前端轴；`getProbeOccupiedSignalDistance(redProbeFront)`）——前方最近"对本车红灯"的信号边界距离（格，沿轨道弧长，`-1` = 窗口内无红灯）。**不做接近减速**：列车按司机操作正常行驶，只有红灯进入 `redEbDistance`（默认 4 格，视为已到信号机）才触发 **EB 锁存**（全制动 + 设定归零，**须把手柄拉到 EB（信号 0）确认**）；4 格以外只在显示器显示 `R:距离`。**后退位（拉杆 11-15）豁免**：探针轴固定在转向架一端，倒车时它朝车尾，保护方向是反的，靠司机目视。目视行车豁免；**从机不读探针**（跟随主机广播 ctrl，全列一起停）。不需要速度传感器即可工作。
- **RHI 档位与设定速度**：0 EB / 1-9 B9..B1 / 10 N / 11-12 K1-K2 降速 / 13 C 保持 / 14-15 K3-K4 提速。**从 EB、B 档或 C 拨回 N/K 区时，设定速度自动改写为当前实际速度**：EB/B 把设定速度压在 0、C 把它冻结在旧值，若直接拨到 K 档会因设定与实际差距过大而猛加/猛减；现在回到 N/K 区就从当前速度接着走。N/K 区内部换档不重置，K1-K4 的 5/1 km/h/s 斜坡照常；程序重启时手柄若已在 N/K 区也按当时实际速度接管。
- **运行时指令**：终端输入命令 + 回车（大小写不敏感）：`VisualDriving`（或 `vd`）开关目视行车；`Calibrate`（或 `calib`）性能标定（两步确认，见下）；`help` 列出命令。
- **性能标定**：先把 RHI 手柄拉到 **EB 位**，输入 `calib` 进入待命（显示器 `ARM`；EB 位再输一次解除），再**拉到 N 位启动**。前置：主机位 + 停车 + 有速度传感器 + 前方清空距离 ≥ `calibStartClearance`。流程：**全牵引爬到最高速度**（速度在 `calibPlateauTime` 内增量不超过 `calibPlateauEps` 即认为到顶，或先撞上 `maxSpeed` 设定上限，取较低者）→ 惰行 `calibSettle` → **按 `calibBrakeStrength`（默认 50%）制动到停车**。拟合**按速度分箱**（1 m/s 一箱，取箱内首末样本算平均速率，跨时 ≥ 0.25 s 才用）再做最小二乘，得到两条速度相关曲线：`a(v)=a0+a1·v`（全牵引，**加速度随速度上升线性衰减**，`a1` 应为负，`a(v)=0` 处即牵引极限 `vmax`）和 `d(v)=d0+d1·v`（全制动，由 50% 实测值线性归一化）。分箱而不是用逐 tick 斜率，是因为 20 Hz 下接近顶速时每拍速度变化极小，量化噪声会淹没真实斜率。结果写 `calib.json` **v3**：`accel.a0/a1/vmax/rms/r2/bins`、`brake.d0/d1/mps2/mps2Full/rms/r2`、`topMps`、以及 `profile`（每 2 m/s 采样表，外部列控可直接读）。标定完成立即生效并打印曲线、拟合质量（rms/r²）、"0→顶速需多少秒、顶速全制动需多少格"，若曲线零点与实测顶速差得远会额外提示。标定中故障/红灯逼近自动中止并全制动；结束保持全制动到停稳（从机同步）。重联时从机跟随一起动，测的是**整列**性能。
- **K 档速率与 pidDt 解耦**：每拍实测 dt，设定速度按 `5/1 km/h/s × dt` 增减、PID 积分/微分、输出斜坡都按 dt 算。
- 文件头注释里的 `config_swd1p.lua / SWD1P` 是历史残留，不影响运行。

---

## 二·五、Simurail 转向架 CC 外设（驱动层）

- 外设类型：`Simurail_PhysicsBogey`（有线网络/贴面可达，`peripheral.getNames()` 可找）。
- **驱动**：`setMaxStress(±bogeyDriveMax)` —— 应力 = |maxStress| × |multiplier|，脚本启动时把 multiplier 锁 1，所以**应力 = maxStress 绝对值，直接反映动力网络消耗**；符号决定方向。
- **制动**：`setBrakeStrengthOverride(0..1)`，与红石/遥控/导航 4 路取 max，CC 覆盖直通不平方。
- **转速前提**：转向架必须有动力学转速（`getSpeed`）才出力——变速箱/动力网络负责，电脑不再管（见上"删掉的红石输出面"）。
- **外设调用节流**：驱动/制动只在数值变化时才调用外设（防 mainThread 任务拖垮主循环）；驱动缓存记录的是**带符号**应力，所以换向时即使幅值没变也会重新下发。重启后外设数值复位，无需额外同步。
- **外设缺失**：启动扫描不到 `Simurail_PhysicsBogey` 时只打印 `ERROR: no Simurail_PhysicsBogey peripheral - this vehicle cannot drive or brake`，此时车**既不能牵引也不能制动**（无红石回退），先查接线/区块加载再动车。
- 转向架 GUI 里的"应力"就是 maxStress 基数——CC 设置的倍率不显示在 GUI，用 `hasStressMultiplierOverride()`/`getStressMultiplier()` 判断。
- **超载保护（可选外设 `Create_Stressometer`）**：驱动强度同时就是网络应力消耗，`Σ|maxStress|×|multiplier|×|网络RPM|` 一旦超过产能，Create 把整条网络判为 overstressed、`getSpeed()` 返回 0，转向架**牵引力整体归零**（不是变小，是归零——油门越大越死）。脚本每拍读一次应力表：`used > capacity` 时把驱动上限压到 `当前值 × capacity/used × stressGuardMargin`，之后冻结 0.3 s，再仅在 `used/capacity < stressGuardReleaseRatio`（默认 0.85，宽回差）时按 `stressGuardRelease`（默认 8/s）慢慢放回。**没有应力表外设时整段逻辑不生效**，行为与接入前完全一致。制动不受影响（制动力公式里没有应力项），压驱动不会削弱停车能力。标定运行中触发保护会按 `stressGuardCalibAbort` 中止——那时不是全牵引，拟合出的加速度曲线不可信。
- 应力表必须接在**被这些转向架消耗的同一条动力网络**上，并且电脑能通过相邻面或同一有线网络看到它（脚本用 `peripheral.getNames()` 扫，和找转向架的方式一样）。

---

## 二·六、转向架探针（冒进防护的数据源）

`startup.lua` 的冒进防护不再读红石，改为读 `Simurail_PhysicsBogey` 的探针接口。要点（都是从 Simurail 源码核对出来的）：

| 事实 | 说明 |
| --- | --- |
| 扫描长度 | `getProbeDistance()` 是**配置项**（格），**默认 0 = 不扫描**。脚本启动时把 `redProbeWindow` 写入每个转向架，所以不用手动设 |
| 刷新频率 | 服务端每 `bogeyProbeInterval` tick 扫一次（配置默认 **5 tick = 0.25 s**，范围 1..40）；CC 读到的是上一次扫描的缓存 |
| 距离单位 | 沿轨道的**弧长（格）**，不是直线距离；`-1` = 窗口内没有目标 |
| 轴的选择 | `getProbe*(true)` = 转向架**前端轴**，`false` = **后端轴**；每根轴朝**自己那一端**的方向看。与行驶方向/换向**无关**（固定轴），所以必须让选中的轴指向行驶方向（`redProbeFront`，默认 `true` = 前端轴） |
| 只报最近一个 | 探针窗口内**第一个**符合条件的边界才会被记录；更远的目标看不到 |
| 朝向过滤 | `getProbeOccupiedSignalAligned()` = 该边界在我们要进入的那一侧**装有信号方块**。为 `false` 时脚本忽略它（不是给我们看的信号），但因此也看不到它后面的信号 |
| 红灯判定 | `getProbeOccupiedSignalDistance` 只在信号被**强制红**、或闭塞分区被**别的重联组**占用时才有值（本组占用不算），`getProbeOccupiedSignalForced()` 区分是否强制红 |
| 站台信息 | `getProbeStationDistance/Name/Id/Pos/BlockPos/Powered`，同样 -1/nil 表示无 |
| 断点 | `getProbeDiscontinuityDistance` 只在"前方没有后续轨道"时给值；**挡车器（buffer）不算**（模组里那条路径没有置 blocked） |
| 已知小瑕疵 | 模组 `reset()` 没有清 `stationId`，可能出现距离为 -1 但 `stationId` 仍是上一个站的残留——用之前先判 `stationDistance >= 0` |

诊断用 `bogey_probe.lua`：它会打印两个轴的探针快照（占用信号距离/朝向/强制红、普通信号、站台、断点）。

---

## 三、mu_config.lua —— 重联配置（最容易写错）

```lua
return {
    protocol = "loco-mu",         -- 协议名：同一组内的车必须逐字符一致
    others = {
        -- 键 = 其他车的电脑 label，值 = 该车相对【本车】的方向
        ["对方车label"] = { reverse = true },   -- true = 对方与本车反向（车头对车头）
        ["另一台车label"] = { reverse = false }, -- false = 同向
    },
}
```

**铁律**：
1. **自己不出现在自己的表里**——`others` 只列"除自己外"的车。
2. **键必须是"对方"的 label**——从机靠 `others[主机label].reverse` 决定是否取反；查不到就不换向（默认同向）。
3. **reverse 是"对方相对我"**：对方车头对着我 → `true`；同向 → `false`。
4. **protocol 组内保持一致、组间必须不同**——protocol 是隔离手段，一组（如两台）共用一个名字；不同组的车互不干扰。

**双机示例**（车头对车头，两台一组）：

9001 电脑的 mu_config.lua：
```lua
return {
    protocol = "grp-a",
    others = { ["YL56U2_9002"] = { reverse = true } },
}
```

9002 电脑的 mu_config.lua：
```lua
return {
    protocol = "grp-a",
    others = { ["YL56U2_9001"] = { reverse = true } },
}
```

> 两台内容**不一样是正常的**（视角不同）。把同一份复制给两台是典型错误——从机会查不到主机的键 → 不换向。

四台车 = 两个重联组：组 A（9001/9002）protocol 用 `grp-a`，组 B（9003/9004）用 `grp-b`，各组 others 只列同组另一台。

---

## 四、部署步骤

1. 每台车 `label set <自己的名字>`（与 mu_config 里 others 的键对应）。
2. 复制 3 个文件到每台车：`startup.lua`、`config_locomodel.lua`、`mu_config.lua`；车门电脑另放 `door_ctrl.lua`（可选，见第六节）。
3. 每台车按自己视角改 `mu_config.lua` 和 `config_locomodel.lua`（接线面）。
4. **接线**：`sideSetSpeed`/`sideReverse` **两个输入面** + 显示器 + 无线 modem；**转向架外设必须有线/贴面可达（无红石回退，探针也走它）**；变速箱用常亮红石供转速。红灯不再接红石，冒进防护读转向架探针。
5. 把想当主机的车拉杆扳到前进/后退，其余中立。开机即运行。

---

## 五、改机车配置文件名

`config_locomodel.lua` 的名字在脚本里写死，改名要同步改脚本。合并版只有**一处**：

| 文件 | 位置 | 代码 |
| --- | --- | --- |
| `startup.lua` | 第 0 节 | `local cfg = dofile("config_locomodel.lua")` |

`mu_config.lua` 同理，`startup.lua` 里 `pcall(dofile, "mu_config.lua")` 一处。

---

## 六、车门集控（door_ctrl.lua）

每节车（或车门附近）一台**独立电脑**运行 `door_ctrl.lua`，与列车控制程序完全解耦，只用 rednet 的 `loco-door` 协议通信。接线面写在脚本顶部常量里（**不走 config_locomodel.lua**）：

| 常量 | 默认面 | 作用 |
| --- | --- | --- |
| `SIDE_IN_L` | right | 左门脉冲输入（上升沿翻转） |
| `SIDE_IN_R` | left | 右门脉冲输入 |
| `SIDE_OUT_L` | front | 左门常电平输出（开门期间为高电平） |
| `SIDE_OUT_R` | back | 右门常电平输出 |
| `SIDE_MODEM` | top | 无线 modem（rednet） |

**行为**：

- 任意一台电脑的按钮产生上升沿 → 本车翻转对应门 → 广播 `{kind="cmd", action="open"/"close", only="left"/"right", from=label}` → **全列同步执行**（集控）；`only=nil` 表示两侧一起动。
- `left`/`right` 是相对车头的 A/B 面：发送方与接收方朝向相反（本车 `mu_config.others[对方].reverse == true`）时自动 `left<->right` 互换，所以同一条命令在每节车开的都是**站台侧**。
- 每 0.5 s 广播一次 `{kind="state", openL, openR, label}` 供监控/LKJ 读取；状态消息不转发，因此不会形成回环。
- 电脑 label 建议 `<车号>_door`；脚本对缺少后缀的 label 会自动补 `_door`，查 `mu_config` 朝向时也会去掉后缀再查。
- ⚠️ `local netUp` 必须声明在 `broadcastState` **之前**（已修复）。Lua 的 local 作用域从声明处开始，声明晚于函数定义时函数里读到的会是全局 `nil`，导致状态广播和心跳全部静默跳过。

**预留**：LKJ 可直接发 `{kind="cmd", action="open", only="right"}`；后续可加 `lock` 动作实现"运行中禁止开门"。

---

## 七、常见问题速查

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 从机不自动换向 | mu_config 的 `others` 键写错/复制了主机那份 | 从机那份的键改成**主机的 label**，reverse 按实车朝向 |
| 收不到对方（无 Heard / RX 不涨） | 组内 protocol 不一致 | 两台 `protocol` 逐字符对比；控制台 `Foreign protocol` 会指出差异 |
| 全列 EB（FAULT） | 组内主机数 ≠ 1（都中立/多台非中立） | 确认恰好一台拉杆在前进/后退 |
| 车完全不动（bogey 模式） | ① 变速箱没转速（常亮红石缺失）② 转向架 maxStress 为 0 ③ 外设根本没找到 | ① 变速箱接常亮红石 ② `bogey_probe.lua` 查 `getMaxStress` ③ 控制台 `ERROR: no Simurail_PhysicsBogey peripheral` |
| 显示器 `T:` 有数值、车却不动或一顿一顿 | 动力网络 overstressed：`getSpeed()` 被清零，牵引力整体为 0 | 接 `Create_Stressometer` 看 `used/capacity`；控制台出现 `STRESS GUARD:` 就是保护在介入，调小 `bogeyDriveMax` 或加大动力产能（多并电机/提高转速） |
| 显示器 `T:` 无变化 | 驱动应力未变或外设失联 | 控制台 `BOGEY CALL FAILED` 提示；`bogey_probe.lua` 单测 |
| 倒车被红灯挡住 | 探针轴固定在转向架一端，倒车时朝车尾 | 拉杆 11-15 时保护整体豁免（靠目视）；倒车也要保护得改成按行驶方向选轴 |
| 前进时保护方向反了（对后方红灯制动 / 前方红灯不动作） | `redProbeFront` 与实际行驶方向相反（纹理方向标识容易看反） | 取反 `redProbeFront`；用 `bogey_probe.lua` 对比两轴 `trackDir` 与行驶方向 |
| 显示器一直不显示 `R:`（红灯不生效） | 探针距离为 0（模组默认）或信号朝向相反 | 看启动横幅 `Red protection: probe front axle, window ...`；`bogey_probe.lua` 查 `getProbeDistance` 与 `occupiedSignalAligned` |
| 红灯不触发 EB / 触发太早 | `redEbDistance` 不合适或探针轴不对 | 调 `redEbDistance`（默认 4 格）；用 `bogey_probe.lua` 核对轴与距离 |
| 想让列车在红灯前自动减速停车 | 按需求已移除接近减速，只保留 4 格内 EB | 后续 LKJ 列控用 `calib.json` 的曲线做目标制动（见规划） |
| 信号明明红灯却不触发 | 该边界在我们这一侧没装信号方块（`aligned=false` 被忽略），或闭塞分区被**本组**占用 | 该方向补装信号；本组占用按设计不算红灯 |
| 标定提示 `brake fit invalid` | （已修复）拟合斜率在制动时是**负值**，旧代码却要求 `b > 0`，任何真实制动都通不过 | 更新 `startup.lua`；修复后应看到 `CALIB brake: x.xxx m/s^2` 和 `CALIB: saved to calib.json` |
| 标定提示 `top speed only X km/h` | 全牵引也爬不到 `calibMinTopSpeed`（牵引力/变速箱转速/制动未释放） | 检查常亮红石、转向架 `getSpeed`、是否有制动残留 |
| 标定提示 `no stable top speed within 120s` | 速度一直在缓慢爬升，`calibPlateauTime` 内没判定到顶 | 加大 `calibRunTimeout`；或把 `calibPlateauTime` 调小 |
| 标定提示 `speed rose during the brake run` | 制动没起作用（制动强度被别处覆盖 / 转向架没转速 / 下坡） | 检查常亮红石、转向架 `brakeStrength`；确认标定时手柄在 N 位 |
| 加速度无力、误差大反而更软 | （已修复）`config_locomodel.lua` 曾有一行重复 `pidKpFar = 2.5` 覆盖 21.3 | 确认文件里只有一处 `pidKpFar`，值 21.3 |
| B1-B9 无制动 | B 档制动 = (10-sig)/15 强度 | 信号 1→0.6（B1 最强只有 60%）、信号 9→0.067，逐级；全制动请用 EB |
| 车门能开关但监控看不到门态 | （已修复）`door_ctrl.lua` 的 `local netUp` 声明晚于 `broadcastState` | 确认 `netUp` 声明在函数之前；命令广播不受影响 |
| 20Hz 下油门高频抖动 | 微分项噪声放大 | pidKd 从 4.3 降到 2~3（0..128 刻度） |
| 控制台 `BROADCAST FAILED` | 广播失败（少见） | 查看原因，多为 modem 被移除 |
| 脚本加载报错 | 文件里有中文/非 ASCII | 注释一律英文 |
