#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-portal-auth.sh —— 校园网网页认证脚本
#
# 本文件的 3 处「← 抓包」已按**真实抓包**填好。下面这套流程来自一次实测抓包
# （2026-09-20，门户 http://10.30.100.5，三步 API、密码 MD5 后提交）：
#
#   GET  /                      → 种下会话 cookie（RAASSESSID）
#   POST /api/login.php         → {"ret":0,"data":{"type":0},"msg":""}
#   POST /api/ack_auth.php      → {"ret":0,"data":[],"msg":""}
#   POST /api/stat.php          → {"ret":0,"data":[],"msg":"认证成功！"}
#
#   三条 POST 的 body 完全相同：
#     user=<账号>&pass=<32位hex>&authmode=0&pool=&isp_id=0&pxyacct=
#
#   失败样本（第二次抓包实测，故意输错密码两次）：
#     {"ret":4,"data":{"type":0},"msg":"帐号密码不正确！"}   ← ret=4 就是密码错
#   认证成功后浏览器跳去 baidu.com：那是**页面 JS 自己跳的**（门户响应里没有任何 302/Location），
#     脚本不需要模拟这一步，能通外网就算成功。
#
# ⚠️ 唯一没定的事：pass 的哈希输入。同一账号两次成功登录提交的值**不同**：
#     18:25  pass=c88a20f6682da8c8f88f4f2f384400c6
#     18:58  pass=c3d33fb1c9bd665c5145226b23531e36
#   若这期间密码没改过 ⇒ 哈希里掺了"每次都变"的东西（页面里下发的盐/challenge），
#   那么 pass_mode=md5 不够用，得按认证页 JS 的算法来（例如 md5(盐+明文)）。
#   处理顺序：先 --hash-test 对比抓包里的值 → 对上就用对应 pass_mode；
#             对不上就把认证页 HTML/JS（GET http://门户地址/ 及其引用的 js）发来。
#
# 换学校怎么办：这个门户是"通用型"的（三步路径 / 字段名 / 固定字段 / 哈希方式全部可配），
#   正常情况只改 uci 就够了，不必改脚本：
#     uci set campus.main.auth_url='http://门户地址'
#     uci set campus.main.api_paths='/api/login.php,/api/ack_auth.php,/api/stat.php'
#     uci set campus.main.extra_fields='authmode=0&pool=&isp_id=0&pxyacct='
#     uci set campus.main.pass_mode='md5'        # plain|md5|md5user|md5passuser|md5md5|literal
#   参数含义见下面「取参数」一节。单接口的门户（如 srun）：api_paths 只留一个即可。
#
# 装在路由器上：/etc/campus-portal-auth.sh（chmod +x）
#   wget -O /etc/campus-portal-auth.sh <raw 链接> && chmod +x /etc/campus-portal-auth.sh
#
# 用法：
#   campus-portal-auth.sh                 # 已经在线就什么都不做；否则登录一次
#   campus-portal-auth.sh --force         # 强制走一次登录流程
#   campus-portal-auth.sh --quiet         # 静默（给 hotplug / cron 用）
#   campus-portal-auth.sh --quick 账号 密码   # ★傻瓜模式：一键配好+立刻认证+装自动登录
#   campus-portal-auth.sh --status           # 一句话报告：外网通不通、自动登录装没装
#   campus-portal-auth.sh --setup         # 交互填门户地址/账号/密码/哈希方式，存进 uci campus
#   campus-portal-auth.sh --hash-test     # 打印各种候选 MD5，用来和抓包里的 pass= 对比
#   campus-portal-auth.sh --diag          # 自检：uci 能不能读能写、参数到底从哪来、密码读到没有
#   campus-portal-auth.sh --install-hook  # 装「WAN 上线自动认证 + 每 5 分钟兜底」
#   campus-portal-auth.sh --uninstall-hook# 卸掉上面两样
#
# 约定（调用方按这个判断，别改）：
#   成功 exit 0（并且外网真的能通）／失败 exit 非 0／已经在线直接 exit 0（幂等）
#
# 参数来源：环境变量优先，其次 uci get campus.main.{auth_url,api_paths,user,pass,pass_mode,...}
#
set -u

HOOKDIR="${HOOKDIR:-/etc/hotplug.d/iface}"
HOOKFILE="$HOOKDIR/99-campus-portal"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
SELF="${SELF:-/etc/campus-portal-auth.sh}"
# 没有 uci 的机器（比如先在电脑上试）用这个文件存配置；--setup 会自动判断该写哪边
CONF="${CAMPUS_CONF:-/etc/campus-portal.conf}"
# --quick 用的默认门户地址（本门户实测地址；换学校：改这里，或 PORTAL=http://x.x.x.x 覆盖）
QUICK_PORTAL="${QUICK_PORTAL:-http://10.30.100.5}"
HAS_UCI=0
command -v uci >/dev/null 2>&1 && HAS_UCI=1
# 配置文件里全是 `: "${VAR:=值}"` 形式 —— 只在该变量还没设过时才赋值，所以环境变量仍然优先
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

say() { [ "${QUIET:-0}" = 1 ] || printf '%s\n' "$*"; }
log() { logger -t campus-portal "$*" 2>/dev/null || true; }
ug()  { [ "$HAS_UCI" = 1 ] && uci -q get "$1" 2>/dev/null; }
env_or_uci() {	# 优先级：环境变量/配置文件 > uci > 默认值
	eval "_v=\"\${$1:-}\""
	[ -z "$_v" ] && _v="$(ug "$2")"
	[ -z "$_v" ] && _v="$3"
	eval "$1=\"\$_v\""
}
# 地址归一化：用户常只填 10.30.100.5（不带协议），这里补 http://
normalize_url() {
	case "${1:-}" in
		'')    printf '' ;;
		*://*) printf '%s' "$1" ;;
		*)     printf 'http://%s' "$1" ;;
	esac
}
# 本机在该 WAN 口上的 IPv4（有些门户把客户端 IP 掺进哈希：md5(密码+IP)）。取不到就返回空
wan_ip() {
	for _i in "${WANIF:-}" wan wwan eth1; do
		[ -n "$_i" ] || continue
		_p="$(ip -4 -o addr show dev "$_i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
		[ -n "$_p" ] && { printf '%s' "$_p"; return 0; }
	done
	_p="$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*"address": *"\([0-9.]*\)".*/\1/p' | head -1)"
	printf '%s' "$_p"
}
# 门户主机名（不含协议与路径），例如 10.30.100.5:801
portal_host() { normalize_url "${PORTAL:-}" | sed 's|^[a-z][a-z]*://||; s|/.*$||'; }
# 本机 WAN 口的 MAC（校园网"IP 绑 MAC"时，门户的哈希里常常掺它）
wan_mac() {
	for _i in "${WANIF:-}" wan wwan eth1; do
		[ -n "$_i" ] || continue
		_m=""
		[ -r "/sys/class/net/$_i/address" ] && _m="$(cat "/sys/class/net/$_i/address" 2>/dev/null)"
		[ -z "$_m" ] && _m="$(ip link show "$_i" 2>/dev/null | awk '/link\/ether/{print $2; exit}')"
		[ -n "$_m" ] && { printf '%s' "$_m"; return 0; }
	done
	printf ''
}
mac_nosep() { printf '%s' "$1" | tr -d ':-' | tr 'A-F' 'a-f'; }

# 在线判定（幂等）：能拿到 204 或 ping 通就算在线
online() {
	[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "${CHECK_URL:-}" 2>/dev/null)" = "204" ] && return 0
	[ "${PING_TARGET:-}" = "-" ] && return 1
	ping -c 1 -W 2 "${PING_TARGET:-223.5.5.5}" >/dev/null 2>&1 && return 0
	return 1
}
md5hex() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

# ---------------------------------------------------------------- RAAS 门户的 pass 算法（已逆向确认）
# 2026-09-21 从门户自己的 JS 里挖出来的（/assets/js/crypto.js 里的 CryptoJS + /tp/school/js/index.js 的 encode()）：
#   p   = 4 个随机字符（取自 "A-Za-z0-9+" 共 61 个字符，服务端会丢掉这 4 位）
#   pass= hex( AES-128-ECB( key="5a3b9f207411a8ed"(16 字节 ASCII), 明文 = p + 密码, ZeroPadding ) )
# 例：p="vh8z" 密码="213511" → fc824d7f244805c56634c66e16ded895（用户抓包里能用那串）
# 所以它不是哈希而是**加密**：同一个密码每次算出来都不同（前缀随机），服务端解出来丢掉前 4 位即可。
# 依此：硬编码一个值也能长期用（只要密码不改），但本函数让脚本每次自己算，改密码/换机都不用手工维护。
RAAS_KEY="${RAAS_KEY:-5a3b9f207411a8ed}"
RAAS_ALPHA='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+'

# 把二进制转成小写 hex。本仓库固件的 busybox **没有编 od**（真机实测 "od: not found"），
# 所以这里按可用性依次回退：od → hexdump -e → hexdump -C → base64+awk（coreutils-base64 固件自带）。
# 每种都用真实字节探测一次，探测通过才用它 —— 不同固件编的 applet 不一样，硬编码某一个必翻车。
hexify() {
	if command -v od >/dev/null 2>&1; then
		if [ "$(printf '\001' | od -An -tx1 | tr -d ' \n')" = "01" ]; then od -An -tx1 | tr -d ' \n'; return 0; fi
	fi
	if command -v hexdump >/dev/null 2>&1; then
		if [ "$(printf '\001\002' | hexdump -v -e '1/1 "%02x"' 2>/dev/null)" = "0102" ]; then
			hexdump -v -e '1/1 "%02x"'; return 0
		fi
		if printf '\001\002' | hexdump -v -C 2>/dev/null | grep -q '01 02'; then
			# canonical 格式：<偏移> 01 02 ... |ascii|  → 只留中间那串 hex
			sed 's/^[0-9a-fA-F]*  *//; s/  *|.*$//' | tr -d ' \n'; return 0
		fi
	fi
	if command -v base64 >/dev/null 2>&1; then
		base64 | awk '
			BEGIN { B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
			{
				for (i = 1; i <= length($0); i++) {
					v = index(B64, substr($0, i, 1)) - 1
					if (v < 0) continue
					n = n * 64 + v; bits += 6
					if (bits >= 8) { bits -= 8; printf "%02x", int(n / 2^bits) % 256; n = n % 2^bits }
				}
			}'
		return 0
	fi
	return 1
}

raas_encode() {	# raas_encode <明文密码> → 32 位 hex；失败原因写进 RAAS_ERR
	RAAS_ERR=""
	if ! command -v openssl >/dev/null 2>&1; then RAAS_ERR="没有 openssl（装 openssl-util）"; return 1; fi
	_keyhex="$(printf '%s' "$RAAS_KEY" | hexify 2>/dev/null)"
	if [ -z "$_keyhex" ]; then RAAS_ERR="没有可用的 hex 转换工具（od/hexdump/base64 都没有）"; return 1; fi
	_nonce=''
	_i=0
	while [ "$_i" -lt 4 ]; do
		_r="$(hexdump -v -n 1 -e '"%u"' /dev/urandom 2>/dev/null)"
		[ -n "$_r" ] || _r="$(printf '%s' "$(date +%N 2>/dev/null)" | sed 's/[^0-9]//g' | cut -c1-3)"
		[ -n "$_r" ] || _r=$(( ($$ + _i) % 256 ))
		_nonce="$_nonce$(printf '%s' "$RAAS_ALPHA" | cut -c$(( _r % 61 + 1 )))"
		_i=$((_i + 1))
	done
	_plain="$_nonce$1"
	_pad=$(( (16 - ${#_plain} % 16) % 16 ))
	_i=0
	{ printf '%s' "$_plain"
	  while [ "$_i" -lt "$_pad" ]; do printf '\0'; _i=$((_i + 1)); done
	} | openssl enc -aes-128-ecb -K "$_keyhex" -nopad 2>/dev/null | hexify
}

# 写校园网配置：**直接写 /etc/config/campus**，不用 `uci set cfg.sec=type` 那套建段语法。
# 为什么（2026-09-21 真机实测）：ImmortalWrt 25.12 的 uci CLI 上 `uci set campus.main='main'`
# 及其后续的 `uci set campus.main.x=y` 全部报 "uci: Entry not found"，commit 也失败 —— 整条链写不进去。
# 直接写文件 + 读回校验最稳：读回来对得上才算成功（写错了不会谎报）。
uci_escape() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# CAMPUS_UCI_FILE 可覆盖（默认 /etc/config/campus），仅供测试/多份配置共存时用
write_campus_config() {	# write_campus_config <portal> <user> <pass> [pass_mode] [api_paths] [extra_fields] [pre_paths]
	_f="${CAMPUS_UCI_FILE:-/etc/config/campus}"
	_p="$(uci_escape "${1:-}")"; _u="$(uci_escape "${2:-}")"; _w="$(uci_escape "${3:-}")"
	_m="$(uci_escape "${4:-raas}")"
	_ap="$(uci_escape "${5:-/api/login.php,/api/stat.php,/api/ack_auth.php}")"
	_ex="$(uci_escape "${6:-authmode=0&pool=&isp_id=0&pxyacct=}")"
	_pre="$(uci_escape "${7:-/api/ip.php}")"
	_tmp="$_f.tmp.$$"
	{
		printf '%s\n' '# 由 campus-portal-auth.sh 生成（--quick/--setup）；含明文密码，权限 600'
		printf '%s\n' "config main 'main'"
		printf "\toption auth_url '%s'\n" "$_p"
		printf "\toption user '%s'\n" "$_u"
		printf "\toption pass '%s'\n" "$_w"
		printf "\toption pass_mode '%s'\n" "$_m"
		printf "\toption api_paths '%s'\n" "$_ap"
		printf "\toption extra_fields '%s'\n" "$_ex"
		printf "\toption pre_paths '%s'\n" "$_pre"
	} > "$_tmp" || return 1
	mv -f "$_tmp" "$_f" || { rm -f "$_tmp"; return 1; }
	chmod 600 "$_f" 2>/dev/null
	# 读回校验（uci 只负责解析这个文件；就算它的 commit 不支持也不影响）
	if command -v uci >/dev/null 2>&1; then
		[ "$(uci -q get campus.main.pass 2>/dev/null)" = "$3" ] || return 1
		uci -q commit campus 2>/dev/null || true
	fi
	return 0
}

# 装自动登录：WAN 一上线就认证 + 每 5 分钟兜底（--quick 与 --install-hook 共用）
do_install_hook() {
	if [ "$HAS_UCI" != 1 ] && [ "${FORCE_HOOK:-0}" != 1 ]; then
		echo "⚠️  本机没有 uci（不是路由器），跳过自动登录的安装" >&2
		return 2
	fi
	[ -x "$SELF" ] || { echo "先把自己放到 $SELF 并 chmod +x：wget -O $SELF <raw> && chmod +x $SELF"; exit 1; }
	mkdir -p "$HOOKDIR"
	cat > "$HOOKFILE" <<-EOF
	#!/bin/sh
	# 由 campus-portal-auth.sh --install-hook 生成：WAN 一上线就认证
	[ "\${ACTION:-}" = "ifup" ] || exit 0
	case "\${INTERFACE:-}" in
		wan|wwan) ;;
		*) [ "\${INTERFACE:-}" = "\$(uci -q get campus.main.iface)" ] || exit 0 ;;
	esac
	[ -x "$SELF" ] || exit 0
	( i=1; while [ "\$i" -le 3 ]; do
		sleep 5
		"$SELF" --quiet && { logger -t campus-portal "认证成功（第 \$i 次）"; exit 0; }
		logger -t campus-portal "第 \$i 次认证失败，重试"; i=\$((i + 1))
	  done
	  logger -t campus-portal "认证 3 次都失败，看 logread | grep campus-portal" ) &
	EOF
	chmod +x "$HOOKFILE"
	grep -q "campus-portal-auth.sh" "$CRONTAB_FILE" 2>/dev/null || {
		mkdir -p "$(dirname "$CRONTAB_FILE")"
		echo "*/5 * * * * $SELF --quiet" >> "$CRONTAB_FILE"
	}
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
	echo "已装：$HOOKFILE（WAN 上线认证）+ $CRONTAB_FILE（每 5 分钟兜底）"
}

# ---------------------------------------------------------------- 子命令
case "${1:-}" in
--diag|--show-config)
	echo "== 环境 =="
	echo "  脚本: $SELF"
	echo "  uci : $(command -v uci 2>/dev/null || echo '（没有！不是路由器？）')   HAS_UCI=$HAS_UCI"
	echo "  配置文件: $CONF $([ -f "$CONF" ] && echo '（存在）' || echo '（不存在）')"
	[ "$HAS_UCI" = 1 ] && { echo; echo "== uci show campus =="; uci show campus 2>&1 | sed 's/^/  /' || true; }
	[ -f "$CONF" ] && { echo; echo "== $CONF =="; sed 's/^/  /' "$CONF"; }
	echo; echo "== /etc/config/campus 与磁盘 =="
	ls -l /etc/config/campus 2>&1 | sed 's/^/  /' || true
	df -h /overlay /etc 2>/dev/null | sed 's/^/  /' || true
	if [ "$HAS_UCI" = 1 ]; then
		echo; echo "== uci 写入自检（写个临时键再读回来）=="
		if uci set campus.main.__probe=1 2>&1 | sed 's/^/  /' && uci commit campus 2>&1 | sed 's/^/  /'; then
			PB="$(uci -q get campus.main.__probe)"
			uci -q delete campus.main.__probe 2>/dev/null; uci -q commit campus 2>/dev/null
			if [ "$PB" = 1 ]; then
				echo "  ✅ uci 可读可写（那 --setup 保存失败就不是 uci 的问题）"
			else
				echo "  ❌ 写进去了但读回来是「${PB:-空}」→ commit 没落地（overlay 满/只读/配置损坏）"
			fi
		else
			echo "  ❌ uci set/commit 直接失败（看上面报错）"
		fi
	fi
	echo; echo "== 脚本实际取到的参数（来源：环境变量/配置文件 > uci > 默认）=="
	env_or_uci PORTAL      campus.main.auth_url  ''
	env_or_uci CAMPUS_USER campus.main.user      ''
	env_or_uci CAMPUS_PASS campus.main.pass      ''
	env_or_uci PASS_MODE   campus.main.pass_mode 'md5'
	env_or_uci API_PATHS   campus.main.api_paths ''
	printf '  门户地址 : %s\n' "${PORTAL:-（空！跑 --setup）}"
	printf '  账号     : %s\n' "${CAMPUS_USER:-（空！）}"
	printf '  密码     : %s\n' "$([ -n "$CAMPUS_PASS" ] && echo "已读到（${#CAMPUS_PASS} 字符）" || echo '（空！← 这就是 --hash-test 说"还没配密码"的原因）')"
	printf '  哈希方式 : %s\n' "${PASS_MODE:-md5}"
	printf '  认证路径 : %s\n' "${API_PATHS:-（用脚本内置默认）}"
	exit 0
	;;
--quick|--onekey)
	# 傻瓜模式：只给账号密码，其余全部按本门户的实测参数配好，然后立刻认证并装自动登录
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	U="${2:-}"; P="${3:-}"
	[ -n "$U" ] || { printf '认证账号: '; read -r U; }
	if [ -z "$P" ]; then
		printf '认证密码: '
		stty -echo 2>/dev/null; read -r P; stty echo 2>/dev/null; echo
	fi
	[ -n "$U" ] && [ -n "$P" ] || { echo "账号和密码都不能空"; exit 2; }
	A="$(normalize_url "${PORTAL:-$QUICK_PORTAL}")"
	[ -n "$A" ] || { echo "没配门户地址：换学校时用 PORTAL=http://x.x.x.x $SELF --quick 账号 密码"; exit 2; }
	echo "门户 $A ／ 账号 $U ／ 密码处理 raas（AES）"
	if [ "$HAS_UCI" = 1 ]; then
		write_campus_config "$A" "$U" "$P" raas \
			'/api/login.php,/api/stat.php,/api/ack_auth.php' 'authmode=0&pool=&isp_id=0&pxyacct=' '/api/ip.php' \
			|| { echo "❌ 写 /etc/config/campus 失败（或读回来对不上）" >&2; exit 1; }
		echo "✅ 已保存到 /etc/config/campus（读回校验通过）"
	else
		{ printf '# 由 %s --quick 生成（本机没有 uci）\n' "$SELF"
		  printf ': "${PORTAL:=%s}"\n' "$A"
		  printf ': "${CAMPUS_USER:=%s}"\n' "$U"
		  printf ': "${CAMPUS_PASS:=%s}"\n' "$P"
		  printf ': "${PASS_MODE:=raas}"\n'
		  printf ': "${API_PATHS:=/api/login.php,/api/stat.php,/api/ack_auth.php}"\n'
		  printf ': "${EXTRA_FIELDS:=authmode=0&pool=&isp_id=0&pxyacct=}"\n'
		  printf ': "${PRE_PATHS:=/api/ip.php}"\n'
		  :
		} > "$CONF" || { echo "❌ 写 $CONF 失败" >&2; exit 1; }
		chmod 600 "$CONF"
		echo "✅ 已保存到 $CONF"
	fi
	FORCE=1; QUICK=1
	;;
--status)
	env_or_uci CHECK_URL   campus.main.check_url  'http://connect.rom.miui.com/generate_204'
	env_or_uci PING_TARGET campus.main.ping_check '223.5.5.5'
	env_or_uci CAMPUS_USER campus.main.user      ''
	if online; then
		echo "✅ 外网是通的（不需要认证）"
	else
		echo "❌ 外网不通 —— 需要认证："
		echo "     $SELF --quick <账号> <密码>     # 一键配好并马上登录"
	fi
	if [ -f "$CRONTAB_FILE" ] && grep -q campus-portal-auth "$CRONTAB_FILE" 2>/dev/null; then
		echo "    自动登录：已装 ✅"
	else
		echo "    自动登录：未装（跑 $SELF --quick 账号 密码 或 $SELF --install-hook）"
	fi
	[ "$CAMPUS_USER" ] && echo "    已保存账号：$CAMPUS_USER" || echo "    还没配账号"
	logread 2>/dev/null | grep campus-portal | tail -3 | sed 's/^/    /'
	exit 0
	;;
--setup)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	printf '门户地址（浏览器打开认证页时的地址，例如 http://10.30.100.5，也可只填 IP）: '; read -r A
	printf '认证账号（学号/上网账号）: '; read -r U
	printf '认证密码（明文，脚本会按哈希方式自己算）: '; read -r P
	printf '密码处理方式 [直接回车=raas（本门户的 AES 方案）/ precomputed（直接给 32 位值）/ md5 / plain]: '; read -r M
	printf '三步认证路径 [直接回车=/api/login.php,/api/ack_auth.php,/api/stat.php]: '; read -r PATHS
	printf '固定字段 [直接回车=authmode=0&pool=&isp_id=0&pxyacct=]: '; read -r EX
	A_RAW="$A"
	A="$(normalize_url "$A_RAW")"
	case "$A_RAW" in
		''|*://*) ;;
		*) echo "门户地址没带协议，已按 $A 处理" ;;
	esac
	if [ "$HAS_UCI" = 1 ]; then
		# 直接写文件（见 write_campus_config 的注释：25.12 的 uci set 建段会报 Entry not found）
		write_campus_config "$A" "$U" "$P" "${M:-raas}" "${PATHS:-}" "${EX:-}" "" \
			|| { echo "❌ 写 /etc/config/campus 失败（或读回来对不上，看上面报错）" >&2; exit 1; }
		echo "已保存到 /etc/config/campus（读回校验通过），门户地址=$A，账号=$U"
	else
		# 没有 uci：写一个可 source 的配置文件（电脑上先用它验证，注意不是路由器）
		{
			printf '# 由 campus-portal-auth.sh --setup 生成（本机没有 uci）\n'
			printf '# 只在该变量还没设过时才赋值，所以命令行上的环境变量仍然优先\n'
			[ -n "$A" ] && printf ': "${PORTAL:=%s}"\n' "$A"
			[ -n "$U" ] && printf ': "${CAMPUS_USER:=%s}"\n' "$U"
			[ -n "$P" ] && printf ': "${CAMPUS_PASS:=%s}"\n' "$P"
			printf ': "${PASS_MODE:=%s}"\n' "${M:-raas}"
			[ -n "${PATHS:-}" ] && printf ': "${API_PATHS:=%s}"\n' "$PATHS"
			[ -n "${EX:-}" ] && printf ': "${EXTRA_FIELDS:=%s}"\n' "$EX"
			:	# 保证整块以成功状态结束（上面的 && 短路会返回 1）
		} > "$CONF" || { echo "❌ 写 $CONF 失败" >&2; exit 1; }
		chmod 600 "$CONF"
		echo "⚠️  本机没有 uci（不是路由器？），已改存到 $CONF（权限 600）"
		echo "    在这台机器上跑认证/测试没问题；要装成开机自动认证请把脚本搬到路由器上再 --setup"
	fi
	echo "提示：下一步跑 --force 真连一次门户看结果；--hash-test 只用于和**同账号**的抓包比对"
	exit 0
	;;
--encode)
	# 手动算一次 RAAS 的 pass 值：campus-portal-auth.sh --encode 明文密码
	[ -n "${2:-}" ] || { echo "用法: $SELF --encode <明文密码>"; exit 2; }
	V="$(raas_encode "$2")"
	if [ -z "$V" ]; then
		echo "算不了：${RAAS_ERR:-未知原因}。两个替代办法：" >&2
		echo "  1) 路由器上：opkg/apk 装 openssl-util（本仓库固件已自带）" >&2
		echo "  2) 任何机器：打开门户登录页 → F12 控制台 → 输入 encode('明文密码') → 得到 32 位值，" >&2
		echo "     再 uci set campus.main.pass_mode=precomputed; uci set campus.main.pass=<那串>" >&2
		exit 1
	fi
	echo "pass 值 : $V"
	echo "（可直接用：uci set campus.main.pass_mode=precomputed; uci set campus.main.pass=$V）"
	exit 0
	;;
--hash-test)
	env_or_uci CAMPUS_USER campus.main.user ''
	env_or_uci CAMPUS_PASS campus.main.pass ''
	if [ -z "$CAMPUS_PASS" ]; then
		echo "还没配密码。两种情况："
		echo "  · 在路由器上：$SELF --setup（写进 uci）"
		echo "  · 在电脑上（没有 uci）：直接给环境变量，例如"
		echo "      CAMPUS_USER=05261241 CAMPUS_PASS=你的明文密码 sh $SELF --hash-test"
		exit 2
	fi
	echo "账号: ${CAMPUS_USER:-（未配）}"
	EXPECT="${2:-}"		# 可选：直接给出抓包里的哈希，命中会标出来
	[ -n "$EXPECT" ] && echo "要比对的已知哈希: $EXPECT"
	env_or_uci WANIF campus.main.iface 'wan'
	env_or_uci PORTAL campus.main.auth_url ''
	IP="$(wan_ip)"; PH="$(portal_host)"; MAC="$(wan_mac)"
	echo "本机 WAN IPv4: ${IP:-（取不到）}   WAN MAC: ${MAC:-（取不到）}   门户主机: ${PH:-（未配）}"
	echo
	HIT=0
	try_hash() {	# try_hash <pass_mode 名字> <哈希>
		[ -n "${2:-}" ] || return 0
		if [ -n "$EXPECT" ] && [ "$2" = "$EXPECT" ]; then
			printf '  %-14s %s   ← ✅ 命中\n' "$1" "$2"
			HIT=1
		else
			printf '  %-14s %s\n' "$1" "$2"
		fi
	}
	echo "逐行和抓包 POST body 里 pass= 后面的值对比（也可以在命令后面直接跟目标哈希）："
	try_hash md5          "$(md5hex "$CAMPUS_PASS")"
	try_hash md5user      "$(md5hex "$CAMPUS_USER$CAMPUS_PASS")"
	try_hash md5passuser  "$(md5hex "$CAMPUS_PASS$CAMPUS_USER")"
	try_hash md5md5       "$(md5hex "$(md5hex "$CAMPUS_PASS")")"
	try_hash md5passip    "$(md5hex "$CAMPUS_PASS$IP")"
	try_hash md5ippass    "$(md5hex "$IP$CAMPUS_PASS")"
	try_hash md5passhost  "$(md5hex "$CAMPUS_PASS$PH")"
	try_hash md5passmac   "$(md5hex "$CAMPUS_PASS$MAC")"
	try_hash md5macpass   "$(md5hex "$MAC$CAMPUS_PASS")"
	try_hash md5passmacns "$(md5hex "$CAMPUS_PASS$(mac_nosep "$MAC")")"
	try_hash md5passipmac "$(md5hex "$CAMPUS_PASS$IP$MAC")"
	try_hash md5passmacip "$(md5hex "$CAMPUS_PASS$MAC$IP")"
	try_hash MD5UPPER     "$(md5hex "$CAMPUS_PASS" | tr 'a-f' 'A-F')"
	echo
	if [ "$HIT" = 1 ]; then
		echo "✅ 命中上面标出来的那个 —— 执行："
		echo "   uci set campus.main.pass_mode=<命中的名字> && uci commit campus && $SELF --force"
		exit 0
	fi
	if [ -n "$EXPECT" ]; then
		echo "❌ 与这个哈希都不匹配 —— 说明盐不是 IP/MAC/账号/门户这些常量。"
		echo "   下一步：把门户下发的随机盐找出来（认证页的 JS）"
		exit 1
	fi
	echo "对上哪个就：uci set campus.main.pass_mode=<左边那个名字>; uci commit campus"
	echo "一个都对不上：说明盐不是上面这些（可能是页面下发的随机数），"
	echo "  → 用浏览器打开 http://门户地址/ 按 Ctrl+F5 强制刷新（绕过缓存，js 才会重新下载），"
	echo "    同时用 Burp 抓这次页面加载，把新抓到的 js 发我；或直接 Ctrl+U 看源码搜 md5/encrypt"
	echo "⚠️ 别拿不同账号的抓包比对；也别连续盲试密码（有些门户会锁账号）"
	exit 0
	;;

--install-hook)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	do_install_hook && exit 0
	exit 2
	;;
--uninstall-hook)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	rm -f "$HOOKFILE"
	if [ -f "$CRONTAB_FILE" ]; then
		sed -i '/campus-portal-auth\.sh/d' "$CRONTAB_FILE"
		[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
	fi
	echo "已卸载自动认证"
	exit 0
	;;
--force) FORCE=1 ;;
--quiet) QUIET=1 ;;
--help|-h) sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
"") FORCE=0 ;;
*) echo "未知参数：$1（用 --help 看用法）" >&2; exit 1 ;;
esac
FORCE="${FORCE:-0}"; QUIET="${QUIET:-0}"

# ---------------------------------------------------------------- 取参数
# PORTAL：门户基地址（不带路径），例如 http://10.30.100.5
env_or_uci PORTAL       campus.main.auth_url     ''					# ← 抓包①：门户地址
# 按顺序提交的接口路径，逗号分隔。单接口门户就写一个（如 /srun_portal）
# 顺序来源：①浏览器抓包是 login → ack_auth → stat；②实测可用的手写脚本是 login → stat → ack_auth。
# 两者都能通过认证 ⇒ 后两步顺序不敏感。这里默认用②（实测过的那份）。
env_or_uci API_PATHS    campus.main.api_paths    '/api/login.php,/api/stat.php,/api/ack_auth.php'	# ← 抓包②：流程
env_or_uci EXTRA_FIELDS campus.main.extra_fields 'authmode=0&pool=&isp_id=0&pxyacct='			# ← 抓包③：固定字段
env_or_uci USER_FIELD   campus.main.user_field   'user'
env_or_uci PASS_FIELD   campus.main.pass_field   'pass'
env_or_uci PASS_MODE    campus.main.pass_mode    'raas'	# raas=AES(前缀+密码) | precomputed=直接给 32 位值 | plain/md5/...
env_or_uci PASS_MD5     campus.main.pass_md5     ''	# 设置后直接用这串，跳过哈希（应急用）
env_or_uci PRE_GET      campus.main.pre_get      '1'	# 1=先 GET 首页拿会话 cookie
# 登录前要 POST 的接口（空 body，只为拿会话/让服务端记住本机 IP）。实测门户是 /api/ip.php；
# 不需要就设成空：uci set campus.main.pre_paths=''
env_or_uci PRE_PATHS    campus.main.pre_paths    '/api/ip.php'	# ← 抓包⑤：登录前的前置请求
env_or_uci CHECK_URL    campus.main.check_url    'http://connect.rom.miui.com/generate_204'
env_or_uci PING_TARGET  campus.main.ping_check   '223.5.5.5'	# 设为 - 则不用 ping 兜底
env_or_uci CAMPUS_USER  campus.main.user         ''
env_or_uci CAMPUS_PASS  campus.main.pass         ''
env_or_uci UA           campus.main.ua           ''
env_or_uci WANIF        campus.main.iface        'wan'
COOKIE="${COOKIE:-/tmp/campus-portal.cookie}"

# ---------------------------------------------------------------- 密码哈希
pass_value() {	# 输出要提交的 pass 值（抓包里 pass= 后面那个）
	if [ -n "$PASS_MD5" ]; then printf '%s' "$PASS_MD5"; return 0; fi
	case "$PASS_MODE" in
		raas)          raas_encode "$CAMPUS_PASS" ;;
		precomputed)   printf '%s' "$CAMPUS_PASS" ;;	# 直接提交已算好的 32 位值
		plain|literal) printf '%s' "$CAMPUS_PASS" ;;
		md5)           md5hex "$CAMPUS_PASS" ;;
		md5user)       md5hex "$CAMPUS_USER$CAMPUS_PASS" ;;
		md5passuser)   md5hex "$CAMPUS_PASS$CAMPUS_USER" ;;
		md5md5)        md5hex "$(md5hex "$CAMPUS_PASS")" ;;
		md5passip)     md5hex "$CAMPUS_PASS$(wan_ip)" ;;
		md5ippass)     md5hex "$(wan_ip)$CAMPUS_PASS" ;;
		md5passhost)   md5hex "$CAMPUS_PASS$(portal_host)" ;;
		md5passmac)    md5hex "$CAMPUS_PASS$(wan_mac)" ;;
		md5macpass)    md5hex "$(wan_mac)$CAMPUS_PASS" ;;
		md5passmacns)  md5hex "$CAMPUS_PASS$(mac_nosep "$(wan_mac)")" ;;
		md5passipmac)  md5hex "$CAMPUS_PASS$(wan_ip)$(wan_mac)" ;;
		md5passmacip)  md5hex "$CAMPUS_PASS$(wan_mac)$(wan_ip)" ;;
		*)             printf '%s' "$CAMPUS_PASS" ;;
	esac
}

if [ "$FORCE" != 1 ] && online; then
	say "已经在线，不用登录"
	exit 0
fi

[ -n "$PORTAL" ] || { say "没配门户地址：跑 $SELF --setup，或 uci set campus.main.auth_url=http://门户地址"; exit 2; }
[ -n "$CAMPUS_USER" ] || { say "没配账号：跑 $SELF --setup，或 uci set campus.main.user=..."; exit 2; }
# 归一化：补协议（uci/配置里可能只存了 10.30.100.5）+ 去掉尾斜杠
PORTAL="$(normalize_url "$PORTAL")"
PORTAL="${PORTAL%/}"
case "$PORTAL" in
	http://*|https://*) ;;
	*) say "门户地址看着不对：$PORTAL（应为 http(s)://主机[:端口]）"; exit 2 ;;
esac

# 用函数而不是拼字符串：UA 里有空格，拼字符串会被 shell 拆成多个参数
curl_auth() {
	if [ -n "$UA" ]; then curl -s -m 15 -k -A "$UA" "$@"
	else curl -s -m 15 -k "$@"; fi
}

# JSON 小工具（BusyBox 没有 jq，用 sed 够用）
json_strip_jsonp() {
	case "$(printf '%s' "$1" | tr -d ' \t\r\n')" in
		'{'*|'['*) printf '%s' "$1" ;;
		*'('*')'*) printf '%s' "$1" | sed 's/^[^(]*(//; s/)[[:space:]]*;*[[:space:]]*$//' ;;
		*)         printf '%s' "$1" ;;
	esac
}
json_num() { printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\":\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1; }
json_str() { printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -1; }

# ---------------------------------------------------------------- 1) 前置请求：拿会话 cookie / 让服务端记住本机 IP
#    ① GET 门户首页：抓包里三条 POST 都带 Cookie: RAASSESSID=…，这个 cookie 就来自首页那次 GET
#    ② POST 前置接口（实测门户是 /api/ip.php，空 body）：名字就叫 ip，怀疑服务端据此记录客户端 IP
if [ "$PRE_GET" = 1 ]; then
	rm -f "$COOKIE"
	if curl_auth -c "$COOKIE" -b "$COOKIE" -o /dev/null "$PORTAL/" 2>/dev/null; then
		say "已 GET $PORTAL/（拿会话 cookie）"
	else
		say "首页 GET 失败，继续"
	fi
fi
for _pre in $(printf '%s' "$PRE_PATHS" | tr ',' ' '); do
	[ -n "$_pre" ] || continue
	case "$_pre" in /*) _purl="$PORTAL$_pre" ;; *) _purl="$PORTAL/$_pre" ;; esac
	PRERESP="$(curl_auth -b "$COOKIE" -c "$COOKIE" 		-H 'X-Requested-With: XMLHttpRequest' 		-H "Referer: $PORTAL/" -H "Origin: $PORTAL" 		-X POST --data '' "$_purl" 2>/dev/null)"
	say "前置 $_pre → $(printf '%s' "$PRERESP" | head -c 200)"
done

# ---------------------------------------------------------------- 2) 按顺序提交（本项目是三步）
PASSV="$(pass_value)"
say "提交账号 ${CAMPUS_USER}（pass=${PASS_MODE}${PASS_MD5:+，用 uci 里指定的哈希}）"

# 门户自己的 JS（raas.js）里的语义，照抄过来：
#   login.php: ret 0/3/121/122 → 继续（它把 3/121/122 都当成功，然后调 ack_auth）；ret 4 → 账号密码不正确
#   stat.php : ret 2/3/4 → 还在处理中，继续轮询（JS 里 timeout 默认 10 次）
RET_ACCEPT="0 3 121 122"
RET_RETRY="2 3 4"
RET_MAX_TRY="${RET_MAX_TRY:-6}"
RET_SLEEP="${RET_SLEEP:-3}"
ret_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

STEP=0
TOTAL_STEPS=$(printf '%s' "$API_PATHS" | tr ',' ' ' | wc -w)
LAST_MSG=""; LAST_RET=""; LAST_TYPE=""; OK_MSG=""; FAILED=0
for _path in $(printf '%s' "$API_PATHS" | tr ',' ' '); do
	[ -n "$_path" ] || continue
	STEP=$((STEP + 1))
	case "$_path" in /*) _url="$PORTAL$_path" ;; *) _url="$PORTAL/$_path" ;; esac
	_try=0
	while :; do
		_try=$((_try + 1))
		RESP="$(curl_auth -b "$COOKIE" -c "$COOKIE" \
			-H 'X-Requested-With: XMLHttpRequest' \
			-H "Referer: $PORTAL/" -H "Origin: $PORTAL" \
			-X POST "$_url" \
			--data-urlencode "$USER_FIELD=$CAMPUS_USER" \
			--data-urlencode "$PASS_FIELD=$PASSV" \
			--data "$EXTRA_FIELDS" \
			2>/dev/null)"
		RESP="$(json_strip_jsonp "$RESP")"
		RET="$(json_num "$RESP" ret)"
		MSG="$(json_str "$RESP" msg)"
		TYPE="$(json_num "$RESP" type)"
		say "  [$STEP/$TOTAL_STEPS] $_path → ret=${RET:-?} msg=${MSG:-（空）}${TYPE:+ type=$TYPE}$([ "$_try" -gt 1 ] && echo "（第 $_try 次）")"
		LAST_MSG="$MSG"; LAST_RET="$RET"; LAST_TYPE="$TYPE"
		case "$MSG" in
			*'成功'*|*'success'*|*'SUCCESS'*|*'已在线'*) OK_MSG="$MSG" ;;
		esac
		[ -z "$RET" ] && break			# 没 ret 字段：交给后面的连通性判定
		ret_in "$RET" "$RET_ACCEPT" && break	# 0/3/121/122 = 已接受，继续下一步
		# 第一步（login）返回 4 = 账号密码不正确（两次错密码实测都是 4）
		if [ "$STEP" = 1 ] && [ "$RET" = 4 ]; then
			say "账号或密码不正确（ret=4 msg=$MSG）"
			say "  → 密码没输错的话，用 --hash-test 核对密码处理方式；或换 --setup 重新填一次"
			log "auth rejected at $(_path): ret=4 (bad credentials)"
			FAILED=1
			break
		fi
		# 后续步骤（stat/ack）返回 2/4/3 = 还在处理中 → 等一会再问（门户 JS 也是这么轮询的）
		if ret_in "$RET" "$RET_RETRY" && [ "$_try" -lt "$RET_MAX_TRY" ]; then
			say "    处理中（ret=$RET $MSG），${RET_SLEEP} 秒后再问一次"
			sleep "$RET_SLEEP"
			continue
		fi
		say "认证被拒绝：$_path 返回 ret=$RET msg=$MSG"
		log "auth rejected at step $STEP ($_path): ret=$RET msg=$MSG"
		FAILED=1
		break
	done
	[ "$FAILED" = 1 ] && break
done

[ "$FAILED" = 1 ] && exit 1
[ "$STEP" -gt 0 ] || { say "没有可提交的接口（检查 campus.main.api_paths）"; exit 2; }

# ---------------------------------------------------------------- 3) 判定成功 ← 抓包④：成功标志
#    实测：最后一步 stat.php 的 msg 是「认证成功！」，且所有步骤 ret=0。
#    失败样本还没抓到，所以这里采取"ret 非 0 即失败（上面已判）+ 特征串/连通性判成功"的双保险。
case "${OK_MSG:-$LAST_MSG}" in
	*'成功'*|*'success'*|*'SUCCESS'*|*'已在线'*|*'ok'*|*'OK'*)
		say "响应含成功标志（msg=${OK_MSG:-$LAST_MSG}）";;
	*)
		say "响应里没有明确的成功字样，用连通性兜底判断…"
		sleep 2
		if ! online; then
			say "认证失败：检查账号密码 / 哈希方式（用 --hash-test 对比抓包）/ 字段名"
			log "auth failed: step=$STEP ret=${LAST_RET:-?} msg=$LAST_MSG"
			exit 1
		fi
		;;
esac

# ---------------------------------------------------------------- 4) 连通性二次确认
sleep 2
if online; then
	say "认证成功 ✅"
	log "auth ok (user=$CAMPUS_USER portal=$PORTAL steps=$STEP msg=${OK_MSG:-$LAST_MSG})"
	if [ "${QUICK:-0}" = 1 ]; then
		say ""
		if do_install_hook; then
			say "✅ 已装好自动登录：插上网线/重启都会自动认证，掉线每 5 分钟兜底"
			say "   以后想手动看状态：$SELF --status"
		fi
	fi
	exit 0
fi
say "提交了但还不通，检查账号密码/哈希方式（可用 --force 强制重试）"
log "auth submitted but still offline (steps=$STEP last_msg=$LAST_MSG)"
exit 1
