#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# md5-probe.py —— 已知「明文密码 + 抓包里的 pass 哈希」，反推它是怎么算出来的
#
# 背景：某个校园网门户提交的是 32 位小写 hex（看着像 MD5），但试了常见的
#       md5(明文)、md5(账号+明文)、md5(md5(明文))… 都不对，说明里面掺了别的东西
#       （最可能是客户端 IP —— 门户还有个 /api/ip.php 接口）。
#       本脚本把"能想到的拼法"一次性全试一遍，命中就直接告诉你公式和对应的 pass_mode。
#
# 用法：
#   python3 md5-probe.py --plain 213511 --hash fc824d7f244805c56634c66e16ded895
#   python3 md5-probe.py --plain 213511 --hash fc824... --user 05261241 --host 10.30.100.5
#   python3 md5-probe.py --plain 213511 --hash fc824... --salt 10.30.88.12      # 客户端 IP
#   python3 md5-probe.py --plain 213511 --hash fc824... --salt-file ips.txt     # 一行一个候选
#
# 退出码：0 命中 / 1 没命中 / 2 参数错误
#
# 说明：只做**字典式组合**，不做大空间爆破（那不是我们的目标——我们要的是"看懂门户用了什么"）。
import argparse
import hashlib
import itertools
import sys

SEPS = ["", "|", "&", ":", "-", "_", "+", ".", ",", "/", " ", "\n", "\r\n", "%7C", "%26", "=", "@", "#", "*"]
CONST_SALTS = [
    "", "raas", "RAAS", "raas3", "RAAS3", "campus", "portal", "srun", "drcom", "eportal",
    "wlan", "login", "ac", "salt", "key", "md5", "ip", "api", "php", "0", "1", "true", "null",
]


def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8", "replace")).hexdigest()


def variants(p: str) -> list:
    """明文的常见变形"""
    out = [("plain", p), ("plain+nl", p + "\n"), ("plain+crlf", p + "\r\n"),
           ("plain+space", p + " "), ("plain.strip", p.strip())]
    m = md5(p)
    out += [("md5(plain)", m), ("md5(plain)大写", m.upper()),
            ("sha1(plain)[:32]", hashlib.sha1(p.encode()).hexdigest()[:32]),
            ("sha256(plain)[:32]", hashlib.sha256(p.encode()).hexdigest()[:32])]
    return out


def mac_variants(mac: str) -> list:
    """MAC 的各写法：aa:bb:cc:dd:ee:ff / AA:BB:.. / aa-bb-.. / aabbccddeeff / AABBCCDDEEFF"""
    hexs = "".join(c for c in mac if c in "0123456789abcdefABCDEF")
    if len(hexs) != 12:
        return [mac]          # 不是标准 MAC 就原样当盐
    lo, up = hexs.lower(), hexs.upper()
    pairs_lo = ":".join(lo[i:i + 2] for i in range(0, 12, 2))
    pairs_up = ":".join(up[i:i + 2] for i in range(0, 12, 2))
    dash_lo = pairs_lo.replace(":", "-")
    dash_up = pairs_up.replace(":", "-")
    return [lo, up, pairs_lo, pairs_up, dash_lo, dash_up]


def build_candidates(plain, user, host, salts):
    """返回 {公式描述: 哈希}"""
    cands = {}
    base = variants(plain)
    for name, val in base:
        cands[name] = md5(val)
        cands["md5(md5(%s))" % name] = md5(md5(val))

    tokens = [("user", user), ("host", host)]
    tokens += [("salt%d" % i, s) for i, s in enumerate(salts)]
    tokens += [("const:%s" % c, c) for c in CONST_SALTS if c]

    for pname, pval in base:
        for tname, tval in tokens:
            if not tval:
                continue
            for sep in SEPS:
                cands["md5(%s%s%s)" % (pname, sep, tname)] = md5(pval + sep + tval)
                cands["md5(%s%s%s)" % (tname, sep, pname)] = md5(tval + sep + pval)
        # 两个 token 夹明文（账号 + IP 这种）
        for (n1, v1), (n2, v2) in itertools.permutations(tokens, 2):
            if not v1 or not v2:
                continue
            for sep in ["", "|", "&", ":", "-", "_"]:
                cands["md5(%s%s%s%s%s)" % (n1, sep, pname, sep, n2)] = md5(v1 + sep + pval + sep + v2)
                cands["md5(%s%s%s%s%s)" % (pname, sep, n1, sep, n2)] = md5(pval + sep + v1 + sep + v2)
    return cands


def main():
    ap = argparse.ArgumentParser(description="反推门户 pass 字段的哈希公式")
    ap.add_argument("--plain", required=True, help="明文密码（你确定是当前生效的那个）")
    ap.add_argument("--hash", required=True, dest="target", help="抓包里 pass= 后面的 32 位值")
    ap.add_argument("--user", default="", help="认证账号")
    ap.add_argument("--host", default="", help="门户主机（如 10.30.100.5 或带端口）")
    ap.add_argument("--salt", action="append", default=[], help="额外的盐候选（可重复），例如客户端 IP")
    ap.add_argument("--mac", action="append", default=[],
                    help="MAC 地址候选（可重复）。校园网 IP 绑 MAC 时盐往往就是它；"
                         "各写法变体（冒号/横杠/无分隔、大小写）自动展开")
    ap.add_argument("--salt-file", help="一行一个盐候选的文件")
    args = ap.parse_args()

    if len(args.target) != 32:
        print("pass 值不是 32 位 hex —— 那可能不是 MD5，把抓包原文发出来看看", file=sys.stderr)
        return 2

    salts = list(args.salt)
    if args.salt_file:
        with open(args.salt_file, encoding="utf-8") as f:
            salts += [l.strip() for l in f if l.strip()]
    for m in args.mac:
        salts += mac_variants(m)

    cands = build_candidates(args.plain, args.user, args.host, salts)
    hits = [(k, v) for k, v in cands.items() if v == args.target]

    print("目标哈希 : %s" % args.target)
    print("明文     : %s（%d 字符）" % (args.plain, len(args.plain)))
    print("账号     : %s" % (args.user or "（未给）"))
    print("门户     : %s" % (args.host or "（未给）"))
    print("盐候选   : %s" % (", ".join(salts[:14]) + ("…" if len(salts) > 14 else "")
                              if salts else "（未给 —— 试客户端 IP 用 --salt，试 MAC 用 --mac）"))
    print("试过组合 : %d 种" % len(cands))
    print()
    if hits:
        print("✅ 命中！公式：")
        for k, _ in hits:
            print("   %s = %s" % (k, args.target))
        print()
        print("→ 如果公式里带 salt（客户端 IP），说明哈希绑定客户端 IP：")
        print("  · 路由器上要把当前 WAN IP 掺进去算（脚本里已有 pass_mode=md5passip 等候选）")
        print("  · 硬编码哈希只在 IP 不变时有效，换 IP/重拨就会失败")
        return 0
    print("❌ 没命中（常见拼法都在里面了）。下一步：")
    print("   1) 把客户端 IP / MAC 传进来试：--salt <IP> --mac <AA:BB:CC:DD:EE:FF>")
    print("      （门户的 /api/ip.php 会告诉你它看到的 IP；MAC 用 ip link show wan | grep ether）")
    print("   2) 还不行就是页面下发的随机盐 → 必须拿到认证页的 JS：")
    print("      curl -s http://门户地址/ -o /tmp/p.html && grep -oE 'src=\"[^\"]+\\.js[^\"]*' /tmp/p.html")
    print("      curl -s http://门户地址/ | grep -n 'md5\\|encrypt\\|pass' | head")
    return 1


if __name__ == "__main__":
    sys.exit(main())
