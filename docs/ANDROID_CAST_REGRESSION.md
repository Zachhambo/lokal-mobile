# Android Cast receiver handoff

Confirmed source faults: selecting a route returned success before the Cast session started; nullable media-client calls and swallowed Android bridge errors lost the subsequent load. Android dropped the MIME type, paused/autoplay flag and starting position passed by Dart. Local SAF grants were rejected instead of served over HTTP. The local-output list also included remote receivers, allowing route-only selection to open an empty Cast receiver app.

The sender now waits for session and media acknowledgements. Android uses the same confirmed paused-load ownership handoff as iOS. It keeps local playback until receiver preparation succeeds and pauses local output before remote Play. Receiver shutdown must be confirmed before local ownership resumes. Errors and timeouts propagate to the existing settings UI. Remote receivers are selected through the Cast handoff rather than the local-only output list.

Original SAF bytes use the existing bounded staging cache. The token-scoped media server supports GET, HEAD, ranges and CORS/private-network preflight, advertises a Wi-Fi/Ethernet address rather than cellular/VPN, and requests Android LAN access through the existing permission bridge. Authenticated network sources remain on the sender's authorized download path; account headers are not forwarded as Cast metadata. No audio transcoding or native PCM/DSD processing changes are introduced.

Automated checks cover ownership failure/cancellation/shutdown uncertainty, channel arguments and errors, staged-file identity, interface selection and real local HTTP range/preflight requests. Robolectric tests cover acknowledgement, timeout and late-callback completion plus actual Cast media request arguments. CI compiles the Android sender and MainActivity channel handler. These checks do not establish physical receiver playback.

## Screen-off sender lifetime

Source inspection found that Android still applied the paused local engine's
playback stream during Cast (the equivalent guard existed only on iOS).
Those events could replace the receiver's playing state and release the
playback service's partial wake lock. The Cast sender also lacked a Wi-Fi
residency lock for its phone-hosted HTTP relay.

Local engine state and Rust position/status listeners now yield to Cast on
all platforms. A lightweight notification update follows receiver
playing/buffering and source preparation, before artwork/favorite lookups
complete. Android declares connected-device foreground work while casting,
keeps CPU and normal Wi-Fi residency during playback/buffering/preparation,
and releases the Wi-Fi lock on pause, disconnect and service destruction.
Local playback still uses the media-playback foreground type. Google's CAF
still owns the Cast media session and notification controls.

These are source-level fixes for screen-off suspension; without device logs
they do not establish that a particular reported stop was an OS process kill.
No automatic background restart or receiver replay is introduced after a
force-stop or real process death. Native tests simulate screen-off and several
track/buffering transitions and assert foreground type, CPU/Wi-Fi protection,
pause/disconnect cleanup and service-destruction cleanup. Dart tests verify
that Cast can establish its foreground relay before metadata is ready.

Device validation still required:

- Cast for at least 45 minutes with the phone locked, crossing at least ten
  tracks, for both phone-local files and online sources. Include receiver-side
  pause/resume, buffering, next-track preparation and loss of Wi-Fi. Capture
  process exit reason/logcat if the process disappears; tests cannot reproduce
  OEM battery managers or establish a physical Cast endurance result.
- Check CPU/Wi-Fi locks in dumpsys while playing/buffering, then confirm release
  on pause, stop casting and service destruction. Repeat ordinary local, USB
  and Bluetooth playback to verify their existing lifetime is unchanged.

- Start a supported MP3 or FLAC from an Android SAF library, seek into it, and select a docked Pixel Tablet or Google Hub. Confirm metadata/audio and the starting position, then exercise receiver/Google Home controls.
- Select receivers through the Cast list; verify the local output list contains local outputs only. Check success and failure UI during connection.
- Reject Android LAN permission, remove source access, disconnect Wi-Fi, or select an unavailable/unsupported source. Confirm an error instead of a false success and confirm local recovery only after receiver shutdown.
- Advance tracks, then stop casting and confirm local playback resumes the selected track at the receiver's position. Test paused handoff and a new user selection during connection.
- Verify the existing iOS sender still connects, loads paused, hands over audio and disconnects correctly.

The reported ordinary tablet lock-screen controls work while undocked. The user reproduced missing docked Hub Mode controls with other apps' direct playback too. This change fixes Lokal's Cast sender; it does not claim Google Home mirrors arbitrary direct local playback in Hub Mode.
