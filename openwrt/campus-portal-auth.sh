#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-portal-auth.sh —— 校园网网页认证脚本
#
# ⚠️ 这个文件是**需要按你学校的抓包来填的**：标了「← 抓包」的 3 处是必须改的地方。
#    抓包清单见同目录 PACKET-CAPTURE.md；把抓包交给 AI，一般能直接生成/补全本文件。
#
# 装在路由器上：/etc/campus-portal-auth.sh（chmod +x）
#   wget -O /etc/campus-portal-auth.sh <raw 链接> && chmod +x /etc/campus-portal-auth.sh
#
# 用法：
#   campus-portal-auth.sh                 # 已经在线就什么都不做；否则登录一次
#   campus-portal-auth.sh --force         # 强制走一次登录流程
#   campus-portal-auth.sh --quiet         # 静默（给 hotplug / cron 用）
#   campus-portal-auth.sh --setup         # 交互填账号/密码/认证地址，存进 uci campus
#   campus-portal-auth.sh --install-hook  # 装「WAN 上线自动认证 + 每 5 分钟兜底」
#   campus-portal-auth.sh --uninstall-hook# 卸掉上面两样
#
# 约定（调用方按这个判断，别改）：
#   成功 exit 0（并且外网真的能通）／失败 exit 非 0／已经在线直接 exit 0（幂等）
#
# 参数来源：环境变量优先，其次 uci get campus.main.{auth_url,user,pass,check_url,ua,iface}
#
set -u

HOOKDIR="${HOOKDIR:-/etc/hotplug.d/iface}"
HOOKFILE="$HOOKDIR/99-campus-portal"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
SELF="${SELF:-/etc/campus-portal-auth.sh}"

say() { [ "${QUIET:-0}" = 1 ] || printf '%s\n' "$*"; }
log() { logger -t campus-portal "$*" 2>/dev/null || true; }
ug()  { uci -q get "$1" 2>/dev/null; }
env_or_uci() {	# env_or_uci <变量名> <uci键> <默认值>
	eval "_v=\"\${$1:-}\""
	[ -z "$_v" ] && _v="$(ug "$2")"
	[ -z "$_v" ] && _v="$3"
	eval "$1=\"\$_v\""
}

# ---------------------------------------------------------------- 子命令
case "${1:-}" in
--setup)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	printf '认证账号: '; read -r U
	printf '认证密码: '; read -r P
	printf '认证接口地址（抓包里的 POST 目标，例如 http://10.10.10.10:801/srun_portal）: '; read -r A
	uci -q set campus.main='main'
	[ -n "$U" ] && uci -q set "campus.main.user=$U"
	[ -n "$P" ] && uci -q set "campus.main.pass=$P"
	[ -n "$A" ] && uci -q set "campus.main.auth_url=$A"
	uci -q commit campus && chmod 600 /etc/config/campus 2>/dev/null
	echo "已保存到 uci campus（/etc/config/campus，权限 600）"
	exit 0
	;;
--install-hook)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
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
	exit 0
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
--help|-h) sed -n '4,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
"") FORCE=0 ;;
*) echo "未知参数：$1（用 --help 看用法）" >&2; exit 1 ;;
esac
FORCE="${FORCE:-0}"; QUIET="${QUIET:-0}"

# ---------------------------------------------------------------- 取参数
env_or_uci AUTH_URL   campus.main.auth_url   ''						# ← 抓包：认证接口
env_or_uci CHECK_URL  campus.main.check_url  'http://connect.rom.miui.com/generate_204'
env_or_uci CAMPUS_USER campus.main.user      ''
env_or_uci CAMPUS_PASS campus.main.pass      ''
env_or_uci UA         campus.main.ua         ''
env_or_uci WANIF      campus.main.iface      'wan'
COOKIE="${COOKIE:-/tmp/campus-portal.cookie}"

# ---------------------------------------------------------------- 在线判定（幂等）
online() {
	[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$CHECK_URL" 2>/dev/null)" = "204" ] && return 0
	ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
	return 1
}
if [ "$FORCE" != 1 ] && online; then
	say "已经在线，不用登录"
	exit 0
fi

[ -n "$AUTH_URL" ] || { say "没配认证地址：跑 $SELF --setup，或 uci set campus.main.auth_url=..."; exit 2; }
[ -n "$CAMPUS_USER" ] || { say "没配账号：跑 $SELF --setup，或 uci set campus.main.user=..."; exit 2; }

# 用函数而不是拼字符串：UA 里有空格，拼字符串会被 shell 拆成多个参数
curl_auth() {
	if [ -n "$UA" ]; then curl -s -m 15 -k -A "$UA" "$@"
	else curl -s -m 15 -k "$@"; fi
}

# ---------------------------------------------------------------- 1)（可选）先 GET 认证页拿 cookie/token
#    抓包时如果看到"先 GET 再 POST"，把下面这行取消注释：
# curl_auth -c "$COOKIE" "$AUTH_URL" >/dev/null

# ---------------------------------------------------------------- 2) 提交账号密码 ← 抓包：URL/方法/字段名
RESP="$(curl_auth -b "$COOKIE" -c "$COOKIE" \
	-X POST "$AUTH_URL" \
	--data-urlencode "user=$CAMPUS_USER" \
	--data-urlencode "pass=$CAMPUS_PASS" \
	2>/dev/null)"
say "认证响应: $(printf '%s' "$RESP" | head -c 300)"

# ---------------------------------------------------------------- 3) 判定成功 ← 抓包：成功标志
case "$RESP" in
	*'"result":"1"'*|*'success'*|*'登录成功'*|*'认证成功'*)
		say "响应看起来是成功";;
	*)
		say "响应里没有成功标志，用连通性兜底判断…"
		sleep 2
		if online; then
			say "按连通性判定：成功"
		else
			say "认证失败：检查账号密码 / 字段名 / 是否需要先 GET 拿 cookie / 响应格式"
			log "auth failed: $RESP"
			exit 1
		fi
		;;
esac

# ---------------------------------------------------------------- 4) 连通性二次确认
sleep 2
if online; then
	say "认证成功 ✅"
	log "auth ok (user=$CAMPUS_USER iface=$WANIF)"
	exit 0
fi
say "提交了但还不通，检查账号密码/字段名（可用 --force 强制重试）"
log "auth submitted but still offline"
exit 1
