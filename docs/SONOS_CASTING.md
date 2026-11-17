# Sonos and UPnP output

Sonos rooms are discovered with SSDP ZonePlayer searches alongside generic
MediaRenderer devices. Selecting a room resolves its existing group coordinator;
Lokal does not create or dissolve groups. Sonos group volume uses
GroupRenderingControl; generic receivers use RenderingControl's Master channel.

The Sonos coordinator owns a queue containing the current occurrence and up to
four prepared successors. Queue edits replace only the future tail. Old history
is removed as the speaker advances. Generic UPnP receivers use the optional
SetNextAVTransportURI command; receivers rejecting it use completion polling.
Title, artist, album, artwork and concrete MIME type travel as escaped DIDL-Lite
metadata. Source authorization stays in Lokal's existing HTTP relay.

Android reuses MusicNotificationService's connected-device foreground service,
remote MediaSession volume provider, partial CPU wake lock and SDK-appropriate
Wi-Fi lock. Casting preparation publishes its buffering state before source work.
An ordinary background transition is different from force-stop or the user's
explicit quit policy: neither foreground services nor wake locks guarantee
survival of a force-stop, reboot, or vendor task killer.

iPhone/iPad must use native AirPlay for phone-hosted audio to continue reliably
with the screen locked. UPnP rejects phone-hosted audio there with an actionable
message; iOS does not provide a general LAN-server background entitlement.
Direct network URLs can play from a Sonos queue independently, but replenishing
the bounded queue requires the sender to run. Native AirPlay uses the existing
system route picker. No silent-audio keepalive or background-mode workaround is
used. A receiver can reject unsupported codecs or expired source URLs.

Stop must be acknowledged before automatic local resumption. An unreachable
receiver can be explicitly abandoned from Casting settings; this returns local
ownership paused, without asserting that remote playback stopped.

## Qualification

Mock HTTP/SOAP tests cover metadata, service selection, queue commands, state and
volume. They do not establish physical Sonos acceptance. Before release, test
S1/S2 and current Sonos hardware, existing groups, denied LAN access, Android
screen-off playback and queue progression, iPhone AirPlay screen-off playback,
queue edits/repeat/shuffle, artwork, hardware/notification volume, another
controller changing playback, receiver shutdown, Wi-Fi loss and recovery.
