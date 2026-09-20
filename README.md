# Login-edu —— 校园网登录 / 认证工具集

各种校园网的**自动登录**方案。每个平台/场景一个独立文件夹，互不干扰；
路由器固件、刷机、编译那类内容**不放这里**（那些在 [boot](https://github.com/2476818641/boot) 仓库）。

> 用途仅限**自己的设备、自己的账号**正常认证上网。请勿用来冒用他人账号或冒充他人设备。

## 目录

| 文件夹 | 平台 | 内容 |
|---|---|---|
| [`openwrt/`](openwrt/) | OpenWrt / ImmortalWrt 路由器（含有线上联与 **WiFi STA 无线上联**） | **两个脚本**：主脚本 `campus-net-setup.sh`（配置 MAC/TTL/MTU/UA + PPPoE 拨号，不做认证）、认证脚本 `campus-portal-auth.sh`（按抓包生成，带 `--install-hook` 自动登录）；另有抓包清单 |

## 30 秒上手（OpenWrt）

```sh
B=https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt

# 1) 主脚本：配置（MAC 克隆 / TTL / MTU / UA）+ PPPoE 拨号 + 连通性测试
wget -O /tmp/campus-net-setup.sh $B/campus-net-setup.sh
DRY_RUN=1 sh /tmp/campus-net-setup.sh     # 先干跑看看要改什么（不落盘、不断网）
sh /tmp/campus-net-setup.sh               # 正式跑

# 2) 认证脚本：只在需要网页认证（含 WiFi 上联）时才要，且要先按抓包生成
wget -O /etc/campus-portal-auth.sh $B/campus-portal-auth.sh && chmod +x /etc/campus-portal-auth.sh
/etc/campus-portal-auth.sh --setup        # 填账号/密码/认证地址
/etc/campus-portal-auth.sh                # 手动验证一次
/etc/campus-portal-auth.sh --install-hook # 装成 WAN 上线自动认证 + 每 5 分钟兜底
```

详细步骤、抓包清单、常见问题见 [`openwrt/README.md`](openwrt/README.md)。

## 背景：校园网一般怎么认人

| 检测手段 | 路由器上怎么对付 | 本仓库对应脚本 |
|---|---|---|
| **User-Agent**（Dr.COM 等查 UA 判断是不是路由器共享） | **UA3F** 统一改写 UA（老固件上的 UA2F 也兼容） | `campus-net-setup.sh` 第 2 步的 UA 段 |
| **TTL / IPID / TCP 指纹** | ① UA3F 的 L3 重写（TTL/IPID/TCP 时间戳/初始窗口）② 脚本另写一条内核 nft 规则兜底（全流量、零开销） | 同上；nft 规则写入 `/etc/nftables.d/10-ttl-fix.nft` |
| **MAC 绑定** | 把电脑的 MAC 克隆到 WAN 侧 | 同上（有线上联写 network，无线上联写 wireless） |
| **网页认证（portal）** | 定时 POST 账号密码到认证接口（**有线、WiFi 上联都一样要**） | `campus-portal-auth.sh`（+ `--install-hook` 自动登录） |
| **PPPoE 拨号** | netifd 里配 pppoe | `campus-net-setup.sh` 方式 1 |

## 许可证

脚本均为 GPL-2.0-only（文件头有 SPDX 标识）。
