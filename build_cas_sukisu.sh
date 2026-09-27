#!/bin/bash
# CI 构建:cas (小米10至尊纪念版/apollo) + MIUI 14 + SukiSU
#
# ---- 为什么锁在这个 commit(2026-09 复核过一遍,别随手换成 main)----
#
# 仓库有九条分支,但只有三条线的 kernel/selinux/sepolicy.c 带 <5.7.0 回退分支,
# 也就是只有它们还能编 4.19。逐个实测的结果:
#
#   main / dev / new-wx / releases   2025-09-05  sepolicy.c 853 行  3 项 Kconfig
#       历史上 2025-03-22 做过 "rewrite the update history",和下面三条【没有
#       共同祖先】。sepolicy.c 里的 <5.7.0 回退分支被整段删掉,
#       struct filename_trans_key 变成无条件使用 —— 而 4.19 的
#       security/selinux/ss/policydb.h 里根本没有这个类型(5.7 才引入),
#       4.19 上只有 struct filename_trans(u32 stype/ttype + u16 tclass),
#       用 ebitmap filename_trans_ttypes 表达源类型集合,也没有
#       compat_filename_trans_count,filename_trans_datum 里也没有 next 指针。
#       => 编不过,和隐藏不隐藏 SELinux 无关。
#
#   nongki                          2025-07-09  sepolicy.c 1070 行  7 项 Kconfig
#       4.19 能编,但 Kconfig 是 KSU_LSM_SECURITY_HOOKS(把钩子挂 LSM framework),
#       没有 KSU_MANUAL_HOOK。这台机器不合适:小米把手动挂钩调用点直接焊进了
#       内核源码(fs/read_write.c:598、fs/exec.c:1954/1987、drivers/input/input.c:458),
#       而这三个全局变量只在 KSU 的非 kprobes 分支里定义,走 LSM 路径就接不上,
#       链接 vmlinux 时三个 undefined reference。
#
#   susfs-1.5.7                     2025-07-09  sepolicy.c 1070 行 23 项 Kconfig
#   susfs-main / susfs-test         2025-07-15  sepolicy.c 1070 行 22 项 Kconfig  <= 用这个
#       两条线的 kernel/selinux/{sepolicy.c,rules.c} 内容【完全相同】(md5 一致),
#       所以 4.19 兼容性一样;susfs-main 只是多 34 个 commit(动态签名、
#       CMD_HOOK_TYPE/stat 钩子、多管理器),并且去掉了已废弃的
#       KSU_SUSFS_SUS_OVERLAYFS。同为 4.19 可用,susfs-main 更新,故取它。
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
#
# 版本锁在【脚本】里,yml 不设 SUKISU_REF 的 env。之前踩过:
#   yml 的 env: SUKISU_REF: f4863b20  ← 优先级高于脚本的 ${SUKISU_REF:-...}
# 于是脚本注释写着 329b7f59、脚本默认值也是 329b7f59,实际编出来的却是
# f4863b20,而 zip 文件名里还印着 329b7f59 —— 三处自相矛盾,而且从产物
# 上完全看不出来。"单一事实来源"这句话,只有在没有更高优先级的来源时
# 才成立。yml 里已删掉这个 env。
SUKISU_REPO="${SUKISU_REPO:-https://github.com/liyafe1997/SukiSU-Ultra}"
SUKISU_REF="${SUKISU_REF:-329b7f59dc84d79ac27a3487cf21d90c01cdf656}"
KSU_EXPECTED_REF="$SUKISU_REF"

# 打在 zip 文件名里的标签 —— 从 REF 派生,不硬编码。
# 之前这里写死 "329b7f59-4.19-nongki",而 REF 可能被 yml 的 env 改掉,
# 结果文件名里的版本号和实际编的东西无关,这正是"声称 v4.2.0 内容却是另一
# 回事"那类错误的来源。派生之后两者永远一致:想换版本只改上面一行。
KSU_LABEL="${KSU_LABEL:-${SUKISU_REF:0:8}-4.19-nongki}"

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

# checkout 之后核对真实 SHA —— 这才是"编的到底是哪一版"的唯一可信凭据。
# 之前只 echo 不校验,而 SUKISU_REF 会被 yml 的 env 悄悄改掉(f4863b20 那次),
# 于是日志第 4 行印着一个版本、实际编的是另一个、产物文件名还印着第三个。
# 凡是靠"我以为我设了"来保证的东西,都要在这里用实际值再对一遍。
KSU_ACTUAL_REF=$(git -C KernelSU rev-parse HEAD)
echo "[SukiSU] HEAD       = ${KSU_ACTUAL_REF}"
echo "[SukiSU] 期望        = ${KSU_EXPECTED_REF}"
echo "[SukiSU] 提交: $(git -C KernelSU log -1 --format='%ad %s' --date=short)"
echo "[SukiSU] 文件名标签  = ${KSU_LABEL}"
if [ "$KSU_ACTUAL_REF" != "$KSU_EXPECTED_REF" ]; then
    echo "❌ 期望 ${KSU_EXPECTED_REF},实际 checkout 到 ${KSU_ACTUAL_REF} —— 版本对不上,终止"
    exit 1
fi
if [ "${KSU_LABEL:0:8}" != "${KSU_ACTUAL_REF:0:8}" ]; then
    echo "❌ 文件名标签 ${KSU_LABEL} 与实际 commit ${KSU_ACTUAL_REF:0:8} 不符 —— 产物会被错标,终止"
    exit 1
fi

# ---- 打 4.19 兼容补丁 ----
#
# 329b7f59 的 kernel/core_hook.c 有一个真实缺陷,和 4.19 本身无关:
#
#   1227  #ifdef CONFIG_KSU_SUSFS
#   1229      bool is_zygote_child = susfs_is_sid_equal(...);
#   1230  #endif            ← 提前闭合
#   1231      if (likely(is_zygote_child)) {      ← 使用跑到保护外面
#   ...
#   1270      }                ← 关闭 1231 那个 {
#   1271  #endif            ← 配 1249 的
#
# SUSFS 开启时正好自洽(声明和使用都在同一个 #ifdef 里),所以上游从来
# 没暴露。我们必须关 SUSFS(这棵树没打 susfs4ksu 补丁),于是:
#   - 1229 的声明被预处理删掉,1231 却还在用它 → use of undeclared identifier
#   - 1249..1271 整段被删,连 1270 那个闭合的 '}' 一起没了
#     → 1231 的 '{' 永远闭合不上,后面每一个函数定义都被报成
#       "function definition is not allowed here"
#
# 这就是"报错位置和错因位置差 230 行"的典型:真正的错因在 1230,
# 而第一条 fatal 报在 1353。f4863b20 没这问题,因为它用一个 #ifdef
# 把「声明 + if 整块」罩住了 —— 本 patch 就是把 329b7f59 改回那种写法。
KSU_PATCH="${KSU_PATCH:-ksu-4.19-compat.patch}"
# 必须转成绝对路径再往下走。`git -C KernelSU apply` 会让 git 按 KernelSU/
# 解析相对路径,而补丁在仓库根目录 —— 于是上面 `[ -f "$KSU_PATCH" ]` 按脚本
# cwd 检查说"在",git 紧接着却报 can't open patch。这个坑栽过一次。
case "$KSU_PATCH" in
    /*) ;;
    *)  KSU_PATCH="$PWD/$KSU_PATCH" ;;
esac
if [ ! -f "$KSU_PATCH" ]; then
    echo "❌ 找不到兼容补丁 $KSU_PATCH(应与本脚本同目录)"
    exit 1
fi
echo "[patch] 校验 $KSU_PATCH 是否适用于 ${KSU_ACTUAL_REF:0:8} ..."
if ! git -C KernelSU apply --check "$KSU_PATCH"; then
    # 不猜"可能上游自己修了"就放行 —— 那样编出来的会是一个没打补丁的
    # 内核,错误在几千行之外才爆出来,比现在停下难查得多。
    echo "❌ 补丁不适用于当前 SukiSU(${KSU_ACTUAL_REF:0:8})"
    echo "   要么上游已改这段(补丁作废,删掉即可),要么改动过大需要重做补丁。"
    echo "   绝不在这里静默跳过 —— 上一次跳过就编出了一个刷不动的内核。"
    exit 1
fi
git -C KernelSU apply "$KSU_PATCH"
echo "[patch] ✅ 已应用"

# ---- 大括号平衡自检 ----
# patch 修的正是"条件编译块里花括号不配对",而这类错误的编译报错点
# 和错因点能差几百行,光看编译日志极难定位。所以在编译【之前】就把它验掉,
# 而不是花 25 分钟跑完整树编译再从报错里反推。
#
# 做法:模拟一次预处理(把 CONFIG_KSU_SUSFS 整组视为关掉 —— 正是我们的实际
# 配置),逐文件数花括号是否配平。其它 #if 条件一律当开,近似足够:实测 15 个
# 源文件里只有 core_hook.c 会被判出问题,其余全部配平,没有误报。
#
# 这个自检本身被反向验证过 —— 断言必须能真的抓到问题,否则只是安慰剂:
#   未打 patch + SUSFS=开  → 配平(所以上游自己的 CI 永远发现不了这个 bug)
#   未打 patch + SUSFS=关  → core_hook.c 净 +1  ← 正是我们这个 4.19 无 susfs 的场景
#   打上 patch(两种模式)  → 配平
check_brace_balance() {
    python3 - <<'PY'
import glob, re, sys
bad = []
files = sorted(glob.glob('KernelSU/kernel/**/*.c', recursive=True))

def susfs_is_on():
    """本自检模拟的是【SUSFS 整组关闭】——正是这棵树实际的配置。"""
    return False

def branch_val(kind, rest):
    """在上面的模拟下,这个 #if 分支是否为真。"""
    if kind == 'if':
        return True                      # 其它条件一律当开,近似足够
    hit = rest.startswith('CONFIG_KSU_SUSFS')
    # 注意方向:SUSFS 关闭时,#ifdef CONFIG_KSU_SUSFS* 为【假】。
    # 这里曾经写反成 `hit if kind == 'ifdef'`,于是整组被当成开启 ——
    # 未打 patch 的 core_hook.c 反而报配平,断言彻底失效且不自知。
    on = susfs_is_on()
    return (hit if on else not hit) if kind == 'ifdef' else not (hit if on else not hit)

for path in files:
    out, stack = [], []
    for raw in open(path, encoding='utf-8', errors='replace'):
        s = raw.strip()
        if s.startswith('//') or s.startswith('*'):
            continue
        m = re.match(r'#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)', s)
        if m:
            d, rest = m.group(1), m.group(2).strip()
            # 栈帧 = (本分支条件是否为真, 外层上下文是否激活)。
            # SUSFS 必须按【前缀】判定整组:C 预处理器只认"宏是否定义",
            # 不认 Kconfig 里的 depends —— CONFIG_KSU_SUSFS_SUS_SU 这类子选项
            # 在依赖不满足时同样不出现在 config.h 里,于是 #ifdef 一律为假。
            # 早先写成精确匹配 'CONFIG_KSU_SUSFS',子选项全被当成开启,
            # 原始文件和修复文件都报配平 —— 断言形同虚设。
            if d in ('ifdef', 'ifndef', 'if'):
                outer = all(t and o for t, o in stack)
                stack.append((branch_val(d, rest), outer))
            elif d in ('elif', 'else'):
                if stack:
                    t, o = stack[-1]
                    stack[-1] = (not t, o)
            elif d == 'endif':
                if stack:
                    stack.pop()
            continue
        # 上一版这里只看了栈帧的第二个元素,而 #else 只翻转第一个,
        # 第二个从头到尾没变过 —— #else 之后的代码根本没被跳过,
        # selinux.c 的 ksu_getenforce() 因此误报。判据必须是 t and o。
        if all(t and o for t, o in stack):
            out.append(raw)
    depth = 0
    for line in out:
        code = re.sub(r'//.*', '', line)
        code = re.sub(r'"(\\.|[^"\\])*"', '""', code)
        depth += code.count('{') - code.count('}')
    if depth != 0:
        bad.append((path, depth))
print(f"[brace] 模拟 SUSFS=关闭,检查 {len(files)} 个源文件的大括号配平 ...")
for path, d in bad:
    print(f"  ❌ {path}  净{d:+d} 个未闭合的 '{{'")
if bad:
    print("  这类错误的编译报错点会远在错因之后,别去编译日志里找 —— 先修条件编译块。")
    sys.exit(1)
print("  ✅ 全部配平")
PY
}
check_brace_balance

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

apply_config() {
# 唯一的配置来源。预检和整树编译都调这个函数 —— 绝不允许两处各写一份。
#
# 踩过的坑:预检原来只 `scripts/config -e KSU -e KPM`,没关 SUSFS。而
# config KSU_SUSFS 的 Kconfig 默认值是 `default y`(只 depends on KSU),
# 于是预检那次编译里 CONFIG_KSU_SUSFS / _SUS_PATH / _SUS_MOUNT 全是开的,
# core_hook.c 里那几段被守卫的代码照样进编译,报出
# "use of undeclared identifier 'CMD_SUSFS_SET_ANDROID_DATA_ROOT_PATH'"。
# 真正的整树编译因为后面有 -d KSU_SUSFS 本来是能过的 —— 也就是说预检对着
# 一份【和真构建不同的配置】给假警报,而它唯一的价值就是"提前 30 分钟报错",
# 一旦配置分叉就从省时间变成白烧一轮 runner。共用函数就是为了根除这个。
scripts/config --file out/.config \
    -e KSU \
    -e KPM \
    -e KSU_MANUAL_HOOK \
    -d KSU_DEBUG \
    -d KSU_CMDLINE \
    -d KSU_ALLOWLIST_WORKAROUND \
    -d KSU_MULTI_MANAGER_SUPPORT

# SUSFS 整组必须关,而这组选项的默认值【几乎全是 y】,漏一条就翻车。
#
#   config KSU_SUSFS                  default y
#   config KSU_SUSFS_SUS_SU           default y   ← 上一次就是死在这条上
#
# SUSFS 依赖内核树侧的 fs/susfs.c(susfs4ksu 补丁),这棵树没打,所以只要
# CONFIG_KSU_SUSFS* 是 y,KSU 子树(core_hook.c 等)就会引用一批不存在的
# CMD_SUSFS_* 标识符,直接编译失败。
#
# 选项名不再手写清单,直接从挂上来的 drivers/kernelsu/Kconfig 里提取全部
# KSU_SUSFS* —— 手写清单已经栽过一次:329b7f59 的 Kconfig 有 15 个 SUSFS 选项,
# 我抄的 14 个少一条 KSU_SUSFS_SUS_SU(它的 depends 里带 KPROBES && HAVE_KPROBES
# && KPROBE_EVENTS,不在前 14 条的命名模式里,肉眼扫极易漏)。
# 上游增删选项时这段不用跟着改,漏一条的后果是整轮 runner 白烧,值得多写这几行。
SUSFS_OPTS=$(sed -n 's/^config \(KSU_SUSFS[A-Z_]*\)$/\1/p' drivers/kernelsu/Kconfig | sort -u)
SUSFS_N=$(printf '%s\n' "$SUSFS_OPTS" | grep -c . || true)
if [ "${SUSFS_N:-0}" -lt 1 ]; then
    echo "❌ 从 drivers/kernelsu/Kconfig 里没提取到任何 KSU_SUSFS* 选项,Kconfig 结构变了?"
    exit 1
fi
echo "[cfg] 关掉 ${SUSFS_N} 个 KSU_SUSFS* 选项:$(echo "$SUSFS_OPTS" | tr '\n' ' ')"
susfs_args=()
while IFS= read -r o; do
    [ -n "$o" ] && susfs_args+=(-d "$o")
done <<< "$SUSFS_OPTS"
scripts/config --file out/.config "${susfs_args[@]}"

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

# 打印实际生效的关键选项,免得"配了但没生效"这种事静默过去。
# SUSFS 也一并打出来:它默认值是 y,是最容易"忘了关"的一个。
echo "===== 生效的关键选项 ====="
grep -E '^CONFIG_(KSU|KPM|KSU_MANUAL_HOOK|KSU_DEBUG|KPROBES|KALLSYMS|KALLSYMS_ALL)=' out/.config || true
grep -E '^# CONFIG_(KSU_MANUAL_HOOK|KSU_DEBUG|KPROBES) is not set' out/.config || true
echo "--- SUSFS 应全部关闭 ---"
if grep -qE '^CONFIG_KSU_SUSFS' out/.config; then
    echo "❌ CONFIG_KSU_SUSFS* 仍处于打开状态,KSU 子树会引用不存在的 fs/susfs.c"
    grep -E '^CONFIG_KSU_SUSFS' out/.config
    exit 1
fi
echo "  ✅ 无 CONFIG_KSU_SUSFS* 打开"
echo "============================="
}

# ---- 预检:只编 KSU 目录 ----
# 整棵树要十几分钟才走到 drivers/kernelsu,4.19 兼容问题一个一个冒出来、一轮十几分钟。
# 这里先把 KSU 单独编出来,配合 -k 一次把剩下所有不兼容点全收齐,再决定要不要跑整树。
echo "[preflight] 单独编译 drivers/kernelsu(配 -k 一次收全所有错误)..."
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig >/dev/null
apply_config
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
# 选项名严格对齐 329b7f59 的 kernel/Kconfig,不去 enable 那个版本上不存在的符号
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
apply_config

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

# ---- KPM 基础设施:编译后必须再 patch 一次内核 ----
# 这是 KPM 运行时加载模块的"接收端":没有这一步,Image 里没有 KPM 头,
# 管理器的 KPM 页就加载不了任何 .kpm。
# 注意别把它和"隐藏 SELinux 修改"混为一谈 —— 后者在 SukiSU 这边是刷机后由
# 管理器注入 KPM 实现的,不是本脚本的编译产物(具体能不能用还没验证过,
# 仓库里也没找到叫这个名字的开关)。本脚本只负责把接收端打好。
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

# ---- 构建凭据:由脚本产出,yml 只负责 cat ----
# yml 以前自己 echo "${SUKISU_REPO} @ ${SUKISU_REF}" 写进 job summary,
# 那个 $SUKISU_REF 是 yml 自己的 env,和脚本实际 checkout 的东西是两条独立
# 通路 —— f4863b20 那次两者就不一致,而 summary 显示的是错的那个。
# 改成让脚本把自己核对过的真实值落盘,yml 只读这个文件,summary 里出现的
# 就只可能是实际编出来的那一版。
cat > dist/BUILD_INFO.txt <<EOF
SukiSU 仓库 : ${SUKISU_REPO}
SukiSU 期望 : ${KSU_EXPECTED_REF}
SukiSU 实际 : ${KSU_ACTUAL_REF}
SukiSU 提交 : $(git -C KernelSU log -1 --format='%ad %s' --date=short)
提交时间   : $(git -C KernelSU log -1 --format=%aI)
文件名标签 : ${KSU_LABEL}
兼容补丁   : ${KSU_PATCH}  ($(md5sum "$KSU_PATCH" | cut -d' ' -f1))
SUSFS 配置 : 整组关闭(这棵树没有 susfs4ksu 内核侧补丁 fs/susfs.c)
内核版本   : $(strings -a dist/Image_cas_sukisu | grep -m1 -o 'Linux version [^ ]*' || echo '(未取到)')
Image 大小 : $(stat -c%s dist/Image_cas_sukisu) 字节
Image md5  : $(md5sum dist/Image_cas_sukisu | cut -d' ' -f1)
EOF
echo "----- 构建凭据 -----"
cat dist/BUILD_INFO.txt
