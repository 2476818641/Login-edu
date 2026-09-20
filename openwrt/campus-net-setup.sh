#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-net-setup.sh —— 校园网接入配置（主脚本）
#
# 只做两件事：**配置** + **PPPoE 拨号**。网页认证不在这里，见同目录 campus-portal-auth.sh。
#
# 做什么：
#   1) 探测现状：上网接口 / 默认路由 / MAC / MTU / TTL 规则 / UA2F
#   2) 问接入方式：1) PPPoE（配好账号密码并拨号）  2) 网页认证（只配网络，认证交给认证脚本）
#      3) 用 WiFi（STA）连校园网——**WiFi 上联同样要认证**，所以选 3 之后还会问一次认证方式
#   3) 配好上网口的 MAC 克隆、TTL（默认 64）、MTU、UA（UA2F）并生效
#   4) 等 20 秒，ping / curl 试外网，报告结果（网页认证模式下会顺带把认证页地址探出来）
#
# 用法：
#   sh campus-net-setup.sh                  # 交互式
#   DRY_RUN=1 sh campus-net-setup.sh        # 只打印要做的改动，不落盘、不断网
#   WAIT_SECS=30 sh campus-net-setup.sh     # 改等待秒数（默认 20）
#   WANIF=wwan sh campus-net-setup.sh       # 指定上网接口（默认按默认路由自动探测）
#   TTL_VALUE=128 sh campus-net-setup.sh    # 改 TTL 目标值（默认 64）
#
# 非交互（可选）：
#   CAMPUS_MODE=pppoe CAMPUS_USER=学号 CAMPUS_PASS=密码 sh campus-net-setup.sh
#   CAMPUS_MODE=portal sh campus-net-setup.sh
#
# 只改 UCI 配置 + 一个 /etc/nftables.d 里的 nft 规则文件，不装任何软件包。
# /etc/nftables.d/ 在 firewall4 的 keep.d 里，所以刷固件升级后 TTL 规则仍在。
#
# 无线上网（STA）注意：必须是"路由模式"（wwan 独立接口 + NAT），不能用 relayd/WDS 桥接中继 ——
# 桥接是二层转发、不过 IP 栈，UA2F 与 TTL 改写都不会生效（脚本会检测并告警）。

set -u

DRY_RUN="${DRY_RUN:-0}"
WAIT_SECS="${WAIT_SECS:-20}"
TTL_VALUE="${TTL_VALUE:-64}"
TTL_FILE="${TTL_FILE:-/etc/nftables.d/10-ttl-fix.nft}"
SYSFS="${SYSFS:-/sys/class/net}"		# 可覆盖，便于测试
LOG_TAG="campus-setup"
CAMPUS_MODE="${CAMPUS_MODE:-}"

msg()  { printf '%s\n' "$*"; }
info() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[!] %s\033[0m\n' "$*" >&2; exit 1; }

run() {	# 干跑模式只打印
	if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}
log() { [ "$DRY_RUN" = 1 ] || logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
ask() {	# ask <提示> <默认值> -> $REPLY
	_p="$1"; _d="${2:-}"
	if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d"; else printf '%s: ' "$_p"; fi
	if ! read -r REPLY; then REPLY=""; fi
	[ -z "$REPLY" ] && REPLY="$_d"
	return 0
}
uget() { uci -q get "$1" 2>/dev/null; }

[ "$(id -u)" = 0 ] || die "请用 root 运行（需要改网络与防火墙配置）"
command -v uci >/dev/null 2>&1 || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上运行"

# ---------------------------------------------------------------- 0) 探测现状
# 上网接口怎么定（优先级从高到低）：
#   1) WANIF 环境变量
#   2) 默认路由的出口设备反查 UCI 接口 —— 最准：无线上联时会认出 wwan（设备 apclix0 之类）
#   3) 兜底：wan 有设备就用 wan，否则 wwan
DEFDEV_RAW="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
DEFDEV_BASE="${DEFDEV_RAW#pppoe-}"	# pppoe-wan -> wan
if [ -z "${WANIF:-}" ] && [ -n "$DEFDEV_BASE" ]; then
	for _i in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='[^']*'$/\1/p"); do
		_d="$(uget network.$_i.device)"; [ -z "$_d" ] && _d="$(uget network.$_i.ifname)"
		_d="${_d%% *}"
		if [ -n "$_d" ] && [ "$_d" = "$DEFDEV_BASE" ]; then WANIF="$_i"; break; fi
	done
fi
if [ -z "${WANIF:-}" ]; then
	if [ -n "$(uget network.wan.device)$(uget network.wan.ifname)" ]; then WANIF="wan"
	elif [ -n "$(uget network.wwan.device)$(uget network.wwan.ifname)" ]; then WANIF="wwan"
	else WANIF="wan"; fi
fi
WANDEV="$(uget network.$WANIF.device)"; [ -z "$WANDEV" ] && WANDEV="$(uget network.$WANIF.ifname)"
WANDEV="${WANDEV%% *}"; [ -z "$WANDEV" ] && WANDEV="$WANIF"
OLD_PROTO="$(uget network.$WANIF.proto)"

# LAN 侧网桥：TTL 规则排除它们，其余出口一律改写 → 网线 / PPPoE / 无线 STA 通吃
LAN_DEVS=""
for _s in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.type='bridge'$/\1/p"); do
	_n="$(uget network.$_s.name)"
	[ -n "$_n" ] && LAN_DEVS="$LAN_DEVS \"$_n\","
done
[ -z "$LAN_DEVS" ] && LAN_DEVS=' "br-lan",'
LAN_DEVS="${LAN_DEVS%,}"; LAN_DEVS="${LAN_DEVS# }"

info "当前状态"
msg "    上网接口     : network.$WANIF（设备 $WANDEV，proto ${OLD_PROTO:-未知}）$([ -n "$DEFDEV_BASE" ] && [ "$WANIF" != "wan" ] && echo '  ← 按默认路由反查出来的')"
msg "    默认路由出口 : ${DEFDEV_RAW:-还没通}$([ -n "$DEFDEV_RAW" ] && echo "（对应接口 network.$WANIF）")"
msg "    当前 WAN MAC : $(cat "$SYSFS/$WANDEV/address" 2>/dev/null || echo 未知)"
msg "    当前 WAN MTU : $(cat "$SYSFS/$WANDEV/mtu" 2>/dev/null || echo 未知)"
msg "    TTL 规则     : $([ -f "$TTL_FILE" ] && echo "有（$TTL_FILE，会被覆盖）" || echo 无)"
if [ -x /usr/bin/ua2f ] || [ -n "$(uget ua2f.enabled.enabled)" ]; then
	msg "    UA2F         : 已安装（启用=$([ "$(uget ua2f.enabled.enabled)" = 1 ] && echo 是 || echo 否)）"
else
	msg "    UA2F         : 未安装"
fi

# LAN 网桥设备名（判断无线上联是"路由模式"还是"桥接中继"）
LANBR=""
_d="$(uget network.lan.device)"; [ -n "$_d" ] && LANBR="${_d%% *}"
[ -z "$LANBR" ] && LANBR="br-lan"
if [ -n "$DEFDEV_RAW" ] && [ -e "$SYSFS/$LANBR/brif/$DEFDEV_RAW" ]; then
	warn "默认路由出口 $DEFDEV_RAW 是 LAN 网桥 $LANBR 的成员端口 → 这是**桥接中继**："
	msg "         流量走二层、不过 IP 栈，UA2F 和 TTL 改写都不会生效。"
	msg "         要改成路由模式：wwan 单独一个接口（不要桥进 $LANBR）+ LAN 用别的网段 + NAT"
elif [ -n "$DEFDEV_RAW" ]; then
	case "$DEFDEV_RAW" in
	*sta*|wlan*|ra[0-9]*|apcl*)
		msg "    无线上联   : $DEFDEV_RAW（路由模式 ✅ —— 独立的 network.$WANIF + 本身是另一个网段）" ;;
	esac
fi
if [ "$WANIF" = "wan" ] && [ -r "$SYSFS/$WANDEV/carrier" ] && \
   [ "$(cat "$SYSFS/$WANDEV/carrier" 2>/dev/null)" = "0" ]; then
	warn "网口 $WANDEV 没有链路（carrier=0）：如果你是靠 WiFi 上校园网，"
	msg "         请用 WANIF=wwan sh 本脚本，或者接入方式选 3（脚本才知道该配哪个接口）"
fi

# ---------------------------------------------------------------- 1) 接入方式
info "1/4 选择接入方式"
if [ -z "$CAMPUS_MODE" ]; then
	msg "    1) PPPoE（要账号密码，本脚本直接配好并拨号）"
	msg "    2) 网页认证（本脚本只配网络；认证用 campus-portal-auth.sh，需要先抓包生成）"
	msg "    3) 我已经用 WiFi 连上校园网了（uplink 是无线 STA，出口走 wwan）"
	ask "    你的方式" "2"
	case "$REPLY" in
	1|pppoe|PPPoE) CAMPUS_MODE="pppoe" ;;
	2|portal|web|网页|网页认证) CAMPUS_MODE="portal" ;;
	3|wifi|wlan|无线) CAMPUS_MODE="portal"; WIFI_UPLINK=1 ;;
	*) die "没看懂：$REPLY（填 1/2/3）" ;;
	esac
fi
msg "    → $CAMPUS_MODE${WIFI_UPLINK:+（无线上网）}"

# 是否需要额外的"门户认证"：PPPoE 自己就是认证；网页认证/无线上联要看学校
AUTH_REQUIRED=1
[ "$CAMPUS_MODE" = "pppoe" ] && AUTH_REQUIRED=0

if [ -n "${WIFI_UPLINK:-}" ]; then
	ask "    无线上网用哪个接口（已经建好的 STA 网络名）" "wwan"
	WANIF="$REPLY"
	WANDEV="$(uget network.$WANIF.device)"; [ -z "$WANDEV" ] && WANDEV="$WANIF"
	msg "    ⚠️ WiFi 上联一样要认证：校园无线通常也是网页认证（Dr.COM / 深澜那套）"
	msg "      1) 网页认证（默认；认证脚本要按抓包生成）"
	msg "      2) PPPoE（少数学校的无线也走拨号）"
	msg "      3) 不用认证（家里测试 / 学校直接放行）"
	ask "    无线上联的认证方式" "1"
	case "$REPLY" in
	2|pppoe|PPPoE) CAMPUS_MODE="pppoe"; AUTH_REQUIRED=0 ;;
	3|none|no|无|不用) AUTH_REQUIRED=0 ;;
	*) CAMPUS_MODE="portal"; AUTH_REQUIRED=1 ;;
	esac
	msg "    → 无线上联 + $CAMPUS_MODE（$([ "$AUTH_REQUIRED" = 1 ] && echo 需要认证 || echo 不需要认证)）"
fi

PPPOE_USER=""; PPPOE_PASS=""
if [ "$CAMPUS_MODE" = "pppoe" ]; then
	PPPOE_USER="${CAMPUS_USER:-}"; PPPOE_PASS="${CAMPUS_PASS:-}"
	[ -z "$PPPOE_USER" ] && { ask "    PPPoE 账号（学号）" ""; PPPOE_USER="$REPLY"; }
	[ -z "$PPPOE_PASS" ] && { ask "    PPPoE 密码" ""; PPPOE_PASS="$REPLY"; }
	[ -n "$PPPOE_USER" ] || die "PPPoE 账号不能为空"
fi

# ---------------------------------------------------------------- 2) 配 MAC / TTL / MTU / UA
info "2/4 配置 MAC / TTL / MTU / UA"

# --- 2.1 MAC 克隆
ask "    要克隆的 MAC（回车=不改，auto=用当前 DHCP 租约里第一台设备）" ""
CLONE_MAC="$REPLY"
case "$CLONE_MAC" in
auto|AUTO)
	CLONE_MAC="$(awk 'NF>=3 && $2 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ {print $2; exit}' /tmp/dhcp.leases 2>/dev/null)"
	[ -n "$CLONE_MAC" ] || warn "      /tmp/dhcp.leases 里没找到租约，跳过 MAC 克隆"
	;;
esac
if [ -n "$CLONE_MAC" ]; then
	printf '%s' "$CLONE_MAC" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
		|| die "MAC 格式不对：$CLONE_MAC（要 AA:BB:CC:DD:EE:FF）"
	if [ -n "${WIFI_UPLINK:-}" ]; then
		msg "    注意：无线上网的 MAC 通常要写在 wireless 的 wifi-iface 上（驱动可能有限制）"
		msg "          本脚本写的是 network 的 device 段；若无效就手动加："
		msg "          uci set wireless.<STA段>.macaddr='$CLONE_MAC'"
	fi
	DEVSEC="$(uci show network 2>/dev/null | awk -F"'" -v d="$WANDEV" \
		'$1 ~ /\.name=$/ && $2 == d { s=$1; sub(/^network\./,"",s); sub(/\.name=$/,"",s); print s; exit }')"
	if [ -z "$DEVSEC" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			printf '    [dry-run] uci add network device; uci set network.<新段>.name=%s macaddr=%s\n' "$WANDEV" "$CLONE_MAC"
		else
			DEVSEC="$(uci add network device)"
			run uci set "network.$DEVSEC.name=$WANDEV"
		fi
	fi
	[ -n "$DEVSEC" ] && run uci set "network.$DEVSEC.macaddr=$CLONE_MAC"
	msg "    MAC 克隆 → $CLONE_MAC"
fi

# --- 2.2 MTU
DEF_MTU=1500
[ "$CAMPUS_MODE" = "pppoe" ] && DEF_MTU=1492
[ -n "${WIFI_UPLINK:-}" ] && DEF_MTU=keep	# 无线侧 MTU 由 AP 决定，别乱改
ask "    MTU（回车=$DEF_MTU，不想改就填 keep）" "$DEF_MTU"
MTU="$REPLY"
if [ "$MTU" != "keep" ] && [ -n "$MTU" ]; then
	case "$MTU" in *[!0-9]*) die "MTU 必须是数字：$MTU" ;; esac
	run uci set "network.$WANIF.mtu=$MTU"
	[ "$CAMPUS_MODE" = "pppoe" ] && run uci set "network.$WANIF.mru=$MTU"
	msg "    MTU → $MTU"
fi

# --- 先确定用哪个 UA 方案（UA3F 优先）
#     UA3F 是 UA2F 的超集：UA 改写 + L3 重写（TTL / IPID / 删 TCP 时间戳 / TCP 初始窗口 / 阻断 QUIC）
#     + Desync（分片乱序 / 混淆注入）+ 可选 HTTPS MitM —— 有 UA3F 就让 UA3F 干，不重复造轮子
UA_IMPL=""
[ -x /usr/bin/ua3f ] && UA_IMPL="ua3f"
[ -z "$UA_IMPL" ] && { [ -x /usr/bin/ua2f ] || [ -n "$(uget ua2f.enabled.enabled)" ]; } && UA_IMPL="ua2f"
[ -z "$UA_IMPL" ] && [ -n "$(uget ua3f.enabled.enabled)" ] && UA_IMPL="ua3f"
TTL_BY_NFT=1

# --- 2.3 TTL
if [ "$UA_IMPL" = "ua3f" ]; then
	msg "    检测到 UA3F：TTL / IPID / TCP 这些 L3 特征交给它做"
	ask "    要不要【另外】再加一条内核 nft 兜底（全流量含 ICMP/UDP，零开销）(y/N)" "y"
	case "$REPLY" in
	1|y|Y|yes|是) TTL_BY_NFT=1 ;;
	*)
		TTL_BY_NFT=0
		msg "    不加兜底：TTL 交给 UA3F（之前装过的规则文件会删掉）"
		run rm -f "$TTL_FILE" ;;
	esac
fi

if [ "$TTL_BY_NFT" = 1 ]; then
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] 写 %s：\n' "$TTL_FILE"
		printf '              chain ttl_fix { ... oifname != { %s } ip ttl set %s ... }\n' "$LAN_DEVS" "$TTL_VALUE"
	else
		mkdir -p "$(dirname "$TTL_FILE")"
		[ -f "$TTL_FILE" ] && cp -f "$TTL_FILE" "$TTL_FILE.bak"
		cat > "$TTL_FILE" <<-EOF
		# campus-net-setup.sh 生成：校园网防 TTL 检测（内核兜底，UA3F 的 TTL 重写并不冲突）
		# fw4 会把 /etc/nftables.d/*.nft 包含进 table inet fw4，这里定义一条自己的 postrouting 链
		# （priority mangle + 1，比 fw4 自带的 mangle_postrouting 晚一步执行）。
		# 语义：除本地网桥（LAN）以外的所有出口，IPv4 TTL 与 IPv6 hop limit 都改成 $TTL_VALUE。
		# 要改设备/关掉：改或删掉本文件后执行 fw4 reload
		chain ttl_fix {
		    type filter hook postrouting priority mangle + 1; policy accept;
		    oifname != { $LAN_DEVS } ip ttl set $TTL_VALUE
		    oifname != { $LAN_DEVS } ip6 hoplimit set $TTL_VALUE
		}
		EOF
		msg "    TTL → 固定 $TTL_VALUE（排除 $LAN_DEVS，其余出口全改；内核兜底）"
	fi
fi

# --- 2.4 UA（UA3F 优先；老固件的 UA2F 自动兼容）
case "$UA_IMPL" in
ua3f)
	CUR_EN="$(uget ua3f.enabled.enabled)"; [ -z "$CUR_EN" ] && CUR_EN=1
	CUR_MODE="$(uget ua3f.main.server_mode)"; [ -z "$CUR_MODE" ] && CUR_MODE=TPROXY
	CUR_UA="$(uget ua3f.main.ua)"; [ -z "$CUR_UA" ] && CUR_UA=FFF
	CUR_TTL="$(uget ua3f.main.l3_rewrite_ttl)"; [ -z "$CUR_TTL" ] && CUR_TTL=0
	msg "    UA3F 现状：启用=$CUR_EN 服务模式=$CUR_MODE UA=$CUR_UA TTL重写=$CUR_TTL"
	[ -z "$(uget ua3f.main.header_rewrite)" ] && \
		warn "      规则表(header_rewrite)是空的 → 装了也不会改 UA，去 LuCI「服务→UA3F」恢复默认规则"

	ask "    启用 UA3F（UA 改写 + L3 重写，校园网防检测核心）" "$CUR_EN"
	case "$REPLY" in
	1|y|Y|yes|是)
		UA_ENABLED=1
		msg "    服务模式：NFQUEUE=老 UA2F 那套（开销最低，推荐）/ TPROXY=代理模式（功能全但吃 CPU）"
		ask "    服务模式" "$CUR_MODE"
		case "$REPLY" in
		NFQUEUE|nfqueue) run uci set ua3f.main.server_mode='NFQUEUE' ;;
		TPROXY|tproxy)   run uci set ua3f.main.server_mode='TPROXY' ;;
		*)               run uci set "ua3f.main.server_mode=$REPLY" ;;
		esac
		msg "    UA 串可填：keep=不改 / win=常见 Chrome UA / 任意字符串（默认 FFF）"
		ask "    UA 串" "$CUR_UA"
		case "$REPLY" in
		keep|KEEP) ;;
		win|WIN|chrome)
			run uci set 'ua3f.main.ua=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' ;;
		*) run uci set "ua3f.main.ua=$REPLY" ;;
		esac

		# ↓ 这些都是 UA3F 独有（UA2F 完全没有）的能力，按学校检测项按需开
		ask "    打开 TTL 重写（l3_rewrite_ttl，出口 TTL 统一成本机值）(y/N)" "$CUR_TTL"
		case "$REPLY" in
		1|y|Y|yes|是)
			run uci set ua3f.main.l3_rewrite_ttl='1'
			ask "      TTL 目标值" "$(uget ua3f.main.l3_rewrite_ttl_value)"; [ -z "$REPLY" ] && REPLY=64
			run uci set "ua3f.main.l3_rewrite_ttl_value=$REPLY" ;;
		*) run uci set ua3f.main.l3_rewrite_ttl='0' ;;
		esac
		ask "    打开 IPID 重写（l3_rewrite_ipid，校园网查 IPID 时有用）(y/N)" "$(uget ua3f.main.l3_rewrite_ipid)"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua3f.main.l3_rewrite_ipid='1' ;; *) run uci set ua3f.main.l3_rewrite_ipid='0' ;; esac
		ask "    删除 TCP Timestamp（l3_rewrite_tcpts）(y/N)" "$(uget ua3f.main.l3_rewrite_tcpts)"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua3f.main.l3_rewrite_tcpts='1' ;; *) run uci set ua3f.main.l3_rewrite_tcpts='0' ;; esac
		ask "    修改 TCP 初始窗口（l3_rewrite_tcpwin，先别开）(y/N)" "$(uget ua3f.main.l3_rewrite_tcpwin)"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua3f.main.l3_rewrite_tcpwin='1' ;; *) run uci set ua3f.main.l3_rewrite_tcpwin='0' ;; esac
		ask "    阻断 QUIC（l3_rewrite_block_quic，强制回落 TCP 好让改写生效）(y/N)" "$(uget ua3f.main.l3_rewrite_block_quic)"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua3f.main.l3_rewrite_block_quic='1' ;; *) run uci set ua3f.main.l3_rewrite_block_quic='0' ;; esac
		ask "    L3 重写用 eBPF 加速（l3_rewrite_bpf_offload；内核 ≥5.15，省 CPU）(y/N)" "$(uget ua3f.main.l3_rewrite_bpf_offload)"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua3f.main.l3_rewrite_bpf_offload='1' ;; *) run uci set ua3f.main.l3_rewrite_bpf_offload='0' ;; esac

		msg "    下面两项是 Desync（对付深层包检测 DPI 的乱序/混淆），不确定就都选 N"
		ask "    TCP 分片乱序发射（desync_reorder）(y/N)" "$(uget ua3f.main.desync_reorder)"
		case "$REPLY" in
		1|y|Y|yes|是)
			run uci set ua3f.main.desync_reorder='1'
			ask "      乱序分片字节数" "$(uget ua3f.main.desync_reorder_bytes)"; [ -z "$REPLY" ] && REPLY=1500
			run uci set "ua3f.main.desync_reorder_bytes=$REPLY"
			ask "      乱序包大小" "$(uget ua3f.main.desync_reorder_packets)"; [ -z "$REPLY" ] && REPLY=8
			run uci set "ua3f.main.desync_reorder_packets=$REPLY" ;;
		*) run uci set ua3f.main.desync_reorder='0' ;;
		esac
		ask "    TCP 混淆注入（desync_inject）(y/N)" "$(uget ua3f.main.desync_inject)"
		case "$REPLY" in
		1|y|Y|yes|是)
			run uci set ua3f.main.desync_inject='1'
			ask "      注入包 TTL" "$(uget ua3f.main.desync_inject_ttl)"; [ -z "$REPLY" ] && REPLY=3
			run uci set "ua3f.main.desync_inject_ttl=$REPLY" ;;
		*) run uci set ua3f.main.desync_inject='0' ;;
		esac
		ask "    日志等级（WARN=安静 / INFO=排查用）" "$(uget ua3f.main.log_level)"; [ -z "$REPLY" ] && REPLY=WARN
		run uci set "ua3f.main.log_level=$REPLY"
		msg "    HTTPS MitM 没动（只给指定域名解密才需要，要先配 CA；在 LuCI「服务→UA3F」里做）"
		run uci set ua3f.enabled.enabled='1'
		;;
	*)
		UA_ENABLED=0
		run uci set ua3f.enabled.enabled='0'
		msg "    UA3F → 关闭"
		;;
	esac
	;;
ua2f)
	CUR_EN="$(uget ua2f.enabled.enabled)"; [ -z "$CUR_EN" ] && CUR_EN=1
	CUR_UA="$(uget ua2f.main.custom_ua)"
	CUR_TLS="$(uget ua2f.firewall.handle_tls)"; [ -z "$CUR_TLS" ] && CUR_TLS=0
	CUR_INTRA="$(uget ua2f.firewall.handle_intranet)"; [ -z "$CUR_INTRA" ] && CUR_INTRA=1
	msg "    UA2F 现状：启用=$CUR_EN 自定义UA=${CUR_UA:-（空=用内置默认）} 处理443=$CUR_TLS 处理内网=$CUR_INTRA"
	msg "    提示：UA2F 只改 UA；要 TTL/IPID/TCP 那套 L3 对抗，建议固件换成 UA3F"

	ask "    启用 UA2F（改写 User-Agent）" "$CUR_EN"
	case "$REPLY" in
	1|y|Y|yes|是)
		UA_ENABLED=1
		msg "    自定义 UA 可填：keep=不改 / empty=清空用内置默认 / win=常见 Chrome UA / 或直接粘贴整串"
		ask "    自定义 UA" "${CUR_UA:-keep}"
		case "$REPLY" in
		keep|KEEP) ;;
		empty|EMPTY) run uci set ua2f.main.custom_ua='' ;;
		win|WIN|chrome)
			run uci set ua2f.main.custom_ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' ;;
		*) run uci set "ua2f.main.custom_ua=$REPLY" ;;
		esac
		ask "    也处理 443 端口的明文 HTTP（handle_tls）" "$CUR_TLS"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua2f.firewall.handle_tls='1' ;; *) run uci set ua2f.firewall.handle_tls='0' ;; esac
		ask "    也处理内网地址流量（handle_intranet；认证页在内网又登不上时改 0）" "$CUR_INTRA"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua2f.firewall.handle_intranet='1' ;; *) run uci set ua2f.firewall.handle_intranet='0' ;; esac
		run uci set ua2f.firewall.handle_fw='1'
		run uci set ua2f.enabled.enabled='1'
		;;
	*)
		UA_ENABLED=0
		run uci set ua2f.enabled.enabled='0'
		msg "    UA2F → 关闭"
		;;
	esac
	;;
*)
	warn "没装 UA3F / UA2F（/usr/bin/ua3f 不存在）—— 跳过 UA 部分"
	msg "    想要：把 UA3F 编进固件，或在有依赖的固件上装官方 apk（见 README「附：不想重编固件」）"
	;;
esac

# ---------------------------------------------------------------- 3) 应用
info "3/4 应用配置"
if [ "$CAMPUS_MODE" = "pppoe" ]; then
	NEW_PROTO='pppoe'
	run uci set "network.$WANIF.proto=pppoe"
	run uci set "network.$WANIF.username=$PPPOE_USER"
	run uci set "network.$WANIF.password=$PPPOE_PASS"
	run uci set "network.$WANIF.ipv6=1"
	run uci set "network.$WANIF.peerdns=1"
else
	NEW_PROTO='dhcp'
	run uci set "network.$WANIF.proto=dhcp"
fi
run uci commit network
if [ -n "${UA_IMPL:-}" ]; then run uci commit "$UA_IMPL"; fi

if [ "$DRY_RUN" = 1 ]; then
	printf '    [dry-run] /etc/init.d/network %s\n' "$([ "$OLD_PROTO" != "$NEW_PROTO" ] && echo restart || echo reload)"
	printf '    [dry-run] fw4 reload\n'
	[ -n "${UA_IMPL:-}" ] && printf '    [dry-run] /etc/init.d/%s %s\n' "$UA_IMPL" "$([ "${UA_ENABLED:-0}" = 1 ] && echo restart || echo stop)"
else
	if [ "$OLD_PROTO" != "$NEW_PROTO" ]; then
		msg "    proto 变了（${OLD_PROTO:-空} → $NEW_PROTO），用 restart"
		run /etc/init.d/network restart
	else
		run /etc/init.d/network reload
	fi
	sleep 2
	command -v fw4 >/dev/null 2>&1 && run fw4 reload
	if [ -n "${UA_IMPL:-}" ]; then
		if [ "${UA_ENABLED:-0}" = 1 ]; then
			run /etc/init.d/"$UA_IMPL" restart
			sleep 1
			if pgrep -f "$UA_IMPL" >/dev/null 2>&1; then msg "    $UA_IMPL 进程：在跑 ✅"; else warn "    $UA_IMPL 没跑起来，看 logread | grep $UA_IMPL"; fi
		else
			run /etc/init.d/"$UA_IMPL" stop
		fi
	fi
	log "applied: iface=$WANIF mode=$CAMPUS_MODE mac=${CLONE_MAC:-unchanged} mtu=${MTU:-unchanged} ttl=${TTL_BY_NFT:-0}/nft ua=${UA_IMPL:-none}:${UA_ENABLED:-none}"
fi

# ---------------------------------------------------------------- 4) 等 20 秒 → 测
info "4/4 等待 ${WAIT_SECS} 秒后检测外网"
[ "$DRY_RUN" = 1 ] || sleep "$WAIT_SECS"

check_net() {
	ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
	_c="$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://www.baidu.com 2>/dev/null)"
	[ "$_c" = "200" ] && return 0
	return 1
}

if check_net; then
	info "外网已通 ✅"
	msg "    出口 IP : $(curl -s -m 8 http://ip.3322.net 2>/dev/null || echo 取不到)"
	[ "${UA_ENABLED:-0}" = 1 ] && msg "    验 UA   : 浏览器打开 http://ua-check.stagoh.com/ 看 User-Agent（UA3F 默认会把该站显示成 UA3F）"
	if [ "${AUTH_REQUIRED:-1}" = 1 ]; then
		msg "    提示     : 还没跑过网页认证，但外网已通（学校可能直接放行，或已认证过）"
		msg "               要让它在掉线后自动补认证：campus-portal-auth.sh --install-hook"
	fi
else
	warn "还没通"
	if [ "${AUTH_REQUIRED:-1}" = 1 ]; then
		U="$(curl -s -m 8 -o /dev/null -w '%{redirect_url}' http://connect.rom.miui.com/generate_204 2>/dev/null)"
		[ -n "$U" ] && msg "    认证页地址：$U"
		cat <<'EOF'
    网页认证不在本脚本里做 —— 认证流程要按你学校的抓包来，见 campus-portal-auth.sh：

      1) 抓一次登录包（清单：PACKET-CAPTURE.md，用 Burp 或浏览器 F12）
      2) 把抓包交给 AI（或自己按「← 抓包」标注填）生成/补全 /etc/campus-portal-auth.sh
      3) wget -O /etc/campus-portal-auth.sh <raw 链接> && chmod +x /etc/campus-portal-auth.sh
      4) 手动验证一次：/etc/campus-portal-auth.sh
      5) 装成开机自动登录：/etc/campus-portal-auth.sh --install-hook
EOF
		if [ -n "${WIFI_UPLINK:-}" ]; then
			msg "    无线上联注意：认证接口有时要带 mac 参数，用你克隆上去的那个 MAC；"
			msg "                  另外 STA 掉线重连后如果又不通，多半是要重新认证（--install-hook 的 cron 会补）"
		fi
	elif [ "$CAMPUS_MODE" = "pppoe" ]; then
		warn "PPPoE 没拨上：检查账号密码、是否需要 VLAN、以及 VLAN ID"
		msg "    看日志：logread | tail -30   （找 pppd 报错）"
		msg "    看状态：ifstatus $WANIF | head -40"
	else
		warn "无线上联没通：先看是不是没关联上/没拿到地址"
		msg "    看 STA 状态：iwinfo | head -20 ; ifstatus $WANIF | head -20"
		msg "    如果学校是要认证的，把认证脚本装上：campus-portal-auth.sh（见 PACKET-CAPTURE.md）"
	fi
fi

info "完成"
cat <<EOF
    以后要改：LuCI → 网络 → 接口 → 设备（MAC/MTU）／ 服务 → UA3F（UA、L3 重写、Desync）
    防识别分工：
      UA 改写 / TTL / IPID / TCP 时间戳 / TCP 初始窗口 / QUIC 阻断 / Desync → UA3F（服务 → UA3F）
      MAC 克隆、MTU                                                        → netifd（网络 → 接口 → 设备）
      TTL 内核兜底（可选、全流量）$([ "${TTL_BY_NFT:-0}" = 1 ] && echo "→ $TTL_FILE（改完 fw4 reload；关掉就删掉它再 fw4 reload）" || echo "→ 本次没装（TTL 交给 UA3F）")
    接入方式：uci set network.$WANIF.proto=... 之后 /etc/init.d/network restart
    无线 STA 还没建好？最小配置（SSID/密码换成你的）：
      uci set wireless.sta=wifi-iface
      uci set wireless.sta.device=radio0
      uci set wireless.sta.mode=sta
      uci set wireless.sta.ssid='校园网 SSID'
      uci set wireless.sta.encryption=none     # 校园网多为开放+网页认证；有密码就写 psk2 并补 key
      uci set wireless.sta.network=wwan
      uci set network.wwan=interface
      uci set network.wwan.proto=dhcp
      uci commit wireless; uci commit network; wifi reload; /etc/init.d/network restart
    注意：wwan 要留在 wan 防火墙区，并且不要用 relayd/WDS 把 lan 和 wwan 桥起来 ——
          桥接走二层、不过 IP 栈，UA2F 与 TTL 都不会生效，要的是路由模式 + NAT。
EOF
