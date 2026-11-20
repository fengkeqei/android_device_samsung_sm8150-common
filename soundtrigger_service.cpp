/*
 * v124: minimal soundtrigger@2.0 service.
 *
 * AOSP ships android.hardware.soundtrigger@2.0-impl (FetchISoundTriggerHw.cpp)
 * but no service binary, and Samsung's stock image has none either. Without a
 * registered android.hardware.soundtrigger@2.0::ISoundTriggerHw/default,
 * SystemServer's StartSoundTriggerMiddlewareService blocks forever:
 *
 *   DefaultHalFactory.create() -> ISoundTriggerHw.getService(true)
 *
 * getService(true) retries indefinitely, so the FakeHalFactory fallback that
 * SystemServer passes alongside it is never reached, and boot_completed is
 * never set.
 *
 * This binary does exactly what the upstream example service does: register
 * the passthrough implementation of the default instance.
 */

#define LOG_TAG "soundtrigger@2.0-service"

#include <android/hardware/soundtrigger/2.0/ISoundTriggerHw.h>
#include <hidl/LegacySupport.h>

using android::hardware::defaultPassthroughServiceImplementation;
using android::hardware::soundtrigger::V2_0::ISoundTriggerHw;

int main() {
    // Instance name must be "default": DefaultHalFactory asks for
    // android.hardware.soundtrigger.V2_0.ISoundTriggerHw/default.
    return defaultPassthroughServiceImplementation<ISoundTriggerHw>("default");
}
