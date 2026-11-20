#!/bin/bash
#
# Copyright (C) 2020 The LineageOS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e

export DEVICE_COMMON=sm8150-common
export VENDOR=samsung

# Load extract_utils and do some sanity checks
MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then MY_DIR="${PWD}"; fi

LINEAGE_ROOT="${MY_DIR}"/../../..

HELPER="${LINEAGE_ROOT}/vendor/lineage/build/tools/extract_utils.sh"
if [ ! -f "${HELPER}" ]; then
    echo "Unable to find helper script at ${HELPER}"
    exit 1
fi
source "${HELPER}"

# Default to sanitizing the vendor folder before extraction
CLEAN_VENDOR=true

SECTION=
KANG=

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n | --no-cleanup )
                CLEAN_VENDOR=false
                ;;
        -k | --kang )
                KANG="--kang"
                ;;
        -s | --section )
                SECTION="${2}"; shift
                CLEAN_VENDOR=false
                ;;
        * )
                SRC="${1}"
                ;;
    esac
    shift
done

if [ -z "${SRC}" ]; then
    SRC="adb"
fi

function blob_fixup() {
    case "${1}" in

    etc/nfcee_access.xml)
        sed -i "s/xliff=\"urn:oasis:names:tc:xliff:document:1.2\"/android=\"http:\/\/schemas.android.com\/apk\/res\/android\"/" "${2}"
        ;;

    # libskeymaster4device is the Samsung keymaster TEE bridge. Its DT_NEEDED
    # names libcrypto.so, but on this A16 port /vendor/lib64/libcrypto.so is the
    # AOSP boringssl build, which lacks the FIPS/MDFPP provider objects, and
    # skeymaster::CreateSKeymasterDevice(TEE) aborts on start against it. The
    # MDFPP libcrypto the blob actually wants ships alongside it as libcrypto_gk
    # (vendor_native_prebuilts.mk / gen_vendor_native_prebuilts.py).
    #
    # Repoint the dependency at that copy. "libcrypto.so" and "libcrypto_gk" are
    # both 13 bytes, so this is an equal-length .dynstr substitution: no offsets,
    # hashes or section sizes change and the ELF stays valid without patchelf.
    # The blob contains exactly one occurrence; assert that so a future stock
    # update which moves the string fails loudly instead of half-patching.
    vendor/lib64/libskeymaster4device.so)
        local n
        n=$(grep -a -c 'libcrypto\.so' "${2}" || true)
        if [ "${n}" != "1" ]; then
            echo "!! ${1}: expected 1 'libcrypto.so' occurrence, found ${n}" >&2
            echo "!! the equal-length .dynstr patch no longer applies; fix by hand" >&2
            return 1
        fi
        perl -0777 -pi -e 's/libcrypto\.so\x00/libcrypto_gk\x00/' "${2}"
        ;;

    esac
}

# Initialize the helper for common device
setup_vendor "${DEVICE_COMMON}" "${VENDOR}" "${LINEAGE_ROOT}" true "${CLEAN_VENDOR}"

extract "${MY_DIR}/proprietary-files.txt" "${SRC}" \
        "${KANG}" --section "${SECTION}"

if [ -s "${MY_DIR}/../${DEVICE}/proprietary-files.txt" ]; then
    # Reinitialize the helper for device
    source "${MY_DIR}/../${DEVICE}/extract-files.sh"
    setup_vendor "${DEVICE}" "${VENDOR}" "${LINEAGE_ROOT}" false "${CLEAN_VENDOR}"

    extract "${MY_DIR}/../${DEVICE}/proprietary-files.txt" "${SRC}" \
            "${KANG}" --section "${SECTION}"
fi

COMMON_BLOB_ROOT="${LINEAGE_ROOT}/vendor/${VENDOR}/${DEVICE_COMMON}/proprietary"

"${MY_DIR}/setup-makefiles.sh"
