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
#   campus-portal-auth.sh --setup         # 交互填门户地址/账号/密码/哈希方式，存进 uci campus
#   campus-portal-auth.sh --hash-test     # 打印各种候选 MD5，用来和抓包里的 pass= 对比
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
md5hex() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

# ---------------------------------------------------------------- 子命令
case "${1:-}" in
--setup)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	printf '门户地址（浏览器打开认证页时的地址，例如 http://10.30.100.5，也可只填 IP）: '; read -r A
	printf '认证账号（学号/上网账号）: '; read -r U
	printf '认证密码（明文，脚本会按哈希方式自己算）: '; read -r P
	printf '哈希方式 [md5/plain/md5user/md5passuser/直接回车=md5]: '; read -r M
	printf '三步认证路径 [直接回车=/api/login.php,/api/ack_auth.php,/api/stat.php]: '; read -r PATHS
	printf '固定字段 [直接回车=authmode=0&pool=&isp_id=0&pxyacct=]: '; read -r EX
	A_RAW="$A"
	A="$(normalize_url "$A_RAW")"
	case "$A_RAW" in
		''|*://*) ;;
		*) echo "门户地址没带协议，已按 $A 处理" ;;
	esac
	if [ "$HAS_UCI" = 1 ]; then
		uci -q set campus.main='main'
		[ -n "$A" ] && uci -q set "campus.main.auth_url=$A"
		[ -n "$U" ] && uci -q set "campus.main.user=$U"
		[ -n "$P" ] && uci -q set "campus.main.pass=$P"
		[ -n "${M:-}" ] && uci -q set "campus.main.pass_mode=$M"
		[ -n "${PATHS:-}" ] && uci -q set "campus.main.api_paths=$PATHS"
		[ -n "${EX:-}" ] && uci -q set "campus.main.extra_fields=$EX"
		# 关键：commit 之后**读回来核对**，不能像以前那样不管成败都打印"已保存"
		if ! uci -q commit campus; then
			echo "❌ uci commit campus 失败（配置没保存）" >&2
			exit 1
		fi
		chmod 600 /etc/config/campus 2>/dev/null
		BACK="$(uci -q get campus.main.pass)"
		if [ "$BACK" != "$P" ]; then
			echo "❌ 写进去又读回来对不上（读到：${BACK:-空}）——配置没生效，别继续" >&2
			exit 1
		fi
		echo "已保存到 uci campus（/etc/config/campus，权限 600），门户地址=$A，账号=$U"
	else
		# 没有 uci：写一个可 source 的配置文件（电脑上先用它验证，注意不是路由器）
		{
			printf '# 由 campus-portal-auth.sh --setup 生成（本机没有 uci）\n'
			printf '# 只在该变量还没设过时才赋值，所以命令行上的环境变量仍然优先\n'
			[ -n "$A" ] && printf ': "${PORTAL:=%s}"\n' "$A"
			[ -n "$U" ] && printf ': "${CAMPUS_USER:=%s}"\n' "$U"
			[ -n "$P" ] && printf ': "${CAMPUS_PASS:=%s}"\n' "$P"
			printf ': "${PASS_MODE:=%s}"\n' "${M:-md5}"
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
	echo "把下面每一行右边那串，和抓包 POST body 里 pass= 后面的值对比，一样的就是正确方式："
	printf '  md5(明文)             %s\n'   "$(md5hex "$CAMPUS_PASS")"
	printf '  md5(账号+明文)        %s\n'   "$(md5hex "$CAMPUS_USER$CAMPUS_PASS")"
	printf '  md5(明文+账号)        %s\n'   "$(md5hex "$CAMPUS_PASS$CAMPUS_USER")"
	printf '  md5(md5(明文))        %s\n'   "$(md5hex "$(md5hex "$CAMPUS_PASS")")"
	printf '  md5(明文) 大写        %s\n'   "$(md5hex "$CAMPUS_PASS" | tr 'a-f' 'A-F')"
	echo
	echo "对应设置：uci set campus.main.pass_mode=md5 | md5user | md5passuser | md5md5"
	echo "都不匹配：说明还有盐/前缀，把认证页里算密码的那段 JS 发我"
	exit 0
	;;
--install-hook)
	[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
	if [ "$HAS_UCI" != 1 ] && [ "${FORCE_HOOK:-0}" != 1 ]; then
		echo "⚠️  本机没有 uci（不是路由器）：--install-hook 是给路由器装 hotplug + cron 的" >&2
		echo "    真要在本机装：FORCE_HOOK=1 $SELF --install-hook" >&2
		exit 2
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
--help|-h) sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
"") FORCE=0 ;;
*) echo "未知参数：$1（用 --help 看用法）" >&2; exit 1 ;;
esac
FORCE="${FORCE:-0}"; QUIET="${QUIET:-0}"

# ---------------------------------------------------------------- 取参数
# PORTAL：门户基地址（不带路径），例如 http://10.30.100.5
env_or_uci PORTAL       campus.main.auth_url     ''					# ← 抓包①：门户地址
# 按顺序提交的接口路径，逗号分隔。单接口门户就写一个（如 /srun_portal）
env_or_uci API_PATHS    campus.main.api_paths    '/api/login.php,/api/ack_auth.php,/api/stat.php'	# ← 抓包②：流程
env_or_uci EXTRA_FIELDS campus.main.extra_fields 'authmode=0&pool=&isp_id=0&pxyacct='			# ← 抓包③：固定字段
env_or_uci USER_FIELD   campus.main.user_field   'user'
env_or_uci PASS_FIELD   campus.main.pass_field   'pass'
env_or_uci PASS_MODE    campus.main.pass_mode    'md5'
env_or_uci PASS_MD5     campus.main.pass_md5     ''	# 设置后直接用这串，跳过哈希（应急用）
env_or_uci PRE_GET      campus.main.pre_get      '1'	# 1=先 GET 首页拿会话 cookie
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
		plain|literal) printf '%s' "$CAMPUS_PASS" ;;
		md5)           md5hex "$CAMPUS_PASS" ;;
		md5user)       md5hex "$CAMPUS_USER$CAMPUS_PASS" ;;
		md5passuser)   md5hex "$CAMPUS_PASS$CAMPUS_USER" ;;
		md5md5)        md5hex "$(md5hex "$CAMPUS_PASS")" ;;
		*)             printf '%s' "$CAMPUS_PASS" ;;
	esac
}

# ---------------------------------------------------------------- 在线判定（幂等）
online() {
	[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$CHECK_URL" 2>/dev/null)" = "204" ] && return 0
	[ "$PING_TARGET" = "-" ] && return 1
	ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1 && return 0
	return 1
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

# ---------------------------------------------------------------- 1) 先 GET 门户首页拿会话 cookie
#    抓包里三条 POST 都带 Cookie: RAASSESSID=…，这个 cookie 来自首页那次 GET。
#    如果实测发现不带 cookie 也能登录，把它关掉即可：uci set campus.main.pre_get=0
if [ "$PRE_GET" = 1 ]; then
	rm -f "$COOKIE"
	if curl_auth -c "$COOKIE" -b "$COOKIE" -o /dev/null "$PORTAL/" 2>/dev/null; then
		say "已 GET $PORTAL/（拿会话 cookie）"
	else
		say "首页 GET 失败，继续尝试直接登录"
	fi
fi

# ---------------------------------------------------------------- 2) 按顺序提交（本项目是三步）
PASSV="$(pass_value)"
say "提交账号 ${CAMPUS_USER}（pass=${PASS_MODE}${PASS_MD5:+，用 uci 里指定的哈希}）"

STEP=0
LAST_MSG=""; LAST_RET=""; LAST_TYPE=""; FAILED=0
for _path in $(printf '%s' "$API_PATHS" | tr ',' ' '); do
	[ -n "$_path" ] || continue
	STEP=$((STEP + 1))
	case "$_path" in /*) _url="$PORTAL$_path" ;; *) _url="$PORTAL/$_path" ;; esac
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
	say "  [$STEP] $_path → ret=${RET:-?} msg=${MSG:-（空）}${TYPE:+ type=$TYPE}"
	LAST_MSG="$MSG"; LAST_RET="$RET"; LAST_TYPE="$TYPE"
	if [ -n "$RET" ] && [ "$RET" != 0 ]; then
		# 失败码对照（来自 2026-09-20 第二次抓包，两条错密码实测）：
		#   ret=4 → msg「帐号密码不正确！」（密码错；两次错密码都是 4）
		#   其它非 0 → 原样打印，等补抓样本再对照
		case "$RET" in
			4) say "认证被拒绝：账号或密码不正确（ret=4 msg=$MSG）"
			   say "  → 先用 --hash-test 核对哈希方式；账号本身没错的话基本就是哈希算错了" ;;
			*) say "认证被拒绝：$_path 返回 ret=$RET msg=$MSG" ;;
		esac
		log "auth rejected at step $STEP ($_path): ret=$RET msg=$MSG"
		FAILED=1
		break
	fi
done

[ "$FAILED" = 1 ] && exit 1
[ "$STEP" -gt 0 ] || { say "没有可提交的接口（检查 campus.main.api_paths）"; exit 2; }

# ---------------------------------------------------------------- 3) 判定成功 ← 抓包④：成功标志
#    实测：最后一步 stat.php 的 msg 是「认证成功！」，且所有步骤 ret=0。
#    失败样本还没抓到，所以这里采取"ret 非 0 即失败（上面已判）+ 特征串/连通性判成功"的双保险。
case "$LAST_MSG" in
	*'成功'*|*'success'*|*'SUCCESS'*|*'已在线'*|*'ok'*|*'OK'*)
		say "响应含成功标志（msg=$LAST_MSG）";;
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
	log "auth ok (user=$CAMPUS_USER portal=$PORTAL steps=$STEP msg=$LAST_MSG)"
	exit 0
fi
say "提交了但还不通，检查账号密码/哈希方式（可用 --force 强制重试）"
log "auth submitted but still offline (steps=$STEP last_msg=$LAST_MSG)"
exit 1
