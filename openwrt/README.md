# OpenWrt / ImmortalWrt 路由器 · 校园网自动登录

一套脚本，把"路由器插上校园网就能上网"这件事做完整：

```
campus-net-setup.sh     一键配置：接入方式 + MAC克隆 + TTL + MTU + UA + 账号密码入库 + 可选装自动认证
campus-portal-auth.sh   网页认证脚本（骨架，按自己学校的抓包填 3 处；幂等、失败非 0）
campus-portal-autologin.sh  WAN 一上线自动认证（装到 /etc/hotplug.d/iface/）+ cron 每 5 分钟兜底
PACKET-CAPTURE.md       抓包清单：按这份抓一次，就能把认证脚本填成正式版
```

适用：OpenWrt 21.02+ / ImmortalWrt（含 apk 版 25.x）。有线 WAN、PPPoE、**WiFi STA 无线上联**都覆盖。

---

## 使用流程（完整）

### 第 0 步：环境前提

- 路由器能 SSH（`root@192.168.1.1`），固件里至少有 `curl`（ImmortalWrt 默认有）
- 有线还是无线？无线（STA 连校园 AP）也可以，只要满足：
  **wwan 是独立接口 + LAN 是另一个网段 + NAT**（路由模式）。
  ⚠️ 用 relayd / WDS 把 wwan 桥进 br-lan 的**桥接中继不行** —— 流量走二层、不过 IP 栈，
  UA2F 与 TTL 改写都会失效。脚本会检测并警告这种情况。

### 第 1 步：抓一次认证包（关键）

按 [`PACKET-CAPTURE.md`](PACKET-CAPTURE.md) 用 Burp/F12 抓一次**登录**请求（最好再抓一次**密码错**的），
拿到：认证接口 URL、字段名、成功标志。

### 第 2 步：把认证脚本填成正式版

编辑 `/etc/campus-portal-auth.sh`，只有 3 处标了 `← 抓包`：

```sh
AUTH_URL='http://10.10.10.10:801/srun_portal'   # ① 认证接口（含端口）
...
--data-urlencode "user=$CAMPUS_USER" \          # ② 字段名照抄抓包（user? username? 学号字段名?）
--data-urlencode "pass=$CAMPUS_PASS" \
...
*'"result":"1"'*)                               # ③ 成功标志（响应里出现什么算成功）
```

如果抓包里发现**先 GET 一次认证页拿 cookie/token**，把脚本里那行注释掉的 `curl_auth -c "$COOKIE" "$AUTH_URL"` 打开。
如果有 **`sign`/`token`/密码加密**，把对应 JS 一并拿出来，我可以帮你补上算法。

### 第 3 步：一键配置

```sh
B=https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt
# 国内可用自己的 ghproxy 加速，例如：
#   B=https://cf.liuass.eu.org/ghproxy/https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt

wget -O /tmp/campus-net-setup.sh   $B/campus-net-setup.sh
wget -O /tmp/campus-portal-auth.sh $B/campus-portal-auth.sh
DRY_RUN=1 sh /tmp/campus-net-setup.sh      # 先干跑：只看要改什么，不落盘、不断网
sh /tmp/campus-net-setup.sh                # 正式跑
```

脚本会依次问：

| 提示 | 说明 |
|---|---|
| 接入方式 | `1` PPPoE ／ `2` 网页认证 ／ `3` 我已经用 WiFi 连上校园网了（无线上联） |
| 认证账号 / 密码 / 认证接口地址 | 网页认证模式才问；存进 `uci campus`（`/etc/config/campus`，权限 600） |
| 要克隆的 MAC | 回车=不改；`auto`=取 `/tmp/dhcp.leases` 第一台设备；或直接填 `AA:BB:CC:DD:EE:FF` |
| MTU | PPPoE 默认 1492，网页认证 1500，无线上联默认 `keep` |
| 启用 UA2F / 自定义 UA / 443 / 内网 | 自定义 UA 支持 `keep`、`empty`、`win`（常见 Chrome UA）或直接粘贴整串 |
| 装自动认证吗 | `y` → 写 hotplug + cron 每 5 分钟兜底 |

它会做这些事（都在 UCI/配置层，可回滚）：

| 项 | 落点 | 回滚 |
|---|---|---|
| MAC 克隆 | `config device` 段（与 LuCI「网络→接口→设备」一致） | LuCI 删掉 MAC 字段 |
| MTU / MRU | `network.<iface>.mtu` / `.mru` | `uci delete ...` |
| 接入方式 | `network.<iface>.proto`（pppoe + 账号密码 / dhcp） | 改回 dhcp |
| **TTL** | `/etc/nftables.d/10-ttl-fix.nft`（除 LAN 网桥外所有出口改回 64） | `rm` 该文件 + `fw4 reload` |
| UA | `ua2f.enabled/s.*`（`handle_fw` 强制开） | LuCI「网络→UA2F」 |
| 认证参数 | `uci campus`（user/pass/auth_url/iface） | `uci delete campus.main` |

> `/etc/nftables.d/` 在 firewall4 的 keep.d 里，**刷固件升级后 TTL 规则仍在**。

### 第 4 步：装自动认证（也可以在配置时选 y）

```sh
B=https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt
wget -O /etc/campus-portal-auth.sh        $B/campus-portal-auth.sh && chmod +x /etc/campus-portal-auth.sh
wget -O /etc/hotplug.d/iface/99-campus-portal $B/campus-portal-autologin.sh && chmod +x /etc/hotplug.d/iface/99-campus-portal
echo '*/5 * * * * /etc/campus-portal-auth.sh --quiet' >> /etc/crontabs/root
/etc/init.d/cron restart
```

### 第 5 步：验证

```sh
/etc/campus-portal-auth.sh            # 手动跑一次，应输出「认证成功 ✅」
logread | grep campus-portal          # 看自动登录的日志
reboot                                # 重启后应自动登录（hotplug 触发）
```

---

## 契约（自己写认证脚本也照这个来）

| 约定 | 说明 |
|---|---|
| 成功 | `exit 0`，**并且外网真的能通** |
| 失败 | `exit 非 0`（调用方会重试 3 次） |
| 已经在线 | 直接 `exit 0`，什么都不做（幂等，方便定时任务反复跑） |
| `--force` | 强制走一次登录流程 |
| `--quiet` | 不往 stdout 输出（给 hotplug/cron 用） |
| 参数来源 | 环境变量优先，其次 `uci get campus.main.{auth_url,check_url,user,pass,ua,iface}` |

---

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| 认证脚本跑了但还不通 | ① 字段名/成功标志与抓包不一致 ② 需要先 GET 拿 cookie/token ③ 认证页在内网、被 UA2F 改了 UA → `uci set ua2f.firewall.handle_intranet=0; uci commit ua2f; /etc/init.d/ua2f restart` ④ 账号已在别处登录 |
| TTL 改了但被检测到 | 确认规则生效：`nft list chain inet fw4 ttl_fix`（应能看到 `ip ttl set 64`）；若你的 WAN 也是网桥，把它的名字从规则排除列表里去掉 |
| 无线上联时 MAC 没变 | WiFi 的 MAC 要写在 wireless 的 `wifi-iface` 上：`uci set wireless.<STA段>.macaddr='...'`；MTK 私有驱动可能限制，改完用 `iw dev <sta设备> info` 核对，并确认还能关联上 AP |
| UA2F 开着但 UA 没变 | 检查 `ua2f.firewall.handle_fw=1`（关着就完全不建规则链）；浏览器打开 <http://ua-check.stagoh.com/> 验证 |
| 桥接中继（relayd/WDS） | 必须改成**路由模式**：wwan 单独接口 + 另一个网段 + NAT；桥接走二层，UA2F/TTL 都不会生效 |
| 无线 STA 没建好 | 见主脚本结尾打印的最小 uci 命令（`wireless.sta` + `network.wwan`） |

## 卸载

```sh
rm -f /etc/hotplug.d/iface/99-campus-portal
sed -i '/campus-portal-auth.sh/d' /etc/crontabs/root && /etc/init.d/cron restart
rm -f /etc/campus-portal-auth.sh
uci delete campus.main; uci commit campus
```

## 相关

- 路由器固件（硬刷方案、UA2F 编译、救砖文档）：<https://github.com/2476818641/boot>
