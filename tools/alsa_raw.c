// [bring-up] 直接向 ALSA PCM 节点写正弦波，绕过 AudioFlinger。
//
// 目的：验证从 PCM 设备 → DSP → CS35L41 功放 → 喇叭 的底层通路。
// 如果这个能出声而 AudioFlinger 不能，问题就在 HAL/mixer 配置；
// 如果这个也不出声，问题在 codec/DAPM/功放。
//
// 纯 C，只用 bionic 提供的 ioctl，不需要 libc++ / framework 头文件。
//
// 编译：
//   clang --target=aarch64-linux-android36 -ffreestanding -D__ANDROID__ \
//     -isystem bionic/libc/include -isystem bionic/libc/kernel/uapi \
//     -isystem bionic/libc/kernel/uapi/asm-arm64 \
//     alsa_raw.c -o alsa_raw

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

// ALSA PCM ioctl 的最小定义（避免依赖 asoundlib 头）
struct snd_pcm_hw_params_raw {
    unsigned int flags;
    unsigned int masks[3];
    unsigned int intervals[12 * 3];
    unsigned int rmask[9];
    unsigned int cmask[9];
    unsigned int info[2];
    unsigned char reserved[124];
};

#define SNDRV_PCM_IOCTL_HW_PARAMS _IOWR('A', 0x11, struct snd_pcm_hw_params_raw)

int main(void) {
    const char* dev = "/dev/snd/pcmC0D0p";
    const int secs = 2;
    const int freq = 440;
    const int rate = 48000;

    char msg[128];
    int n = 0;
    n += 9; write(2, "alsa_raw\n", 9);

    int fd = open(dev, O_WRONLY);
    if (fd < 0) {
        write(2, "open FAILED\n", 12);
        return 1;
    }
    write(2, "opened\n", 7);

    // 不设 hw_params，直接用设备默认参数写入。
    // tinyplay 也是这么做的（先 hw_params，失败则用默认）。
    int16_t frame[2];
    long total = (long)rate * secs;
    long written = 0;
    for (long i = 0; i < total; i++) {
        int16_t v = (int16_t)(32000.0 * sin(2.0 * M_PI * freq * i / rate));
        frame[0] = v;
        frame[1] = v;
        ssize_t n = write(fd, frame, sizeof(frame));
        if (n < 0) {
            write(2, "write failed\n", 13);
            break;
        }
        written++;
    }
    write(2, "wrote frames\n", 13);
    close(fd);
    return 0;
}
