#!/bin/bash
# CI 构建:cas (小米10至尊纪念版) + MIUI + SukiSU v4.2.0
# 由 awaw49 在 fork 上新增,用于 GitHub Actions 出包
set -euo pipefail

# 本脚本有 ~60 处 GNU 风格 `sed -i 's/../g' file`。macOS 的 BSD sed 语法不同,
# 这些命令会静默失败(不报错、也不改文件),结果是 dts 补丁全丢但构建照样跑完,
# 出一个"看着成功"实则没打 MIUI 补丁的包。与其让它悄悄错,不如直接拦下。
if ! sed --version >/dev/null 2>&1; then
    echo "错误:需要 GNU sed。本脚本在 macOS/BSD sed 上会静默失效(请用 CI 或 Linux)。" >&2
    exit 1
fi

TARGET_DEVICE=cas
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
SUKISU_TAG="${SUKISU_TAG:-v4.2.0}"

# ---- 工具链:CI 里用 AOSP clang + 交叉 binutils ----
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

# ---- 装 SukiSU(v4 的 setup.sh 接口:收 tag/commit,不再收 SUSFS commit) ----
echo "[SukiSU] 安装 ${SUKISU_TAG} ..."
curl -LSs "https://github.com/SukiSU-Ultra/SukiSU-Ultra/raw/${SUKISU_TAG}/kernel/setup.sh" | sh -s "${SUKISU_TAG}"
test -d KernelSU/kernel || { echo "SukiSU 安装失败"; exit 1; }
echo "[SukiSU] 实际版本: $(cd KernelSU && git describe --tags 2>/dev/null || echo unknown)"

# ---- 4.19 兼容:KPM 用了两参数 access_ok,而 4.19 的 arm64 还是三参数 ----
# 上游 v4.2.0 的 kpm.c 里 10 处 access_ok() 全是裸调、零版本保护,在这棵 4.19
# 树上会直接报 "too few arguments provided to function-like macro invocation"。
# 按仓库自己 kernel/infra/file_wrapper.c 的 #if/#elif/#else 范式补一个包装宏,
# 只在 <5.9 时走三参数分支;不改上游任何逻辑,只换调用点。
KPM_C=KernelSU/kernel/kpm/kpm.c
python3 - "$KPM_C" <<'PY'
import sys

p = sys.argv[1]
src = open(p).read()

# 幂等守卫必须看 shim 的【定义行】,不能看 ksu_access_ok 这个名字 ——
# 调用点改写之后这个名字必然出现在文件里,拿它当判据会自己把自己拦下来。
if "#define ksu_access_ok" in src:
    print("[compat] 兼容层已存在,跳过")
    sys.exit(0)

n = src.count("if (!access_ok(")
if n == 0:
    print("[compat] 上游已无裸调 access_ok,跳过")
    sys.exit(0)

# 锚点取自 kpm.c:41,插在所有 #include 之后(此时 <linux/version.h> 已就位),
# 且远早于第一个调用点。
marker = "#define KPM_NAME_LEN 32"
if marker not in src:
    sys.exit("锚点 '#define KPM_NAME_LEN 32' 未找到 —— kpm.c 结构已变,补丁需人工跟进")

src = src.replace("if (!access_ok(", "if (!ksu_access_ok(")

shim = """/*
 * ---- 4.19 兼容层(构建时本地追加,非上游代码)----
 * KPM 按 5.9+ 的两参数 access_ok(addr, size) 写,
 * 而 4.19 及更早的 arm64 定义是三参数 access_ok(type, addr, size),
 * 裸调会编译失败。这里按内核版本分派。
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
#define ksu_access_ok(addr, size) access_ok(0, (addr), (size))
#else
#define ksu_access_ok(addr, size) access_ok((addr), (size))
#endif

"""
src = src.replace(marker, shim + marker, 1)

# 打完必须一条裸调都不剩、且改写数与预期一致,否则又得白跑一轮 40 分钟
left = src.count("if (!access_ok(")
done = src.count("if (!ksu_access_ok(")
if left or done != n:
    sys.exit(f"替换数量异常: 残留={left} 改写={done} 预期={n},中止")
if src.count("#define ksu_access_ok") != 2:
    sys.exit("shim 分支数异常(应为 2),中止")

open(p, "w").write(src)
print(f"[compat] 改写 {n} 处,残留 0 处,shim 已插入 {p}")
PY

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

# ---- 内核选项:KSU v4 + MIUI 专属 ----
    scripts/config --file out/.config \
        -e KSU \
        -e KPM \
        -d KSU_DEBUG \
        -d KSU_MANUAL_SU \
        -d KSU_DISABLE_MANAGER \
        -d KSU_DISABLE_POLICY

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

make $MAKE_ARGS -j$(nproc)

[ -f out/arch/arm64/boot/Image ] || { echo "编译失败:没有生成 Image"; exit 1; }
echo "[build] Image 生成成功"

find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

# ---- KPM 基础设施:编译后必须再 patch 一次内核,管理器才能嵌 selinux_hook ----
echo "[KPM] patch_linux 打补丁 ..."
cd out/arch/arm64/boot
wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
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
zip -r9 "../dist/Kernel_MIUI_${TARGET_DEVICE}_SukiSU-${SUKISU_TAG}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip" ./* -x .git .gitignore out/ ./*.zip
cd ..

echo "===== 完成 ====="
ls -la dist/
