/*
 * [bring-up] Standalone probe for Samsung's legacy audio HAL.
 *
 * The A16 audio stack talks AIDL only, and our AIDL HAL uses the AOSP
 * "example" tinyalsa backend, which opens pcmC0D0p but never routes the
 * speaker amplifier (no mixer_paths_tavil.xml handling).  Before writing an
 * AIDL-to-legacy bridge, this probe answers the one question that decides
 * whether that bridge is worth building:
 *
 *     can /vendor/lib/hw/audio.primary.msmnile.so produce sound at all
 *     on this device under the current vendor image?
 *
 * It loads the module the same way hw_get_module() would, opens a primary
 * output stream for the speaker, and writes 3 seconds of a 440 Hz sine.
 *
 * Build: 32-bit only, because the blob is 32-bit (ELF32 ARM, Android 30).
 */

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <hardware/audio.h>
#include <hardware/hardware.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define LEGACY_HAL "/vendor/lib/hw/audio.primary.msmnile.so"
#define TAG        "[audio_legacy_test] "

int main(int argc, char **argv) {
    /* Unbuffered: if the vendor HAL crashes we still get to see the trace. */
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *path = argc > 1 ? argv[1] : LEGACY_HAL;
    int seconds = argc > 2 ? atoi(argv[2]) : 3;
    if (seconds <= 0 || seconds > 30) seconds = 3;

    printf(TAG "loading %s\n", path);
    void *dl = dlopen(path, RTLD_NOW);
    if (dl == NULL) {
        printf(TAG "dlopen failed: %s\n", dlerror());
        return 1;
    }

    hw_module_t *module = (hw_module_t *)dlsym(dl, HAL_MODULE_INFO_SYM_AS_STR);
    if (module == NULL) {
        printf(TAG "dlsym(%s) failed: %s\n", HAL_MODULE_INFO_SYM_AS_STR, dlerror());
        return 1;
    }
    printf(TAG "module id=%s name=%s api=%u\n", module->id, module->name,
           module->module_api_version);

    if (module->methods == NULL || module->methods->open == NULL) {
        printf(TAG "module has no open method\n");
        return 1;
    }

    /* audio_hw_device_open() passes AUDIO_HARDWARE_INTERFACE; mirror that. */
    struct audio_hw_device *dev = NULL;
    int r = module->methods->open(module, AUDIO_HARDWARE_INTERFACE,
                                  (struct hw_device_t **)&dev);
    if (r != 0 || dev == NULL) {
        printf(TAG "open failed: %d (%s)\n", r, strerror(-r));
        return 1;
    }
    printf(TAG "adev opened, api_version=0x%x\n", dev->common.version);

    r = dev->init_check(dev);
    printf(TAG "init_check -> %d (%s)\n", r, r == 0 ? "ok" : strerror(-r));
    if (r != 0) {
        return 1;
    }

    dev->set_mode(dev, AUDIO_MODE_NORMAL);
    if (dev->set_master_volume) {
        r = dev->set_master_volume(dev, 1.0f);
        printf(TAG "set_master_volume -> %d\n", r);
    }
    dev->set_parameters(dev, "screen_state=on");

    struct audio_config config;
    memset(&config, 0, sizeof(config));
    config.sample_rate = 48000;
    config.channel_mask = AUDIO_CHANNEL_OUT_STEREO;
    config.format = AUDIO_FORMAT_PCM_16_BIT;

    struct audio_stream_out *out = NULL;
    r = dev->open_output_stream(dev, 0 /* io_handle */, AUDIO_DEVICE_OUT_SPEAKER,
                                AUDIO_OUTPUT_FLAG_PRIMARY, &config, &out,
                                "" /* address (HAL strlcpy()s it unchecked) */);
    printf(TAG "open_output_stream(speaker) -> %d (%s), out=%p\n", r,
           r == 0 ? "ok" : strerror(-r), (void *)out);
    if (r != 0 || out == NULL) {
        return 1;
    }
    /* The sample-rate / channel-mask / format getters live in the common
       audio_stream struct, not directly on audio_stream_out. */
    printf(TAG "stream: sr=%u mask=0x%x fmt=0x%x\n",
           out->common.get_sample_rate(&out->common),
           out->common.get_channels(&out->common),
           out->common.get_format(&out->common));

    if (out->set_volume) {
        r = out->set_volume(out, 0.9f, 0.9f);
        printf(TAG "set_volume -> %d\n", r);
    }

    const size_t frames_per_chunk = 1024;
    int16_t *buf = (int16_t *)malloc(frames_per_chunk * 2 * sizeof(int16_t));
    if (buf == NULL) {
        printf(TAG "oom\n");
        return 1;
    }

    const size_t total_frames = (size_t)seconds * 48000;
    size_t written_frames = 0;
    double phase = 0.0;
    const double step = 2.0 * M_PI * 440.0 / 48000.0;
    while (written_frames < total_frames) {
        size_t n = total_frames - written_frames;
        if (n > frames_per_chunk) n = frames_per_chunk;
        for (size_t i = 0; i < n; i++) {
            int16_t v = (int16_t)(11000.0 * sin(phase));
            buf[2 * i] = v;
            buf[2 * i + 1] = v;
            phase += step;
            if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
        }
        ssize_t w = out->write(out, buf, n * 2 * sizeof(int16_t));
        if (w <= 0) {
            printf(TAG "write failed at frame %zu: %zd (%s)\n", written_frames, w,
                   w < 0 ? strerror((int)-w) : "0 bytes");
            break;
        }
        written_frames += (size_t)w / (2 * sizeof(int16_t));
    }
    printf(TAG "wrote %zu frames (%zu ms)\n", written_frames,
           written_frames / 48);

    /* Let the HAL drain its buffers before tearing the stream down. */
    sleep(1);
    out->common.standby(&out->common);
    dev->close_output_stream(dev, out);
    dev->common.close(&dev->common);
    free(buf);
    printf(TAG "done\n");
    return 0;
}
