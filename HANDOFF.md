# 交接文档（给在本目录工作的 AI 工具）

**读者**：Deepseek Harness（DSH）、WorkBuddy、以及后续任何在本目录工作的 AI 工具，也包括人。
**最后更新**：2026-10-27，由 WorkBuddy 整理。

本文件是**跨工具的上下文中继**：本目录同时被人、DSH、WorkBuddy 读写，任何一方都可能看不到
别人的会话记录。请在你开始动手前先读第 0、1 节，在你结束动手前更新第 2 节和待办清单。
不要删除本文件，不要把它重命名为只有你自己看得懂的名字。

---

## 0. 三条硬约束（违反会直接炸游戏或丢文件）

1. **所有 `.lua` 与游戏内配置文件必须纯 ASCII。**
   CC:Tweaked 加载不了含非 ASCII 字符的脚本——出现一个中文注释，电脑开机就报错。
   中文说明只写在本仓库的 `.md` / `.txt` 文档里，这些文档不要复制进游戏电脑。
   自检命令见第 5 节。

2. **`backup_pre_*` 目录不要清理。**
   其中 `locomaster.lua` / `locoslave.lua`（合并前的双脚本架构）**从未进入过 git 历史**，
   磁盘上是唯一副本。同目录里的 `config_yl56u2.lua` 已被通用 `config_locomodel.lua` 取代，无保留价值。
   （这条也写在 README 顶部"第一约束"里。）

3. **不要在仓库根跑 `npm install`。**
   `tcc/` 是刻意零依赖的。2026-10-27 曾在根目录误装过一次，产生 `node_modules/` +
   `package.json` + `package-lock.json` 并污染工作区（已清理）。需要 node 依赖时装到
   `C:\Users\Admin\.workbuddy\binaries\node\workspace`。`.gitignore` 已加了防护条目。

---

## 1. 项目现状速览

**这是什么**：Minecraft 1.21.1 + NeoForge 整合下的**物理化列车控制系统**。
CC:Tweaked 电脑 + Create 动力学网络 + Simurail 物理转向架 + Sable 装配结构。
目标是让游戏内列车具备真实机车的驾驶、重联、冒进防护、性能标定，并最终实现 LKJ 列控。

**三层结构**

| 层 | 位置 | 说明 |
| --- | --- | --- |
| 车载层 | `locos/` | Lua（纯 ASCII）。`startup.lua` 主机/从机合一单脚本，约 1679 行 / 70KB |
| 上位机层 | `tcc/` | Node.js **零依赖**。手写 RFC6455 WebSocket + HTTP 静态服务，端口 8090 |
| 工具层 | `tools/` | `parse_create_tracks.js`（gzip NBT 读取器）、`generate_line.js`、`ws_probe*.js`、`sim_stress_guard.py` |

**版本状态（2026-10-27 晚）**

- 远端 `origin/main` 与本地 `main` 一致在 **`7a1f7aa`**，工作区干净。
- 仓库地址：`https://github.com/plants13/minecraft-cc-simurail-train-lococonsist`
- `.gitignore` 在仓库根并随仓库分发（**不要**再往 `.git/info/exclude` 写规则——
  那是本地私有文件，其他 AI 工具看不到，历史上正是它导致 `tcc/` 与 `tools/` 长期无版本保护）。

**驱动/控制通道（重要）**

- 驱动 `setMaxStress(±128)`，制动 `setBrakeStrengthOverride(0..1)`，换向 = 应力符号。
  **已无红石回退通道**，外设不可达时只打印错误并保持无输出。
- 角色由模式拉杆模拟量决定：0-4 前进主机 / 5-10 从机 / 11-15 后退主机；同协议组必须恰好 1 台主机。
- 冒进防护读转向架探针 `getProbeOccupiedSignalDistance`，红灯 4 格内 EB 锁存，不做接近减速。

---

## 2. 本次会话做了什么（2026-10-27，WorkBuddy）

按时间线，共七件事：

### 2.1 全目录盘点与清理
通读目录输出项目全貌；分类出可删项。经用户确认后删除 4 项：
`NUL;`（2>NUL 误建的空文件）、`.reasonix/`（旧 AI 日志）、`.stale-backup/`、
`Create-mc1.21.1-dev.zip`（16MB，解压目录 11759 文件完整对应，可随时重新打包）。
**教训**：本环境的 Windows 回收站 API 报"无法找到指定文件"，实际是硬删除。
**今后删文件不要再向用户承诺"先移到回收站"。**

### 2.2 版本控制改造
把 `.git/info/exclude` 里的"忽略一切 `/*` + 白名单放行 6 项"迁移为仓库根 `.gitignore`，
`exclude` 清空为纯注释。由此 `tcc/`、`tools/` 首次进入版本保护。

### 2.3 git 联网排障（局域网代理 + MITM 证书）
- 现象：`git fetch` 失败。根因两层：
  1. 环境注入 `http_proxy=http://127.0.0.1:11593`，它对 CONNECT 隧道返回 **502**（浏览器不走这个代理，所以用户侧"访问没问题"）；
  2. 绕开代理后链路是本地 MITM（`remote_ip=127.0.0.1`），schannel 卡在证书吊销检查
     `CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`；换 openssl 后端则"unable to get local issuer certificate"。
- **可用组合**（已写入本仓库 `.git/config`，`git fetch/push` 现在可直接用）：
  `http.sslBackend=schannel` + `http.schannelCheckRevoke=false` + `http.proxy=`（空值，覆盖环境变量）。
  撤销用 `git config --local --unset <key>`。

### 2.4 历史对齐与首次同步
PR #1 被 merge 了两次（远端 `88b4a90` 网页 merge + 本地 `d680d57` 本地 merge），
两边父提交相同且 **tree 完全相同**（`2e27926…`），内容逐字节一致。
用 `git pull --rebase origin main` 丢弃等价的本地 merge，本地提交变 `3fe71bf`，快进推送成功。
入库 18 个文件 +1556/−3。**结论：不要 force push。**

### 2.5 拉取上游 Simurail 最新源码
- 旧快照保留为 `Create-Simurail-20260825-snapshot/`，新 clone 放在 `Create-Simurail/`
  （自带 `.git`，可直接 `git pull`）。用户明确说过"我们不缺存储"，
  **不要为了省空间合并或删除这两份**。
- 上游 HEAD `4c11d53`；自 2026-08-25 起共 **127 个提交**。
- **已确认：CC 外设 `PhysicsBogeyPeripheral` 不暴露任何轮速方法**（无 `slipSpeed` / `getSpeed`）。
  BE 里虽有 `visualSpeed` / `slipSpeed` 字段，但没通过 CC 暴露出来。

### 2.6 实现空转防护（wheel slip guard）—— 默认关闭
见第 3 节，那是本次最重要的设计决定。

### 2.7 推送
`e45bc87`（空转防护，+152）+ `7a1f7aa`（.gitignore，+8/−1），推送 `3fe71bf..7a1f7aa`。

---

## 3. 关键设计决定（想改动前请先读完，别直接推翻）

### 3.1 空转防护：为什么是"加速度亏空"，以及为什么默认关

**约束**：外设没有轮速，所以"轮速 > 车速"这种标准判据用不了。
**方案**：用标定曲线反推——

```
expected = accelAt(v) * (commandedStress / DRIVE_STRESS_MAX)
判空转：measured / expected < slipGuardRatio
```

指令应力在、速度增益不在 → 轮子在打滑。判到之后按 `slipGuardCut` 乘性削减牵引天花板，
到 `slipGuardFloor` 为止，保持 `slipGuardHold` 秒，再按 `slipGuardRelease` 缓慢恢复——
形状与既有的过应力保护一致。

**三条边界，都是有意为之**：

1. **只砍牵引，绝不减制动。** 制动时误判会吃掉制动距离，那是这套控制器唯一不能拿来换的东西。
2. **没有 `calib.json` 就是空转。** 依赖 `perf.accel`，无标定时整段直接 return，不做任何事。
3. **低于速度/应力下限时不出结论。** 起步阶段标定曲线本身最不确定。

**默认 `slipGuardEnabled = false`。** 原因：期望加速度来自**按某一固定编组标定出来的曲线**，
而机辆模式频繁挂车摘车，实际编组质量一直在变、曲线不变，这个偏差正是空转判据读到的东西——
结果就是在轮子完全正常的时候砍牵引。**只在固定编组运行、或每次改编组后重跑一次 `CALIBRATE`
才打开**，然后对着状态行的 `SLIP:0.xx` 读数调 `slipGuardRatio`。

**代码位置**：`locos/startup.lua` 的 `0b3. Wheel slip guard` 段；
主循环在 `getActualSpeed()` 之后调 `updateSlipGuard(dt, actualSpeed)`；
`setThrottleOutput` 里 `if out > slipLimit then out = slipLimit end`；
显示器第 7 行状态位 `SLIP:0.xx`。参数在 `locos/config_locomodel.lua` 的 `slipGuard*` 一组 9 个键。

### 3.2 过应力保护可能需要重新标定（上游副作用）

上游 `5a4a74a`（10-14）让应力变化**立即**刷新动力学网络，`getStress` 读数滞后显著变小。
现有过应力保护当初是按"滞后较大"调的，**升级后可能偏保守**。
如果要动，方向是：略放宽 `STRESS_GUARD_MARGIN`、加快 `stressGuardRelease`。
这个判断还没有做实车验证，只是从上游 diff 推出来的。

### 3.3 上游升级要注意的配置反转

`ac7f971`（09-17）**反转了 bogey box / sublevel 配置项**。升级到新版本时留意这一条。

---

## 4. 待办与已知遗留

**没做、但值得做的**

- [ ] **空转阈值的实车标定**：`slipGuardRatio = 0.45` 是拍的，没跑过实车。
      建议固定编组跑一趟，对着 `SLIP:0.xx` 读数调，再改默认值。
- [ ] **过应力保护重调**（见 3.2），依赖升级到新上游之后的实测。
- [ ] **标定与编组解耦**：目前 `calib.json` 与编组强绑定，是空转防护默认关的根因，
      也是 LKJ 目标制动曲线要落地必须解决的问题。可能的路子：按车数/质量分档存标定，
      或者在线估计质量。这个没设计，只提出来。

**清理候选（都还没动，删之前先问用户）**

- 根目录 `startup.lua`（41KB / 1049 行，2026-10-13）—— **`locos/startup.lua` 的旧副本**，
  里面连过应力保护都没有（`grep stressGuard` 命中 0），已在 git 里。要么删，要么至少加注释说明它已废弃。
- `create_tracks_parsed.json`（6.4MB）—— `tools/parse_create_tracks.js` 的产物，可再生成。
  注意：`tcc/` 直接解析 `.dat`，不需要它。
- `tools/ws_probe.js` ~ `ws_probe5.js` —— 五版探针脚本，可能只留最后一版。
- `line_主环线.json`（856KB）—— `generate_line.js` 产物，建议保留。

**README 里已修正的一处过期描述**：原第 86 行说"上位机 `tcc/` 服务目前不在本目录中"，
`tcc/` 已于 2026-10-27 入库，该描述已更新。

---

## 5. 常用校验命令

改完 Lua 后跑一遍，两条都要干净：

```bash
# 1) 纯 ASCII + Lua 语法（luaparse 装在工作区，不要在仓库根装）
NODE_PATH=/c/Users/Admin/.workbuddy/binaries/node/workspace/node_modules \
  node /tmp/luacheck.js locos/startup.lua locos/config_locomodel.lua locos/mu_config.lua locos/door_ctrl.lua

# 2) 块配平检查（仓库自带）
python tools/lua_balance_check.py locos/startup.lua
```

两个都要满足：非 ASCII 字符数 = 0，parse 通过。CC 端报的是运行时错，
语法/编码问题是开机就炸，所以这一步不能省。

---

## 6. 上游依赖速查

- 仓库：<https://github.com/Crystaelix/Create-Simurail>（MIT，主力作者 TheLMiffy1111）
- 本地两份：`Create-Simurail/`（clone，HEAD `4c11d53`，可 pull）、
  `Create-Simurail-20260825-snapshot/`（旧快照，解压不完整 183/333）。
- 反查 API 时看 `src/main/java/com/crystaelix/simurail/compat/computercraft/peripheral/PhysicsBogeyPeripheral.java`——
  **那份文件就是 CC 能调用的全部方法的权威清单**，动手前先看它，别凭印象猜 API。

**自 2026-08-25 起 127 个提交中，与本项目相关的**：

| 提交 | 日期 | 内容 / 影响 |
| --- | --- | --- |
| `ac7f971` | 09-17 | 反转 bogey box / sublevel 配置 —— 升级时注意 |
| `a4f34cf` | 10-07 | 支持用 sable forceload 强制加载转向架 |
| `5a4a74a` | 10-14 | 应力变化时立即更新应力网络 → 读数滞后变小，见 3.2 |
| `df55124` | 10-18 | **修复"改变转向架应力时崩溃"**（加了 `hasNetwork()` 判断）—— 我们每帧调 `setMaxStress`，旧版有崩溃风险 |
| `4c11d53` | 10-26 | 探针忽略反方向站台（只影响 stationDistance，不影响 `getProbeOccupiedSignalDistance`） |

---

## 7. 更新本文件

改动了项目状态、做完一件事、或者发现本文档有错，请直接更新对应小节，并在顶部改掉
"最后更新"的日期与署名。第 2 节按时间线追加，不要覆盖别人的条目。
