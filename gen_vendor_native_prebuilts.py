import os, re

ROOT = "/home/dev/Videos/Avium/avium16.2"
DEV = os.path.join(ROOT, "device/samsung/sm8150-common")
STAGE = os.path.join(ROOT, "out/target/product/beyond1q/vendor")
PREFIX = "out/target/product/beyond1q/"

# Authoritative Soong install targets: anything listed here is already produced
# by a Soong module (even if a previous interrupted build left it out of the
# staging dir), so a Make prebuilt for the same path would be a duplicate rule.
SOONG_INSTALLED = set()
for imk in ("out/soong/installs-lineage_beyond1q.mk",):
    path = os.path.join(ROOT, imk)
    if os.path.exists(path):
        for line in open(path, errors="ignore"):
            if line.startswith(PREFIX):
                dst = line.split(":", 1)[0].strip()
                SOONG_INSTALLED.add(dst[len(PREFIX):])

PRODUCT_OUT = os.path.join(ROOT, "out/target/product/beyond1q")

# Soong install rules that exist on paper but do NOT reliably land in the
# vendor image. These must always be force-installed by us.
#
# android.hardware.memtrack@1.0-impl.so: the rule exists in
# installs-lineage_beyond1q.mk and the file is staged, yet vendor.img came out
# without it -> "Could not get passthrough implementation for
# android.hardware.memtrack@1.0::IMemtrack/default" -> memtrack-hal crash-loop
# -> system_server stuck in MemtrackProxyService -> boot_completed never set.
FORCE_INSTALL = {
    "vendor/lib64/hw/android.hardware.memtrack@1.0-impl.so",
    "vendor/lib/hw/android.hardware.memtrack@1.0-impl.so",
    # ipacm's DT_NEEDED closure. libipanat is the only one of the four that
    # cannot be built on this port: it pulls qti_kernel_headers, whose
    # linux/sched/types.h defines `struct sched_param` and collides with the
    # identical definition in bionic's sched.h, so its source module is marked
    # installable: false and the stock blob has to be shipped here.
    #
    # liboffloadhal, libnfnetlink and libnetfilter_conntrack are deliberately
    # NOT listed: they compile fine on A16 (external/libnfnetlink,
    # external/libnetfilter_conntrack and the legacy-um hal module respectively)
    # and their own install rules produce the files, so a prebuilt here would
    # collide with them.
    #
    # Missing libipanat leaves /vendor/bin/ipacm unexecutable, vendor.ipacm
    # down, ril.cidManager.initiated at 0 and the modem producing no RF
    # measurement at all (every RAT RSSI 0x0000 -> LTE never registers).
    "vendor/lib64/libipanat.so",
}

def installed(rel):
    # Only Soong install targets. Do NOT look at the staging dir: after one
    # build it already contains our own prebuilt outputs, which would make the
    # generator non-idempotent.
    if rel in FORCE_INSTALL:
        return False
    return rel in SOONG_INSTALLED

# Destinations installed by PRODUCT_COPY_FILES (vendor_restore.mk etc.).
COPY_DSTS = set()
for _base in ("device/samsung", "vendor/samsung", "vendor/qcom"):
    for _root, _, _files in os.walk(os.path.join(ROOT, _base)):
        for _f in _files:
            if not _f.endswith(".mk"):
                continue
            try:
                _txt = open(os.path.join(_root, _f), errors="ignore").read()
            except OSError:
                continue
            for _line in _txt.splitlines():
                if "$(TARGET_COPY_OUT_VENDOR)" not in _line or ":" not in _line:
                    continue
                for _part in _line.split():
                    if _part.startswith("#"):
                        break
                    if ":" in _part:
                        _dst = _part.rsplit(":", 1)[1]
                        if "$(TARGET_COPY_OUT_VENDOR)/" in _dst:
                            COPY_DSTS.add(_dst.split("$(TARGET_COPY_OUT_VENDOR)/", 1)[1].rstrip("\\"))


def san(s):
    return re.sub(r'[^A-Za-z0-9_]', '_', s)

entries = []   # (module_name, class, src_rel_from_DEV, install_dir, stem)
mods = []

def add(mod, cls, src, path, stem):
    entries.append((mod, cls, src, path, stem)); mods.append(mod)

# stock libs missing from proprietary/staging
skip = {
 "android.hardware.graphics.composer@2.1.so",
 "android.hardware.graphics.composer@2.1-resources.so",
 "android.hardware.graphics.composer@2.2-resources.so",
 "libhwc2on1adapter.so",
 "libhwc2onfbadapter.so",
 "libbluetooth_audio_session.so",
 "android.hardware.bluetooth.audio@2.0.so",
 # v136: EGL family must NOT be shipped from the stock vendor_libs.
 # linkerconfig aborts with
 #   "duplicate: libEGL.so is provided by default and system in [vendor]"
 # because the stock libEGL is also listed as a system-provided library for
 # the vendor namespace. The abort makes init fall back to the static
 # /linkerconfig/*/ld.config.txt stub, where /system/lib64 is the only search
 # path - which is what made keystore2 and qseecomd fail with
 # "libandroidicu.so not found". The AOSP-built libEGL/libGLESv2/libGLESv3
 # that Soong installs for vendor are the correct copies.
 "libEGL.so",
 "libGLESv2.so",
 "libGLESv3.so",
}
for arch in ("lib64", "lib"):
    d = os.path.join(DEV, "vendor_libs", arch)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if not name.endswith(".so") or name in skip:
            continue
        # A file in proprietary/ normally means some module installs it, so the
        # scan defers. FORCE_INSTALL entries are the exception: nothing installs
        # those, so do not skip them here.
        rel = "vendor/%s/%s" % (arch, name)
        if rel not in FORCE_INSTALL and os.path.exists(
                os.path.join(ROOT, "vendor/samsung/sm8150-common/proprietary/vendor", arch, name)):
            continue
        if installed("vendor/%s/%s" % (arch, name)):
            continue
        add("avium_stock_%s_%s" % (arch, san(name)), "ETC",
            "vendor_libs/%s/%s" % (arch, name), "$(TARGET_OUT_VENDOR)/" + arch, name)

# hw/ passthrough implementation modules. The top-level scan above misses
# these, and they are exactly what the HIDL passthrough loader dlopens.
for arch in ("lib64", "lib"):
    d = os.path.join(DEV, "vendor_libs", arch, "hw")
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if not name.endswith(".so") or name in skip:
            continue
        if os.path.exists(os.path.join(ROOT, "vendor/samsung/sm8150-common/proprietary/vendor", arch, "hw", name)):
            continue
        if installed("vendor/%s/hw/%s" % (arch, name)):
            continue
        add("avium_stock_%s_hw_%s" % (arch, san(name)), "ETC",
            "vendor_libs/%s/hw/%s" % (arch, name),
            "$(TARGET_OUT_VENDOR)/" + arch + "/hw", name)

# firmware (skip what vendor_restore already installs)
fwroot = os.path.join(DEV, "vendor_firmware/firmware")
for dirpath, _, files in os.walk(fwroot):
    for f in sorted(files):
        rel = os.path.relpath(os.path.join(dirpath, f), fwroot)
        if installed("vendor/firmware/" + rel):
            continue
        if ("firmware/" + rel) in COPY_DSTS:
            continue
        sub = os.path.dirname(rel)
        dest = "$(TARGET_OUT_VENDOR)/firmware" + (("/" + sub) if sub not in ("", ".") else "")
        add("avium_fw_" + san(rel), "ETC", "vendor_firmware/firmware/" + rel, dest, os.path.basename(rel))

# gatekeeper module + private libcrypto (impl is built by AOSP already)
if not installed("vendor/lib64/hw/gatekeeper.default.so"):
    add("avium_gk_gatekeeper_default", "ETC", "vendor_gatekeeper/gatekeeper.default.so",
    "$(TARGET_OUT_VENDOR)/lib64/hw", "gatekeeper.default.so")
if not installed("vendor/lib64/libcrypto_gk"):
    add("avium_gk_libcrypto_gk", "ETC", "vendor_gatekeeper/libcrypto_gk",
    "$(TARGET_OUT_VENDOR)/lib64", "libcrypto_gk")
# soundtrigger rc: the cc_binary module's init_rc install is not part of the
# vendorimage dependency graph, so install the file as a regular prebuilt.
add("avium_soundtrigger_rc", "ETC", "soundtrigger_service.rc",
    "$(TARGET_OUT_VENDOR)/etc/init", "soundtrigger_service.rc")

# mount point placeholders (fstab targets must exist inside the ro vendor image)
for d in ("firmware_mnt", "firmware-modem", "dsp"):
    add("avium_keep_" + san(d), "ETC", "vendor_keep/%s/.keep" % d,
        "$(TARGET_OUT_VENDOR)/" + d, ".keep")

# VINTF fragments (Kati rejects vintf/manifest paths in PRODUCT_COPY_FILES)
for f in sorted(os.listdir(os.path.join(DEV, "vendor_fragments"))):
    if not f.endswith(".xml") or f == "power-samsung.xml":
        continue
    # composer-qti-display.xml declares composer@2.4 while the device manifest
    # declares 2.1 (the version this build actually registers). Installing both
    # makes VINTF abort with "Conflicting FqInstance".
    if f == "android.hardware.graphics.composer-qti-display.xml":
        continue
    # wifi.supplicant is declared in DEVICE_MANIFEST_FILE (version 5, which
    # assemble_vintf would otherwise rewrite down to 4 in a vintf_fragment).
    if f == "android.hardware.wifi.supplicant.xml":
        continue
    if installed("vendor/etc/vintf/manifest/" + f):
        continue
    if ("etc/vintf/manifest/" + f) in COPY_DSTS:
        continue
    add("avium_frag_" + san(f), "ETC", "vendor_fragments/" + f,
        "$(TARGET_OUT_VENDOR)/etc/vintf/manifest", f)

# executables
if not installed("vendor/bin/hw/rild"):
    add("avium_rild", "EXECUTABLES", "vendor_radio/bin/hw/rild",
    "$(TARGET_OUT_VENDOR)/bin/hw", "rild")
if not installed("vendor/bin/hw/vendor.qti.hardware.display.allocator-service"):
    add("avium_display_allocator_service", "EXECUTABLES",
    "vendor_bins/bin/hw/vendor.qti.hardware.display.allocator-service",
    "$(TARGET_OUT_VENDOR)/bin/hw", "vendor.qti.hardware.display.allocator-service")

# Final guard: drop anything Soong already installs (targets and
# copy-vintf-manifest-checked macro lines included). FORCE_INSTALL entries are
# exempt: their rules are in the manifest but do not actually land in the
# image (same failure mode as memtrack), so they must be installed by us.
_inst = open(os.path.join(ROOT, "out/soong/installs-lineage_beyond1q.mk"), errors="ignore").read()
def _full(e):
    return "out/target/product/beyond1q/vendor/" + e[3].replace("$(TARGET_OUT_VENDOR)/", "") + "/" + e[4]
def _forced(e):
    return "vendor/" + e[3].replace("$(TARGET_OUT_VENDOR)/", "") + "/" + e[4] in FORCE_INSTALL
entries = [e for e in entries if _forced(e) or _full(e) not in _inst]
mods = [e[0] for e in entries]

out = ["# Generated by device/samsung/sm8150-common/gen_vendor_native_prebuilts.py - do not hand-edit.\n",
       "LOCAL_PATH := $(call my-dir)\n\n",
       "# Native Make prebuilts replacing the old fix_vendor_mountpoints.sh debugfs\n",
       "# injection. Included from device/samsung/beyond1q/Android.mk.\n\n"]
for mod, cls, src, path, stem in entries:
    out.append("include $(CLEAR_VARS)\n")
    out.append("LOCAL_MODULE := %s\n" % mod)
    out.append("LOCAL_MODULE_CLASS := %s\n" % cls)
    out.append("LOCAL_MODULE_TAGS := optional\n")
    out.append("LOCAL_SRC_FILES := %s\n" % src)
    out.append("LOCAL_MODULE_PATH := %s\n" % path)
    out.append("LOCAL_MODULE_STEM := %s\n" % stem)
    out.append("LOCAL_CHECK_ELF_FILES := false\n")
    out.append("include $(BUILD_PREBUILT)\n\n")
open(os.path.join(DEV, "vendor_native_prebuilts.mk"), "w").write("".join(out))

# PRODUCT_PACKAGES in vendor_native_fixes.mk: replace the generated package block
mkpath = os.path.join(DEV, "vendor_native_fixes.mk")
mk = open(mkpath).read()
head = mk.split("PRODUCT_PACKAGES += \\\n")[0]
lines = []
cur = "   "
for m in mods:
    cand = cur + " " + m
    if len(cand) > 110:
        lines.append(cur + " \\\n"); cur = "   " + " " + m
    else:
        cur = cand
lines.append(cur + "\n\n")
note = ("# All payloads are Make prebuilts listed above; there are no\n"
        "# PRODUCT_COPY_FILES here (Soong already installs the allocator and\n"
        "# gatekeeper rcs, and Kati rejects VINTF metadata in copy files).\n")
open(mkpath, "w").write(head + "PRODUCT_PACKAGES += \\\n" + "".join(lines) + note)

print("entries", len(entries))
