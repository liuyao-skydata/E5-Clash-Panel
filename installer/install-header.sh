#!/bin/sh
# =============================================================================
#  E5 信息屏 · Clash 面板  安装包（自解压）
#
#  适用：跑本 OpenWrt 镜像（armsr/armv8，apk 包管理）的 E5 随身 WiFi
#  内容：信息屏前端（www）+ 后端 api.uc + Clash 状态采集 + 时区修复
#  不会动：/etc/e5-infoscreen（壁纸、已装插件）、/etc/config/e5-infoscreen（你的设置）
#
#  用法（在手机上，root shell）：
#      sh e5-panel-install.sh              # 安装 / 升级
#      sh e5-panel-install.sh --restore    # 还原到安装前的版本
#      sh e5-panel-install.sh --help       # 看帮助
#
#  安装前会自动备份到 /root/e5-panel-backups/<时间>/，出问题可以还原。
# =============================================================================

PKG_NAME="e5-infoscreen-clash"
PKG_VER="1.0.0"
BUILT="2026-11-12"
PAYLOAD_SHA="@SHA256@"
SKIP=@SKIP@
BACKUP_ROOT=/root/e5-panel-backups
PATHS="usr/share/e5-infoscreen usr/libexec/e5-infoscreen usr/libexec/e5-clash-status etc/init.d/e5-infoscreen www/luci-static/resources/view/e5-infoscreen usr/share/luci/menu.d/luci-app-e5-infoscreen.json usr/share/rpcd/acl.d/luci-app-e5-infoscreen.json usr/share/zoneinfo/Asia/Shanghai"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }
banner() {
	say "=============================================="
	say " E5 信息屏 · Clash 面板  $PKG_VER  ($BUILT)"
	say "=============================================="
}

help_text() {
	banner
	cat <<'EOF'
安装：sh e5-panel-install.sh
还原：sh e5-panel-install.sh --restore   （回到最近一次安装前的状态）
卸载：sh e5-panel-install.sh --uninstall --yes
      （删掉信息屏的程序文件；壁纸、插件、设置在 /etc 里，会留着）
帮助：sh e5-panel-install.sh --help

装完在设备屏幕上：应用 → Clash面板（第 10 页）就是这一页。
EOF
}

need_root() {
	[ "$(id -u)" = 0 ] || die "要用 root 跑：ssh root@<设备IP> 之后执行"
}

# 把即将被覆盖的路径逐个打包，还原时逐个解回去
backup_now() {
	TS=$(date +%Y%m%d-%H%M%S)
	BAK="$BACKUP_ROOT/$TS"
	mkdir -p "$BAK" || die "建不了备份目录 $BAK（存储满了？）"
	n=0
	for p in $PATHS; do
		[ -e "/$p" ] || continue
		f=$(echo "$p" | tr '/' '_')
		tar -czf "$BAK/$f.tar.gz" -C / "$p" 2>/dev/null && n=$((n + 1))
	done
	[ "$n" -gt 0 ] || { rmdir "$BAK" 2>/dev/null; BAK=""; }
}

# 只留最近 5 份备份，别把 /root 塞满
prune_backups() {
	ls -1 "$BACKUP_ROOT" 2>/dev/null | sort | head -n -5 | while read -r old; do
		rm -rf "$BACKUP_ROOT/$old"
	done
}

verify_payload() {
	[ -n "$PAYLOAD_SHA" ] || return 0
	got=$(tail -n +"$SKIP" "$0" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$PAYLOAD_SHA" ] || die "安装包内容校验失败（文件损坏或被改动过）：期望 $PAYLOAD_SHA，实际 $got"
}

stop_service() {
	[ -x /etc/init.d/e5-infoscreen ] && /etc/init.d/e5-infoscreen stop >/dev/null 2>&1
	sleep 1
	return 0
}

wait_api() {
	i=0
	while [ "$i" -lt 20 ]; do
		if wget -q -T 2 -O /dev/null http://127.0.0.1:8088/ 2>/dev/null; then return 0; fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

do_install() {
	banner
	need_root
	[ -f /etc/openwrt_release ] || die "这不是 OpenWrt：找不到 /etc/openwrt_release"
	grep -q "^DISTRIB_ARCH='aarch64_generic'" /etc/openwrt_release || \
		say "! 注意：这台设备的架构不是 aarch64_generic，文件虽然是纯脚本/网页，仍建议先备份"

	verify_payload
	say "· 安装包校验通过"

	say "· 备份现有文件…"
	backup_now
	[ -n "$BAK" ] && { say "  已备份到 $BAK"; prune_backups; } || say "  （这是全新安装，没有可备份的旧文件）"

	say "· 停止信息屏…"
	stop_service

	say "· 解包…"
	mkdir -p /etc/e5-infoscreen/plugins /etc/e5-infoscreen/wallpapers
	tail -n +"$SKIP" "$0" | tar -xzf - -C / || die "解包失败，用 --restore 还原"

	# 权限：脚本要可执行，网页/配置保持只读
	chmod 755 /etc/init.d/e5-infoscreen 2>/dev/null
	chmod 755 /usr/libexec/e5-infoscreen/* 2>/dev/null
	chmod 755 /usr/libexec/e5-clash-status 2>/dev/null
	chmod 644 /usr/share/e5-infoscreen/*.uc /usr/share/e5-infoscreen/default.config 2>/dev/null
	chmod 644 /usr/share/e5-infoscreen/www/*.js /usr/share/e5-infoscreen/www/*.html /usr/share/e5-infoscreen/www/*.css 2>/dev/null

	# 全新安装：没有配置就铺一份默认的（老用户不动他的设置）
	[ -f /etc/config/e5-infoscreen ] || {
		cp /usr/share/e5-infoscreen/default.config /etc/config/e5-infoscreen
		say "· 写入默认配置 /etc/config/e5-infoscreen"
	}

	# 依赖只提示，不拦：缺了也能装，只是页面起不来或测速没数
	miss=""
	for b in ucode uhttpd; do command -v "$b" >/dev/null 2>&1 || miss="$miss $b"; done
	[ -d /usr/lib/ucode ] || miss="$miss ucode-mod-*"
	[ -n "$miss" ] && say "! 还缺这些，信息屏可能起不来：$miss（apk add uhttpd-mod-ucode ucode-mod-uci 等）"
	command -v curl >/dev/null 2>&1 || say "! 没装 curl：Clash 面板的延迟/IP 卡会是空的"
	command -v clash >/dev/null 2>&1 || [ -d /etc/openclash ] || say "! 没装 OpenClash：面板能开，但会显示「未运行」"

	say "· 启动信息屏…"
	/etc/init.d/e5-infoscreen enable >/dev/null 2>&1
	/etc/init.d/e5-infoscreen restart >/dev/null 2>&1
	if wait_api; then
		say "✓ 安装完成，面板已上线（版本 $PKG_VER + Clash 面板）"
		say "  · 设备屏幕： 应用 → Clash面板（第 10 页）"
		say "  · 页面地址： http://127.0.0.1:8088（只在本机，不对外开）"
		[ -n "$BAK" ] && say "  · 还原用：   sh $0 --restore"
	else
		say "! 装好了，但 8088 端口 20 秒内没起来。看日志：logread -f | grep -i 'e5-infoscreen\\|uhttpd'"
		[ -n "$BAK" ] && say "! 要退回去：sh $0 --restore"
		exit 1
	fi
}

do_restore() {
	banner
	need_root
	latest=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort | tail -n 1)
	[ -n "$latest" ] || die "找不到备份（$BACKUP_ROOT 是空的）"
	say "· 还原到安装前：$latest"
	stop_service
	for f in "$BACKUP_ROOT/$latest"/*.tar.gz; do
		[ -e "$f" ] || continue
		tar -xzf "$f" -C / || die "还原失败：$f"
	done
	/etc/init.d/e5-infoscreen enable >/dev/null 2>&1
	/etc/init.d/e5-infoscreen restart >/dev/null 2>&1
	if wait_api; then
		say "✓ 已还原，信息屏在跑"
	else
		say "! 还原后 8088 还没起来，logread 看看"
		exit 1
	fi
}

do_uninstall() {
	banner
	need_root
	say "· 停止并禁用信息屏…"
	stop_service
	[ -x /etc/init.d/e5-infoscreen ] && /etc/init.d/e5-infoscreen disable >/dev/null 2>&1
	say "· 删除程序文件…"
	tail -n +"$SKIP" "$0" | tar -tzf - | while read -r p; do
		case "$p" in
		usr/* | etc/init.d/* | www/*) rm -rf "/$p" ;;
		esac
	done
	rmdir /etc/e5-infoscreen/plugins /etc/e5-infoscreen/wallpapers 2>/dev/null
	say "✓ 已卸载。留下的：/etc/e5-infoscreen（壁纸、插件）、/etc/config/e5-infoscreen（设置）"
	say "  想连这些一起清掉： rm -rf /etc/config/e5-infoscreen /etc/e5-infoscreen"
}

case "$1" in
--help | -h) help_text ;;
--restore) do_restore ;;
--uninstall)
	[ "$2" = "--yes" ] || die "卸载会删掉 /usr/share/e5-infoscreen 等目录，确认请加 --yes"
	do_uninstall
	;;
"") do_install ;;
*) die "未知参数 $1（用 --help 看用法）" ;;
esac

exit 0
__PAYLOAD__
