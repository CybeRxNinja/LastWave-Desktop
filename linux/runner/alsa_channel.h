#ifndef RUNNER_ALSA_CHANNEL_H_
#define RUNNER_ALSA_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "lastwave/alsa" method channel: enumerateDevices,
// probeDevice, defaultDeviceId.
//
// This is the Linux counterpart of the Windows WASAPI engine: it enumerates
// `hw:` playback PCMs through alsa-lib and reports the PCM formats each one
// really accepts, so the UI can show an honest bit-perfect verdict instead of
// "no native probe". PCM rendering stays in libmpv (`ao=alsa` on the same
// `hw:CARD=<card>,DEV=<n>` string), so this layer never opens a stream for
// playback and never configures a device.
//
// Registration is a process-lifetime side effect: the channel is created once,
// owned by the plugin registrar and never released, mirroring the
// "owned by the registrar, kept alive for process lifetime" pattern the other
// runner channel already uses.
//
// `my_application_activate` must call this next to
// `yt_webview_guard_register(view)`; until it does, Dart sees no channel here
// and `Platform.isLinux` plus the procfs fallback remain in charge.
void alsa_channel_register(FlView* view);

#endif  // RUNNER_ALSA_CHANNEL_H_