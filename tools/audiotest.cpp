// [bring-up] 最小 AudioTrack 测试：验证 audio HAL → DSP → CS35L41 功放 全通路
//
// 用途：系统里没有播放器时，用它产生一段真实 PCM 交给 AudioFlinger，
// 从而触发 mixer 通路和 DAPM（功放只在真实播放时上电）。
//
// 手工编译（不走 soong）：
//   clang++ --target=aarch64-linux-android36 \
//     -I out/target/product/beyond1q/system/include \
//     -L out/target/product/beyond1q/system/lib64 \
//     -laudioclient -lutils -lmediautils -lbinder -lcutils -llog -lui -lbase \
//     audiotest.cpp -o audiotest

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

#include <media/AudioTrack.h>
#include <system/audio.h>
#include <utils/StrongPointer.h>

using namespace android;

int main(int argc, char** argv) {
    const int rate = 48000;
    const int secs = (argc > 1) ? atoi(argv[1]) : 2;
    const int freq = (argc > 2) ? atoi(argv[2]) : 440;
    const int chans = 2;
    const int64_t frames = static_cast<int64_t>(rate) * secs;

    printf("AudioTrack test: %d Hz, %d ch, %d s, %d frames\n", freq, chans, secs,
           static_cast<int>(frames));

    sp<AudioTrack> track = new AudioTrack(
            AUDIO_STREAM_MUSIC,
            rate,
            AUDIO_FORMAT_PCM_16_BIT,
            AUDIO_CHANNEL_OUT_STEREO,
            frames,
            AUDIO_OUTPUT_FLAG_NONE,
            nullptr,
            0);

    status_t st = track->initCheck();
    if (st != NO_ERROR) {
        printf("initCheck failed: %d\n", st);
        return 1;
    }
    printf("initCheck OK, frameCount=%zu\n", (size_t)track->frameCount());

    track->setVolume(1.0f, 1.0f);
    st = track->start();
    if (st != NO_ERROR) {
        printf("start failed: %d\n", st);
        return 1;
    }
    printf("started\n");

    short buf[512 * 2];
    int64_t written = 0;
    while (written < frames) {
        int64_t n = (frames - written > 512) ? 512 : (frames - written);
        for (int64_t i = 0; i < n; i++) {
            short v = static_cast<short>(32000 * sin(2 * M_PI * freq * (written + i) / rate));
            buf[i * 2] = v;
            buf[i * 2 + 1] = v;
        }
        ssize_t got = track->write(buf, static_cast<size_t>(n) * 2 * sizeof(short));
        if (got < 0) {
            printf("write failed: %zd\n", got);
            break;
        }
        written += n;
    }

    printf("wrote %lld frames, waiting for drain\n", (long long)written);
    track->stop();
    printf("done\n");
    return 0;
}
