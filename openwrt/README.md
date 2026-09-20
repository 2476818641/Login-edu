# OpenWrt / ImmortalWrt 路由器 · 校园网自动登录

**两个脚本，各管一件事**：

| 脚本 | 干什么 | 需要抓包吗 |
|---|---|---|
| **`campus-net-setup.sh`**（主脚本） | 探测现状 → 问接入方式 → 配 **MAC 克隆 / TTL / MTU / UA(UA2F)** → **PPPoE 拨号** → 等 20 秒测外网、报告结果。**不实现网页认证** | 不需要，装上就能跑 |
| **`campus-portal-auth.sh`**（认证脚本） | 网页认证：提交账号密码、判定成功、装成开机自动登录（`--install-hook`） | **已按一次实测抓包实现**（三步 API + MD5 密码，全部可配）：换个学校通常只改 uci，无需改脚本；想让它适配你的门户，抓包丢进 `captures/`，配 `captures/AI-PROMPT.md` 的提示词让 AI 出结论 |

抓包相关三件套：`PACKET-CAPTURE.md`（抓包清单）、`captures/`（抓包投放点 + AI 提示词）、`tools/burp-xml-summary.py`（把几十 MB 的 Burp XML 压成几 KB 小抄）。
有线 WAN、PPPoE、**WiFi STA 无线上联**都覆盖。

---

## 完整流程

### 第 1 步：先用主脚本把"底层"配好

```sh
B=https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt
# 国内可套自己的 ghproxy：B=https://cf.liuass.eu.org/ghproxy/$B

wget -O /tmp/campus-net-setup.sh $B/campus-net-setup.sh
DRY_RUN=1 sh /tmp/campus-net-setup.sh      # 先干跑：只看要改什么，不落盘、不断网
sh /tmp/campus-net-setup.sh                # 正式跑
```

它会依次问：

| 提示 | 说明 |
|---|---|
| 接入方式 | `1` PPPoE（本脚本直接配好账号密码并拨号）／`2` 网页认证（只配网络，认证交给认证脚本）／`3` 我已经用 WiFi 连上校园网了 |
| 选 `3` 之后的认证方式 | **WiFi 上联一样要认证**：`1` 网页认证（默认）／`2` PPPoE／`3` 不用认证（家里测试） |
| 要克隆的 MAC | 回车=不改；`auto`=取 `/tmp/dhcp.leases` 第一台设备；或填 `AA:BB:CC:DD:EE:FF` |
| MTU | PPPoE 默认 1492，网页认证 1500，无线上联默认 `keep`（由 AP 决定） |
| UA（UA3F，自动识别） | 自动判断固件里装的是 **UA3F**（新，推荐，带 L3 重写）还是 **UA2F**（老固件）。UA3F 会问：启用 / **服务模式**（`NFQUEUE` 最省，`TPROXY` 功能全）/ **UA 串**（`keep`、`win`=常见 Chrome UA、或直接粘贴）/ **L3 重写**：TTL(=64)、IPID、删 TCP Timestamp、TCP 初始窗口、阻断 QUIC |

它改了什么（都可回滚）：

| 项 | 落点 | 回滚 |
|---|---|---|
| MAC 克隆 | `config device` 段（与 LuCI「网络→接口→设备」一致） | LuCI 删掉 MAC 字段 |
| MTU / MRU | `network.<iface>.mtu` / `.mru` | `uci delete ...` |
| 接入方式 | `network.<iface>.proto`（pppoe + 账号密码 / dhcp） | 改回 `dhcp` |
| **TTL** | `/etc/nftables.d/10-ttl-fix.nft`（**除 LAN 网桥外所有出口**改回 64） | `rm` 该文件 + `fw4 reload` |
| UA | `ua3f.*`（启用/服务模式/UA 串/L3 重写开关）；老固件才是 `ua2f.*` | LuCI「服务→UA3F」（老固件「网络→UA2F」） |

> `/etc/nftables.d/` 在 firewall4 的 keep.d 里，**刷固件升级后 TTL 规则仍在**。
> 规则用"排除 LAN 网桥"而不是写死设备名，所以网线 / PPPoE / 无线 STA 都自动覆盖。

跑完它会等 20 秒，然后 `ping 223.5.5.5` 或 `curl baidu.com` 测一次：

- **通了** → 收工（网页认证模式下若直接通，说明学校放行或已认证过）
- **没通 + PPPoE** → 提示去看 `logread` 里的 pppd 报错
- **没通 + 网页认证（有线上联和无线都一样）** → 探出认证页地址，并让你去做第 2 步

### 功能对应表：校园网的每一种检测，由谁来实现

UA3F 优先 —— 它有 UA2F 完全没有的 L3 重写与 Desync，脚本会**自动检测并优先用 UA3F**：

| 校园网检测项 | 谁来做 | 具体选项 / 位置 |
|---|---|---|
| **User-Agent**（判断是不是路由器共享） | **UA3F** | `ua3f.main.ua`（替换串）+ `ua3f.main.header_rewrite`（规则表，LuCI「服务→UA3F」里可视化编辑；默认对微信/B站/Steam 放行） |
| **TTL**（共享的包过一跳 -1） | **UA3F** | `ua3f.main.l3_rewrite_ttl=1` + `l3_rewrite_ttl_value=64`；另可选内核 nft 兜底（全流量含 ICMP/UDP，脚本会问） |
| **IPID**（部分 Dr.COM 会查） | **UA3F** | `ua3f.main.l3_rewrite_ipid=1` |
| **TCP Timestamp**（指纹特征） | **UA3F** | `ua3f.main.l3_rewrite_tcpts=1`（删掉该选项） |
| **TCP 初始窗口**（指纹特征） | **UA3F** | `ua3f.main.l3_rewrite_tcpwin=1` |
| **QUIC 绕过**（走 UDP 443 躲开改写） | **UA3F** | `ua3f.main.l3_rewrite_block_quic=1`（强制回落 TCP） |
| **深层包检测 DPI** | **UA3F** | `desync_reorder`（分片乱序，+`_bytes`/`_packets`）、`desync_inject`（混淆注入，+`_ttl`） |
| **HTTPS 里的 UA**（需要解密才能改） | **UA3F** | HTTPS MitM：`mitm_enabled` + CA（客户端要信任该 CA，仅对指定域名生效） |
| 改写性能（省 CPU） | **UA3F** | `l3_rewrite_bpf_offload=1`（eBPF，要求内核 ≥5.15） |
| **MAC 绑定** | netifd（脚本配置） | `config device` → `macaddr`；无线上联写在 `wireless` 的 `wifi-iface` |
| **MTU** | netifd（脚本配置） | `network.<iface>.mtu` / `.mru` |
| **网页认证（portal）** | `campus-portal-auth.sh` | POST 账号密码到认证接口（按抓包生成） |
| **PPPoE 拨号** | netifd（脚本配置） | `network.<iface>.proto=pppoe` + 账号密码 |

服务模式选择：`NFQUEUE`（老 UA2F 那条路，内核队列，开销最低）或 `TPROXY`（完整代理，功能全但吃 CPU）。
不确定就先用 `NFQUEUE`。

### 附：不想重编固件？先手动装 UA3F 也能用

UA3F 官方发布页提供了各架构的 `apk` / `ipk`（我们的目标 `aarch64_cortex-a53` 就有）。**依赖满足时**直接装即可：

```sh
# 依赖（本仓库固件全部自带；换别的固件请先确认这些都在）
#   iptables-nft / iptables-mod-{tproxy,extra,ipopt,nfqueue,conntrack-extra}
#   ipset / luci-compat / kmod-nf-conntrack-netlink
apk add /tmp/ua3f-3.6.0-r1-aarch64_cortex-a53.apk     # 老固件用 opkg install ua3f_*.ipk
uci set ua3f.enabled.enabled=1
uci set ua3f.main.server_mode=NFQUEUE     # 先走省 CPU 的那条路
uci commit ua3f && /etc/init.d/ua3f restart
```

两条注意：

- **这样装出来的 UA3F 在 overlay 里，sysupgrade 升级固件后会丢**，升级完要重装（编进固件的版本没这个问题）。
- 依赖里的 `kmod-nf-conntrack-netlink` 是**内核模块**：自编译固件如果没选它，官方仓库的 kmod 装不上（vermagic 不匹配），这时只能重编固件把它带进去。

### 第 2 步：网页认证脚本（已按实测抓包实现，只需填账号）

脚本的 3 处填空**已经按一次真实抓包填好了**：门户 `http://10.30.100.5` 的三步 API ——
`GET /` 拿会话 cookie（`RAASSESSID`）→ `POST /api/login.php` → `POST /api/ack_auth.php` → `POST /api/stat.php`，
密码 **MD5 后**提交，三次 body 都是 `user=&pass=&authmode=0&pool=&isp_id=0&pxyacct=`。
路径、字段名、固定字段、哈希方式全部可配，**换学校不用改脚本，只改 uci**。

```sh
# 1) 装上去
B=https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt
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

换学校改这些（`uci campus.main.*`，也接受同名环境变量覆盖）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `auth_url` | 空（必填） | 门户**基地址**，如 `http://10.30.100.5`（不带路径） |
| `api_paths` | `/api/login.php,/api/ack_auth.php,/api/stat.php` | 按顺序提交的接口；**单接口门户**（如 srun）就写一个 |
| `extra_fields` | `authmode=0&pool=&isp_id=0&pxyacct=` | 抓包里的固定字段，原样照抄 |
| `user_field` / `pass_field` | `user` / `pass` | 抓包里的字段名 |
| `pass_mode` | `md5` | `plain`／`md5`／`md5user`／`md5passuser`／`md5md5` |
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
| `--quiet` | 不输出（hotplug / cron 用） |
| 参数来源 | 环境变量优先，其次 `uci get campus.main.{auth_url,api_paths,user,pass,pass_mode,...}` |

> 已经确定 / 还差的：
> 1. **失败形态已确定**（第二次抓包拿到）：密码错就是 `{"ret":4,"data":{"type":0},"msg":"帐号密码不正确！"}`，
>    脚本已对 `ret=4` 给专门提示；其它非 0 码按通用失败处理。
> 2. ⚠️ **哈希输入还没定，而且比想象的复杂**：同一账号两次成功登录提交的 `pass` **不一样**
>    （`c88a20f6…` vs `c3d33fb1…`）。若这期间密码没改过，说明哈希里掺了每次都会变的东西
>    （认证页下发的盐/challenge）——即 `md5(盐+明文)` 之类，`pass_mode=md5` 就不够用，
>    需要认证页 JS 里的算法。**先用 `--hash-test` 对比**：能对上就用对应 `pass_mode`；对不上就把认证页 HTML 与它引用的 JS 发来。
> 3. 认证成功后浏览器跳 `baidu.com` 是**页面 JS 自己跳的**（门户响应里没有任何 302/Location），
>    脚本不用模拟；该窗口内也没看到周期请求，心跳保活暂按"未知"处理（cron 兜底仍在）。

（本脚本已对着复刻实测流程的假门户做过端到端测试：正确密码三步成功、错密码 `ret=4` 被拒并给出
正确提示、缺会话 cookie 被拒、哈希配错失败、`pass_md5` 应急通道、在线幂等、hook 装卸、
请求头/字段与抓包逐字一致 —— 20 项全过。）

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
| UA3F 开着但 UA 没变 | ① `uci get ua3f.enabled.enabled` 要为 1 ② `ua3f.main.header_rewrite` 规则表别是空的（空的就不会改）③ 默认规则对微信/B站/Steam 是放行的。浏览器打开 <http://ua-check.stagoh.com/> 验证（该站默认会显示 `UA3F`）|
| UA2F 与 UA3F | UA2F 只做 UA 改写（NFQUEUE）；UA3F 是它的超集（多 L3 重写 + Desync + 可选 MitM）。**别同时开**，脚本会自动优先识别 UA3F |
| 想改回原样 | 删 `/etc/nftables.d/10-ttl-fix.nft` + `fw4 reload`；LuCI 里把 MAC/MTU 去掉；`/etc/campus-portal-auth.sh --uninstall-hook` |

## 卸载

```sh
/etc/campus-portal-auth.sh --uninstall-hook
rm -f /etc/campus-portal-auth.sh /etc/nftables.d/10-ttl-fix.nft && fw4 reload
uci delete campus.main; uci commit campus
```

## 相关

- 抓包投放点 / AI 提示词：`captures/README.md`、`captures/AI-PROMPT.md`
- Burp XML 压缩脚本：`tools/burp-xml-summary.py`
- 路由器固件（硬刷方案、UA2F 编译、救砖文档）：<https://github.com/2476818641/boot>
