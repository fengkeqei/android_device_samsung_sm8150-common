#!/usr/bin/env python3
"""Generate vendor_hidl_prebuilts.mk: the stock HIDL interface libraries that
the vendor partition needs but that neither Soong's install graph nor the
generated vendor.mk ships.

Background
----------
The vendor HAL binaries are prebuilt Samsung blobs, so Soong's dependency graph
never walks their DT_NEEDED closure. The stock HIDL interface libraries they
link (android.hardware.usb@1.3.so, android.hardware.wifi@1.4.so, ...) are
therefore missing from vendor.img unless something installs them.

Historically that gap was filled by inject_vendor_hidl_libs.sh, which rewrote
vendor.img with debugfs after every build. That made the image depend on a
post-processing step instead of on the build graph, so a plain `mka vendorimage`
produced an unbootable vendor partition.

This generator emits the same payload as native Make prebuilts instead. The
source of truth is the library list in inject_vendor_hidl_libs.sh, so the two
cannot drift.

Run it from the tree root. It is idempotent.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.abspath(os.path.join(ROOT, "..", "..", ".."))
DEV = ROOT
STOCKV = os.path.join(DEV, "vendor_libs")
PROP = os.path.join(TREE, "vendor/samsung/sm8150-common/proprietary/vendor")
OUT_MK = os.path.join(DEV, "vendor_hidl_prebuilts.mk")

# Libraries the injector leaves alone because an AOSP-built vendor variant must
# win. Keep this in sync with skip_v() in inject_vendor_hidl_libs.sh.
SKIP = {
    "android.hardware.graphics.composer@2.1.so",
    "android.hardware.graphics.composer@2.1-resources.so",
    "android.hardware.graphics.composer@2.2-resources.so",
    "libhwc2on1adapter.so",
    "libhwc2onfbadapter.so",
    "libbluetooth_audio_session.so",
    "android.hardware.bluetooth.audio@2.0.so",
    "libstagefright_bufferqueue_helper.so",
    "android.hidl.token@1.0-utils.so",
    "android.hidl.token@1.0.so",
    "libEGL.so",
    "libGLESv2.so",
    "libGLESv3.so",
    "libandroid_net.so",
    "libapexsupport.so",
    "libbinder_ndk.so",
    "liblog.so",
    "libnativewindow.so",
    "libselinux.so",
    "libsync.so",
    "libvndksupport.so",
}


def injector_libs():
    """Read the LIBS="..." list out of the injector script."""
    path = os.path.join(DEV, "inject_vendor_hidl_libs.sh")
    text = open(path, errors="ignore").read()
    m = re.search(r'^LIBS="\n(.*?)\n"', text, re.S | re.M)
    if not m:
        sys.exit("could not find LIBS block in inject_vendor_hidl_libs.sh")
    return [ln.strip() for ln in m.group(1).splitlines() if ln.strip().endswith(".so")]


def san(s):
    return re.sub(r"[^A-Za-z0-9_]", "_", s)


def source_for(lib):
    """Return (source_path_relative_to_DEV, vendor_subdir) or None."""
    for arch in ("lib64", "lib"):
        for base, rel in ((STOCKV, "vendor_libs"), (PROP, None)):
            p = os.path.join(base, arch, lib)
            if os.path.isfile(p):
                if rel:
                    return os.path.join(rel, arch, lib), arch
                # proprietary/ is already relative to the tree, not to DEV;
                # emit an absolute-from-tree path instead.
                return os.path.join(
                    "vendor/samsung/sm8150-common/proprietary/vendor", arch, lib
                ), arch
    return None


def main():
    libs = [l for l in injector_libs() if l not in SKIP]
    # The injector list can name the same library twice (it is built from both
    # the HIDL list and the stock vendor_libs scan), and a library may exist in
    # both vendor_libs/ and proprietary/. Emit each destination once.
    # Soong already installs some of these to vendor/lib* (its install graph
    # covers the interface libraries that a built vendor HAL links). A Make
    # prebuilt for the same destination makes Kati abort with
    #   error: overriding commands for target
    #   `out/target/product/beyond1q/vendor/lib64/<lib>'
    # so drop anything already in the install manifest.
    soong = set()
    manifest = os.path.join(TREE, "out/soong/installs-lineage_beyond1q.mk")
    if os.path.isfile(manifest):
        prefix = "out/target/product/beyond1q/vendor/"
        for line in open(manifest, errors="ignore"):
            if line.startswith(prefix) and ":" in line:
                soong.add(line.split(":", 1)[0][len(prefix):])

    # vendor_native_prebuilts.mk (the other generator) already ships some of
    # these; two Make prebuilts for one destination abort with
    #   error: overriding commands for target `.../vendor/lib64/<lib>'
    other = os.path.join(DEV, "vendor_native_prebuilts.mk")
    covered = set()
    if os.path.isfile(other):
        for line in open(other, errors="ignore"):
            if line.startswith("LOCAL_MODULE_STEM :="):
                covered.add(line.split(":=", 1)[1].strip())

    seen = set()
    entries = []
    missing = []
    for lib in libs:
        if lib in seen:
            continue
        seen.add(lib)
        got = source_for(lib)
        if got is None:
            missing.append(lib)
            continue
        src, arch = got
        if "%s/%s" % (arch, lib) in soong:
            continue
        if lib in covered:
            continue
        entries.append((lib, src, arch))

    out = [
        "# Generated by device/samsung/sm8150-common/gen_vendor_hidl_prebuilts.py\n",
        "# Do not hand-edit. Re-run the generator instead.\n",
        "#\n",
        "# Stock HIDL interface libraries the prebuilt vendor HALs link but that\n",
        "# Soong's install graph does not ship (the blobs are prebuilt, so their\n",
        "# DT_NEEDED closure is invisible to Soong). Installing them as native\n",
        "# Make prebuilts keeps vendor.img self-contained: a plain\n",
        "# `mka vendorimage` no longer needs the debugfs post-processing that\n",
        "# inject_vendor_hidl_libs.sh used to do.\n\n",
        "LOCAL_PATH := $(call my-dir)\n\n",
    ]
    for lib, src, arch in entries:
        out.append("include $(CLEAR_VARS)\n")
        out.append("LOCAL_MODULE := avium_hidl_%s_%s\n" % (arch, san(lib)))
        out.append("LOCAL_MODULE_CLASS := ETC\n")
        out.append("LOCAL_MODULE_TAGS := optional\n")
        out.append("LOCAL_SRC_FILES := %s\n" % src)
        out.append("LOCAL_MODULE_PATH := $(TARGET_OUT_VENDOR)/%s\n" % arch)
        out.append("LOCAL_MODULE_STEM := %s\n" % lib)
        out.append("LOCAL_CHECK_ELF_FILES := false\n")
        out.append("include $(BUILD_PREBUILT)\n\n")

    open(OUT_MK, "w").write("".join(out))
    print("entries: %d, missing (supplied by Soong): %d" % (len(entries), len(missing)))
    for m in missing:
        print("  soong: %s" % m)


if __name__ == "__main__":
    main()
