# Login-edu —— 校园网自动登录（先伪装，再认证）

路由器（OpenWrt / ImmortalWrt）上的**校园网自动登录**：一条命令跑完
「网络伪装（MAC / TTL / MTU / UA）→ 网页认证 → 装好自动登录」。
有线 WAN、PPPoE、**WiFi STA 无线上联**都覆盖。路由器固件与刷机内容在 [boot](https://github.com/2476818641/boot) 仓库。

> 用途仅限**自己的设备、自己的账号**正常认证上网。请勿用来冒用他人账号或冒充他人设备。

## 目录（3 个脚本 + 3 个文档）

| 文件 | 作用 |
|---|---|
| **`campus-net-setup.sh`** | **入口脚本**：先做网络伪装（MAC 克隆 / MTU / TTL / UA-Mask 的 UA 改写），配完测外网；不通就**自动接着做认证**，成功后装好自动登录 |
| **`campus-portal-auth.sh`** | **认证脚本**：网页认证实现（三步 API + AES 加密的 `pass`）。入口脚本会自动下载它；也可单独用（`--quick` / `--status` / `--setup`） |
| **`burp-xml-summary.py`** | **解析 XML 脚本**：把 Burp 导出的几十 MB XML 压成几 KB 小抄（换学校抓包时才用） |
| **`README.md`** | 介绍流程（本文） |
| **`PACKET-CAPTURE.md`** | 抓包流程：怎么抓、抓什么、放哪、怎么脱敏 |
| **`AI-PROMPT.md`** | 给 AI 的提示词：把抓包交给任意 AI，吐出认证脚本需要的结论 |

（另有一个 `.gitignore`，只用来防止抓包 XML 被提交进仓库。）

---

## 🚀 傻瓜版（推荐：一条命令）

```sh
# 第 1 步：下载入口脚本（就这一行）
wget -O /tmp/campus-net-setup.sh https://cdn.jsdelivr.net/gh/2476818641/Login-edu@main/campus-net-setup.sh

# 第 2 步：一条命令跑完（伪装用推荐默认值，认证用你给的账号）
sh /tmp/campus-net-setup.sh --quick 你的账号 你的密码
```

看到 `认证完成 ✅（网络伪装 + 网页认证 都已生效）` 就成了。认证脚本**不用你下载**，入口脚本会自动取。

`--quick` 里**只有 MAC 会单独问你一次**（校园网常按 MAC 分配/绑定 IP，默认不改；直接回车即可跳过）：

```
  ── MAC 地址（校园网常按 MAC 分配/绑定 IP，克隆成已知设备的 MAC 最稳）──
     当前 WAN MAC（wan）: aa:bb:cc:dd:ee:ff
     路由器下面这些设备拿过地址，可以参考/直接抄：
       aa:bb:cc:11:22:33  MyPhone
    要克隆的 MAC（回车=不改；auto=取上面第一台设备；或填 AA:BB:CC:DD:EE:FF）:
```

> 认证脚本如果本机没有，入口脚本会**先在你放脚本的目录里找**（比如两个文件都在 `/root`，它会自动装到
> `/etc/campus-portal-auth.sh`），找不到才尝试下载（每个源最多 8 秒，失败不纠缠）。
> 因为**认证前本来就没网**，建议一开始就把两个文件一起传到路由器同一目录，最省事。

> ### UA 改写用 UA-Mask（当前方案）
>
> UA-Mask 是**只做 UA 改写**的透明代理：只劫持 TCP，默认就绕过 22/443，而且能把「确认不是 HTTP」
> 的目标**自动卸载进 nftables 集合** —— 命中后那些流量根本不进用户态代理。这一条就是解决
> "游戏加速器/Steam 被代理转坏"的关键：隧道类流量（非 80/443 的高位端口 TCP）学几次后永久绕过，
> 而且按 `目标IP.端口` 记录，**节点 IP 变了会自动重新学**，不需要你维护 IP 白名单。
>
> 脚本的 `--quick` 一键做的就是下面这一整套（不用你手点 LuCI）：
>
> | 项 | 值 | 为什么 |
> |---|---|---|
> | `ua` | 常见 Windows Chrome UA | 所有设备（手机也是）统一成"同一台 PC" |
> | `match_mode` | `regex`（正表，默认）/ `all`（全量） | 正表只统一「设备类」UA，其余原样放行，兼容性最好 |
> | `ua_regex` | `(iPhone\|iPad\|Android\|Macintosh\|Windows\|Linux\|Apple\|Mac OS X\|Mobile)` | 命中才改写，未命中放行 |
> | `Firewall_ua_whitelist` | `QeeYouAcceler,Valve/Steam,HttpDns,Microsoft-CryptoAPI,Microsoft NCSI` | 这些 UA **不改写**，并且**命中即把该目标立刻卸载出代理**（24h） |
> | `Firewall_drop_on_match` | `0` | **必须是 0**，填 1 会直接掐断匹配上的连接 |
> | `enable_firewall_set` + `Firewall_ua_bypass` | `1` + `1` | 流量卸载总开关 + 绕过非 HTTP 流量（固件默认已开） |
> | `firewall_nonhttp_threshold / decision_delay / timeout` | `1` / `10`（秒）/ `86400` | 决策器默认"5 次观测 + 60s 延迟 + 8h"是为了防误判泄露；压到最小让隧道尽快被卸载 |
> | `bypass_ports` | `22 443` | 443 是 TLS，本来也看不到 UA |
> | `operating_profile` | `Medium` | 256MB 机器：Low=200 并发 / Medium=500 / High=1000 |
>
> ⚠️ **三个"名单"的优先级**（源码 `internal/rewrite/engine.go`，从高到低）：
> `Firewall_ua_whitelist`（不改写 **且卸载**）→ `whitelist`（只是不改写）→
> `match_mode`（`all` 全改 / `regex` 命中才改 / `keywords` 含关键词才改）。
> **别把 `MicroMessenger` / `Bilibili` 放进 `Firewall_ua_whitelist`** —— 它优先级高于正则，而手机微信/
> 哔哩哔哩的 UA 里带 `Android`/`iPhone`，一旦被放过，"Windows Chrome UA + Android UA"同时出现，
> **反而暴露多设备**。所以脚本把 `whitelist`（第二个名单）留空。
>
> 切换范围（随时可换，不碰网络和认证）：
>
> ```sh
> sh campus-net-setup.sh --ua-mode regex     # 正表（默认，推荐）
> sh campus-net-setup.sh --ua-mode all       # 全量改写（最统一，兼容性最差）
> UA_MODE=all sh campus-net-setup.sh --quick 账号 密码      # --quick 时指定
> UA_STR='Mozilla/5.0 ...' sh ... --quick 账号 密码          # 换伪装 UA（记得 TTL 要自洽）
> SKIP_UA=1 sh ... --quick 账号 密码                         # 这次完全不动 UA 改写
> ```
>
> 旧写法 `--ua3f-rules whitelist|blacklist|all` 仍然能用（会提示改名，`whitelist→regex`、`blacklist/all→all`）。
>
> ### TTL：UA-Mask 没有这个功能，由内核 nft 规则负责
>
> UA-Mask 不做 L3（没有 TTL/IPID/删 TCP 时间戳/阻断 QUIC/Desync —— 那些是旧方案 UA3F 的能力，
> 而它们实测会打死加速器与 QUIC 流量）。所以 TTL 由脚本写的 `/etc/nftables.d/10-ttl-fix.nft` 负责，
> 默认值与 UA 人设**自洽**：UA 说 Windows → `128`，说 Android/Linux/macOS → `64`
> （UA 与 TTL 自相矛盾正是 DPI 会抓的点）。改：`TTL_VALUE=128 sh ... --quick 账号 密码`。
>
> ### 自检
>
> 脚本跑完会检查：服务在跑 / 核心配置 `/var/run/UAmask/config.json` 生成正确 / fw4 里存在
> 绕过集合 `UAmask_bypass_set`。**真实效果要在电脑或手机上打开 <http://ua-check.stagoh.com/> 看** ——
> 路由器自己 curl 是不准的（UA-Mask 只处理 LAN 侧进来的流量），而且"grep 页面里有没有某字样"
> 那种判法是假阳性（那个站本身就叫 UA3F）。
>
> 加速器还是不通时，先看它有没有被卸载出去：
>
> ```sh
> nft list set inet fw4 UAmask_bypass_set      # 应该有 节点IP.端口
> ```
>
> 想跳过"学习期"，把端口静态加进放行列表：
> `uci add_list UAmask.main.bypass_ports='端口号'; uci commit UAmask; /etc/init.d/UAmask restart`
>
> ### 旧方案（UA3F / UA2F）仍兼容
>
> 老固件里装的是 UA3F 时，脚本会自动走 legacy 路径（规则表那套逻辑照旧）；**同时装了两套**时，
> 脚本会**自动停用 UA3F 并 `nft delete table inet UA3F`** —— 必须删表：UA3F 的 `stop` 不清 nft，
> 残留的 `tcp dport != {22} redirect to :1080` 会把除 22 外的所有 TCP 吸进没人监听的端口，
> 表现是"电脑没网但 ping 正常"。
>

想连这一步也不问（脚本化/远程执行时方便）：

```sh
CAMPUS_MAC=AA:BB:CC:DD:EE:FF sh /tmp/campus-net-setup.sh --quick 你的账号 你的密码
```

> 提示：`--quick` 在没有终端的环境（管道、cron、`wget | sh`）里不会提问，会自动用默认值，不会卡住。

它按这个顺序做（**先伪装，后认证**）：

```
1/4 选择接入方式      → 网页认证（--quick 自动选）
2/4 网络伪装          → MAC（默认不改）→ MTU → TTL（内核 nft 规则，128/64 跟 UA 人设走）→ UA 改写（UA-Mask 一键配好）
3/4 应用配置          → uci commit → network restart → fw4 reload
4/4 等 20 秒测外网    → 通了：完成（顺手存账号 + 装自动登录）
                       └ 不通：自动接着做网页认证，成功后装 hotplug + cron
```

其它常用姿势：

```sh
DRY_RUN=1 sh /tmp/campus-net-setup.sh --quick 账号 密码   # 先看要改什么（不落盘、不断网、不认证）
sh /tmp/campus-net-setup.sh                              # 交互式：自己挑 MAC/TTL/UA 等伪装项
/etc/campus-portal-auth.sh --status                      # 看状态：外网通不通 / 自动登录装没装
/etc/campus-portal-auth.sh --quick 账号 密码              # 只重做认证（不动伪装）
```

| 你会遇到的情况 | 怎么办 |
|---|---|
| 改密码了 | 再跑一次 `--quick 账号 新密码` |
| 换学校 / 换门户地址 | `PORTAL=http://新门户 sh ... --quick 账号 密码`，或交互式里改 |
| 想知道为什么需要伪装 | 见下面「校园网一般怎么认人」 |

---

## 校园网一般怎么认人（以及本仓库怎么对付）

| 检测手段 | 路由器上怎么对付 | 落在哪 |
|---|---|---|
| **User-Agent**（判断是不是路由器共享） | UA-Mask 把各设备的 UA 统一成一台 PC（只改明文 HTTP） | 入口脚本第 2 步的 UA 段 |
| **TTL**（路由器共享的包每过一跳 -1） | 内核 nft 规则（**全流量含 ICMP/UDP**，零开销；UA-Mask 本身没有 TTL 功能），规则在 `/etc/nftables.d/10-ttl-fix.nft` | 入口脚本第 2 步 |
| **深层包检测 DPI** | 不启用（Desync/乱序注入实测会把加速器隧道与 QUIC 打坏，得不偿失） | — |
| **MAC 绑定** | 把已知设备的 MAC 克隆到 WAN 侧（有线上联写 network，无线上联写 wireless） | 同上 |
| **网页认证（portal）** | 定时 POST 账号密码到认证接口（**有线、WiFi 上联都一样要**） | `campus-portal-auth.sh` |
| **PPPoE 拨号** | netifd 配 pppoe | 入口脚本方式 1 |

---

## 完整流程

### 第 1 步：先用主脚本把"底层"配好

```sh
B=https://raw.githubusercontent.com/2476818641/Login-edu/main
# 国内可套自己的 ghproxy：B=https://cf.liuass.eu.org/ghproxy/$B

wget -O /tmp/campus-net-setup.sh $B/campus-net-setup.sh
DRY_RUN=1 sh /tmp/campus-net-setup.sh      # 先干跑：只看要改什么，不落盘、不断网
sh /tmp/campus-net-setup.sh                # 正式跑
```

它会依次问：

| 提示 | 说明 |
|---|---|
| 接入方式 | `1` PPPoE（本脚本直接配好账号密码并拨号）／`2` 网页认证（**配完网络会自动接着做认证**）／`3` 我已经用 WiFi 连上校园网了 |
| 选 `3` 之后的认证方式 | **WiFi 上联一样要认证**：`1` 网页认证（默认）／`2` PPPoE／`3` 不用认证（家里测试） |
| 要克隆的 MAC | 回车=不改；`auto`=取 `/tmp/dhcp.leases` 第一台设备；或填 `AA:BB:CC:DD:EE:FF` |
| MTU | PPPoE 默认 1492，网页认证 1500，无线上联默认 `keep`（由 AP 决定） |
| UA 改写（自动识别工具） | 固件里是 **UAmask**（当前方案）就一键配好整套（UA 串 / 匹配规则 / 放行名单 / 流量卸载调优），并**自动停掉旧方案残留**；只有 **ua3f**（旧固件）才走 legacy 规则表那套。会问：启用 / **匹配规则**（`regex` 正表 或 `all` 全量）/ **UA 串**（默认常见 Chrome UA）/ **放行名单** / 是否把非 HTTP 卸载调成快速生效 |

它改了什么（都可回滚）：

| 项 | 落点 | 回滚 |
|---|---|---|
| MAC 克隆 | `config device` 段（与 LuCI「网络→接口→设备」一致） | LuCI 删掉 MAC 字段 |
| MTU / MRU | `network.<iface>.mtu` / `.mru` | `uci delete ...` |
| 接入方式 | `network.<iface>.proto`（pppoe + 账号密码 / dhcp） | 改回 `dhcp` |
| **TTL** | `/etc/nftables.d/10-ttl-fix.nft`（**除 LAN 网桥外所有出口**统一成 128 或 64，按 UA 人设） | `rm` 该文件 + `fw4 reload` |
| UA 改写 | `UAmask.*`（启用/UA 串/匹配规则/放行名单/流量卸载）；旧固件是 `ua3f.*`、更老是 `ua2f.*` | LuCI「服务 → UA MASK」（旧固件「服务→UA3F」） |

> `/etc/nftables.d/` 在 firewall4 的 keep.d 里，**刷固件升级后 TTL 规则仍在**。
> 规则用"排除 LAN 网桥"而不是写死设备名，所以网线 / PPPoE / 无线 STA 都自动覆盖。

跑完它会等 20 秒，然后 `ping 223.5.5.5` 或 `curl baidu.com` 测一次：

- **通了** → 收工（网页认证模式下若直接通，说明学校放行或已认证过；给了账号就顺手装好自动登录）
- **没通 + PPPoE** → 提示去看 `logread` 里的 pppd 报错
- **没通 + 网页认证（有线上联和无线都一样）** → **自动接着做认证**（入口脚本会先把认证脚本下载好），
  成功打印「认证完成 ✅（网络伪装 + 网页认证 都已生效）」

### 附：UA 改写选项对应表（进阶参考）

现在用 **UA-Mask**（只做 UA 改写）。脚本自动识别工具：UAmask → 一键配好；旧固件的 ua3f → 走 legacy：

| 校园网检测项 | 谁来做 | 具体选项 / 位置 |
|---|---|---|
| **User-Agent**（判断是不是路由器共享） | **UA-Mask** | `UAmask.main.ua`（伪装串）+ `match_mode`（`regex` 正表 / `all` 全量）+ `ua_regex`；LuCI「服务 → UA MASK」 |
| **协议敏感流量**（加速器 / Steam / App 内 HttpDns） | **UA-Mask** | `Firewall_ua_whitelist`（不改写**且命中即卸载出代理**）+ `enable_firewall_set=1` + `Firewall_ua_bypass=1`（非 HTTP 目标自动卸载到 nft 集合） |
| **TTL**（共享的包过一跳 -1） | 内核 nft 规则 | `/etc/nftables.d/10-ttl-fix.nft`；值跟 UA 人设走（Windows→128 / Android·Linux·macOS→64） |
| **IPID / TCP Timestamp / TCP 初始窗口 / QUIC 阻断** | 不启用 | 这些是旧方案 UA3F 的 L3 能力；"阻断 QUIC"会丢光 UDP 443，把加速器/语音/QUIC 视频全打死 |
| **深层包检测 DPI** | 不启用 | UA3F 的 `desync_*` 实测会把加速器隧道搅碎 |
| **HTTPS 里的 UA** | 改不了（也不需要） | 443 是 TLS，明文 UA 只存在于 HTTP，UA-Mask 默认就绕过 443 |
| **MAC 绑定** | netifd（脚本配置） | `config device` → `macaddr`；无线上联写在 `wireless` 的 `wifi-iface` |
| **MTU** | netifd（脚本配置） | `network.<iface>.mtu` / `.mru` |
| **网页认证（portal）** | `campus-portal-auth.sh` | POST 账号密码到认证接口（按抓包生成） |
| **PPPoE 拨号** | netifd（脚本配置） | `network.<iface>.proto=pppoe` + 账号密码 |

### 附：不想重编固件？先手动装 UA-Mask 也能用

本仓库固件已内置 UA-Mask；老固件想先用起来，可以自己编译一个包再装（ImmortalWrt 25.12 是 **apk**，
`make package/UA-Mask/compile` 编出来的 `uamask-*.apk` 直接装）：

```sh
# 装之前必须先把旧方案停干净 —— 漏了这步会"电脑没网但 ping 正常"
uci set ua3f.enabled.enabled='0'; uci commit ua3f; /etc/init.d/ua3f stop
nft delete table inet UA3F
apk add --allow-untrusted /tmp/uamask-0.4.3-r1.apk
sh campus-net-setup.sh --ua-mode regex      # 一键配好 UA / 放行名单 / 流量卸载
```

两条注意：

- **装在 overlay 里的包，sysupgrade 升级固件后会丢**，升级完要重装（编进固件的版本没这个问题）。
- UA-Mask 的 LuCI 页面是 Lua CBI，需要固件里有 `luci-compat`（本仓库固件自带）。

### 第 2 步：网页认证脚本（入口脚本会自动下载，通常不用手动装）

> 正常情况下你**不需要**手动执行本节 —— 入口脚本在第 4 步发现外网不通时会自动下载并调用它。
> 这里写的是它单独使用时的用法（比如只想重做认证、或换学校后单独调参）。

脚本的 3 处填空**已经按一次真实抓包填好了**：门户 `http://10.30.100.5` 的三步 API ——
`GET /` 拿会话 cookie（`RAASSESSID`）→ `POST /api/login.php` → `POST /api/ack_auth.php` → `POST /api/stat.php`，
密码 **MD5 后**提交，三次 body 都是 `user=&pass=&authmode=0&pool=&isp_id=0&pxyacct=`。
路径、字段名、固定字段、哈希方式全部可配，**换学校不用改脚本，只改 uci**。

```sh
# 1) 装上去
B=https://raw.githubusercontent.com/2476818641/Login-edu/main
wget -O /etc/campus-portal-auth.sh $B/campus-portal-auth.sh && chmod +x /etc/campus-portal-auth.sh

# 2) 填门户地址/账号/密码/哈希方式（存进 /etc/config/campus，权限 600）
/etc/campus-portal-auth.sh --setup

# 3) 确认哈希方式：把输出和抓包里 pass= 后面那 32 位比对
/etc/campus-portal-auth.sh --hash-test

# 4) 手动跑一次验证（--force 跳过"已在线"判断，强制走完整登录流程）
/etc/campus-portal-auth.sh --force

# 5) 装成自动：WAN 一上线就认证 + 每 5 分钟兜底
/etc/campus-portal-auth.sh --install-hook
```

> 先在电脑上试（没有 uci）：`--setup` 会自动改存到 `/etc/campus-portal.conf`（权限 600），
> 也可以直接给环境变量：`PORTAL=10.30.100.5 CAMPUS_USER=账号 CAMPUS_PASS=密码 sh campus-portal-auth.sh --force`
> （门户地址只填 IP 也行，脚本自动补 `http://`）。要装成开机自动认证，必须在路由器上跑 `--setup`。

换学校改这些（`uci campus.main.*`，也接受同名环境变量覆盖）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `auth_url` | 空（必填） | 门户**基地址**，如 `http://10.30.100.5`（不带路径） |
| `api_paths` | `/api/login.php,/api/ack_auth.php,/api/stat.php` | 按顺序提交的接口；**单接口门户**（如 srun）就写一个 |
| `extra_fields` | `authmode=0&pool=&isp_id=0&pxyacct=` | 抓包里的固定字段，原样照抄 |
| `user_field` / `pass_field` | `user` / `pass` | 抓包里的字段名 |
| `pass_mode` | `raas` | `raas`＝本门户的 AES 方案（每次随机前缀+加密，推荐）／`precomputed`＝直接给 32 位值／`plain`／`md5` 等 |
| `pass_md5` | 空 | 设置后直接用这串，跳过哈希（应急用，值从抓包抄） |
| `pre_get` | `1` | 先 GET 首页拿会话 cookie；实测不带 cookie 会被拒 |
| `check_url` / `ping_check` | 小米 204 / `223.5.5.5` | 在线判定；`ping_check=-` 表示只用 HTTP 判断 |

认证脚本的约定（自己改也照这个来）：

| 约定 | 说明 |
|---|---|
| 成功 | `exit 0`，**并且外网真的能通** |
| 失败 | `exit 非 0`（hotplug 会重试 3 次） |
| 已经在线 | 直接 `exit 0`，什么都不做（幂等，cron 反复跑没事） |
| `--force` | 强制走一次登录流程 |
| `--hash-test` | 打印各候选哈希；**只能和同一账号的抓包比对**（账号换了就不能比） |
| `--diag` | 自检：uci 能不能读能写、每个参数从哪来、密码到底读到没有（排查"配置没生效"第一命令） |
| `--quiet` | 不输出（hotplug / cron 用） |
| 参数来源 | 环境变量优先，其次 `uci get campus.main.{auth_url,api_paths,user,pass,pass_mode,...}` |

> **门户的结果码语义**（照抄门户自己的 JS `raas.js`，别自己想当然）：
> `0 / 3 / 121 / 122` = 已接受（它把 3「正在认证…」也当成功继续走 ack_auth）；
> `stat.php` 返回 `2 / 3 / 4` = 还在处理中 → **继续轮询**（脚本默认每 3 秒问一次、最多 6 次）；
> `login.php` 返回 `4` = 账号密码不正确（两条错密码实测都是 4）。
>
> 已经确定 / 还差的：
> 1. **失败形态已确定**（第二次抓包拿到）：密码错就是 `{"ret":4,"data":{"type":0},"msg":"帐号密码不正确！"}`，
>    脚本已对 `ret=4` 给专门提示；其它非 0 码按通用失败处理。
> 2. ✅ **`pass` 字段已破译 —— 不是哈希，是 AES 加密**（详见下面第 5 条）。
> 3. 认证成功后浏览器跳 `baidu.com` 是**页面 JS 自己跳的**（门户响应里没有任何 302/Location），
>    脚本不用模拟；该窗口内也没看到周期请求，心跳保活暂按"未知"处理（cron 兜底仍在）。
> 4. **流程已按一份"实测能上网"的手写脚本对齐**：前置多一步 `POST /api/ip.php`（空 body，
>    该接口看起来是让服务端记录客户端 IP），默认顺序改为 `login → stat → ack_auth`
>    （浏览器抓包是 `login → ack → stat`，两者都能过 ⇒ 后两步顺序不敏感）。
> 5. ✅ **`pass` 字段已完全破译（2026-09-21）——它不是哈希，是加密。**
>    从门户自己的 JS 里挖出来的（`/assets/js/crypto.js` 里的 CryptoJS + `/tp/school/js/index.js` 的 `encode()`）：
>
>    ```js
>    // 4 位随机前缀（服务端会丢掉这 4 位；每位取自 61 字符表 A-Za-z0-9+）
>    var p = ''; for (var i=0;i<4;i++) p += 'ABC…xyz0123456789+'[Math.floor(Math.random()*61)];
>    pass = hex( AES-128-ECB( key = "5a3b9f207411a8ed"(16 字节 ASCII),
>                             明文 = p + 明文密码, ZeroPadding ) );
>    // 特例：输入本来就是 32 位 [0-9A-Za-z] 时原样提交（所以硬编码一个值也能长期用）
>    ```
>
>    验证：抓到的 5 个 `pass` 值全部用该算法解回「4 位前缀 + 明文密码 + 全零填充」，
>    且两次"成功"的值解出**同一个密码** ⇒ 之前"同账号不同哈希"只是随机前缀不同，密码从没变过。
>    例：`fc824d7f244805c56634c66e16ded895` → 解密 → `vh8z` + `213511` + 零填充。
>
>    **结论：与 IP/MAC 无关**，硬编码的值只在**改密码**时失效。脚本现在能自己算：
>    `pass_mode=raas`（默认，用固件自带的 `openssl-util` 每次生成新前缀再加密；本仓库固件已含 `openssl-util - 3.5.6-r1`）；
>    也可以 `pass_mode=precomputed` 直接提交现成的 32 位值。
>    手动算一次：`/etc/campus-portal-auth.sh --encode 明文密码`；
>    或在任何机器上打开门户登录页 → F12 控制台 → `encode('明文密码')`。

（本脚本已对着复刻实测流程的假门户做过端到端测试：正确密码三步成功、错密码 `ret=4` 被拒并给出
正确提示、缺会话 cookie 被拒、哈希配错失败、`pass_md5` 应急通道、在线幂等、hook 装卸、
请求头/字段与抓包逐字一致、`raas` 加密（假门户用真算法解密校验）、`--encode` —— **32 项全过**。）

### 第 3 步：验证

```sh
/etc/campus-portal-auth.sh          # 手动：应输出「认证成功 ✅」
logread | grep campus-portal        # 自动登录日志
reboot                              # 重启后应自动认证（hotplug 触发），掉线由 cron 补
```

---

## WiFi（STA）上联特别说明

| 事项 | 说明 |
|---|---|
| **一样要认证** | 校园无线通常也是网页认证（Dr.COM / 深澜），主脚本选 `3` 时会再问一次认证方式，别默认以为"无线就放行" |
| 必须是**路由模式** | `wwan` 独立接口 + 另一个网段 + NAT。用 relayd/WDS 桥进 `br-lan` 的桥接中继**不行**——流量走二层、不过 IP 栈，UA2F 与 TTL 都失效（主脚本会检测并告警） |
| MAC 克隆 | 无线的 MAC 要写在 `wireless` 的 `wifi-iface` 上：`uci set wireless.<STA段>.macaddr='...'`；MTK 私有驱动可能有限制，改完用 `iw dev <设备> info` 核对并确认还能关联 |
| MTU | 由 AP 决定，主脚本默认 `keep` |
| 认证接口要 `mac` 参数 | 用克隆上去的那个 MAC（抓包时留意 body 里有没有 `mac=`） |
| 掉线重连 | STA 重连后常常要重新认证 —— 这正是 `--install-hook` 的 cron 兜底存在的理由 |

STA 还没建好的最小配置（SSID/密码换成你自己的）：

```sh
uci set wireless.sta=wifi-iface
uci set wireless.sta.device=radio0
uci set wireless.sta.mode=sta
uci set wireless.sta.ssid='校园网 SSID'
uci set wireless.sta.encryption=none     # 校园网多为开放+网页认证；有密码就写 psk2 并补 key
uci set wireless.sta.network=wwan
uci set network.wwan=interface
uci set network.wwan.proto=dhcp
uci commit wireless; uci commit network; wifi reload; /etc/init.d/network restart
```

---

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| 主脚本跑完不通（网页认证） | 正常，认证不在主脚本里做 —— 去做第 2 步（抓包生成认证脚本） |
| 认证脚本跑了但还不通 | ① 字段名/成功标志与抓包不一致 ② 需要先 GET 拿 cookie/token ③ 认证页在内网、被 UA2F 改了 UA → `uci set ua2f.firewall.handle_intranet=0; uci commit ua2f; /etc/init.d/ua2f restart` ④ 账号已在别处登录 |
| TTL 改了还被检测 | `nft list chain inet fw4 ttl_fix` 看规则在不在；若你的 WAN 也是网桥，把它从规则排除列表里去掉 |
| UA-Mask 开着但 UA 没变 | ① `uci get UAmask.enabled.enabled` 要为 1 ② UA 没命中匹配规则（`match_mode=regex` 下不匹配就原样放行，这是设计行为）③ 目标端口在 `bypass_ports` 里。真实效果要用**电脑/手机**打开 <http://ua-check.stagoh.com/> 看（路由器自己 curl 不准）|
| 加速器能连上但延迟测不出来 / 报 `-08` | 隧道类流量被代理转坏了。UA-Mask 靠「非 HTTP 目标自动卸载」解决：`nft list set inet fw4 UAmask_bypass_set` 看有没有学到 `节点IP.端口`；没有就把端口加进 `bypass_ports`。**UA3F 时代无解**（它劫持除 22 外的全部 TCP） |
| 想改回原样 | 删 `/etc/nftables.d/10-ttl-fix.nft` + `fw4 reload`；LuCI 里把 MAC/MTU 去掉；`/etc/campus-portal-auth.sh --uninstall-hook` |

## 卸载

```sh
/etc/campus-portal-auth.sh --uninstall-hook
rm -f /etc/campus-portal-auth.sh /etc/nftables.d/10-ttl-fix.nft && fw4 reload
uci delete campus.main; uci commit campus
```

## 相关

- 抓包投放点 / AI 提示词：`PACKET-CAPTURE.md`、`AI-PROMPT.md`
- Burp XML 压缩脚本：`burp-xml-summary.py`
- 路由器固件（硬刷方案、内置 UA-Mask、救砖文档）：<https://github.com/2476818641/boot>
