# Login-edu · 单文件版（本校专用）

本分支（`school-onekey`）只服务一个目标：**本校校园网**。一个脚本干完三件事，没有别的东西。

> 通用版（多校适配、PPPoE、无线 STA、抓包流程、给 AI 的提示词）都在 **`main`** 分支；
> 换学校或要重新抓包时切回 `main` 看那份。

## 三条命令

```sh
# 下载（一个文件就够了）
wget -O /root/campus-onekey.sh https://cdn.jsdelivr.net/gh/2476818641/Login-edu@school-onekey/campus-onekey.sh
chmod +x /root/campus-onekey.sh

# 一键：伪装（UA-Mask + TTL）→ 认证 → 装启动项
sh /root/campus-onekey.sh 你的学号 你的密码
```

以后：

```sh
/root/campus-onekey.sh --status      # 外网通不通 / 启动项装没装 / UA-Mask 状态 / TTL 值
/root/campus-onekey.sh --auth        # 手动补一次认证（掉线时）
/root/campus-onekey.sh --uninstall   # 卸掉启动项（账号密码仍留在 /etc/config/campus）
```

## 它做了什么

| 步骤 | 具体动作 | 落点 |
|---|---|---|
| ① 伪装 | UA-Mask：把各设备 UA 统一成一台 PC；`QeeYouAcceler,Valve/Steam,HttpDns,Microsoft-CryptoAPI,Microsoft NCSI` 放行**且命中即卸载出代理**；非 HTTP 目标自动卸载到内核；`bypass_ports='22 443'`（443 不进代理 → Steam 等大流量不受影响） | `/etc/config/UAmask` → LuCI「服务 → UA MASK」 |
| ① 伪装 | TTL 固定（与 UA 人设自洽：Windows=128 / Android·Linux·macOS=64）；同时停掉并清掉旧方案 UA3F（它会和 UA-Mask 抢 TCP） | `/etc/nftables.d/10-ttl-fix.nft`（fw4 的 keep.d，刷固件升级也在） |
| ② 认证 | 门户三步：`/api/login.php` → `/api/stat.php` → `/api/ack_auth.php`（先 GET 首页拿 `RAASSESSID`，再 POST `/api/ip.php`）；`pass` = `hex(AES-128-ECB(key, 4位随机前缀+密码))` | `/etc/config/campus`（明文密码，权限 600） |
| ③ 启动项 | init.d（开机，LuCI「系统 → 启动项」可见）/ hotplug（网口上线）/ cron（每 5 分钟兜底） | `/etc/init.d/campus-onekey`、`/etc/hotplug.d/iface/99-campus-portal`、`/etc/crontabs/root` |

脚本会把自己复制到 `/etc/campus-onekey.sh`（启动项引用这个固定路径）。

## 验证（30 秒）

```sh
/root/campus-onekey.sh --status
nft list chain inet fw4 Uamask_prerouting_before   # 应看到 tcp dport != { 22, 443 } redirect to :12032
nft list set inet fw4 Uamask_bypass_set            # 加速器/大流量跑一会儿后会出现 目标IP.端口
```

- **UA 真被改**：用**电脑/手机**打开 <http://ua-check.stagoh.com/> 看它显示的 User-Agent
  （**不要**用路由器自己 curl 判断 —— UA-Mask 只处理 LAN 侧进来的流量）
- **TTL 真被改**：`WAN=$(uci get network.wan.device || echo wan); tcpdump -ni "$WAN" -c 5 -v icmp`，
  同时从电脑 `ping 223.5.5.5`，看输出里的 `ttl 128`

## 出问题怎么回退

```sh
/root/campus-onekey.sh --uninstall                     # 卸启动项
uci set UAmask.enabled.enabled='0'; uci commit UAmask; /etc/init.d/UAmask stop
rm -f /etc/nftables.d/10-ttl-fix.nft && fw4 reload      # 关掉 TTL 改写
```

## 换学校要改什么

只有脚本顶部「本校参数」那一段：`PORTAL`、`PRE_PATHS`、`API_PATHS`、`EXTRA_FIELDS`、
`USER_FIELD`/`PASS_FIELD`、`RAAS_KEY`、`RET_*`。抓包和推导方法见 `main` 分支的
`PACKET-CAPTURE.md` 与 `AI-PROMPT.md`。

## 已知边界

- **明文 HTTP（80 端口）的大流量下载仍会走 UA-Mask 的代理**：UA 改写只对 80 有意义，不能整段绕过，
  否则伪装就没了。缓解：把该下载客户端的 UA 关键词加进放行名单（命中即卸载）。
- **TTL 是唯一保留的 L3 特征**：IPID、删 TCP 时间戳、改 TCP 初始窗口在旧方案里会走 NFQUEUE
  （又把流量拉回用户态），阻断 QUIC 会丢光 UDP 443（加速器/语音/QUIC 视频全废），都不做。
- 在高通平台上若开了 NSS/ECM 硬件加速，被卸载的流可能绕过 netfilter，TTL 改写需要用上面的
  tcpdump 方式实测确认。
