#!/system/bin/sh
# [bring-up] 直接把 PCM 数据写进 /dev/snd/pcmC0D0p 验证音频输出通路
# 用法：audio_raw_test.sh [秒数]
# 注意：需要先让 mixer 通路打开（播放时 DAPM 才会 auto-connect）

SECS=${1:-2}
DEV=/dev/snd/pcmC0D0p
RATE=48000

echo "PCM raw test -> $DEV  ${SECS}s"

# 生成 440Hz 立体声 16bit PCM
# 用 od 构造太慢，直接调 python 不可用，改用 awk 生成二进制
python_bin=""
for p in /system/bin/python3 /system/xbin/python3 /data/local/tmp/python3; do
    [ -x "$p" ] && python_bin="$p" && break
done

if [ -n "$python_bin" ]; then
    "$python_bin" -c "
import math, struct, sys
rate=48000; secs=$SECS; freq=440
n=rate*secs
data=bytearray()
for i in range(n):
    v=int(32000*math.sin(2*math.pi*freq*i/rate))
    data += struct.pack('<hh', v, v)
open('/data/local/tmp/test.pcm','wb').write(data)
print('generated', len(data), 'bytes')
"
    cat /data/local/tmp/test.pcm > "$DEV" 2>/dev/null
    echo "write rc=$?"
else
    echo "no python; 用 dd 生成静音测试"
    dd if=/dev/zero of=/data/local/tmp/silence.pcm bs=1024 count=$((RATE*4*SECS/1024)) 2>/dev/null
    cat /data/local/tmp/silence.pcm > "$DEV" 2>/dev/null
    echo "silence write rc=$?"
fi
