# Login-edu —— 校园网登录 / 认证工具集

各种校园网的**自动登录**方案。每个平台/场景一个独立文件夹，互不干扰；
路由器固件、刷机、编译那类内容**不放这里**（那些在 [boot](https://github.com/2476818641/boot) 仓库）。

> 用途仅限**自己的设备、自己的账号**正常认证上网。请勿用来冒用他人账号或冒充他人设备。

## 目录

| 文件夹 | 平台 | 内容 |
|---|---|---|
| [`openwrt/`](openwrt/) | OpenWrt / ImmortalWrt 路由器（含有线上联与 **WiFi STA 无线上联**） | 一键配置（MAC/TTL/MTU/UA + PPPoE/网页认证）、网页认证脚本骨架、WAN 上线自动认证（hotplug + cron 兜底） |

## 30 秒上手（OpenWrt）

```sh
# 1) 拿脚本（国内可套你自己的 ghproxy）
B=https://raw.githubusercontent.com/2476818641/Login-edu/main/openwrt
wget -O /tmp/campus-net-setup.sh   $B/campus-net-setup.sh
wget -O /etc/campus-portal-auth.sh $B/campus-portal-auth.sh
chmod +x /etc/campus-portal-auth.sh

# 2) 先干跑看看要改什么（不落盘、不断网）
DRY_RUN=1 sh /tmp/campus-net-setup.sh

# 3) 正式配置（会问接入方式、MAC、TTL、MTU、UA、账号密码）
sh /tmp/campus-net-setup.sh
```

详细步骤、抓包清单、常见问题见 [`openwrt/README.md`](openwrt/README.md)。

## 背景：校园网一般怎么认人

| 检测手段 | 路由器上怎么对付 | 本仓库对应脚本 |
|---|---|---|
| **User-Agent**（Dr.COM 等查 UA 判断是不是路由器共享） | UA2F 统一改写 UA | `campus-net-setup.sh` 第 2 步的 UA 段 |
| **TTL**（共享的包经过一跳 TTL 会 -1） | nftables 在 postrouting 把出口 TTL 改回 64 | 同上，写入 `/etc/nftables.d/10-ttl-fix.nft` |
| **MAC 绑定** | 把电脑的 MAC 克隆到 WAN 侧 | 同上（有线上联写 network，无线上联写 wireless） |
| **网页认证（portal）** | 定时 POST 账号密码到认证接口 | `campus-portal-auth.sh` + hotplug/cron |
| **PPPoE 拨号** | netifd 里配 pppoe | `campus-net-setup.sh` 方式 1 |

## 许可证

脚本均为 GPL-2.0-only（文件头有 SPDX 标识）。
