#!/bin/bash
# CI 构建:cas (小米10至尊纪念版/apollo) + MIUI 14 + SukiSU
#
# ---- 版本锁:yspbwx2010/SukiSU-Ultra 真上游 main(2026-09-27 重订)----
#
# 之前锁的是 liyafe1997/SukiSU-Ultra —— 那是 yspbwx2010 的【个人 fork】,
# 停在 2025-07-15,比真上游落后整整 13 个月。后果不是"版本旧一点",而是直接废机:
# 内核里的 manager 签名表还是 2025-07 那版,而手机上装的是 2026 年的 SukiSU
# 管理器 —— 包名对不上、APK 签名 sha256 也对不上,于是
# 【管理器认不出内核】+【不给 root】,两个症状一个原因。
# 所以这里锁的必须是 yspbwx2010 本家,不是任何人的 fork。
#
# 197cad88 (2026-08-15) 的 kernel/ 相比 329b7f59 变化很大:
#   - 目录从扁平 15 个 .c 拆成 core/ feature/ hook/ infra/ kpm/ manager/
#     policy/ runtime/ selinux/ sulog/ supercall/ 十一层
#   - 挂钩换成 kprobes + 直接改写 sys_call_table,不再依赖内核树里预埋的
#     ksu_vfs_read_hook / ksu_execveat_hook / ksu_input_hook
#   - Kconfig 整组重写:没有 SUSFS、没有 KSU_MANUAL_HOOK,
#     新增 KSU_MANUAL_SU / KPM / KSU_DISABLE_MANAGER / KSU_DISABLE_POLICY
#   - config KSU depends on KPROBES && EXT4_FS,这棵树两个都是 y
#
# 4.19 上要补的洞一共四处,分别写在下面两个 patch 里,每处都注明了为什么。
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
SUKISU_REPO="${SUKISU_REPO:-https://github.com/yspbwx2010/SukiSU-Ultra}"
SUKISU_REF="${SUKISU_REF:-197cad8838da8d6cdf80356678e6100ce5e27a41}"
KSU_EXPECTED_REF="$SUKISU_REF"

# 打在 zip 文件名里的标签 —— 从 REF 派生,不硬编码。
# 之前这里写死 "329b7f59-4.19-nongki",而 REF 可能被 yml 的 env 改掉,
# 结果文件名里的版本号和实际编的东西无关,这正是"声称 v4.2.0 内容却是另一
# 回事"那类错误的来源。派生之后两者永远一致:想换版本只改上面一行。
KSU_LABEL="${KSU_LABEL:-${SUKISU_REF:0:8}-4.19-kprobes}"

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
# 必须完整 clone,不能用 --filter=blob:none / --depth。
# kernel/Kbuild 用 `git rev-list --count main` 算 KSU_VERSION
# (KSU_VERSION = 40000 + commit数 - 2815),浅克隆里没有 main 这个 ref,
# rev-list 失败 → KSU_VERSION 掉回兜底值 13000,管理器里显示成一个 ancient 版本。
# 这个数是内核对外报的版本号,不是装饰,算错就等于交了一份对不上的货。
git clone "${SUKISU_REPO}" KernelSU
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

# ---- 打 4.19 兼容补丁(两个,分属两棵树) ----
#
# 329b7f59 时代只有一个 ksu-4.19-compat.patch,改的是 KSU 自己的 core_hook.c。
# 197cad88 换了挂钩机制之后,缺口换了一整类,得两个 patch 分头补:
#
# [A] ksu-4.19-kprobes.patch —— 打在内核树(仓库根)上,两处:
#   (1) 摘掉 fs/read_write.c、fs/exec.c、drivers/input/input.c 里那三处
#       #ifdef CONFIG_KSU 的预埋调用点。
#       这棵树出厂时把 KSU 的【手动挂钩】焊进了内核源码,但上游 main 已经
#       删掉了对应的全局变量(ksu_vfs_read_hook / ksu_execveat_hook /
#       ksu_input_hook —— 在 197cad88 的 kernel/ 里 grep 全是 0 命中)。
#       CONFIG_KSU 一开,调用点就激活而变量无人定义,链接 vmlinux 直接
#       undefined reference。main 走的是 kprobes + 改 sys_call_table,
#       不需要这些调用点,所以正确做法是摘掉,不是补定义。
#   (2) kernel/kallsyms.c 末尾补一行 EXPORT_SYMBOL_GPL(kallsyms_lookup_name)。
#       4.19 里这个函数【存在但不导出】(实测 kernel/kallsyms.c 只有
#       sprint_symbol / sprint_symbol_no_offset 两个 EXPORT)。
#       main 的 infra/symbol_resolver.c 直接调它来定位 sys_call_table,
#       不导出就是链接失败。这是 4.19 移植绕不开的一刀,社区各 LKM 也都这么补。
#
# [B] ksu-4.19-main.patch —— 打在 KernelSU 上,两处:
#   (1) include/ksu.h 补 copy_{from,to}_user_nofault 垫片(5.8 才有的 API)。
#   (2) Kbuild 给 KSU 子树加 -Wno-error(cas_defconfig 里 CONFIG_CC_WERROR=y)。
apply_patch_file() {
    local patch="$1" dir="$2" what="$3"
    # 回填绝对路径,BUILD_INFO 后面要再取一次 md5
    # 必须转成绝对路径。`git -C <dir> apply` 会让 git 按 <dir>/ 解析相对路径,
    # 而补丁文件在仓库根 —— 于是 `[ -f "$patch" ]` 按脚本 cwd 检查说"在",
    # git 紧接着却报 can't open patch。这个坑栽过一次。
    case "$patch" in
        /*) ;;
        *)  patch="$PWD/$patch" ;;
    esac
    if [ ! -f "$patch" ]; then
        echo "❌ 找不到 $what 补丁 $patch(应与本脚本同目录)"
        exit 1
    fi
    echo "[patch:$what] 校验 $patch ..."
    if ! git -C "$dir" apply --check "$patch"; then
        # 不猜"可能上游自己修了"就放行 —— 那样编出来的会是一个没打补丁的
        # 内核,错误在几千行之外才爆出来,比现在停下难查得多。
        echo "❌ $what 补丁不适用于当前代码"
        echo "   要么上游已改这段(补丁作废,删掉即可),要么改动过大需要重做补丁。"
        echo "   绝不在这里静默跳过。"
        exit 1
    fi
    git -C "$dir" apply "$patch"
    echo "[patch:$what] ✅ 已应用  ($(md5sum "$patch" | cut -d' ' -f1))"
    printf -v "${4}" '%s' "$patch"
}

KSU_PATCH="${KSU_PATCH:-ksu-4.19-main.patch}"
KERNEL_PATCH="${KERNEL_PATCH:-ksu-4.19-kprobes.patch}"
apply_patch_file "$KERNEL_PATCH" "." "内核侧" KERNEL_PATCH_ABS
apply_patch_file "$KSU_PATCH"   "KernelSU" "KSU侧" KSU_PATCH_ABS

# 补丁生效的硬断言:内核树里不该再有任何指向已删除符号的引用。
# 链接器当然也会报,但那时整树已经编了十几分钟;这里几秒钟就能拦下,
# 而且报出来的信息直接指向是哪个文件哪一行。
LEFT=$(grep -rln 'ksu_vfs_read_hook\|ksu_execveat_hook\|ksu_input_hook\|ksu_handle_faccessat\|ksu_handle_stat\|ksu_handle_devpts' \
        fs/ drivers/ arch/ include/ 2>/dev/null || true)
if [ -n "$LEFT" ]; then
    echo "❌ 内核树里仍有已删除符号的引用:"
    echo "$LEFT"
    exit 1
fi
echo "[patch] ✅ 内核树已无 ksu_*_hook / ksu_handle_* 残留引用"

# path_mount 出口:上游 KSU 的 su_mount_ns.c 要调它(MS_PRIVATE|MS_REC 把 root
# 子树改 private),而 cas 这棵 Android 4.19 的 fs/namespace.c 里没有这个入口,
# 能干活的 do_change_type() 是 static。内核侧补丁里补了一个薄封装,这里确认它
# 真的补进去了 —— 缺了不会在这里报,要到链接 vmlinux 才炸,而那时整树已经
# 编了二十多分钟。
grep -q 'EXPORT_SYMBOL_GPL(path_mount);' fs/namespace.c || {
    echo "❌ fs/namespace.c 里没有 path_mount 出口,内核侧补丁没生效"
    exit 1
}
echo "[patch] ✅ fs/namespace.c 的 path_mount 出口就位"

# ---- 大括号平衡自检 ----
# 这类错误的编译报错点和错因点能差几百行,光看编译日志极难定位。
# 所以在编译【之前】就把它验掉,而不是花二十几分钟跑完整树再从报错里反推。
#
# 做法:按我们【实际生效的配置】模拟一次预处理,逐文件数花括号是否配平。
# 197cad88 的 Kconfig 一共只有 7 个选项,取值全部已知(main 已经没有 SUSFS):
#   KSU=y  KSU_DEBUG=n  KSU_MANUAL_SU=y  KPM=y
#   KSU_DISABLE_MANAGER=n  KSU_DISABLE_POLICY=n  KSU_X86_PATCH_...=n
# 未知的一律当"开"—— 这是保守方向:多算几行代码,宁可误报也不漏报。
#
# 关键点:C 预处理器只认"宏是否【定义】",不认 Kconfig 里的 depends。
# 所以 CONFIG_KSU_DISABLE_MANAGER 在关掉时同样不出现在 config.h 里,
# #ifdef 一律为假 —— 这里必须逐个选项查表,不能靠"整组前缀"。
#
# 这个自检本身被反向验证过 —— 断言必须能真的抓到问题,否则只是安慰剂:
#   拿 329b7f59 那份有 bug 的 core_hook.c 反向灌进来,必须报出净 +1。
check_brace_balance() {
    python3 - <<'PY'
import glob, re, sys

# 与 build_cas_sukisu.sh 的 scripts/config 调用保持一致
OPTS = {
    "CONFIG_KSU":                            True,
    "CONFIG_KSU_DEBUG":                      False,
    "CONFIG_KSU_MANUAL_SU":                  True,
    "CONFIG_KPM":                            True,
    "CONFIG_KSU_DISABLE_MANAGER":            False,
    "CONFIG_KSU_DISABLE_POLICY":             False,
    "CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER": False,
}

def macro_defined(rest):
    """rest 形如 'CONFIG_KSU_DEBUG' 或 'defined(CONFIG_KSU) && FOO'。
    取其中所有 CONFIG_KSU* / CONFIG_KPM 项,全部已定义才算真;
    没提到的宏(KPROBES 之类)一律当已定义。"""
    names = re.findall(r'\b(CONFIG_[A-Z0-9_]+|KPM)\b', rest)
    for n in names:
        if n in OPTS and not OPTS[n]:
            return False
    return True

def branch_val(kind, rest):
    if kind == 'if':
        return macro_defined(rest)
    if kind == 'ifdef':
        return macro_defined(rest)
    return not macro_defined(rest)      # ifndef

bad = []
files = sorted(glob.glob('KernelSU/kernel/**/*.c', recursive=True))
if not files:
    sys.exit("❌ 一个 KernelSU/kernel/*.c 都没找到 —— 挂载或路径出了问题")

for path in files:
    out, stack = [], []
    for raw in open(path, encoding='utf-8', errors='replace'):
        t = raw.strip()
        if t.startswith('//') or t.startswith('*'):
            continue
        m = re.match(r'#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)', t)
        if m:
            d, rest = m.group(1), m.group(2).strip()
            # 栈帧 = (本分支条件是否为真, 外层上下文是否激活)。
            # 判据必须是 t and o —— 早先只看了第二项,而 #else 只翻转第一项,
            # 第二项从头到尾没变,#else 之后的代码根本没被跳过。
            if d in ('ifdef', 'ifndef', 'if'):
                outer = all(t0 and o0 for t0, o0 in stack)
                stack.append((branch_val(d, rest), outer))
            elif d in ('elif', 'else'):
                if stack:
                    t0, o0 = stack[-1]
                    stack[-1] = (not t0, o0)
            elif d == 'endif':
                if stack: stack.pop()
            continue
        if all(t0 and o0 for t0, o0 in stack):
            out.append(raw)
    depth = 0
    for line in out:
        code = re.sub(r'//.*', '', line)
        code = re.sub(r'"(\\.|[^"\\])*"', '""', code)
        depth += code.count('{') - code.count('}')
    if depth != 0:
        bad.append((path, depth))

print(f"[brace] 按本脚本实际配置模拟预处理,检查 {len(files)} 个源文件的大括号配平 ...")
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
# 早先预检和整树各写一份 scripts/config,两边配置分叉,预检对着一份
# 【和真构建不同的配置】给假警报,而它唯一的价值就是"提前二十几分钟报错",
# 一旦分叉就从省时间变成白烧一轮 runner。共用函数就是为了根除这个。
#
# 选项名严格对齐 197cad88 的 kernel/Kconfig,不 enable 那一版上不存在的符号
# (scripts/config 对不存在的选项照样会写一行 "# CONFIG_X is not set",
#  无害,但会让人以为"配过了")。
#
#   KSU                          必开。depends on KPROBES && EXT4_FS
#   KSU_MANUAL_SU                手动 su(上游默认 y),按原样保留
#   KPM                          Kernel Patch Module 接收端,原作者的包也开着
#   KSU_DEBUG                    关。pr_info 本身不受它控制,照常出日志
#   KSU_DISABLE_MANAGER          关 = 保留管理器识别(我们靠这个)
#   KSU_DISABLE_POLICY           关 = 保留 per-app root 策略
#   KSU_X86_PATCH_SYSCALL_DISPATCHER  x86 专用,arm64 上无意义
#
# 197cad88 的 Kconfig 里【没有 SUSFS,也没有 KSU_MANUAL_HOOK】,上一版那套
# "从 Kconfig 里动态提取 KSU_SUSFS* 全部关掉"的逻辑连同它的前提一起作废了。
# 那段逻辑本身没错(手写清单漏过一次选项),但它守的是一个已经不存在的风险。
scripts/config --file out/.config \
    -e KSU \
    -e KSU_MANUAL_SU \
    -e KPM \
    -d KSU_DEBUG \
    -d KSU_DISABLE_MANAGER \
    -d KSU_DISABLE_POLICY \
    -d KSU_X86_PATCH_SYSCALL_DISPATCHER

# 依赖不满足时 Kconfig 会【静默丢弃】CONFIG_KSU,编出一个看着成功、
# 实则根本没有 KSU 的内核。这里逐条硬查,缺一条就当场停。
echo "[cfg] 检查 KSU 的 Kconfig 依赖是否真的满足 ..."
missing=0
for opt in KPROBES EXT4_FS; do
    if grep -qE "^CONFIG_${opt}=y" out/.config; then
        echo "  ✅ CONFIG_${opt}=y"
    else
        echo "  ❌ CONFIG_${opt} 不是 y —— config KSU depends on KPROBES && EXT4_FS,"
        echo "     Kconfig 会把 CONFIG_KSU 整个丢掉,内核里就不会有 KSU"
        missing=1
    fi
done
if ! grep -qE '^CONFIG_KSU=y' out/.config; then
    echo "  ❌ CONFIG_KSU 没有生效。Kconfig 把它丢了,或 drivers/kernelsu 没接进构建。"
    missing=1
fi
[ "$missing" -eq 0 ] || exit 1

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
echo "===== 生效的关键选项 ====="
grep -E '^CONFIG_(KSU|KPM|KSU_MANUAL_SU|KSU_DEBUG|KSU_DISABLE_MANAGER|KSU_DISABLE_POLICY|KPROBES|KALLSYMS|KALLSYMS_ALL)=y$' out/.config || true
grep -E '^# CONFIG_(KSU|KSU_DEBUG|KPROBES|EXT4_FS) is not set' out/.config || true
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
# 所以光看退出码不够,还要数 .o,并且核对的是【新版目录结构】里的那几个文件。
#
# 197cad88 的 kernel/Kbuild 在 CONFIG_KSU=y、KPM=y、DISABLE_*=n 时会编 27 个 .o。
# 门槛设 20:既能区分"真的编了"和"空跑",又给内核版本差异留了余量。
#
# 更有用的是下面这条路径断言 —— 上一轮把用户手机刷废,根因就是"编的不是
# 我以为的那一版",而产物外观完全看不出差别。这里直接点名 197cad88 才有的
# hook/arm64/syscall_hook.o:它不存在,就说明挂上去的根本不是新版 KSU。
if make $MAKE_ARGS -k drivers/kernelsu/ >/tmp/preflight.log 2>&1; then
    NOBJ=$(find out/drivers/kernelsu -name '*.o' 2>/dev/null | wc -l | tr -d ' ')
    if [ "${NOBJ:-0}" -lt 20 ]; then
        echo "[preflight] ❌ make 退出 0 但只产出 ${NOBJ} 个 .o —— 预检在空跑,不可信"
        grep -E "Nothing to be done|No rule to make target" /tmp/preflight.log | head -8
        exit 1
    fi
    for must in core/init.o hook/arm64/syscall_hook.o infra/symbol_resolver.o \
                runtime/ksud_integration.o supercall/dispatch.o; do
        if [ ! -f "out/drivers/kernelsu/${must}" ]; then
            echo "[preflight] ❌ 缺 out/drivers/kernelsu/${must}"
            echo "   197cad88 的 kernel/Kbuild 一定会编它。缺了就说明挂上去的"
            echo "   不是这一版 KSU(很可能是旧的扁平目录结构)—— 停在这里,"
            echo "   别让它编出一个"看着成功、实则版本不对"的内核。"
            exit 1
        fi
    done
    echo "[preflight] ✅ KSU 目录编译通过(${NOBJ} 个 .o,新版目录结构已确认)"
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

# KSU 对外报的版本号是 Kbuild 用 `40000 + git rev-list --count main - 2815`
# 算出来的,管理器读的就是这个数。它不是装饰 —— 算错了就是交了一份对不上
# 的货。这里把构建日志里 Kbuild 自己打印的那行原样抓出来,进 BUILD_INFO。
KSU_VERSION_REPORTED=$(grep -oE 'SukiSU-Ultra version: [0-9]+ \[[^]]*\]' /tmp/build.log | head -1 || true)
if [ -z "$KSU_VERSION_REPORTED" ]; then
    echo "❌ 构建日志里找不到 Kbuild 打印的 KSU 版本号 —— 版本锁没生效?"
    grep -m3 'version:' /tmp/build.log || true
    exit 1
fi
echo "[build] ${KSU_VERSION_REPORTED}"

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
KSU 版本号 : ${KSU_VERSION_REPORTED:-未取到}
manager 包名: ${KSU_MANAGER_PACKAGE:-(不校验,仅校验 APK 签名)}
manager 签名: size=${KSU_EXPECTED_SIZE:-0x35c} sha256=${KSU_EXPECTED_HASH:-上游默认}
内核侧补丁 : ${KERNEL_PATCH_ABS}  ($(md5sum "$KERNEL_PATCH_ABS" | cut -d' ' -f1))
KSU 侧补丁 : ${KSU_PATCH_ABS}  ($(md5sum "$KSU_PATCH_ABS" | cut -d' ' -f1))
挂钩方式   : kprobes + 改写 sys_call_table(内核树里预埋的 ksu_*_hook 调用点已摘除)
KSU 选项   : KSU=y KSU_MANUAL_SU=y KPM=y 其余关
依赖检查   : CONFIG_KPROBES=y CONFIG_EXT4_FS=y
内核版本   : $(strings -a dist/Image_cas_sukisu | grep -m1 -o 'Linux version [^ ]*' || echo '(未取到)')
Image 大小 : $(stat -c%s dist/Image_cas_sukisu) 字节
Image md5  : $(md5sum dist/Image_cas_sukisu | cut -d' ' -f1)
EOF