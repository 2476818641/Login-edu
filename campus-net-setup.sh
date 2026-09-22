#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-net-setup.sh —— 校园网接入配置（主脚本）
#
# 一条流水线：**先做网络伪装（MAC/TTL/MTU/UA）→ 再自动做网页认证**。
# 认证逻辑在同目录 campus-portal-auth.sh 里（没装会自动下载），所以本脚本是唯一入口：
#   sh campus-net-setup.sh --quick 账号 密码     # 全自动：伪装 + 认证 + 装自动登录
#   或直接跑：sh campus-net-setup.sh             # 交互式，网页认证的账号密码会在中途问你要
#
# 做什么：
#   1) 探测现状：上网接口 / 默认路由 / MAC / MTU / TTL 规则 / UA 改写工具（UAmask / UA3F / UA2F）
#   2) 问接入方式：1) PPPoE（配好账号密码并拨号）  2) 网页认证（只配网络，认证交给认证脚本）
#      3) 用 WiFi（STA）连校园网——**WiFi 上联同样要认证**，所以选 3 之后还会问一次认证方式
#   3) 配好上网口的 MAC 克隆、TTL、MTU、UA 改写并生效
#   4) 等 20 秒，ping / curl 试外网，报告结果（网页认证模式下会顺带把认证页地址探出来）
#
# UA 改写用哪个工具（新固件首选 UA-Mask，脚本自动识别，不用你选）：
#   UAmask —— 当前推荐（固件里已内置）。只劫持 TCP，默认绕过 22/443，并且能把"确认不是 HTTP"
#             的目标自动卸载进 nftables 集合（命中后流量不进用户态代理）→ 游戏加速器/Steam/P2P 不再被转坏
#   ua3f   —— 旧方案（会被识别为 legacy）：它的 REDIRECT 会劫持除 22 外的**全部 TCP**，
#             实测会把加速器隧道转坏，而且停服务时规则残留会导致"TCP 全断但 ping 正常"
#   ua2f   —— 更老的方案，只改 UA
#   如果同时装了 UAmask 和 ua3f，脚本会**自动停掉 ua3f 并清掉它残留的 nft 表**（否则 TCP 会被吸走）。
#
# TTL：UA-Mask **没有** TTL 功能（它不是 L3 工具），所以 TTL 由本脚本写的内核 nft 规则负责，
#      默认值与 UA 人设保持一致：UA 说 Windows → 128，说 Android/Linux/macOS → 64。
#
# 用法：
#   sh campus-net-setup.sh                  # 交互式
#   DRY_RUN=1 sh campus-net-setup.sh        # 只打印要做的改动，不落盘、不断网
#   WAIT_SECS=30 sh campus-net-setup.sh     # 改等待秒数（默认 20）
#   WANIF=wwan sh campus-net-setup.sh       # 指定上网接口（默认按默认路由自动探测）
#   TTL_VALUE=128 sh campus-net-setup.sh    # 手动指定 TTL 目标值（默认按 UA 人设自动定，见上）
#
# 非交互（可选）：
#   CAMPUS_MODE=pppoe CAMPUS_USER=学号 CAMPUS_PASS=密码 sh campus-net-setup.sh
#   CAMPUS_MODE=portal sh campus-net-setup.sh
#   CAMPUS_MAC=AA:BB:CC:DD:EE:FF sh campus-net-setup.sh --quick 账号 密码   # 连 MAC 也不问
#   SKIP_UA=1 sh campus-net-setup.sh --quick 账号 密码                        # 这次完全不碰 UA 改写（先只搞认证时用）
#   UA_MODE=regex|all sh campus-net-setup.sh --quick 账号 密码                # UA 改写范围（默认 regex 正表）
#   UA_STR='...' UA_WHITELIST='A,B' sh campus-net-setup.sh --quick 账号 密码  # 改伪装 UA / 放行名单
#   sh campus-net-setup.sh --ua-mode regex                                   # 只改 UA 配置（不动网络/认证）
#   sh campus-net-setup.sh --ua-only --ua-mode all                           # 同上（--ua-only 是 --ua-mode 的长写）
#
# 只改 UCI 配置 + 一个 /etc/nftables.d 里的 nft 规则文件，不装任何软件包。
# /etc/nftables.d/ 在 firewall4 的 keep.d 里，所以刷固件升级后 TTL 规则仍在。
#
# 无线上网（STA）注意：必须是"路由模式"（wwan 独立接口 + NAT），不能用 relayd/WDS 桥接中继 ——
# 桥接是二层转发、不过 IP 栈，UA 改写与 TTL 改写都不会生效（脚本会检测并告警）。

set -u

DRY_RUN="${DRY_RUN:-0}"
WAIT_SECS="${WAIT_SECS:-20}"
TTL_VALUE="${TTL_VALUE:-}"	# 空 = 自动（按 UA 人设：Windows→128，Android/Linux/macOS→64）
TTL_FILE="${TTL_FILE:-/etc/nftables.d/10-ttl-fix.nft}"
SYSFS="${SYSFS:-/sys/class/net}"		# 可覆盖，便于测试
LOG_TAG="campus-setup"
CAMPUS_MODE="${CAMPUS_MODE:-}"
SKIP_UA="${SKIP_UA:-${SKIP_UA3F:-0}}"	# 1=这次完全不碰 UA 改写
UA_MODE="${UA_MODE:-${UA3F_RULES:-}}"	# 空=自动（--quick 默认 regex 正表）；regex|all
UA_STR="${UA_STR:-}"			# 空=用内置默认（Windows Chrome UA）
UA_WHITELIST="${UA_WHITELIST:-}"	# 空=用内置默认（协议敏感名单：加速器/Steam/HttpDns…）
UA_OFFLOAD_TUNE="${UA_OFFLOAD_TUNE:-1}"	# 1=把"非 HTTP 目标卸载"调成快速生效（阈值1/延迟10s/24h）
UA3F_MODE="${UA3F_MODE:-}"		# 仅 legacy：UA3F 服务模式（空=自动，--quick 用 REDIRECT）
# 说明：UA_MODE=regex（正表：只统一"设备类" UA，其余放行，推荐）/ all（全量改写，最统一但兼容性最差）
#       UA3F_RULES=whitelist|blacklist|all 是旧变量名，会自动映射成 regex|all|all（见 apply_ua_config）

# --quick 账号 [密码]：一条命令跑完（伪装用推荐默认值 + 用你给的账号做网页认证）
case "${1:-}" in
--quick|--onekey|-q)
	AUTO=1
	CAMPUS_MODE="${CAMPUS_MODE:-portal}"
	CAMPUS_USER="${2:-${CAMPUS_USER:-}}"
	CAMPUS_PASS="${3:-${CAMPUS_PASS:-}}"
	shift $(( $# > 3 ? 3 : $# ))
	;;
--skip-ua)
	SKIP_UA=1
	shift
	;;
--ua-mode|--ua-only)
	# --ua-only 是旧写法（原来叫 --ua3f-rules）：只改 UA 配置，不动网络/认证
	UA_ONLY=1
	[ -n "${2:-}" ] && { UA_MODE="$2"; shift; }
	shift
	;;
--ua3f-rules)	# 旧参数名，保留兼容
	UA_ONLY=1
	LEGACY_RULES_FLAG=1	# 提示留到函数定义之后再打印（这个 case 块比 warn() 更早执行）
	[ -n "${2:-}" ] && { UA_MODE="$2"; shift; }
	shift
	;;
esac
CAMPUS_USER="${CAMPUS_USER:-}"; CAMPUS_PASS="${CAMPUS_PASS:-}"

msg()  { printf '%s\n' "$*"; }
info() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[!] %s\033[0m\n' "$*" >&2; exit 1; }

run() {	# 干跑模式只打印
	if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}
log() { [ "$DRY_RUN" = 1 ] || logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
AUTO="${AUTO:-0}"		# 1=不提问，全部采用默认值（--quick 用）
ask() {	# ask <提示> <默认值> -> $REPLY
	_p="$1"; _d="${2:-}"
	if [ "$AUTO" = 1 ]; then
		REPLY="$_d"
		msg "$_p ${_d:+→ $_d}（--quick 用默认值）"
		return 0
	fi
	if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d"; else printf '%s: ' "$_p"; fi
	if ! read -r REPLY; then REPLY=""; fi
	[ -z "$REPLY" ] && REPLY="$_d"
	return 0
}
# 只有真终端才提问；管道/非交互环境自动用默认值。
# ASK_FORCE_TTY=1 是给测试用的钩子：强制认为"有终端"（沙箱里建不了伪终端时用）
tty_ok() { [ "${ASK_FORCE_TTY:-0}" = 1 ] && return 0; [ -t 0 ] && [ -t 1 ]; }
ask_always() {	# 与 ask 相同，但 **--quick 模式下也会问**（没终端时仍走默认值）
	_p="$1"; _d="${2:-}"
	if [ "$AUTO" != 1 ] || tty_ok; then
		if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d"; else printf '%s: ' "$_p"; fi
		if ! read -r REPLY; then REPLY=""; fi
		[ -z "$REPLY" ] && REPLY="$_d"
		return 0
	fi
	REPLY="$_d"
	msg "$_p ${_d:+→ $_d}（非交互环境，用默认值）"
	return 0
}
uget() { uci -q get "$1" 2>/dev/null; }

# ---------------------------------------------------------------- UA 改写（UAmask 为主，ua3f/ua2f 兼容）
#
# UA-Mask 的三个"名单"优先级（源码 internal/rewrite/engine.go，从高到低）：
#   1) Firewall_ua_whitelist —— 不改写该 UA，且**命中即把该目标立刻卸载出代理**（24h）
#   2) whitelist             —— 只是不改写（不卸载），留空才不会破坏"所有设备看起来是同一台"
#   3) match_mode            —— all=全量改写 / regex=正则命中才改 / keywords=含关键词才改
#   ⚠️ 别把 MicroMessenger / Bilibili 放进 Firewall_ua_whitelist：它优先级高于正则，而手机
#      微信/哔哩哔哩的 UA 里带 Android/iPhone，一旦被放过，"Windows Chrome UA + Android UA"
#      同时出现，反而暴露多设备。
UAMASK_DEFAULT_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
# 协议敏感名单：不改写 + 命中即卸载。这些 UA 本来也不匹配下面的设备正则，
# 放进这里是白拿"卸载出代理"这个好处（加速器 / Steam / 应用内 HttpDns / Windows 证书与联网探测）。
UAMASK_DEFAULT_WHITELIST='QeeYouAcceler,Valve/Steam,HttpDns,Microsoft-CryptoAPI,Microsoft NCSI'
UAMASK_DEVICE_REGEX='(iPhone|iPad|Android|Macintosh|Windows|Linux|Apple|Mac OS X|Mobile)'

ua_persona_ttl() {	# 按 UA 人设给 TTL 默认值：Windows=128，Android/Linux/macOS=64
	case "$1" in
	*Windows*) printf '128' ;;
	*Android*|*Linux*|*iPhone*|*iPad*|*Macintosh*|*"Mac OS X"*) printf '64' ;;
	*) printf '128' ;;
	esac
}

ua_mode_norm() {	# 归一化改写范围：regex（正表，推荐）| all（全量）；旧值 whitelist/blacklist 自动映射
	case "$1" in
	'' | regex | REGEX | whitelist | WHITELIST | white) printf 'regex' ;;
	all | ALL | blacklist | BLACKLIST | black)          printf 'all' ;;
	*) return 2 ;;
	esac
}

ua_tool_detect() {	# 自动识别本机用哪套 UA 工具（UAmask 优先）
	if [ -x /usr/bin/UAmask ] || [ -n "$(uget UAmask.enabled.enabled)" ]; then printf 'UAmask'
	elif [ -x /usr/bin/ua3f ] || [ -n "$(uget ua3f.enabled.enabled)" ]; then printf 'ua3f'
	elif [ -x /usr/bin/ua2f ] || [ -n "$(uget ua2f.enabled.enabled)" ]; then printf 'ua2f'
	fi
}

apply_uamask_config() {	# apply_uamask_config <regex|all> —— 一键写全套 UAmask 配置
	_mode="$1"
	_ua="${UA_STR:-$UAMASK_DEFAULT_UA}"
	_wl="${UA_WHITELIST:-$UAMASK_DEFAULT_WHITELIST}"
	_iface="${LANBR:-br-lan}"
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] uci set UAmask.enabled.enabled=1\n'
		printf '    [dry-run] uci set UAmask.main.ua=%s\n' "$_ua"
		printf '    [dry-run] uci set UAmask.main.match_mode=%s (+ua_regex=%s)\n' "$_mode" "$UAMASK_DEVICE_REGEX"
		printf '    [dry-run] uci set UAmask.main.Firewall_ua_whitelist=%s\n' "$_wl"
		printf '    [dry-run] uci set UAmask.main.enable_firewall_set=1 Firewall_ua_bypass=1 Firewall_drop_on_match=0\n'
		[ "$UA_OFFLOAD_TUNE" = 1 ] && printf '    [dry-run] uci set UAmask.main.firewall_advanced_settings=1 firewall_nonhttp_threshold=1 firewall_decision_delay=10 firewall_timeout=86400\n'
		printf '    [dry-run] uci set UAmask.main.iface=%s bypass_ports="22 443" proxy_host=0 operating_profile=Medium\n' "$_iface"
		printf '    [dry-run] uci commit UAmask && /etc/init.d/UAmask restart\n'
		return 0
	fi
	command -v uci >/dev/null 2>&1 || { warn "    不是路由器（没有 uci），跳过"; return 1; }
	uci set UAmask.main.ua="$_ua" || { warn "    uci set UAmask.main.ua 失败"; return 1; }
	uci set UAmask.main.match_mode="$_mode"
	uci set UAmask.main.ua_regex="$UAMASK_DEVICE_REGEX"
	uci set UAmask.main.replace_method='full'
	uci set UAmask.main.keywords=''
	uci set UAmask.main.whitelist=''			# 留空：填了等于让那些 UA 不被统一
	uci set UAmask.main.Firewall_ua_whitelist="$_wl"
	uci set UAmask.main.Firewall_drop_on_match='0'		# 必须 0：1 = 命中就掐断连接
	uci set UAmask.main.enable_firewall_set='1'		# 流量卸载总开关
	uci set UAmask.main.Firewall_ua_bypass='1'		# 绕过非 HTTP 流量（加速器/Steam/P2P 的关键）
	if [ "$UA_OFFLOAD_TUNE" = 1 ]; then
		# 决策器默认"5 次观测 + 60s 延迟 + 8h"：为的是不误判导致 UA 泄露。
		# 校园网这台路由器上把阈值/延迟压到最小（代码下限 10s）、有效期拉到 24h，
		# 让"隧道类流量"尽快被卸载、且不用反复重学。
		uci set UAmask.main.firewall_advanced_settings='1'
		uci set UAmask.main.firewall_nonhttp_threshold='1'
		uci set UAmask.main.firewall_decision_delay='10'
		uci set UAmask.main.firewall_timeout='86400'
	fi
	uci set UAmask.main.iface="$_iface"
	uci set UAmask.main.port='12032'
	uci set UAmask.main.bypass_ports='22 443'
	uci set UAmask.main.bypass_ips='172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16'
	uci set UAmask.main.proxy_host='0'
	uci set UAmask.main.operating_profile='Medium'	# 256MB 机器：Low=200并发/Medium=500/High=1000
	uci set UAmask.main.log_level='info'
	uci set UAmask.main.log_file='/tmp/UAmask/UAmask.log'
	uci set UAmask.enabled.enabled='1'
	uci commit UAmask 2>/dev/null || { warn "    uci commit UAmask 失败"; return 1; }
	# 读回校验：写进去了才算数（uci CLI 在某些固件上会静默失败）
	[ "$(uget UAmask.main.enabled.enabled; uget UAmask.enabled.enabled)" = "1" ] || warn "    enabled 没存成 1"
	[ "$(uget UAmask.main.match_mode)" = "$_mode" ] || warn "    match_mode 没存成 $_mode"
	[ -n "$(uget UAmask.main.Firewall_ua_whitelist)" ] || warn "    Firewall_ua_whitelist 是空的（大写 F 不能写错）"
	/etc/init.d/UAmask restart >/dev/null 2>&1
	sleep 1
	if pgrep -f UAmask >/dev/null 2>&1; then
		msg "    ✅ UAmask 已启动（match_mode=$_mode，UA=$(printf %.48s "$_ua")…）"
	else
		warn "    UAmask 没起来：logread -e UAmask | tail -20（生成 /var/run/UAmask/config.json 失败会写在这里）"
	fi
	[ -f /var/run/UAmask/config.json ] && grep -q "$_ua" /var/run/UAmask/config.json 2>/dev/null \
		&& msg "    ✅ 核心配置已生成且 UA 正确（/var/run/UAmask/config.json）" \
		|| warn "    没看到 /var/run/UAmask/config.json 或里面 UA 不对"
	if command -v nft >/dev/null 2>&1; then
		if nft list table inet fw4 2>/dev/null | grep -qi uamask; then
			msg "    ✅ 已注册 fw4 规则（含绕过集合 UAmask_bypass_set）"
		else
			warn "    没看到 fw4 规则 —— UA 可能不会被改写：nft list table inet fw4 | grep -i uamask"
		fi
	fi
	case "$_mode" in
	regex) msg "       正表：只统一「设备类」UA（手机/PC/平板），其余原样放行" ;;
	all)   msg "       全量：除放行名单外全部改写成同一个 UA（最统一，但兼容性最差）" ;;
	esac
	return 0
}

disable_other_ua_tools() {	# 停掉其它 UA 工具（两套劫持会互相打架，残留规则还会断网）
	_stopped=0
	if [ -x /etc/init.d/ua3f ] || [ -n "$(uget ua3f.enabled.enabled)" ]; then
		if [ "$(uget ua3f.enabled.enabled)" != "0" ] || nft list table inet UA3F >/dev/null 2>&1; then
			msg "    检测到旧方案 UA3F → 停用并清理（否则残留的全量 TCP 重定向会把网络弄断）"
			run uci set ua3f.enabled.enabled='0'
			run uci commit ua3f
			run /etc/init.d/ua3f stop
			# ⚠️ 关键：UA3F 的 stop 不清 nft，残留 `tcp dport != {22} redirect to :1080`
			#    会把除 22 外的所有 TCP 吸进没人监听的端口 → "电脑没网但 ping 正常"
			run nft delete table inet UA3F
			if [ "$DRY_RUN" != 1 ] && nft list tables 2>/dev/null | grep -qi ua3f; then
				warn "      UA3F 的 nft 表没删干净：nft list tables | grep -i ua3f"
			fi
			_stopped=1
		fi
	fi
	if [ -x /etc/init.d/ua2f ] || [ -n "$(uget ua2f.enabled.enabled)" ]; then
		if [ "$(uget ua2f.enabled.enabled)" != "0" ]; then
			msg "    检测到更老的方案 UA2F → 停用（它也会劫持 HTTP 流量）"
			run uci set ua2f.enabled.enabled='0'
			run uci commit ua2f
			run /etc/init.d/ua2f stop
			_stopped=1
		fi
	fi
	[ "$_stopped" = 1 ] || msg "    没有其它 UA 工具需要停用"
	return 0
}

# ---------------------------------------------------------------- UA3F 规则表（legacy，仅旧固件用）
# UA3F 的规则表是 UCI 里的一段 JSON（LuCI「服务→UA3F」可视化编辑）。字段：type/action/match_*/rewrite_*；
# type 可用：HEADER-KEYWORD HEADER-REGEX DOMAIN DOMAIN-KEYWORD DOMAIN-SUFFIX IP-CIDR DEST-PORT
#           SRC-IP URL-REGEX FINAL；action 可用：DIRECT REPLACE REPLACE-REGEX DELETE ADD DROP REJECT。
# 规则自上而下匹配、FINAL 兜底；HEADER-REGEX 是**子串匹配**（Go regexp.MatchString，不用加锚）。
#
# ⚠️ 关键：UA3F 有 rewrite_mode，**规则表只在 RULE 模式生效**：
#     GLOBAL（官方默认）—— 不读规则表！只放行 5 个硬编码 UA：
#         MicroMessenger Client / Bilibili Freedoooooom/MarkII /
#         Valve/Steam HTTP Client 1.0 / Go-http-client/1.1 / ByteDancePcdn
#         其余**全部**改写成 uci 里的 ua —— 加速器/HttpDns/各类 App 就是这么被改坏的。
#     RULE   —— 按 header_rewrite 规则表逐条匹配（正表/反表都需要它）。
#     DIRECT —— 完全不改写。
#     所以本函数应用规则表时**会同时把 rewrite_mode 设成 RULE**（all 则设回 GLOBAL）。
UA3F_DEFAULT_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

ua3f_target_ua() {	# 用 uci 里已配的 UA；没配或是占位符就用默认
	_u="$(uget ua3f.main.ua)"
	case "$_u" in ''|keep|KEEP|FFF|fff) printf '%s' "$UA3F_DEFAULT_UA" ;; *) printf '%s' "$_u" ;; esac
}

ua3f_rules_json() {	# ua3f_rules_json <whitelist|blacklist|all> <UA>
	case "$1" in
	whitelist)
		printf '[{"enabled":true,"type":"HEADER-REGEX","match_header":"User-Agent","match_value":"(uclient|Wget|wget|curl|libcurl|nghttp2|Go-http-client|python-requests|Python-urllib|aria2|Transmission|BusyBox|OpenWrt|LuCI)","action":"REPLACE","rewrite_header":"User-Agent","rewrite_value":"%s","description":"正表：路由器/命令行 UA 统一成 PC"},{"enabled":true,"type":"FINAL","action":"DIRECT","description":"其余一律不改写（Steam/加速器/HttpDns 等协议敏感流量靠这条放行）"}]' "$2"
		;;
	blacklist)
		# 反表：默认全局改写，只放行"协议敏感"流量。
		# 前 5 条与 UA3F 官方 GLOBAL 模式硬编码白名单保持一致（微信 / B站 / Steam / Go 客户端 / 字节 PCDN），
		# 后面是实测踩到的：迅游 allawntech、奇游 qiyou、加速器 SDK、App 内 HttpDns、Windows 证书与联网探测。
		printf '[{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"MicroMessenger Client","action":"DIRECT","description":"微信（与官方默认一致）"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"Bilibili Freedoooooom/MarkII","action":"DIRECT","description":"B站（与官方默认一致）"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"Valve/Steam HTTP Client 1.0","action":"DIRECT","description":"Steam 客户端（与官方默认一致）"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"Go-http-client/1.1","action":"DIRECT","description":"Go 客户端（与官方默认一致）"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"ByteDancePcdn","action":"DIRECT","description":"字节 PCDN（与官方默认一致）"},{"enabled":true,"type":"DOMAIN-KEYWORD","match_value":"steam","action":"DIRECT","description":"Steam 商店/CDN"},{"enabled":true,"type":"DOMAIN-KEYWORD","match_value":"qiyou","action":"DIRECT","description":"奇游加速器"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"QeeYouAcceler","action":"DIRECT","description":"奇游加速器客户端 UA"},{"enabled":true,"type":"DOMAIN-KEYWORD","match_value":"allawntech","action":"DIRECT","description":"迅游加速器"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"KCG-PD","action":"DIRECT","description":"加速器"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"NxSdk","action":"DIRECT","description":"加速器 SDK"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"HttpDns","action":"DIRECT","description":"App 内 HTTPDNS（改了会解析失败）"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"Microsoft-CryptoAPI","action":"DIRECT","description":"Windows 证书/更新"},{"enabled":true,"type":"HEADER-KEYWORD","match_header":"User-Agent","match_value":"Microsoft NCSI","action":"DIRECT","description":"Windows 联网探测"},{"enabled":true,"type":"FINAL","action":"REPLACE","rewrite_header":"User-Agent","rewrite_value":"%s","description":"默认：统一改写"}]' "$2"
		;;
	all)
		printf '[{"enabled":true,"type":"FINAL","action":"REPLACE","rewrite_header":"User-Agent","rewrite_value":"%s","description":"全部改写（兼容性最差）"}]' "$2"
		;;
	*) return 2 ;;
	esac
}

apply_ua3f_rules() {	# apply_ua3f_rules <whitelist|blacklist|all>
	_set="$1"
	_json="$(ua3f_rules_json "$_set" "$(ua3f_target_ua)")" || { warn "未知规则集：$_set（可选 whitelist / blacklist / all）"; return 2; }
	if ! command -v uci >/dev/null 2>&1; then
		msg "    （不是路由器：规则表内容如下，可粘进 LuCI「服务→UA3F」的规则编辑器）"
		printf '%s\n' "$_json"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] uci set ua3f.main.rewrite_mode=%s\n' "$([ "$_set" = all ] && echo GLOBAL || echo RULE)"
		printf '    [dry-run] uci set ua3f.main.header_rewrite=<%s 规则表 %s 字节>\n' "$_set" "$(printf '%s' "$_json" | wc -c)"
		return 0
	fi
	# 规则表要生效必须切到 RULE 模式（GLOBAL 会忽略规则表）
	case "$_set" in
		all) _mode="GLOBAL" ;;
		*)   _mode="RULE" ;;
	esac
	uci set "ua3f.main.rewrite_mode=$_mode" 2>/dev/null || true
	if ! uci set "ua3f.main.header_rewrite=$_json" 2>/dev/null; then
		warn "    uci set 失败 —— 去 LuCI「服务→UA3F」手工把规则表替换成下面这份："
		printf '%s\n' "$_json"
		return 1
	fi
	uci commit ua3f 2>/dev/null || { warn "    uci commit ua3f 失败"; return 1; }
	[ -n "$(uci -q get ua3f.main.header_rewrite)" ] || { warn "    规则表没存进去"; return 1; }
	/etc/init.d/ua3f restart >/dev/null 2>&1
	[ "$(uci -q get ua3f.main.rewrite_mode)" = "$_mode" ] || warn "    rewrite_mode 没设成 $_mode，规则表可能不生效"
	msg "    ✅ 已应用 UA3F 规则集：$_set（rewrite_mode=$_mode，已重启 UA3F）"
	case "$_set" in
		whitelist) msg "       只有路由器/命令行类 UA 会被改写；Steam / 加速器 / HttpDns 等一律放行" ;;
		blacklist) msg "       其余全部统一改写，只放行列出的协议敏感流量" ;;
		all)       msg "       全部改写（Steam / 加速器 可能受影响）" ;;
	esac
	msg "       验证：LuCI「服务→UA3F」→『请求 Header 实时统计』，对比 原文 UA / 改写后 UA"
	return 0
}

[ "${LEGACY_RULES_FLAG:-0}" = 1 ] && warn "--ua3f-rules 已改名为 --ua-mode（取值 regex|all）；whitelist→regex、blacklist/all→all 已自动映射"

# apply_ua_config <regex|all>：按本机装的工具分发（UAmask 优先，UA3F 走 legacy）
apply_ua_config() {
	_mode="$(ua_mode_norm "${1:-regex}")" || { warn "未知的 UA 改写范围：$1（可选 regex / all）"; return 2; }
	_tool="$(ua_tool_detect)"
	case "$_tool" in
	UAmask)
		disable_other_ua_tools
		apply_uamask_config "$_mode" || return 1
		;;
	ua3f)
		# legacy：UA3F 没有 regex/all，用它的 whitelist（正表）/all（全量）规则集表达同一件事
		case "$_mode" in
		regex) apply_ua3f_rules whitelist || return 2 ;;
		all)   apply_ua3f_rules all || return 2 ;;
		esac
		;;
	ua2f)
		warn "本机只有老方案 UA2F（只改 UA，没有放行/卸载能力）；建议固件换成内置 UA-Mask 的版本"
		run uci set ua2f.enabled.enabled='1'
		run uci set "ua2f.main.custom_ua=${UA_STR:-$UAMASK_DEFAULT_UA}"
		run uci set ua2f.firewall.handle_tls='0'	# 443 是 TLS，处理它没意义还添乱
		run uci set ua2f.firewall.handle_fw='1'
		run uci commit ua2f
		run /etc/init.d/ua2f restart
		;;
	*)
		warn "没装 UAmask / UA3F / UA2F —— 跳过 UA 改写（固件里应内置 UAmask，见 README）"
		return 1
		;;
	esac
	return 0
}

# --ua-mode [regex|all] / --ua-only：只改 UA 配置（不动网络与认证）
if [ "${UA_ONLY:-0}" = 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	apply_ua_config "${UA_MODE:-regex}" || exit 1
	_ttl="${TTL_VALUE:-$(ua_persona_ttl "${UA_STR:-$UAMASK_DEFAULT_UA}")}"
	msg "    TTL 由内核 nft 规则负责（UA-Mask 没有 TTL 功能）：目标值 $_ttl"
	msg "      写规则：sh $0 --quick … 时会一并写好；或手动建 $TTL_FILE 后 fw4 reload"
	exit 0
fi

[ "$(id -u)" = 0 ] || die "请用 root 运行（需要改网络与防火墙配置）"
command -v uci >/dev/null 2>&1 || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上运行"

if [ "${AUTO:-0}" = 1 ]; then
	info "一键模式：伪装走推荐默认值，认证用你给的账号（账号：${CAMPUS_USER:-稍后输入}）"
	msg "    MAC 地址会单独问你一次（校园网常按 MAC 绑定；不想改就直接回车）"
	msg "    想全自动不提问：CAMPUS_MAC=AA:BB:CC:DD:EE:FF sh $0 --quick 账号 密码"
fi

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
# 状态栏：优先报 UA-Mask（当前方案），再报旧方案；UAmask 与 ua3f 同时装着要提醒（会互相打架）
_tool="$(ua_tool_detect)"
case "$_tool" in
UAmask)
	msg "    UA 改写      : UAmask（当前方案）启用=$([ "$(uget UAmask.enabled.enabled)" = 1 ] && echo 是 || echo 否)，match_mode=$(uget UAmask.main.match_mode)，UA=$(uget UAmask.main.ua)"
	if [ -x /etc/init.d/ua3f ] || [ -n "$(uget ua3f.enabled.enabled)" ]; then
		warn "         同时装着旧方案 UA3F —— 两套劫持会互相打架，脚本会自动停用它并清掉残留 nft 表"
	fi
	;;
ua3f)
	msg "    UA 改写      : ua3f（旧方案，建议换内置 UAmask 的固件）启用=$([ "$(uget ua3f.enabled.enabled)" = 1 ] && echo 是 || echo 否)，服务模式=$(uget ua3f.main.server_mode)，UA=$(uget ua3f.main.ua)"
	;;
ua2f)
	msg "    UA 改写      : ua2f（更老方案，只改 UA）启用=$([ "$(uget ua2f.enabled.enabled)" = 1 ] && echo 是 || echo 否)"
	;;
*)
	msg "    UA 改写      : 没装（UAmask / ua3f / ua2f 都没有）"
	;;
esac

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
		WIRELESS_UPLINK=1	# 自动识别：出口是无线 → MTU 默认 keep、MAC 提示走无线分支
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
	msg "    2) 网页认证（本机已是本门户的实测实现：配完网络会自动接着做认证）"
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
	msg "      1) 网页认证（默认；配完网络会自动接着做认证）"
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

# 网页认证：就地收集账号密码，稍后（伪装配置完 → 测完网）自动接着认证
if [ "$AUTH_REQUIRED" = 1 ] && [ "$CAMPUS_MODE" = "portal" ]; then
	if [ -z "${CAMPUS_USER:-}" ] && [ "$DRY_RUN" != 1 ]; then
		msg ""
		msg "  ── 网页认证要用的账号（回车=稍后再填，先只做网络伪装）──"
		ask "    认证账号（学号/上网账号）" ""
		CAMPUS_USER="$REPLY"
		if [ -n "$CAMPUS_USER" ]; then
			printf '    认证密码: '
			stty -echo 2>/dev/null; read -r CAMPUS_PASS; stty echo 2>/dev/null; echo
		fi
	fi
elif [ -z "${CAMPUS_USER:-}" ] && [ "$CAMPUS_MODE" = "pppoe" ]; then
	: # PPPoE 的账号在上面那段处理
fi

# ---------------------------------------------------------------- 2) 配 MAC / TTL / MTU / UA
info "2/4 配置 MAC / TTL / MTU / UA"

# --- 2.1 MAC 克隆
msg ""
msg "  ── MAC 地址（校园网常按 MAC 分配/绑定 IP，克隆成已知设备的 MAC 最稳）──"
msg "     当前 WAN MAC（$WANDEV）: $(cat "$SYSFS/$WANDEV/address" 2>/dev/null || echo 未知)"
if [ -s /tmp/dhcp.leases ]; then
	msg "     路由器下面这些设备拿过地址，可以参考/直接抄："
	awk 'NF>=3 && $2 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ {printf "       %s  %s\n", $2, ($4 != "*" ? $4 : "")}' /tmp/dhcp.leases 2>/dev/null | head -5
fi
CLONE_MAC="${CAMPUS_MAC:-}"		# 可用环境变量直接给：CAMPUS_MAC=AA:BB:... sh campus-net-setup.sh --quick 账号 密码
if [ -n "$CLONE_MAC" ]; then
	msg "     MAC 使用环境变量 CAMPUS_MAC=$CLONE_MAC"
else
	ask_always "    要克隆的 MAC（回车=不改；auto=取上面第一台设备；或填 AA:BB:CC:DD:EE:FF）" ""
	CLONE_MAC="$REPLY"
fi
case "$CLONE_MAC" in
auto|AUTO)
	CLONE_MAC="$(awk 'NF>=3 && $2 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ {print $2; exit}' /tmp/dhcp.leases 2>/dev/null)"
	[ -n "$CLONE_MAC" ] || warn "      /tmp/dhcp.leases 里没找到租约，跳过 MAC 克隆"
	;;
esac
if [ -n "$CLONE_MAC" ]; then
	printf '%s' "$CLONE_MAC" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
		|| die "MAC 格式不对：$CLONE_MAC（要 AA:BB:CC:DD:EE:FF）"
	if [ -n "${WIFI_UPLINK:-}${WIRELESS_UPLINK:-}" ]; then
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
[ -n "${WIFI_UPLINK:-}${WIRELESS_UPLINK:-}" ] && DEF_MTU=keep	# 无线侧 MTU 由 AP 决定，别乱改
# --quick：本机已经配过 MTU 就**保持不动**（改错 MTU 会让部分网站打不开/卡死）
if [ "$AUTO" = 1 ]; then
	_curmtu="$(uget "network.$WANIF.mtu")"
	[ -n "$_curmtu" ] && { DEF_MTU=keep; msg "    本机 MTU 已是 $_curmtu，--quick 保持不动（想改请跑交互式）"; }
fi
ask "    MTU（回车=$DEF_MTU，不想改就填 keep）" "$DEF_MTU"
MTU="$REPLY"
if [ "$MTU" != "keep" ] && [ -n "$MTU" ]; then
	case "$MTU" in *[!0-9]*) die "MTU 必须是数字：$MTU" ;; esac
	run uci set "network.$WANIF.mtu=$MTU"
	[ "$CAMPUS_MODE" = "pppoe" ] && run uci set "network.$WANIF.mru=$MTU"
	msg "    MTU → $MTU"
fi

# --- 先确定用哪个 UA 方案（UAmask 优先，其次旧方案 ua3f / ua2f）
UA_IMPL="$(ua_tool_detect)"
TTL_BY_NFT=1
# SKIP_UA=1：这次完全不碰 UA 改写（认证只发几个 HTTP 请求，跟 UA 改写无关）。
# 做法是把 UA_IMPL 清空 → 后面 case 落到"没装"分支，也不会去 restart 服务。
SKIPPED_UA=0
if [ "$SKIP_UA" = 1 ]; then
	warn "SKIP_UA=1：这次完全不动 UA 改写（先把认证做完，再单独调 UA）"
	msg "    TTL 仍由内核 nft 规则负责，认证不受影响"
	UA_IMPL=""; SKIPPED_UA=1
fi

# --- 2.3 TTL
# UA-Mask **没有** TTL 功能（它是纯 UA 改写工具；TTL/IPID/删 TCP 时间戳/阻断 QUIC/Desync 都是
# 旧方案 UA3F 的 L3 能力，那几个开关实测会打死加速器与 QUIC 流量，换方案时一起弃用了）。
# 所以 TTL 完全由这里写的内核 nft 规则负责，不存在"两处打架"的问题。
# 自动选取：环境变量 TTL_VALUE > 按 UA 人设（Windows→128，Android/Linux/macOS→64）
if [ -z "$TTL_VALUE" ]; then
	TTL_VALUE="$(ua_persona_ttl "${UA_STR:-$UAMASK_DEFAULT_UA}")"
	msg "    TTL 默认值 $TTL_VALUE（与 UA 人设保持一致：UA 说 Windows 就该是 128，说 Android/Linux 是 64）"
	# 旧文件里如果是"另一种人设"的值，提示一下：UA 与 TTL 自相矛盾正是 DPI 会抓的点
	if [ -f "$TTL_FILE" ]; then
		_oldttl="$(sed -n 's/.*ip ttl set \([0-9]*\).*/\1/p' "$TTL_FILE" 2>/dev/null | head -1)"
		if [ -n "$_oldttl" ] && [ "$_oldttl" != "$TTL_VALUE" ]; then
			warn "    现有 $TTL_FILE 里是 $_oldttl，与 UA 人设不一致 → 本次改成 $TTL_VALUE"
			msg "         想保持 $_oldttl：TTL_VALUE=$_oldttl sh $0 …（或把 UA 串换成对应人设）"
		fi
	fi
fi
if [ "$UA_IMPL" = "ua3f" ]; then
	msg "    检测到旧方案 UA3F：它的 L3 重写（TTL/IPID/TCP）已建议别开，TTL 也由这里的 nft 规则统一负责"
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
UAmask)
	# ---- 当前推荐方案：UA-Mask ----
	CUR_EN="$(uget UAmask.enabled.enabled)"; [ -z "$CUR_EN" ] && CUR_EN=1
	# 归一化现有值：match_mode 用统一的名字（regex/all），UA 若是上游占位符（FFF/keep/空）就用内置默认——
	# 否则 --quick 会把 "FFF" 这种占位符当成"你要保留的 UA"照搬过去
	CUR_MODE="$(ua_mode_norm "$(uget UAmask.main.match_mode)")" || CUR_MODE=regex
	CUR_UA="$(uget UAmask.main.ua)"
	case "$CUR_UA" in ''|keep|KEEP|FFF|fff) CUR_UA="$UAMASK_DEFAULT_UA" ;; esac
	CUR_WL="$(uget UAmask.main.Firewall_ua_whitelist)"; [ -z "$CUR_WL" ] && CUR_WL="$UAMASK_DEFAULT_WHITELIST"
	CUR_OFF="$(uget UAmask.main.Firewall_ua_bypass)"
	msg "    UA-Mask 现状：启用=$CUR_EN 匹配=$CUR_MODE 卸载非HTTP=${CUR_OFF:-未设} UA=$(printf %.48s "$CUR_UA")…"
	msg "    白话：UA-Mask 只改明文 HTTP 的 User-Agent（443 是 TLS，看不到 UA）；"
	msg "          它没有 TTL 功能 —— TTL 由本脚本写的内核 nft 规则负责（见下一步）。"

	ask "    启用 UA-Mask（把各设备的 UA 统一成一台 PC）" "$CUR_EN"
	case "$REPLY" in
	1|y|Y|yes|是)
		UA_ENABLED=1
		disable_other_ua_tools
		ask "    匹配规则：regex=只统一「设备类」UA，其余放行（推荐）/ all=除放行名单外全改" "$CUR_MODE"
		case "$REPLY" in
		all|ALL|blacklist|BLACKLIST) UA_MODE_USED=all ;;
		*)                           UA_MODE_USED=regex ;;
		esac
		msg "    伪装 UA 可填：win=常见 Chrome（默认）/ 或直接粘贴整串（要和自己说的系统自洽）"
		ask "    伪装成什么 UA" "$CUR_UA"
		case "$REPLY" in
		win|WIN|chrome|CHROME) UA_STR="$UAMASK_DEFAULT_UA" ;;
		''|keep|KEEP)          UA_STR="$CUR_UA" ;;
		*)                     UA_STR="$REPLY" ;;
		esac
		msg "    放行名单（不改写 + 命中即把该目标卸载出代理）：留空=用默认"
		msg "      默认：$UAMASK_DEFAULT_WHITELIST"
		ask "    放行名单" "$CUR_WL"
		UA_WHITELIST="$REPLY"
		ask "    把「非 HTTP 目标自动卸载」调成快速生效（阈值1/延迟10s/有效期24h）(y/N)" "$UA_OFFLOAD_TUNE"
		case "$REPLY" in 1|y|Y|yes|是) UA_OFFLOAD_TUNE=1 ;; *) UA_OFFLOAD_TUNE=0 ;; esac
		apply_uamask_config "$UA_MODE_USED" || warn "    应用 UA-Mask 配置失败，看上面的报错"
		;;
	*)
		UA_ENABLED=0
		run uci set UAmask.enabled.enabled='0'
		run uci commit UAmask
		msg "    UA-Mask → 关闭"
		;;
	esac
	;;
ua3f)
	CUR_EN="$(uget ua3f.enabled.enabled)"; [ -z "$CUR_EN" ] && CUR_EN=1
	CUR_MODE="$(uget ua3f.main.server_mode)"; [ -z "$CUR_MODE" ] && CUR_MODE=NFQUEUE
	# 服务模式怎么选（以真机实测为准）：
	#   REDIRECT —— 本机实测**可行**（UA 确实被改写），本脚本默认用它
	#   TPROXY   —— 本机实测**不行**（UA 没被改写）而且最贵：全部流量绕本机代理一遍
	#               （loopback 收发各一次），实测 sys 60%+ / io 20%+ / 负载 4+
	#   NFQUEUE  —— 开销最低，理论上可用；本机没实测过，想省 CPU 可以自己试
	if [ "$AUTO" = 1 ] && [ "$SKIP_UA" != 1 ]; then
		[ -n "$UA3F_MODE" ] && NEW_MODE="$UA3F_MODE" || NEW_MODE="REDIRECT"
		[ "$CUR_MODE" != "$NEW_MODE" ] && msg "    UA3F 服务模式：$CUR_MODE → $NEW_MODE（$([ -n "$UA3F_MODE" ] && echo "按 UA3F_MODE 指定" || echo "默认用本机实测可行的 REDIRECT；TPROXY 实测不改写 UA 且最贵")）"
		CUR_MODE="$NEW_MODE"
	fi
	CUR_UA="$(uget ua3f.main.ua)"; [ -z "$CUR_UA" ] && CUR_UA=FFF
	CUR_TTL="$(uget ua3f.main.l3_rewrite_ttl)"; [ -z "$CUR_TTL" ] && CUR_TTL=0
	msg "    UA3F 现状：启用=$CUR_EN 服务模式=$CUR_MODE 改写模式=$(uget ua3f.main.rewrite_mode) UA=$CUR_UA TTL重写=$CUR_TTL"
	[ "$(uget ua3f.main.rewrite_mode)" = GLOBAL ] && msg "      ⚠️ 改写模式是 GLOBAL —— 规则表不生效（只有 5 个硬编码 UA 放行），应用规则集会自动切成 RULE"
	[ -z "$(uget ua3f.main.header_rewrite)" ] && \
		warn "      规则表(header_rewrite)是空的 → 装了也不会改 UA，去 LuCI「服务→UA3F」恢复默认规则"

	ask "    启用 UA3F（UA 改写 + L3 重写，校园网防检测核心）" "$CUR_EN"
	case "$REPLY" in
	1|y|Y|yes|是)
		UA_ENABLED=1
		msg "    服务模式：REDIRECT=实测可用（默认）/ NFQUEUE=开销最低（未实测）/ TPROXY=实测不行且最贵"
		ask "    服务模式" "$CUR_MODE"
		UA_MODE_USED="$REPLY"
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
			ask "      TTL 目标值" "$TTL_VALUE"; [ -z "$REPLY" ] && REPLY="$TTL_VALUE"
			[ "$REPLY" = "$TTL_VALUE" ] || warn "      注意：UA3F=$REPLY 而内核兜底仍是 $TTL_VALUE，两处不一致可能互相打架（建议一致）"
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
		EBPF_DEF="$(uget ua3f.main.l3_rewrite_bpf_offload)"
		if [ -z "$EBPF_DEF" ]; then
			_kv="$(uname -r | cut -d. -f1-2)"
			case "$_kv" in
				6.*|5.1[5-9]|5.[2-9][0-9]) EBPF_DEF=1 ;;
				*) EBPF_DEF=0 ;;
			esac
			[ "$AUTO" = 1 ] && [ "$EBPF_DEF" = 1 ] && msg "    内核 $_kv 支持 eBPF → L3 重写默认用 eBPF 卸载（省 CPU）"
		fi
		ask "    L3 重写用 eBPF 加速（l3_rewrite_bpf_offload；内核 ≥5.15，省 CPU）(y/N)" "$EBPF_DEF"
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
		# UA 改写范围：默认"正表"——只改路由器/命令行类 UA，放行 Steam/加速器/HttpDns 等协议敏感流量
		# 旧方案的规则集：regex（正表）↔ whitelist，all（全量）↔ all
		apply_ua3f_rules "$([ "$(ua_mode_norm "${UA_MODE:-regex}")" = all ] && echo all || echo whitelist)"
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
	if [ "${SKIPPED_UA:-0}" = 1 ]; then
		msg "    （按 SKIP_UA=1 跳过；UA 改写工具的配置原样不动）"
	else
	warn "没装 UAmask / UA3F / UA2F —— 跳过 UA 改写部分"
	msg "    正路：用内置 UA-Mask 的固件（本仓库固件已内置）；旧固件也可以直接装 apk：apk add --allow-untrusted uamask-*.apk"
	fi
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

# 认证脚本：没装就自动下载（用户只需要认识主脚本这一个入口）
AUTH_SCRIPT="${AUTH_SCRIPT:-/etc/campus-portal-auth.sh}"
AUTH_OK=0
# 找认证脚本：① 目标位置 ② 入口脚本同目录（用户通常把两个放一起）③ /root ④ /tmp ⑤ 当前目录
# 只有都找不到才尝试下载 —— 而且**必须设超时**：认证前本来就没网，无超时的 wget 会卡死（2026-09-21 真机踩到）
ensure_auth_script() {
	[ -x "$AUTH_SCRIPT" ] && return 0
	_selfdir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
	for _c in "$_selfdir/campus-portal-auth.sh" "./campus-portal-auth.sh" \
	          /root/campus-portal-auth.sh /tmp/campus-portal-auth.sh "$HOME/campus-portal-auth.sh"; do
		[ -n "$_c" ] && [ -f "$_c" ] || continue
		[ -x "$AUTH_SCRIPT" ] && break
		msg "    找到认证脚本：$_c"
		if [ "$DRY_RUN" = 1 ]; then msg "    （DRY_RUN：不复制）"; return 0; fi
		if cp -f "$_c" "$AUTH_SCRIPT" 2>/dev/null && chmod +x "$AUTH_SCRIPT" 2>/dev/null; then
			msg "    已装到 $AUTH_SCRIPT"
			return 0
		fi
		warn "    复制到 $AUTH_SCRIPT 失败，直接用找到的那份"
		AUTH_SCRIPT="$_c"
		return 0
	done
	[ "$DRY_RUN" = 1 ] && { msg "    （DRY_RUN：跳过下载）"; return 0; }
	info "    本机没有认证脚本，尝试下载（每个源最多 8 秒，失败不纠缠）"
	for _u in "https://cdn.jsdelivr.net/gh/2476818641/Login-edu@main/campus-portal-auth.sh" \
	          "https://raw.githubusercontent.com/2476818641/Login-edu/main/campus-portal-auth.sh"; do
		# -T 8 超时、-t 1 不重试：没认证前根本没网，卡住比失败更糟
		if wget -q -T 8 -t 1 -O "$AUTH_SCRIPT" "$_u" 2>/dev/null && [ -s "$AUTH_SCRIPT" ]; then
			chmod +x "$AUTH_SCRIPT"
			if grep -q -- '--quick' "$AUTH_SCRIPT"; then
				msg "    已装到 $AUTH_SCRIPT"
				return 0
			fi
			warn "    下载到的脚本不像新版（没有 --quick），继续尝试下一个源"
			rm -f "$AUTH_SCRIPT"
		fi
	done
	rm -f "$AUTH_SCRIPT" 2>/dev/null
	warn "    没有认证脚本，也下载失败（认证前没网是正常的）"
	msg  "    手动装法（用能上网的电脑/手机下载后传到路由器）："
	msg  "      1) 下载 campus-portal-auth.sh"
	msg  "      2) 传到路由器，和 campus-net-setup.sh 放同一个目录（例如都放 /root）"
	msg  "         或者直接放到 /etc/campus-portal-auth.sh"
	msg  "      3) 再跑一次本脚本即可（它会自动找到并装好）"
	return 1
}
run_portal_auth() {
	[ "$DRY_RUN" = 1 ] && { msg "    （DRY_RUN：跳过真正的认证）"; return 0; }
	ensure_auth_script || return 1
	if [ -n "${CAMPUS_USER:-}" ] && [ -n "${CAMPUS_PASS:-}" ]; then
		"$AUTH_SCRIPT" --quick "$CAMPUS_USER" "$CAMPUS_PASS" && AUTH_OK=1
	elif [ -n "${CAMPUS_USER:-}" ]; then
		"$AUTH_SCRIPT" --quick "$CAMPUS_USER" && AUTH_OK=1
	else
		msg "    （没给账号，认证脚本会问你要一次）"
		"$AUTH_SCRIPT" --quick && AUTH_OK=1
	fi
	return $([ "$AUTH_OK" = 1 ] && echo 0 || echo 1)
}

check_net() {
	# 测试/调试用：强制认为通或不通（CAMPUS_FORCE_OFFLINE=1 / CAMPUS_FORCE_ONLINE=1）
	[ "${CAMPUS_FORCE_OFFLINE:-0}" = 1 ] && return 1
	[ "${CAMPUS_FORCE_ONLINE:-0}" = 1 ] && return 0
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
		msg "    提示     : 外网已通（学校可能直接放行，或已认证过）"
		if ensure_auth_script && [ "$DRY_RUN" != 1 ]; then
			if [ -n "${CAMPUS_USER:-}" ] && [ -n "${CAMPUS_PASS:-}" ]; then
				msg "    顺手把账号存好并装好自动登录（掉线后自己补认证）"
				"$AUTH_SCRIPT" --quick "$CAMPUS_USER" "$CAMPUS_PASS" >/dev/null 2>&1
				msg "    已装：$AUTH_SCRIPT --status 可查看"
			else
				msg "    想让它掉线后自动补认证：  $AUTH_SCRIPT --quick 账号 密码"
			fi
		fi
	fi
else
	warn "还没通"
	if [ "${AUTH_REQUIRED:-1}" = 1 ]; then
		U="$(curl -s -m 8 -o /dev/null -w '%{redirect_url}' http://connect.rom.miui.com/generate_204 2>/dev/null)"
		[ -n "$U" ] && msg "    认证页地址：$U"
		msg ""
		msg "  ── 伪装已配好，接着做网页认证 ──"
		run_portal_auth
		if [ "${AUTH_OK:-0}" = 1 ]; then
			info "认证完成 ✅（网络伪装 + 网页认证 都已生效）"
		else
			warn "认证没成功，看上面的输出；常见原因：账号密码错 / 已欠费 / 学校在维护"
			msg "    重试：$AUTH_SCRIPT --quick 账号 密码"
			msg "    看状态：$AUTH_SCRIPT --status"
		fi
		if [ -n "${WIFI_UPLINK:-}${WIRELESS_UPLINK:-}" ]; then
			msg "    无线上联注意：STA 掉线重连后可能又要认证一次（--install-hook 的 cron 每 5 分钟兜底）"
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

# UA 改写自检。
# ⚠️ 注意：**不能**用"路由器自己 curl 一个站点、看页面里有没有某个字样"来判断 ——
#    ① UA-Mask/UA3F 都只处理 LAN 侧进来的流量（iifname br-lan），路由器自身的请求不过代理；
#    ② 以前那样 grep ua-check 页面里的 "UA3F" 字样是**假阳性**：那个站本身就叫 UA3F，HTML 里必然有。
# 真正有效的三个信号：服务在跑、核心配置生成正确、fw4 里的规则与"卸载集合"存在。
if [ "${UA_ENABLED:-0}" = 1 ] && [ "$DRY_RUN" != 1 ] && check_net; then
	info "UA 改写自检（$UA_IMPL，范围 ${UA_MODE_USED:-?}）"
	_ok=1
	if pgrep -f "$UA_IMPL" >/dev/null 2>&1; then msg "    ✅ $UA_IMPL 进程在跑"; else warn "    ❌ $UA_IMPL 进程没跑"; _ok=0; fi
	case "$UA_IMPL" in
	UAmask)
		if [ -f /var/run/UAmask/config.json ]; then
			msg "    ✅ 核心配置已生成：/var/run/UAmask/config.json"
			grep -o '"user_agent":"[^"]*"' /var/run/UAmask/config.json 2>/dev/null | head -1 | sed 's/^/       /'
		else warn "    ❌ 没有 /var/run/UAmask/config.json（生成失败，看 logread -e UAmask）"; _ok=0; fi
		if nft list set inet fw4 UAmask_bypass_set >/dev/null 2>&1; then
			msg "    ✅ fw4 里已有绕过集合 UAmask_bypass_set（非 HTTP 目标会被卸载到这里）"
			_n="$(nft list set inet fw4 UAmask_bypass_set 2>/dev/null | grep -c 'elements')"
			msg "       当前卸载项：$([ "$_n" -gt 0 ] && echo "有（见 nft list set inet fw4 UAmask_bypass_set）" || echo "还没有（LAN 设备产生非 HTTP 流量后会陆续出现）")"
		else warn "    ❌ fw4 里没有 UAmask 的规则 —— UA 不会被改写"; _ok=0; fi
		;;
	ua3f)
		[ -n "$(uget ua3f.main.header_rewrite)" ] && msg "    ✅ 规则表非空" || { warn "    ❌ 规则表是空的（LuCI「服务→UA3F」恢复默认规则）"; _ok=0; }
		;;
	esac
	# 真实改写效果只能在 LAN 侧验证（浏览器开 http://ua-check.stagoh.com/ 看 User-Agent）
	msg "    真实效果请用**电脑/手机**打开 http://ua-check.stagoh.com/ 看它显示的 User-Agent"
	msg "      期望值：${UA_STR:-$UAMASK_DEFAULT_UA}"
	[ "$_ok" = 1 ] || warn "    上面有 ❌，按提示处理后重跑本脚本"
fi

info "完成"
cat <<EOF
    以后要改：LuCI → 网络 → 接口 → 设备（MAC/MTU）／ 服务 → UA MASK（UA、匹配规则、放行名单、流量卸载）
    防识别分工：
      UA 改写（明文 HTTP 的 User-Agent）                                    → UA-Mask（服务 → UA MASK）
      TTL（全流量，含 ICMP/UDP）                                          → 内核 nft 规则 $TTL_FILE
      MAC 克隆、MTU                                                       → netifd（网络 → 接口 → 设备）
    TTL 规则状态：$([ "${TTL_BY_NFT:-0}" = 1 ] && echo "已写入（值 ${TTL_VALUE:-?}；改完 fw4 reload；删掉文件再 fw4 reload 就关掉）" || echo "本次没装")
    加速器/Steam 类流量：UA-Mask 会把"确认不是 HTTP"的目标自动卸载到内核
      （fw4 集合 UAmask_bypass_set，按 目标IP.端口 记录，IP 变了会重新学）
      如果某次还是不通，先看它有没有学进去：
        nft list set inet fw4 UAmask_bypass_set
      想跳过"学习期"：把该端口加进放行端口
        uci add_list UAmask.main.bypass_ports='端口号'; uci commit UAmask; /etc/init.d/UAmask restart
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
