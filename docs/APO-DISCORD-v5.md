# MicFX v5 / Equalizer APO iOS integration — experimental

**Source branch:** `feature/apo-discord-stereo-v5`.

## Built

The original MicFX v4 native source and JS plugin are retained. The native dylib
now also builds `native/APOGroup.mm` and uses its additional settings at
Discord's already-verified mono AudioUnit capture interception point.
The existing pitch, detune, eight-band EQ, advanced gain, music bridge
switches, and legacy plugin settings are not deleted or renamed.

The new bridge reads `micfx-control-v1.json` from an App Group named
`group.f172ad8c5e5f97bc.1` periodically on a worker. Settings include:

- **Mic** enable (off by default), gain/preamp, mute, left/right attenuation.
- **One APO filter** type PK/LPQ/HPQ/BP/LS/HS/NO/AP, frequency, gain and Q.
- **Music** gain (applies to stereo packet input only).
- The original `stereo-slot-%02u.bin` frame contract (16 slots, 960
  stereo frames each, 48,000 Hz; checksum and fresh-session checks).
- Live status through pre-existing MicFX diagnostics keys:
  `MicFXAPOSettingsApplied` and `MicFXAPOStereoPackets`.

The APO controller app already installed on the phone writes this JSON to the
App Group. The new dylib does not require changing its original Qt UI.

## Limits — **do not mistake compilation for successful phone audio**

- The target Discord audio hook expects executable UUID
  `c7693551-f7aa-399a-9d24-41014f85f9b8` and prevalidated GOT slots.
  It refuses to install on other builds.
- Discord's captured microphone frames are *mono*; 2-channel music is
  accepted and mixed down at output. This does not force true stereo Opus
  voice transmission to Discord.
- The standard Spotify app does **not** expose decoded PCM or share this
  App Group. Nothing here captures Spotify audio by itself. A legitimate
  stereo source must provide the packets.
- The decoder expects 48-kHz music when directly mixing the stereo packets;
  in other sample-rate calls the separate stereo bridge stays silent.
- No live on-device voice call or microphone loopback test has passed yet.
- The optional APO EQ covers the first filter in the JSON only; not all of
  Equalizer APO's desktop filter engine is ported.
- The independent MP3 music+mic recorder, live processed monitor,
  and full stereo outgoing transport have **not** been built into this
  native dylib. Do not claim they are working.
- Output is an **unsigned** dylib/IPA; modified Mach-O code invalidates the
  old app signature. Sign every embedded component with a compatible iPhone
  profile; profiles must authorize the same group for both apps.
- Changing/replacing the main Discord client may replace its private local
  data. Back up settings/presets and use the test installation carefully.
- No signing certificates or provisioning private keys should be uploaded
  to this public GitHub repository.

## GitHub Actions

The existing workflow
`.github/workflows/build-micfx-v41.yml` builds and uploads the combined
`MicFX.dylib` on a GitHub macOS Intel runner. Use the workflow run's
`MicFX-v4.2-dylib` artifact.

The unsigned Discord IPA is separately repackaged from the user's exact
Endcord build. GitHub cannot install or sign it for a personal iPhone without
an authorized provisioning profile. Keep the original IPA unchanged.

## Testing plan

1. Check installed APO app reports shared settings saved.
2. Sign/install the modified Endcord build with an authorized App Group, only
   after backing up the currently working installation.
3. Test a Discord voice channel with mic gain at 0 dB, no music, then -6 dB,
   then mute. Ask a trusted participant to verify audio, and watch Native
   diagnostics. Start at low playback levels to avoid loud clipping.
4. Test an authorized 48 kHz stereo PCM sender. Verify packet counters and
   distinguish internal L/R stereo from Discord's final mono transport.
5. Do **not** assume Spotify integration, recording, or monitoring is done.

This is a source-only experimental fork, not an official Discord or APO release.
