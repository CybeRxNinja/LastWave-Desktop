#include "alsa_channel.h"

#include <alsa/asoundlib.h>

#include <cctype>
#include <cstdio>
#include <cstring>
#include <exception>
#include <map>
#include <string>
#include <vector>

namespace lastwave {
namespace alsa {
namespace {

// The candidate matrix is copied from the Windows engine (wasapi_engine.cpp:
// kRates/kDepths/kChannels) so a DAC is asked the same question on both
// platforms. 8 rates x 3 depths x 1 channel = 24 combinations, each answered by
// a cheap hw_params query on an already-open handle.
constexpr int kRates[] = {44100, 48000, 88200, 96000,
                          176400, 192000, 352800, 384000};
constexpr int kDepths[] = {16, 24, 32};
constexpr int kChannels[] = {2};

constexpr char kHwPrefix[] = "hw:";
constexpr char kSysDefaultPrefix[] = "sysdefault:CARD=";

struct PcmFormat {
  int sample_rate_hz = 0;
  int bit_depth = 0;
  int channels = 0;
};

struct DeviceInfo {
  std::string id;
  std::string name;
  std::string enumerator;
  bool is_default = false;
  bool exclusive_supported = false;
  bool hardware_volume = false;
  std::vector<PcmFormat> formats;
};

// What one pass of the name hints yields: the human text for each `hw:` PCM
// plus the card `sysdefault` resolves to.
struct NameHints {
  std::map<std::string, std::string> descriptions;
  std::string default_card_id;
};

FlMethodChannel* g_channel = nullptr;

void LogErrorf(const char* prefix, const std::string& arg) {
  fprintf(stderr, "[alsa] %s%s\n", prefix, arg.c_str());
}

void LogError(const char* message) {
  fprintf(stderr, "[alsa] %s\n", message);
}

// `hw:CARD=<cardId>,DEV=<n>` is the PCM string libmpv receives verbatim, and
// the only id shape the Dart side builds, so it is spelled here exactly once.
std::string MakeHwId(const char* card_id, int device) {
  char buf[256];
  snprintf(buf, sizeof(buf), "hw:CARD=%s,DEV=%d", card_id, device);
  return std::string(buf);
}

std::string Trim(const std::string& in) {
  size_t begin = 0;
  size_t end = in.size();
  while (begin < end && std::isspace(static_cast<unsigned char>(in[begin]))) {
    begin++;
  }
  while (end > begin && std::isspace(static_cast<unsigned char>(in[end - 1]))) {
    end--;
  }
  return in.substr(begin, end - begin);
}

bool EqualsIgnoreCase(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++) {
    if (std::tolower(static_cast<unsigned char>(a[i])) !=
        std::tolower(static_cast<unsigned char>(b[i]))) {
      return false;
    }
  }
  return true;
}

void WriteCtlName(char* buffer, size_t size, int card) {
  snprintf(buffer, size, "hw:%d", card);
}

// ---------------------------------------------------------------------------
// Name hints
// ---------------------------------------------------------------------------

// Hints are the only alsa-lib source for the human text a card driver
// publishes, and for the card ALSA resolves `sysdefault` to. Neither is
// guaranteed: with the stock `alsa.conf` (`namehint.extended off`) the `hw:`
// entries are absent entirely, so an empty `descriptions` map is the normal
// case and the caller falls back to the card and PCM names that come from the
// control interface. Nothing here is required for correctness.
NameHints ReadNameHints() {
  NameHints hints;
  void** list = nullptr;
  if (snd_device_name_hint(-1, "pcm", &list) < 0 || list == nullptr) {
    if (list != nullptr) snd_device_name_free_hint(list);
    return hints;
  }
  for (void** entry = list; *entry != nullptr; entry++) {
    char* name = snd_device_name_get_hint(*entry, "NAME");
    if (name == nullptr) continue;
    const bool is_hw = strncmp(name, kHwPrefix, strlen(kHwPrefix)) == 0;
    const bool is_sysdefault =
        strncmp(name, kSysDefaultPrefix, strlen(kSysDefaultPrefix)) == 0;
    if (is_hw || is_sysdefault) {
      char* description = snd_device_name_get_hint(*entry, "DESC");
      if (description != nullptr) {
        if (is_hw) {
          hints.descriptions[std::string(name)] = std::string(description);
        } else if (hints.default_card_id.empty()) {
          hints.default_card_id =
              std::string(name + strlen(kSysDefaultPrefix));
        }
      }
      // Every snd_device_name_get_hint result is an allocated string the
      // caller owns.
      free(description);
    }
    free(name);
  }
  snd_device_name_free_hint(list);
  return hints;
}

// ---------------------------------------------------------------------------
// Format probing
// ---------------------------------------------------------------------------

// One candidate combination, answered without ever configuring the hardware.
//
// `snd_pcm_hw_params_any` resets the constraint mask and the `test_*` family is
// read-only, so the combination is never applied with `snd_pcm_hw_params()` and
// `snd_pcm_prepare()` is never reached: probing cannot reconfigure a card
// another process is streaming on. `test_rate` is called with dir = 0, so an
// inexact rate counts as unsupported - anything else would report a resampling
// card as bit-perfect.
bool TestFormat(snd_pcm_t* pcm,
                snd_pcm_hw_params_t* params,
                int rate,
                int depth,
                int channels) {
  if (snd_pcm_hw_params_any(pcm, params) < 0) return false;
  // Interleaved is the access libmpv's alsa AO uses.
  if (snd_pcm_hw_params_test_access(pcm, params,
                                    SND_PCM_ACCESS_RW_INTERLEAVED) < 0) {
    return false;
  }
  // Both 24-bit containers report bitDepth 24: S24_3LE is packed (3 bytes per
  // sample), S24_LE is padded to 4. Cards commonly accept only one of them.
  bool format_ok = false;
  switch (depth) {
    case 16:
      format_ok =
          snd_pcm_hw_params_test_format(pcm, params, SND_PCM_FORMAT_S16_LE) >=
          0;
      break;
    case 24:
      format_ok =
          snd_pcm_hw_params_test_format(pcm, params,
                                        SND_PCM_FORMAT_S24_3LE) >= 0 ||
          snd_pcm_hw_params_test_format(pcm, params, SND_PCM_FORMAT_S24_LE) >=
              0;
      break;
    case 32:
      format_ok =
          snd_pcm_hw_params_test_format(pcm, params, SND_PCM_FORMAT_S32_LE) >=
          0;
      break;
    default:
      return false;
  }
  if (!format_ok) return false;
  if (snd_pcm_hw_params_test_channels(pcm, params,
                                      static_cast<unsigned int>(channels)) <
      0) {
    return false;
  }
  return snd_pcm_hw_params_test_rate(pcm, params,
                                     static_cast<unsigned int>(rate), 0) >= 0;
}

// Opens `id` for playback queries only. The blocking open is tried first and
// the non-blocking open is the fallback, so probing a card that mpv already
// holds fails fast (EBUSY) instead of queueing behind the running stream.
// The handle is closed on every path.
bool ProbeFormats(const std::string& id, std::vector<PcmFormat>* out) {
  out->clear();
  snd_pcm_t* pcm = nullptr;
  int err = snd_pcm_open(&pcm, id.c_str(), SND_PCM_STREAM_PLAYBACK, 0);
  if (err < 0) {
    if (pcm != nullptr) snd_pcm_close(pcm);
    pcm = nullptr;
    err = snd_pcm_open(&pcm, id.c_str(), SND_PCM_STREAM_PLAYBACK,
                       SND_PCM_NONBLOCK);
  }
  if (err < 0 || pcm == nullptr) {
    if (pcm != nullptr) snd_pcm_close(pcm);
    LogErrorf("cannot open playback PCM ", id);
    return false;
  }

  snd_pcm_hw_params_t* params = nullptr;
  if (snd_pcm_hw_params_malloc(&params) < 0) {
    snd_pcm_close(pcm);
    LogErrorf("hw_params allocation failed for ", id);
    return false;
  }

  for (size_t c = 0; c < sizeof(kChannels) / sizeof(kChannels[0]); c++) {
    for (size_t d = 0; d < sizeof(kDepths) / sizeof(kDepths[0]); d++) {
      for (size_t r = 0; r < sizeof(kRates) / sizeof(kRates[0]); r++) {
        if (!TestFormat(pcm, params, kRates[r], kDepths[d], kChannels[c])) {
          continue;
        }
        PcmFormat format;
        format.sample_rate_hz = kRates[r];
        format.bit_depth = kDepths[d];
        format.channels = kChannels[c];
        out->push_back(format);
      }
    }
  }

  snd_pcm_hw_params_free(params);
  snd_pcm_close(pcm);
  return true;
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

void AppendCardDevices(int card,
                       const NameHints& hints,
                       bool probe_formats,
                       std::vector<DeviceInfo>* out) {
  char ctl_name[32];
  WriteCtlName(ctl_name, sizeof(ctl_name), card);
  snd_ctl_t* ctl = nullptr;
  if (snd_ctl_open(&ctl, ctl_name, 0) < 0 || ctl == nullptr) {
    if (ctl != nullptr) snd_ctl_close(ctl);
    return;
  }

  snd_ctl_card_info_t* card_info = nullptr;
  snd_ctl_card_info_alloca(&card_info);
  if (snd_ctl_card_info(ctl, card_info) < 0) {
    snd_ctl_close(ctl);
    return;
  }
  const char* card_id = snd_ctl_card_info_get_id(card_info);
  const char* card_name = snd_ctl_card_info_get_name(card_info);
  if (card_id == nullptr) {
    snd_ctl_close(ctl);
    return;
  }

  snd_pcm_info_t* pcm_info = nullptr;
  snd_pcm_info_alloca(&pcm_info);
  int device = -1;
  while (snd_ctl_pcm_next_device(ctl, &device) == 0 && device >= 0) {
    // Asking for the playback stream makes a capture-only PCM fail here, and
    // the class check repeats that intent explicitly (this mirrors alsa-lib's
    // own src/control/namehint.c) rather than trusting the driver.
    snd_pcm_info_set_device(pcm_info, static_cast<unsigned int>(device));
    snd_pcm_info_set_stream(pcm_info, SND_PCM_STREAM_PLAYBACK);
    if (snd_ctl_pcm_info(ctl, pcm_info) < 0) continue;
    const snd_pcm_class_t pcm_class = snd_pcm_info_get_class(pcm_info);
    if (pcm_class == SND_PCM_CLASS_DIGITIZER ||
        pcm_class == SND_PCM_CLASS_MODEM) {
      continue;
    }
    const char* pcm_name = snd_pcm_info_get_name(pcm_info);

    DeviceInfo info;
    info.id = MakeHwId(card_id, device);
    // Same rule as the Dart enumerator: only DEV=0 of the default card is the
    // default output; every other PCM is just another device.
    info.is_default = device == 0 && hints.default_card_id == card_id;
    const std::map<std::string, std::string>::const_iterator described =
        hints.descriptions.find(info.id);
    if (described != hints.descriptions.end() && !described->second.empty()) {
      info.name = described->second;
    } else if (card_name != nullptr && pcm_name != nullptr) {
      info.name = std::string(card_name) + ", " + pcm_name;
    } else {
      info.name = info.id;
    }
    info.enumerator = "alsa";
    // On ALSA "exclusive" is a property of the name, not of an open: an
    // `hw:CARD=..,DEV=..` PCM is the raw hardware, so no dmix/plughw - and
    // therefore no mixer - sits in its path. That is what the Dart enumerator
    // already reports for a procfs `pcm<n>p` node, and it keeps a card that is
    // momentarily busy from being shown as "exclusive unavailable". `formats`
    // is the measured half and stays empty when the card could not be opened,
    // which the Dart side already reads as unknown.
    info.exclusive_supported = true;
    // No control-ABI access in this slice, so volume stays software-side and
    // the hardware-volume knob must stay hidden.
    info.hardware_volume = false;
    if (probe_formats) {
      ProbeFormats(info.id, &info.formats);
    }
    out->push_back(info);
  }

  snd_ctl_close(ctl);
}

std::vector<DeviceInfo> EnumerateDevices(bool probe_formats) {
  const NameHints hints = ReadNameHints();
  std::vector<DeviceInfo> devices;
  int card = -1;
  while (snd_card_next(&card) == 0 && card >= 0) {
    AppendCardDevices(card, hints, probe_formats, &devices);
  }
  return devices;
}

// ---------------------------------------------------------------------------
// FlValue marshalling
// ---------------------------------------------------------------------------

FlValue* FormatsToValue(const std::vector<PcmFormat>& formats) {
  FlValue* list = fl_value_new_list();
  for (const PcmFormat& format : formats) {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "sampleRateHz",
                             fl_value_new_int(format.sample_rate_hz));
    fl_value_set_string_take(map, "bitDepth",
                             fl_value_new_int(format.bit_depth));
    fl_value_set_string_take(map, "channels",
                             fl_value_new_int(format.channels));
    fl_value_append_take(list, map);
  }
  return list;
}

FlValue* DeviceToValue(const DeviceInfo& device) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "id", fl_value_new_string(device.id.c_str()));
  fl_value_set_string_take(map, "name",
                           fl_value_new_string(device.name.c_str()));
  // ALSA publishes no vendor string for a PCM, so this stays empty instead of
  // being inferred from the driver name.
  fl_value_set_string_take(map, "manufacturer", fl_value_new_string(""));
  fl_value_set_string_take(map, "enumerator",
                           fl_value_new_string(device.enumerator.c_str()));
  fl_value_set_string_take(map, "isDefault",
                           fl_value_new_bool(device.is_default));
  fl_value_set_string_take(map, "exclusiveSupported",
                           fl_value_new_bool(device.exclusive_supported));
  fl_value_set_string_take(map, "hardwareVolume",
                           fl_value_new_bool(device.hardware_volume));
  fl_value_set_string_take(map, "formats", FormatsToValue(device.formats));
  return map;
}

std::string ReadIdArgument(FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return std::string();
  }
  FlValue* id = fl_value_lookup_string(args, "id");
  if (id == nullptr || fl_value_get_type(id) != FL_VALUE_TYPE_STRING) {
    return std::string();
  }
  const gchar* value = fl_value_get_string(id);
  return value == nullptr ? std::string() : std::string(value);
}

// ---------------------------------------------------------------------------
// Method dispatch
// ---------------------------------------------------------------------------

void HandleMethodCall(FlMethodChannel* channel,
                      FlMethodCall* method_call,
                      gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(method_call);
  if (method == nullptr) {
    fl_method_call_respond_error(method_call, "alsa", "missing method name",
                                 nullptr, nullptr);
    return;
  }
  try {
    if (strcmp(method, "enumerateDevices") == 0) {
      const std::vector<DeviceInfo> devices = EnumerateDevices(true);
      FlValue* list = fl_value_new_list();
      for (const DeviceInfo& device : devices) {
        fl_value_append_take(list, DeviceToValue(device));
      }
      fl_method_call_respond_success(method_call, list, nullptr);
      return;
    }
    if (strcmp(method, "probeDevice") == 0) {
      const std::string id = Trim(ReadIdArgument(method_call));
      if (id.empty()) {
        LogError("probeDevice: missing or malformed id argument");
        fl_method_call_respond_success(method_call, fl_value_new_null(),
                                      nullptr);
        return;
      }
      // Identity comes from the same enumeration the id is checked against, so
      // a stale preference cannot resurrect a DAC that is gone.
      const std::vector<DeviceInfo> devices = EnumerateDevices(false);
      const DeviceInfo* found = nullptr;
      for (const DeviceInfo& device : devices) {
        if (EqualsIgnoreCase(device.id, id)) {
          found = &device;
          break;
        }
      }
      if (found == nullptr) {
        LogErrorf("probeDevice: not an ALSA playback PCM: ", id);
        fl_method_call_respond_success(method_call, fl_value_new_null(),
                                      nullptr);
        return;
      }
      DeviceInfo probed = *found;
      if (!ProbeFormats(probed.id, &probed.formats)) {
        // Unopenable is null, not a device with an empty list: the Dart side
        // then keeps its existing "unavailable" handling rather than showing a
        // device that claims exclusive support with nothing measured.
        fl_method_call_respond_success(method_call, fl_value_new_null(),
                                      nullptr);
        return;
      }
      fl_method_call_respond_success(method_call, DeviceToValue(probed),
                                    nullptr);
      return;
    }
    if (strcmp(method, "defaultDeviceId") == 0) {
      // Same rule as the Dart enumerator: DEV=0 of the default card, empty
      // when ALSA will not name a default card.
      const std::vector<DeviceInfo> devices = EnumerateDevices(false);
      for (const DeviceInfo& device : devices) {
        if (!device.is_default) continue;
        fl_method_call_respond_success(
            method_call, fl_value_new_string(device.id.c_str()), nullptr);
        return;
      }
      fl_method_call_respond_success(method_call, fl_value_new_string(""),
                                    nullptr);
      return;
    }
    fl_method_call_respond_not_implemented(method_call, nullptr);
  } catch (const std::exception& error) {
    // Nothing may unwind into the platform-thread dispatcher.
    fprintf(stderr, "[alsa] %s raised: %s\n", method, error.what());
    fl_method_call_respond_error(method_call, "alsa", "ALSA probe failed",
                                 nullptr, nullptr);
  } catch (...) {
    fprintf(stderr, "[alsa] %s raised an unknown error\n", method);
    fl_method_call_respond_error(method_call, "alsa", "ALSA probe failed",
                                 nullptr, nullptr);
  }
}

}  // namespace
}  // namespace alsa
}  // namespace lastwave

void alsa_channel_register(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "LastWaveAlsaChannel");
  // Owned by the registrar and never released: the channel must outlive this
  // call, the same process-lifetime rule the Windows runner channel follows
  // (flutter_window.cpp keeps the WasapiChannel alive for the whole run).
  lastwave::alsa::g_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "lastwave/alsa",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(lastwave::alsa::g_channel,
                                            lastwave::alsa::HandleMethodCall,
                                            nullptr, nullptr);
}