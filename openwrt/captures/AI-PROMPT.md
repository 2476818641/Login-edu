# AI 提示词：让任意 AI 把 Burp 抓包翻译成认证脚本的填空

配套文件：`captures/README.md`（怎么抓、怎么交付）、`tools/burp-xml-summary.py`（把几十 MB 的 Burp XML 压成几 KB 的小抄）。
本文件的作用：**你不用自己看懂抓包**，把抓包 + 下面这段提示词丢给 AI，让它按固定格式吐出 `campus-portal-auth.sh` 需要的 6 段内容。

---

## 一、怎么用

1. 按 `PACKET-CAPTURE.md` 抓一次包（**必须包含"输错密码失败一次 + 输对成功一次"**）。
2. Burp → Proxy → HTTP history → 全选 → 右键 `Save items` → 导出为 XML。
3. 二选一：
   - **丢文件夹**：把 XML 放进 `/tmp/campus-capture/`（本机），告诉我文件名即可，我来分析；
   - **贴给 AI**：先跑压缩脚本，再把它生成的 Markdown + 下面的提示词一起贴：
     ```
     python3 tools/burp-xml-summary.py captures/我的抓包.xml -o captures/小抄.md
     ```
     （`--no-redact` 会把 cookie/密码值也带上；默认是脱敏的，字段名仍然完整——判断字段名够用了。）
4. 把 AI 输出的 A~F 六段发我，我改进 `campus-portal-auth.sh` 并本地验证。

> 隐私提醒：Burp XML 里含**明文密码、学号、会话 cookie**。默认别提交进 git（`captures/.gitignore` 已挡住非文档文件），贴给外部 AI 前先跑压缩脚本。

---

## 二、提示词正文（从下面这条横线开始，整段复制）

---

你是「校园网门户认证脚本」的逆向助手。我会给你一份 Burp Suite 导出的 HTTP 抓包（或由脚本压缩过的抓包小抄），里面有我校校园网网页认证的完整过程，理想情况下包含**一次输错密码的失败请求**和**一次成功的请求**。如果没有失败样本，直接在输出里说明「缺失败样本」并告诉我你会退化成用连通性判定。

我的运行环境（不要提出环境里没有的东西）：

- 路由器：MT7981（联发科 filogic）刷 ImmortalWrt 25.12，shell 是 BusyBox `ash`
- 可用命令：`curl`（支持 `-k`、`--data-urlencode`、`-b/-c` cookie 文件）、`uci`、`logger`、`ping`、`wget`、`sed`、`awk`、`grep`、`nslookup`
- **没有**：python、node、jq、openssl 命令行、bash 数组、`curl --json`
- 脚本必须是 POSIX sh，能通过 `sh -n` 检查；不要用 `[[ ]]`、不要用数组
- 账号密码从 `uci get campus.main.user` / `uci get campus.main.pass` 读取，认证地址从 `uci get campus.main.auth_url` 读取
- **绝对不要**把真实密码、学号、姓名、cookie 值复述或写进脚本；抓包里出现的这些值一律用 `$CAMPUS_USER` / `$CAMPUS_PASS` / 占位符代替

请严格按下面 6 段输出，**不要输出整个脚本文件**，只要这 6 段；每段都要短、可粘贴：

【A. 认证接口】
- 完整字面量 URL（协议、主机、端口、路径、query 一个都不能少）：`...`
- 依据：抓包里哪一条（时间 / 方法 / 状态码）

【B. 前置请求】
- 是否需要先 GET 某个页面或接口来拿 cookie / token / challenge？需要 / 不需要
- 需要：GET 的完整 URL、是否要写 cookie 文件、要从响应里提取什么，并给出 BusyBox 下可用的提取片段（`sed`/`grep`/`awk`，一行到三行）
- 不需要：写「不需要」并给出依据（例如抓包里 POST 是第一个请求且没带前置 cookie）

【C. 登录请求】
- 方法：POST / GET
- `Content-Type`：
- 字段表，一行一个：`字段名 | 值来源（账号变量 / 密码变量 / 固定字面量 / 需计算 / 来自上一步响应）| 说明`
- 如果 body 或 query 里出现 `t` / `sign` / `token` / `callback` / `mac` / `nasip` / `wlanacname` / `wlanuserip` / `ac_id` / `user_ip` 之类，**逐个**说明：它从哪来、能不能写死、不能写死怎么算
- 密码是明文提交吗？如果不是（md5/hex/base64/自定义加密），必须给出：证据（哪个 JS 文件、哪段代码）、以及 BusyBox 环境下的替代方案（例如找明文的挑战接口、改用服务端接受的另一种登录方式，或明确说「本环境无法实现，需要外部算」）

【D. 成功判定】
- 成功响应里**独一无二**的特征字符串（精确到引号和大小写，不要只说 "success"）
- 失败响应的特征字符串（优先用这次错密码样本里的）
- 可直接粘贴的 POSIX sh 片段，形如：
  ```sh
  case "$RESP" in
      *'精确成功串'*) ok=1 ;;
      *'精确失败串'*) ok=0; say "认证被拒绝（账号或密码错）" ;;
      *) ok=2 ;;
  esac
  ```

【E. 附加机制】（有就写，没有就写「无」）
- JSONP/callback 包装：成功串是否被 `callback(...)` 包住，怎么剥离
- 心跳/保活：抓包里有没有周期性请求？间隔多久？要不要加 cron 兜底
- 登出接口（可选）
- 登录成功后是否还需要访问某个 URL 才算真正放行（有些门户要「确认页」）
- `User-Agent` / `Referer` 是否被服务端校验（我该用抓包里的哪个 UA，原样给出）

【F. 需要我确认的不确定点】
- 逐条列出你的推断和不确定的地方。**不要**把猜测当成事实写进 A~E

硬性规则：

1. 每条结论都要能对应到抓包里的具体证据（时间戳 / URL / 字段名 / 响应片段）；对应不上的放进 F。
2. 不许编造字段名或接口。缺证据就说不确定。
3. 如果这份抓包里**根本没有认证流量**（例如只是正常上网、刷论坛、看视频的流量），直接输出「这份抓包里没有认证流量」，并告诉我该重新抓什么：从哪个状态开始（断网/刚插网线）、点哪个按钮、以及抓到后用什么关键字自检（例如 URL 里含 `portal`/`srun`/`auth`，或响应里有 `302` + `Location`）。
4. 输出用中文；代码块里只放能直接粘贴的 sh，不要伪代码。

---

## 三、自检：AI 的输出合格吗

| 检查项 | 不合格的样子 | 合格的样子 |
|---|---|---|
| 认证 URL | `http://portal.example/login`（丢了 query、丢了端口） | 完整的 `http://10.10.10.10:801/srun_portal?callback=jsonp` |
| 字段名 | `user=/pass=`（通用猜的） | `action=login&user_name=...&user_pwd=...&nasip=...`（抓包里原样） |
| 成功判定 | `*success*` | `*'"result":"1"'*` 这种独一无二的串，并附上失败串 |
| 加密 | 「密码可能加密了」 | 「密码是 md5(username+password+token)，证据 xx.js 第 n 行；BusyBox 下无法实现，建议改用 xxx」 |
| 不确定 | 悄悄猜一个 | 明确列进 F 段 |

---

## 四、不想自己贴 AI？一句话模板

把 XML 放进投放点后，你只要跟我说：

> 抓包已放到 `/tmp/campus-capture/xxu-20260920-wired.xml`，按 `captures/AI-PROMPT.md` 的 A~F 六段分析，然后把 `campus-portal-auth.sh` 的 3 处填空补成正式实现，给我本地验证命令。

我会自己跑压缩脚本、自己判断"这份抓包里有没有认证流量"，然后给你改动 + 验证命令（不会替你编译/刷机）。
