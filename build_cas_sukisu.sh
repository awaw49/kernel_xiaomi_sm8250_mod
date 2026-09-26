#!/bin/bash
# CI 构建:cas (小米10至尊纪念版/apollo) + MIUI 14 + SukiSU
#
# 版本锁定说明(重要,别随手改):
#   上游 v4.2.0 的 hide-SELinux 特性(selinux/sepolicy.c / rules.c / selinux_hide.c)
#   在这棵 4.19 树上会炸出 83 个错误 —— 4.19 的 selinux_state 没有 policy/status_lock/
#   status_page,struct selinux_policy 是不完整类型,filename_trans_key 的字段名
#   (otype/stypes/next)整体不同。那 88 个 SELinux 错误【就是】隐藏 SELinux 的实现本身,
#   不是能打补丁绕过的胶水层,而是一次从零开始的 4.19 SELinux 移植。
#   所以:要 4.19,就不能要 v4.2.0 的 hide-SELinux。二者在这台机器上互斥。
#
#   这里锁到 liyafe1997/SukiSU-Ultra@f4863b20(2025-07-09)。该版本的
#   selinux/*.c 全部有 KERNEL_VERSION 守卫,且 sepolicy.c 里有一条显式的
#   "< 5.7.0 回退路径"(原注释: "// < 5.7.0, has no filename_trans_key,
#   but struct filename_trans"),4.19 会正确落进去。
#   锚点上 ksu_access_ok / MODULE_IMPORT_NS 也都是上游自带且已版本守卫,
#   所以本脚本不再做任何源码级兼容改写 —— 少改一行就少错一处。
set -euo pipefail

# 本脚本有多处 GNU 风格 `sed -i 's/../g' file`。macOS 的 BSD sed 语法不同,
# 这些命令会静默失败(不报错、也不改文件),结果是 dts 补丁全丢但构建照样跑完,
# 出一个"看着成功"实则没打 MIUI 补丁的包。与其让它悄悄错,不如直接拦下。
if ! sed --version >/dev/null 2>&1; then
    echo "错误:需要 GNU sed。本脚本在 macOS/BSD sed 上会静默失效(请用 CI 或 Linux)。" >&2
    exit 1
fi

TARGET_DEVICE=cas
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)

# ---- SukiSU 固定版本 ----
SUKISU_REPO="${SUKISU_REPO:-https://github.com/liyafe1997/SukiSU-Ultra}"
SUKISU_REF="${SUKISU_REF:-f4863b20cc8dc0f8cc67418980f022e43014b598}"
# 打在 zip 文件名里的标签。锁的是 commit 不是 tag,这里用日期+短 sha 标,
# 免得文件名上写着 v4.2.0 结果内容完全是另一回事。
KSU_LABEL="${KSU_LABEL:-f4863b20-4.19-compatible}"

# ---- 工具链:CI 里用 clang + 交叉 binutils ----
if [ -z "${CLANG_BIN:-}" ]; then
    echo "错误:请设置 CLANG_BIN 环境变量指向 clang 的 bin 目录"; exit 1
fi
export PATH="$CLANG_BIN:$PATH"
command -v clang >/dev/null || { echo "clang 不可用"; exit 1; }
command -v aarch64-linux-gnu-ld >/dev/null || { echo "缺 aarch64-linux-gnu-ld"; exit 1; }
command -v arm-linux-gnueabi-ld >/dev/null || { echo "缺 arm-linux-gnueabi-ld"; exit 1; }
echo "[clang] $(clang --version | head -1)"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang \
CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

# ---- 装 SukiSU ----
# 这里没用上游 kernel/setup.sh,而是自己 clone + checkout + 挂 symlink + 改
# drivers/{Makefile,Kconfig}。原因:setup.sh 把仓库 URL 写死在函数体里,换 fork
# 就得把它的源码 sed 掉再管道给 sh;自己写这 4 步既能控制 checkout 的 commit,
# 也能对"挂上了没有"做硬断言 —— setup.sh 里那句
#   grep -q "kernelsu" $DRIVER_MAKEFILE || printf ... && echo
# 用了 `||` 和 `&&` 混 precedence,一旦 grep 命中就整条短路,append 不执行也不报错,
# 后面照样接着跑,最后产出一个没有 KSU 的内核。
echo "[SukiSU] clone ${SUKISU_REPO} @ ${SUKISU_REF}"
rm -rf KernelSU
git clone --filter=blob:none "${SUKISU_REPO}" KernelSU
git -C KernelSU checkout --detach "${SUKISU_REF}"
echo "[SukiSU] HEAD = $(git -C KernelSU rev-parse HEAD)"
echo "[SukiSU] 提交: $(git -C KernelSU log -1 --format='%ad %s' --date=short)"

# 挂进 drivers/ —— 必须是相对 symlink,kbuild 才能找到源文件
ln -sfn ../KernelSU/kernel drivers/kernelsu
test -f drivers/kernelsu/Kconfig || { echo "错误:symlink 没挂上"; exit 1; }

# 把 kernelsu 接进 drivers 的构建
if ! grep -q 'drivers/kernelsu\|obj-\$(CONFIG_KSU) += kernelsu' drivers/Makefile; then
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    echo "[SukiSU] drivers/Makefile 已加 obj-\$(CONFIG_KSU) += kernelsu/"
fi
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
    sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    echo "[SukiSU] drivers/Kconfig 已加 source"
fi

# 4.19 这棵树告警致命(诊断标签是 [-Werror,-Wimplicit-int]),而 CI 用的是
# clang 17、上游当年是 proton-clang 12 —— 新版 clang 对同一份代码吐的新告警
# 会直接顶死构建,而那些告警无一影响 KSU 功能。给 KSU 子目录单独关掉 -Werror。
# 追加在文件末尾:上游 Makefile 结尾有 "Keep a new line here!!" 的显式邀请。
if ! grep -q 'KSU_NO_WERROR_MARK' drivers/kernelsu/Makefile; then
    printf '\n# KSU_NO_WERROR_MARK: 4.19 + clang17 的新告警不应杀死 KSU 子树\nccflags-y += -Wno-error\n' >> drivers/kernelsu/Makefile
    echo "[SukiSU] 已给 KSU 子目录加 -Wno-error"
fi

# ---- 预生成 security/selinux 的派生头文件 ----
# out/security/selinux/flask.h 不是源码,是 scripts/selinux/genheaders/genheaders
# 在编译 security/selinux/ 时生成的(见该目录 Makefile 第 31 行)。
# KSU 的 selinux/sepolicy.c、selinux/rules.c 要 include 它,KSU Makefile 靠
# -I$(objtree)/security/selinux 定位 —— 路径本身是对的,问题在顺序:
# 顶层 Makefile 里 drivers/ 排在 security/ 之前,-j 并行时 drivers/kernelsu
# 很可能先编完,而那时 flask.h 还不存在。预检只编 drivers/kernelsu/,更是必然落空。
# 社区那个 modder 能编出包,靠的是并行时序碰巧对了,不可复现。
#
# 办法:先单独编一遍 security/selinux/ 把 flask.h 落盘。preflight 和后面的整树
# 编译共用同一个 out/,所以这一步对两段都有效。整树编译若因 .config 变化重编
# selinux,flask.h 会被重新生成 —— 但那时它至少已经存在过,ksu 那边不会失败。
gen_flask_header() {
    echo "[genhdr] 预生成 security/selinux/flask.h ..."
    if ! make $MAKE_ARGS -k security/selinux/ >/tmp/genhdr.log 2>&1; then
        echo "[genhdr] ❌ 编译 security/selinux 失败,尾部日志:"
        tail -30 /tmp/genhdr.log
        exit 1
    fi
    local f=out/security/selinux/flask.h
    test -f "$f" || { echo "[genhdr] ❌ 编译成功但没有 $f,genheaders 规则变了?"; exit 1; }
    echo "[genhdr] ✅ $f ($(wc -c < "$f" | tr -d ' ') 字节)"
}

# ---- 预检:只编 KSU 目录 ----
# 整棵树要十几分钟才走到 drivers/kernelsu,4.19 兼容问题一个一个冒出来、一轮十几分钟。
# 这里先把 KSU 单独编出来,配合 -k 一次把剩下所有不兼容点全收齐,再决定要不要跑整树。
echo "[preflight] 单独编译 drivers/kernelsu(配 -k 一次收全所有错误)..."
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig >/dev/null
scripts/config --file out/.config -e KSU -e KPM
gen_flask_header
rm -rf out/drivers/kernelsu 2>/dev/null || true
rm -f /tmp/preflight.log

# 目标名必须带结尾斜杠。kbuild 对已存在的目录目标不做任何事,make 视为 up-to-date
# 直接 exit 0 —— 那样预检就是空跑:上一轮 13 秒报"编译通过",整树阶段照样 83 个错误。
# 所以光看退出码不够,还要数 .o。KSU 有 9 个 + selinux 3 个 + kpm 3 个 = 15 个源文件,
# 门槛设 5 既有足够区分度,又不会因为内核版本差异导致误报。
if make $MAKE_ARGS -k drivers/kernelsu/ >/tmp/preflight.log 2>&1; then
    NOBJ=$(find out/drivers/kernelsu -name '*.o' 2>/dev/null | wc -l | tr -d ' ')
    if [ "${NOBJ:-0}" -lt 5 ]; then
        echo "[preflight] ❌ make 退出 0 但只产出 ${NOBJ} 个 .o —— 预检在空跑,不可信"
        grep -E "Nothing to be done|No rule to make target" /tmp/preflight.log | head -8
        exit 1
    fi
    echo "[preflight] ✅ KSU 目录编译通过(${NOBJ} 个 .o)"
else
    if grep -q "No rule to make target" /tmp/preflight.log; then
        # 目标名在这个内核版本上不认,不是真错误,放行让整树编译去暴露问题
        echo "[preflight] 目标名不适用于本内核,跳过预检(不影响后续整树编译)"
    else
        echo "[preflight] ❌ KSU 编译失败,错误清单:"
        grep -E "error:|fatal error" /tmp/preflight.log | head -60
        echo "[preflight] 完整日志 /tmp/preflight.log"
        exit 1
    fi
fi

# ---- AnyKernel3 打包用 ----
git clone --depth=1 -b kona https://github.com/liyafe1997/AnyKernel3 anykernel

# ---- 打上构建日期后缀 ----
sed -i "s/-perf/-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ---- MIUI 专用:屏幕/显示驱动 dts 修补(逐字取自原 build.sh) ----
dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

# Correct panel dimensions on MIUI builds
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# Enable back mi smartfps while disabling qsync min refresh-rate
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

# Enable back refresh rates supported on MIUI
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi


# Enable back brightness control from dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# ---- 内核选项 ----
# 选项名严格对齐 f4863b20 的 kernel/Kconfig,不去 enable 那个版本上不存在的符号
# (scripts/config 对不存在的选项照样会写一行 "# CONFIG_X is not set",无害但会误导人)。
#
# KSU_MANUAL_HOOK 必须【开】,这是这棵树出厂就决定的,不是可选项:
# 小米把 KernelSU 的手动挂钩调用点直接焊进了内核源码 ——
#   fs/read_write.c:598        调 ksu_vfs_read_hook()
#   fs/exec.c:1954 / :1987     调 ksu_execveat_hook()
#   drivers/input/input.c:458  调 ksu_input_hook()
# 而这三个全局变量在 SukiSU 里是 ksud.c:52 那个 #ifdef 的【else】分支里定义的:
#   #ifdef CONFIG_KSU_KPROBES_HOOK ... #else bool ksu_vfs_read_hook = true; ...
# KPROBES 模式不会定义它们,可内核树里的调用点是按 #ifdef CONFIG_KSU 守卫的,
# 与 MANUAL_HOOK 无关 —— 于是 CONFIG_KSU 一开,调用点就激活,而没有定义,
# 最后链接 vmlinux 时三个 undefined reference,rc=2。
# 所以:既然树里已经预埋了手动调用点,就必须让 KSU 走手动路径把它们接上。
# (KPROBES 模式要求内核侧调用点被摘掉,那是改内核树,没有必要。)
# 反过来这也解释了社区那个 cas 预编译包:它 Image 里 register_kprobe 命中为 0,
# 不是"装饰品",而是它本来就走的 MANUAL_HOOK 路径。
scripts/config --file out/.config \
    -e KSU \
    -e KPM \
    -e KSU_MANUAL_HOOK \
    -d KSU_DEBUG \
    -d KSU_CMDLINE \
    -d KSU_ALLOWLIST_WORKAROUND \
    -d KSU_MULTI_MANAGER_SUPPORT

# SUSFS 整组关掉:SUSFS 是内核树侧的东西(kernel/Makefile 里靠 test -e fs/susfs.c 探测),
# 这棵树没集成 susfs4ksu,留着 KSU_SUSFS=y 只会写一堆没人读的 .config 项。
# 真要 SUSFS 得先按 gitlab.com/simonpunk/susfs4ksu 打补丁,那是另一件事。
scripts/config --file out/.config \
    -d KSU_SUSFS \
    -d KSU_SUSFS_HAS_MAGIC_MOUNT \
    -d KSU_SUSFS_SUS_PATH \
    -d KSU_SUSFS_SUS_MOUNT \
    -d KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -d KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -d KSU_SUSFS_SUS_KSTAT \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -d KSU_SUSFS_TRY_UMOUNT \
    -d KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -d KSU_SUSFS_SPOOF_UNAME \
    -d KSU_SUSFS_ENABLE_LOG \
    -d KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG

# KPM 靠 select 拉进来的 KALLSYMS_ALL 会把全量符号名塞进 Image。
# 这正好让 CI 的 strings 校验能真的查到 KernelSU 符号,而不是靠字符串残留蒙。
scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK	\
    -e SF_BINDER		\
    -e OVERLAY_FS		\
    -d DEBUG_FS \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -e PERF_HUMANTASK \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO \
    -e SF_BINDER \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -d CONFIG_MODULE_SIG_SHA512 \
    -d CONFIG_MODULE_SIG_HASH \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM \

# 打印实际生效的关键选项,免得"配了但没生效"这种事静默过去
echo "===== 生效的关键选项 ====="
grep -E '^CONFIG_(KSU|KPM|KSU_MANUAL_HOOK|KSU_DEBUG|KPROBES|KALLSYMS|KALLSYMS_ALL)=' out/.config || true
grep -E '^# CONFIG_(KSU_MANUAL_HOOK|KSU_DEBUG|KPROBES) is not set' out/.config || true
echo "============================="

# 整树编译前再确认一次 flask.h 在位。中间隔了一次 defconfig,若 .config 有任何
# 变化导致 security/selinux 被重编,它的 flask.h 会跟着重新生成 —— 顺序上
# drivers/ 仍然在 security/ 之前,所以这里显式再落一次盘,不去赌并行时序。
gen_flask_header

# -k:一次把剩下所有错误收齐,而不是撞上第一个就停。
# 每轮整树编译十几分钟,一轮只换一个错误太亏。
set +e
make $MAKE_ARGS -k -j$(nproc) 2>&1 | tee /tmp/build.log
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
    echo "===== 编译失败 (rc=${rc}),错误清单 ====="
    grep -E "error:|fatal error" /tmp/build.log | head -80
    echo "===== 完整日志 /tmp/build.log ====="
    exit 1
fi

[ -f out/arch/arm64/boot/Image ] || { echo "编译失败:没有生成 Image"; exit 1; }
echo "[build] Image 生成成功"

find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

# ---- KPM 基础设施:编译后必须再 patch 一次内核,管理器才能嵌 selinux_hook ----
# 注意:这是 KPM 运行时加载模块的"接收端",不是编译期嵌 selinux_hook。
# 隐藏 SELinux 修改需要 KSU 管理器在刷入后执行「重新修补镜像」把 selinux_hook
# 这个 KPM 塞进来;4.19 上即使塞了也未必能工作(理由见文件头)。
echo "[KPM] patch_linux 打补丁 ..."
cd out/arch/arm64/boot
wget -q -O patch_linux https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
chmod +x patch_linux
./patch_linux
rm -f Image && mv oImage Image
cd - >/dev/null

# ---- 打包 anykernel3 ----
rm -rf anykernel/kernels/ && mkdir -p anykernel/kernels/
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb  anykernel/kernels/

mkdir -p dist
cp out/arch/arm64/boot/Image dist/Image_cas_sukisu

cd anykernel
zip -r9 "../dist/Kernel_MIUI_${TARGET_DEVICE}_SukiSU-${KSU_LABEL}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip" ./* -x .git .gitignore out/ ./*.zip
cd ..

echo "===== 完成 ====="
ls -la dist/
