// A short-lived CoreAudio helper. Reading status never changes an audio property.
// Only the two explicit write commands below can change volume or mute.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioHardwareService.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                         AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static BOOL readProperty(AudioObjectID object, AudioObjectPropertyAddress a,
                         UInt32 size, void *value) {
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &size, value) == noErr;
}
static BOOL writable(AudioObjectID object, AudioObjectPropertyAddress a) {
    Boolean settable = false;
    return AudioObjectHasProperty(object, &a) &&
        AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable;
}
static AudioDeviceID resolveDevice(UInt32 route) {
    AudioDeviceID device = route;
    if (!device && !readProperty(kAudioObjectSystemObject,
        address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal),
        sizeof(device), &device)) return kAudioObjectUnknown;
    return device;
}
static NSString *deviceName(AudioDeviceID device) {
    CFStringRef value = NULL;
    if (!readProperty(device, address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
                      sizeof(value), &value) || !value) return @"Аудиовыход";
    return CFBridgingRelease(value);
}
static AudioObjectPropertyAddress volumeAddress(AudioDeviceID device) {
    // The virtual main control preserves channel balance on devices without a main control.
    AudioObjectPropertyAddress a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                          kAudioDevicePropertyScopeOutput);
    if (!AudioObjectHasProperty(device, &a)) a.mSelector = kAudioDevicePropertyVolumeScalar;
    return a;
}
static NSDictionary *status(AudioDeviceID device) {
    UInt32 alive = 0, transport = 0, muted = 0;
    if (!device || !readProperty(device, address(kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal), sizeof(alive), &alive) || !alive)
        return @{@"available": @NO, @"controllable": @NO, @"error": @"device_unavailable"};
    readProperty(device, address(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal),
                 sizeof(transport), &transport);
    AudioObjectPropertyAddress vol = volumeAddress(device);
    AudioObjectPropertyAddress mute = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput);
    Float32 scalar = 0;
    BOOL hasVolume = readProperty(device, vol, sizeof(scalar), &scalar) && isfinite(scalar);
    BOOL hasMute = readProperty(device, mute, sizeof(muted), &muted);
    return @{@"available": @YES, @"deviceId": @(device), @"name": deviceName(device),
        @"transport": transport == kAudioDeviceTransportTypeHDMI ? @"HDMI" :
            transport == kAudioDeviceTransportTypeDisplayPort ? @"DisplayPort" :
            transport == kAudioDeviceTransportTypeBuiltIn ? @"Built-in" : @"Other",
        @"controllable": hasVolume && writable(device, vol) ? @YES : @NO,
        @"volume": hasVolume ? @(lroundf(fmaxf(0, fminf(1, scalar)) * 100)) : (id)[NSNull null],
        @"muteControllable": hasMute && writable(device, mute) ? @YES : @NO,
        @"muted": hasMute ? (muted != 0 ? @YES : @NO) : (id)[NSNull null]};
}
static int emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    if (!data) return 1;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
    return value[@"error"] ? 1 : 0;
}
static BOOL integer(const char *value, UInt32 *result) {
    if (!value || !*value) return NO;
    for (const char *p = value; *p; p++) if (*p < '0' || *p > '9') return NO;
    char *end = NULL; unsigned long long n = strtoull(value, &end, 10);
    if (*end || n > UINT32_MAX) return NO;
    *result = (UInt32)n; return YES;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // A slow/broken audio driver must not hold the VLC HTTP interface indefinitely.
        alarm(2);
        UInt32 route = 0, expected = 0, value = 0;
        if (argc < 3 || !integer(argv[2], &route)) return emit(@{@"error": @"bad_value"});
        NSString *command = @(argv[1]);
        AudioDeviceID device = resolveDevice(route);
        if ([command isEqualToString:@"status"] && argc == 3) return emit(status(device));
        BOOL volume = [command isEqualToString:@"volume"];
        BOOL mute = [command isEqualToString:@"mute"];
        if ((!volume && !mute) || argc != 5 || !integer(argv[3], &expected) ||
            !integer(argv[4], &value) || value > (volume ? 100 : 1))
            return emit(@{@"error": @"bad_value"});
        if (device != expected || !device) return emit(@{@"error": @"device_changed"});
        NSDictionary *before = status(device);
        if (![before[volume ? @"controllable" : @"muteControllable"] boolValue])
            return emit(@{@"error": @"system_volume_unavailable"});
        AudioObjectPropertyAddress a = volume ? volumeAddress(device) :
            address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput);
        Float32 scalar = value / 100.0f;
        // Recheck a default-device route immediately before writing. Never switch devices.
        if (resolveDevice(route) != device) return emit(@{@"error": @"device_changed"});
        OSStatus result = volume ? AudioObjectSetPropertyData(device, &a, 0, NULL, sizeof(scalar), &scalar) :
                                   AudioObjectSetPropertyData(device, &a, 0, NULL, sizeof(value), &value);
        if (result != noErr) return emit(@{@"error": @"system_volume_failed"});
        return emit(status(device));
    }
}
