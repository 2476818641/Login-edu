# 抓包清单（校园网网页认证）

目标：抓一次登录，就能把 `campus-portal-auth.sh` 里的 3 处 `← 抓包` 一次填对。

## 交付方式（选一个，都通）

| 方式 | 怎么做 | 适合 |
|---|---|---|
| **① 直接给 Burp XML** | Burp → Proxy → HTTP history → 全选 → 右键 `Save items` → 存 `.xml` → 丢进 `captures/`（本机也可放 `/tmp/campus-capture/`）→ 告诉我文件名 | 最省事、一字不漏；几十 MB 我这边能处理 |
| **② 压缩后贴给 AI** | `python3 tools/burp-xml-summary.py captures/xx.xml -o captures/小抄.md` → 小抄 + `captures/AI-PROMPT.md` 的提示词一起贴给任意 AI | 用在线 AI（上下文有限），脚本会自动脱敏 cookie/密码值 |
| **③ 手抄关键报文** | 按下面「要交出来的内容」①②③抄 3 段原文 | 只想截图/手机上看两眼 |

> 抓包里含**明文密码、学号、会话 cookie**：别提交进 git（`captures/.gitignore` 已挡住），贴给外部 AI 前先走方式 ②。
> 抓之前记住两条，比任何技巧都重要：**从断网状态开始抓**、**故意输错一次再输对一次**。

## 怎么抓

**方案 A（推荐）：电脑接在路由器 LAN 口，用 Burp 抓**

1. 电脑网线插路由器 LAN 口（拿到 192.168.1.x），确认能打开认证页（此时外网还不通，正常）
2. Burp → Proxy → Options → 监听 `0.0.0.0:8080`（Allow remote 不用开，因为是本机浏览器）
3. 浏览器/系统代理设为 `127.0.0.1:8080`，装好 Burp 证书（抓 https 必需）
4. 打开认证页 → 输入账号密码 → 登录（**先故意输错一次**，再输对一次）
5. Burp → HTTP history → 找到 `POST` 那条（认证接口）→ 右键 `Copy to file` 或直接看 Raw

**方案 B：浏览器 F12**

F12 → Network → 勾 Preserve log → 登录 → 找 `POST`（或 XHR/fetch）那条 →
右键 `Copy as cURL` 或看 `Payload`/`Response` 标签。

## 要交出来的内容

### ① 完整登录请求（必给）

```
POST /srun_portal?callback=jsonp HTTP/1.1        ← 请求行（方法 + 路径 + query）
Host: 10.10.10.10:801                            ← 认证接口地址与端口
Content-Type: application/x-www-form-urlencoded
User-Agent: Mozilla/5.0 (...)
Referer: http://10.10.10.10/srun_portal_pc
Cookie: JSESSIONID=xxxxx                          ← 有 cookie 就是关键信息
                                                  ← 空行以下是 body
user=2026xxxx&pass=xxxx&nasip=10.10.0.1&...&t=1758...
```

**尤其注意 body 里有没有这些**：`mac` / `ip` / `nasip` / `wlanacname` / `wlanuserip` / `t`（时间戳）/
`sign` / `token` / `callback`（jsonp）。有就原样保留。

### ② 完整响应（必给）

```
HTTP/1.1 200 OK
Content-Type: application/json

{"result":"1","msg":"认证成功"}                    ← 成功时长什么样
```

### ③ 失败一次的响应（强烈建议）

故意输错密码抓的那条。有成功/失败对照，判定条件才可靠（否则只能靠"外网通不通"兜底）。

### ④ 其它（有就给）

| 项 | 为什么需要 |
|---|---|
| POST 之前是否先 `GET` 过认证页/接口 | 有些认证要先拿 session/cookie 或 challenge |
| `pass=` 后面是不是明文密码 | 若是 32 位 hex 等，说明前端加密了，需要**算密码的那段 JS** |
| 登录成功后 5~10 分钟内有无周期性请求 | 有的校园网要心跳保活，否则会被踢下线 |
| 登出接口 | 可选，用于切换账号 |
| 认证页 HTML（登录页源码） | 里面有表单字段名和 JS，纯静态分析就能确认 |

## 交出来之后会发生什么

1. 把 `campus-portal-auth.sh` 的 3 处填空改成正式实现（必要时加 cookie/token/心跳/加密）
2. 你自己 `wget` 覆盖到路由器 `/etc/campus-portal-auth.sh`，`chmod +x`
3. 跑一次 `/etc/campus-portal-auth.sh` 验证 → 再 `reboot` 验证自动登录

抓包放哪、怎么让 AI 先读一遍：见 `captures/README.md` 与 `captures/AI-PROMPT.md`。
