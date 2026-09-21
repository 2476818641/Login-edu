#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# burp-xml-summary.py —— 把 Burp 导出的超大 XML 压成「给 AI 看的小抄」
#
# 为什么需要它：一次浏览抓下来的 Burp XML 动辄几十 MB（大量静态资源、base64 图片），
# 直接丢给 AI 既塞不进去也没用。本脚本只留下跟「网页认证」有关的条目，
# 解码 base64、只保留关键头、默认把 cookie/密码值脱敏，输出几 KB 的 Markdown。
#
# 用法（VPS / 本机都可以，只依赖 Python 3 标准库）：
#   python3 burp-xml-summary.py logon.xml                  > 小抄.md
#   python3 burp-xml-summary.py logon.xml -o 小抄.md
#   python3 burp-xml-summary.py logon.xml --all            # 不筛，全部条目都留（仍然脱敏）
#   python3 burp-xml-summary.py logon.xml --no-redact      # 不脱敏（自己看/自己贴给本地模型时用）
#   python3 burp-xml-summary.py logon.xml --max-body 4000  # 单条 body/响应最多留多少字符
#
# 退出码：0 正常（哪怕一条都没筛出来）／1 参数或文件错误

import argparse
import base64
import binascii
import html
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime

# ---------------------------------------------------------------- 判定「像认证流量」
KEYWORDS = (
    "login", "logon", "auth", "portal", "srun", "eportal", "drcom", "wlan",
    "ac_portal", "aclogin", "check", "challenge", "captive", "redirect",
    "portalpage", "sso", "cas", "radius", "nasip", "online",
)
SUCCESS_WORDS = ("成功", "success", "result\":1", "result=1", '"result":"1"', "ok\"", "登录")
FAIL_WORDS = ("失败", "fail", "error", "错误", "密码", "invalid", "denied", "result\":0", "result=0")
# 认证接口基本都在内网，这些网段单独加权
PRIVATE_RE = re.compile(r"^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)")

SECRET_KEY_RE = re.compile(r"(pass|pwd|passwd|password|secret|token|sign|signature|key|auth_code|验证码)", re.I)
ACCOUNT_KEY_RE = re.compile(r"^(user|username|user_?name|userid|user_?id|account|acct|login_?name|"
                            r"stu(?:dent)?_?(?:id|no|num)?|学号|账号|卡号)$", re.I)
UA_SECRET_RE = re.compile(r"(password|passwd|pwd|token|secret)", re.I)

KEEP_REQ_HEADERS = ("content-type", "user-agent", "referer", "origin", "host",
                    "x-requested-with", "accept", "content-length", "cookie", "authorization")
KEEP_RESP_HEADERS = ("content-type", "location", "set-cookie", "content-length", "server")


def b64(s):
    s = (s or "").strip()
    if not s:
        return ""
    try:
        raw = base64.b64decode(s, validate=False)
    except (binascii.Error, ValueError):
        return s
    for enc in ("utf-8", "gb18030", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1", "replace")


def split_http(text):
    """把原始 HTTP 报文切成 (请求行/状态行, [(头名, 头值)], body)"""
    if not text:
        return "", [], ""
    text = text.replace("\r\n", "\n")
    head, _, body = text.partition("\n\n")
    lines = head.split("\n")
    start = lines[0].strip() if lines else ""
    headers = []
    for line in lines[1:]:
        if ":" in line:
            k, _, v = line.partition(":")
            headers.append((k.strip(), v.strip()))
    return start, headers, body


def mask_account(val):
    """账号脱敏但保留有用的形状：域名后缀要留下（有些学校要求 user@domain），位数留下（判断是不是学号）"""
    if not val:
        return val
    if "@" in val:
        return "<账号@%s>" % val.split("@", 1)[1]
    if val.isdigit():
        return "<账号 %d 位数字>" % len(val)
    return "<账号 已脱敏 %d 字符>" % len(val)


def redact_value(key, val, on):
    if not on or not val:
        return val
    if SECRET_KEY_RE.search(key):
        return "<已脱敏 %d 字符>" % len(val)
    if ACCOUNT_KEY_RE.match(key.strip()):
        return mask_account(val)
    return val


JSON_PAIR_RE = re.compile(r'"([A-Za-z_][A-Za-z0-9_\-]{0,30})"\s*:\s*"([^"]{0,300})"')


def redact_json(body, on):
    if not on or not body:
        return body

    def repl(m):
        k, v = m.group(1), m.group(2)
        nv = redact_value(k, v, True)
        return m.group(0) if nv == v else '"%s":"%s"' % (k, nv)

    return JSON_PAIR_RE.sub(repl, body)


def redact_body(body, on):
    """只对**请求** body 用：密码/令牌/账号的值脱敏，字段名与其它参数原样保留"""
    if not on or not body:
        return body
    out = []
    for line in body.split("\n"):
        if "=" in line and not line.lstrip().startswith(("{", "[")):
            parts = []
            for pair in line.split("&"):
                k, sep, v = pair.partition("=")
                parts.append(k + sep + redact_value(k, v, on))
            out.append("&".join(parts))
        else:
            out.append(line)
    return redact_json("\n".join(out), on)


def redact_cookie(value, on):
    if not on:
        return value
    names = [c.split("=", 1)[0].strip() for c in value.split(";") if c.strip()]
    return "<cookie 名：%s（值已脱敏）>" % ", ".join(names) if names else "<cookie 已脱敏>"


def clip(s, n):
    s = s or ""
    if n and len(s) > n:
        return s[:n] + "\n…（截断，原长 %d 字符）" % len(s)
    return s


def tkey(t):
    """Burp 的时间形如 Sun Sep 20 12:25:17 CST 2026 —— 尽力解析，失败返回 None"""
    try:
        p = (t or "").split()
        return datetime.strptime(" ".join(p[:4]) + " " + p[-1], "%a %b %d %H:%M:%S %Y")
    except (ValueError, IndexError):
        return None


def render_headers(headers, allow, redact=True):
    out = []
    for k, v in headers:
        lk = k.lower()
        if lk not in allow:
            continue
        if lk == "cookie":
            v = redact_cookie(v, redact)
        elif lk == "set-cookie":
            name = v.split("=", 1)[0].strip()
            v = "<Set-Cookie 名：%s（值已脱敏）>" % name if redact else v
        elif lk == "authorization" and redact:
            v = "<已脱敏>"
        out.append("%s: %s" % (k, v))
    return out


def score_item(method, url, host, status, path, resp_body):
    s = 0
    if method.upper() == "POST":
        s += 3
    try:
        if 300 <= int(status) < 400:
            s += 3
    except (TypeError, ValueError):
        pass
    low = (url + " " + path).lower()
    if any(k in low for k in KEYWORDS):
        s += 2
    if PRIVATE_RE.match(host or ""):
        s += 1
    low_body = (resp_body or "").lower()
    if any(w.lower() in low_body for w in SUCCESS_WORDS):
        s += 1
    if any(w.lower() in low_body for w in FAIL_WORDS):
        s += 1
    if path.lower().endswith((".js", ".css", ".png", ".jpg", ".gif", ".svg", ".woff", ".woff2", ".ico", ".mp4")):
        s -= 5
    return s


def extract_forms(body):
    """从 HTML 里抠出 <form action=...> 和 <input name=...>，这是字段名最可靠的来源"""
    if not body or "<form" not in body.lower():
        return []
    forms = []
    for m in re.finditer(r"<form[^>]*>", body, re.I):
        tag = m.group(0)
        action = re.search(r'action\s*=\s*["\']?([^"\'\s>]+)', tag, re.I)
        method = re.search(r'method\s*=\s*["\']?([^"\'\s>]+)', tag, re.I)
        end = body.lower().find("</form>", m.end())
        inner = body[m.end():end if end > 0 else m.end() + 4000]
        fields = []
        for im in re.finditer(r"<input[^>]*>", inner, re.I):
            it = im.group(0)
            name = re.search(r'name\s*=\s*["\']?([^"\'\s>]+)', it, re.I)
            if not name:
                continue
            typ = re.search(r'type\s*=\s*["\']?([^"\'\s>]+)', it, re.I)
            val = re.search(r'value\s*=\s*["\']?([^"\'>]*)', it, re.I)
            fields.append((name.group(1),
                           (typ.group(1) if typ else "text").lower(),
                           val.group(1) if val else ""))
        forms.append({"action": action.group(1) if action else "",
                      "method": (method.group(1) if method else "get").upper(),
                      "fields": fields})
    return forms


def full_url(it):
    """拼回完整 URL：默认端口不显示，别的端口补上"""
    host, port, proto = it["host"], it["port"], it["proto"]
    if not port or (proto == "http" and port == "80") or (proto == "https" and port == "443"):
        return "%s://%s%s" % (proto, host, it["path"])
    return "%s://%s:%s%s" % (proto, host, port, it["path"])


def main():
    ap = argparse.ArgumentParser(description="Burp XML → 给 AI 看的认证流量小抄")
    ap.add_argument("input", help="Burp 导出的 .xml")
    ap.add_argument("-o", "--output", help="输出文件（默认 stdout）")
    ap.add_argument("--all", action="store_true", help="不筛选，保留全部条目")
    ap.add_argument("--max-body", type=int, default=1500, help="单条请求/响应 body 最多保留字符数（默认 1500）")
    ap.add_argument("--no-redact", action="store_true", help="不脱敏 cookie/密码/令牌")
    ap.add_argument("--min-score", type=int, default=3, help="筛选阈值（默认 3，越低留得越多）")
    args = ap.parse_args()

    redact = not args.no_redact

    try:
        ctx = ET.iterparse(args.input, events=("end",))
    except (OSError, ET.ParseError) as e:
        print("打不开/解析不了 %s：%s" % (args.input, e), file=sys.stderr)
        return 1

    items = []
    total = 0
    try:
        for _, elem in ctx:
            if elem.tag != "item":
                continue
            total += 1
            g = lambda t: (elem.findtext(t) or "")
            req_attr = elem.find("request")
            resp_attr = elem.find("response")
            req_raw = b64(req_attr.text) if (req_attr is not None and req_attr.get("base64") == "true") else g("request")
            resp_raw = b64(resp_attr.text) if (resp_attr is not None and resp_attr.get("base64") == "true") else g("response")
            req_line, req_headers, req_body = split_http(req_raw)
            resp_line, resp_headers, resp_body = split_http(resp_raw)
            it = {
                "time": g("time"), "url": g("url"), "host": g("host"),
                "port": g("port"), "proto": g("protocol"), "method": g("method"),
                "path": g("path"), "status": g("status"), "mime": g("mimetype"),
                "req_line": req_line, "req_headers": req_headers, "req_body": req_body,
                "resp_line": resp_line, "resp_headers": resp_headers, "resp_body": resp_body,
            }
            it["score"] = score_item(it["method"], it["url"], it["host"], it["status"], it["path"], resp_body)
            if args.all or it["score"] >= args.min_score:
                items.append(it)
            elem.clear()
    except ET.ParseError as e:
        print("解析 %s 失败（第 %d 条附近）：%s" % (args.input, total + 1, e), file=sys.stderr)
        print("提示：必须是 Burp「Save items」导出的 XML；浏览器 F12 复制的 cURL 不是 XML。", file=sys.stderr)
        return 1

    out = []
    w = out.append
    w("# Burp 抓包小抄（网页认证）")
    w("")
    w("- 来源：`%s`" % args.input)
    w("- 原始条目：%d 条；保留：%d 条（阈值 %s%s）" % (
        total, len(items), args.min_score, "，--all 全留" if args.all else ""))
    w("- 脱敏：%s" % ("已开启（cookie 值 / 密码 / token 值已替换）" if redact else "**未开启**"))
    times = [tkey(i["time"]) for i in items if tkey(i["time"])]
    if times:
        w("- 覆盖时间段：%s ～ %s" % (min(times).strftime("%Y-%m-%d %H:%M:%S"),
                                    max(times).strftime("%Y-%m-%d %H:%M:%S")))
    else:
        w("- 覆盖时间段：未知")
    w("- 请求体已脱敏；**响应体保留原文**（成功/失败判定串必须逐字保留，别改）")
    w("")

    # ---- 全局线索
    posts, locations, fields_by_target, hits = {}, {}, {}, []
    forms_seen = []
    for it in items:
        if it["method"].upper() == "POST":
            target = full_url(it)
            posts.setdefault(target, 0)
            posts[target] += 1
            names = sorted({p.split("=", 1)[0] for p in re.split(r"[&\n]", it["req_body"]) if "=" in p})
            fields_by_target.setdefault(target, set()).update(names)
        for k, v in it["resp_headers"]:
            if k.lower() == "location":
                locations.setdefault(v, 0)
                locations[v] += 1
        if it["req_body"] or it["resp_body"]:
            for line in (it["resp_body"] or "").split("\n"):
                s = line.strip()
                if s.startswith("<"):        # HTML 标签行不算「成功/失败字样」
                    continue
                if any(x.lower() in s.lower() for x in SUCCESS_WORDS + FAIL_WORDS) and len(s) < 400:
                    hits.append((it["url"], s))
        forms_seen.extend(extract_forms(it["resp_body"]))

    w("## 1. POST 目标（认证接口候选）")
    if posts:
        for t, n in sorted(posts.items(), key=lambda kv: -kv[1]):
            w("- `%s`  ×%d" % (t, n))
            if fields_by_target.get(t):
                w("  - 表单字段：%s" % ", ".join("`%s`" % f for f in sorted(fields_by_target[t])))
    else:
        w("- （筛出来的条目里没有 POST，把 `--min-score` 调低或加 `--all` 再跑一次）")
    w("")

    w("## 2. 跳转（Location）—— 门户劫持的典型特征")
    if locations:
        for t, n in sorted(locations.items(), key=lambda kv: -kv[1])[:20]:
            w("- `%s`  ×%d" % (t, n))
    else:
        w("- 无")
    w("")

    w("## 3. 响应里的成功／失败字样")
    if hits:
        seen = set()
        for url, line in hits:
            if line in seen:
                continue
            seen.add(line)
            w("- `%s` → `%s`" % (url, line[:200]))
            if len(seen) >= 25:
                break
    else:
        w("- 没找到。**必须故意输错一次密码再抓一遍**，否则判定条件只能靠连通性兜底。")
    w("")

    w("## 4. 认证页 HTML 里的表单（字段名最可靠来源）")
    if forms_seen:
        for i, f in enumerate(forms_seen[:10], 1):
            w("- 表单 %d：method=%s action=`%s`" % (i, f["method"], f["action"]))
            for name, typ, val in f["fields"][:30]:
                w("  - `%s` (%s)%s" % (name, typ, (" 默认值 `%s`" % val) if val else ""))
    else:
        w("- 抓到的响应里没有 `<form>`（可能是纯 JS/AJAX 认证，看第 1 节的 POST 字段）")
    w("")

    # ---- 逐条明细
    w("## 5. 明细（按可疑度排序）")
    w("")
    for it in sorted(items, key=lambda x: -x["score"]):
        w("### %s %s" % (it["method"], it["url"]))
        w("- 时间：%s ／ 状态：`%s` ／ 可疑度：%d" % (it["time"], it["status"], it["score"]))
        w("- Host：`%s:%s`（%s）" % (it["host"], it["port"], it["proto"]))
        if it["req_line"]:
            w("- 请求行：`%s`" % it["req_line"])
        hs = render_headers(it["req_headers"], KEEP_REQ_HEADERS, redact=redact)
        if hs:
            w("")
            w("```http")
            for h in hs:
                w(h)
            w("```")
        if it["req_body"].strip():
            w("- 请求 body：")
            w("")
            w("```")
            w(clip(redact_body(it["req_body"], redact).strip(), args.max_body))
            w("```")
        if it["resp_line"]:
            w("- 响应行：`%s`" % it["resp_line"])
        hs = render_headers(it["resp_headers"], KEEP_RESP_HEADERS, redact=redact)
        if hs:
            w("")
            w("```http")
            for h in hs:
                w(h)
            w("```")
        if it["resp_body"].strip():
            w("- 响应 body：")
            w("")
            w("```")
            w(clip(it["resp_body"].strip(), args.max_body))
            w("```")
        w("")

    text = "\n".join(out) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        print("已写出 %s（%d 字节，%d 条）" % (args.output, len(text.encode()), len(items)))
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
