import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';
import 'package:flick/services/casting/dlna_backend.dart';
import 'package:flick/services/casting/cast_device.dart';

String envelope(String body) =>
    '<s:Envelope xmlns:s="soap"><s:Body>$body</s:Body></s:Envelope>';
String text(XmlDocument doc, String name) =>
    doc.findAllElements(name, namespaceUri: '*').first.innerText;
void main() {
  test(
    'speaker cover is selected only for a successful image response',
    () async {
      const media = 'http://phone:8000/token/track.mp3';
      var found = true;
      final backend = DlnaBackend(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/getaa');
          expect(request.url.queryParameters['u'], media);
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(
            [0xff, 0xd8, 0xff],
            found ? 200 : 404,
            headers: {'content-type': 'image/jpeg'},
          );
        }),
      );
      const control = 'http://speaker:1400/MediaRenderer/AVTransport/Control';
      expect(
        await backend.speakerArtwork(control, media),
        '/getaa?u=${Uri.encodeQueryComponent(media)}',
      );
      found = false;
      expect(await backend.speakerArtwork(control, media), isNull);
    },
  );

  test(
    'Sonos reports the actual inserted index and can reject an empty insert',
    () async {
      var added = 1;
      final backend = DlnaBackend(
        client: MockClient((request) async {
          expect(
            text(
              XmlDocument.parse(request.body),
              'DesiredFirstTrackNumberEnqueued',
            ),
            '1',
          );
          return http.Response(
            envelope(
              '<NumTracksAdded>$added</NumTracksAdded>'
              '<FirstTrackNumberEnqueued>1</FirstTrackNumberEnqueued>',
            ),
            200,
          );
        }),
      );
      Future<int?> enqueue() => backend.enqueue(
        'http://speaker/control',
        'http://phone/track.mp3',
        '',
        position: 1,
      );
      expect(await enqueue(), 1);
      added = 0;
      await expectLater(enqueue(), throwsStateError);
    },
  );

  test(
    'Sonos uses the configured UTF-8 room name and the existing renderer ID',
    () async {
      final backend = DlnaBackend(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
              '<manufacturer>Sonos</manufacturer><UDN>uuid:RINCON_1</UDN>'
              '<friendlyName>192.168.1.20 - Sonos One</friendlyName>'
              '<roomName> Séjour &amp; Cuisine </roomName><deviceList><device><serviceList>'
              '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
              '<controlURL>/av</controlURL></service>'
              '</serviceList></device></deviceList></device></root>',
            ),
            200,
            headers: {'content-type': 'text/xml'},
          ),
        ),
      );
      final device = await backend.resolve(
        'http://192.168.1.20:1400/description.xml',
      );
      expect(device?.name, 'Séjour & Cuisine');
      expect(device?.id, 'uuid:RINCON_1');
      expect(device?.controlUrl, 'http://192.168.1.20:1400/av');
    },
  );
  test('grouped room targets its coordinator while keeping the selected room identity', () async {
    final topology =
        '<ZoneGroups><ZoneGroup Coordinator="MASTER"><ZoneGroupMember UUID="MEMBER" Location="http://member/device.xml"/><ZoneGroupMember UUID="MASTER" Location="http://master/device.xml"/></ZoneGroup></ZoneGroups>';
    final backend = DlnaBackend(
      client: MockClient((r) async {
        if (r.method == 'POST')
          return http.Response(
            envelope(
              '<ZoneGroupState>${XmlText(topology).toXmlString()}</ZoneGroupState>',
            ),
            200,
          );
        return http.Response(
          '<root><device><manufacturer>Sonos</manufacturer><UDN>uuid:MASTER</UDN><friendlyName>Living room</friendlyName><serviceList>'
          '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/av</controlURL></service>'
          '<service><serviceType>urn:schemas-upnp-org:service:GroupRenderingControl:1</serviceType><controlURL>/group</controlURL></service>'
          '</serviceList></device></root>',
          200,
        );
      }),
    );
    const selected = CastDevice(
      id: 'uuid:MEMBER',
      name: 'Kitchen',
      backend: CastBackend.dlna,
      isSonos: true,
      topologyControlUrl: 'http://member/topology',
    );
    final target = await backend.coordinator(selected);
    expect(target.id, selected.id);
    expect(target.name, 'Kitchen (2 rooms)');
    expect(target.controlUrl, 'http://master/av');
    expect(target.groupRenderingControlUrl, 'http://master/group');
  });
  test('DIDL metadata survives SOAP encoding with artist, album, artwork and exact MIME', () async {
    late http.Request request;
    final backend = DlnaBackend(
      client: MockClient((r) async {
        request = r;
        return http.Response(envelope(''), 200);
      }),
    );
    await backend.setUri(
      'http://speaker/control',
      'http://phone/audio?a=1&b=2',
      title: 'A & <B>',
      artist: 'Singer',
      album: 'Record',
      artworkUrl: 'http://phone/art?a=1&b=2',
      contentType: 'audio/flac',
    );
    final soap = XmlDocument.parse(request.body);
    final didl = XmlDocument.parse(text(soap, 'CurrentURIMetaData'));
    expect(text(didl, 'title'), 'A & <B>');
    expect(text(didl, 'artist'), 'Singer');
    expect(text(didl, 'album'), 'Record');
    expect(text(didl, 'albumArtURI'), 'http://phone/art?a=1&b=2');
    expect(
      didl.findAllElements('res').first.getAttribute('protocolInfo'),
      'http-get:*:audio/flac:*',
    );
    expect(text(didl, 'res'), 'http://phone/audio?a=1&b=2');
  });
  test('room and group RenderingControl endpoints are distinct', () async {
    final backend = DlnaBackend(
      client: MockClient(
        (_) async => http.Response(
          '<root><device>'
          '<manufacturer>Sonos</manufacturer><friendlyName>Kitchen</friendlyName><UDN>uuid:RINCON_1</UDN><serviceList>'
          '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/av</controlURL></service>'
          '<service><serviceType>urn:schemas-upnp-org:service:GroupRenderingControl:1</serviceType><controlURL>/group</controlURL></service>'
          '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/room</controlURL></service>'
          '</serviceList></device></root>',
          200,
        ),
      ),
    );
    final device = await backend.resolve('http://speaker:1400/description.xml');
    expect(device!.isSonos, isTrue);
    expect(device.renderingControlUrl, 'http://speaker:1400/room');
    expect(device.groupRenderingControlUrl, 'http://speaker:1400/group');
  });
  test(
    'Sonos volume uses group service, generic devices use Master channel',
    () async {
      final requests = <http.Request>[];
      final backend = DlnaBackend(
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
            envelope('<CurrentVolume>42</CurrentVolume>'),
            200,
          );
        }),
      );
      const sonos = CastDevice(
        id: 'uuid:room',
        name: 'Room',
        backend: CastBackend.dlna,
        isSonos: true,
        groupRenderingControlUrl: 'http://speaker/group',
      );
      await backend.setDeviceVolume(sonos, 150);
      expect(requests.last.headers['SOAPAction'], contains('SetGroupVolume'));
      expect(
        text(XmlDocument.parse(requests.last.body), 'DesiredVolume'),
        '100',
      );
      expect(await backend.deviceVolume(sonos), 42);
      const other = CastDevice(
        id: 'other',
        name: 'Other',
        backend: CastBackend.dlna,
        renderingControlUrl: 'http://other/room',
      );
      await backend.setDeviceVolume(other, 23);
      expect(requests.last.headers['SOAPAction'], contains('#SetVolume'));
      expect(text(XmlDocument.parse(requests.last.body), 'Channel'), 'Master');
    },
  );
  test('poll includes actual queue track, URI and pause state without inventing completion', () async {
    final backend = DlnaBackend(
      client: MockClient(
        (r) async => http.Response(
          envelope(
            r.headers['SOAPAction']!.contains('GetPositionInfo')
                ? '<Track>3</Track><TrackURI>http://phone/third</TrackURI>'
                      '<TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;'
                      '&lt;res&gt;http://phone/third.mp3&lt;/res&gt;'
                      '&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>'
                      '<RelTime>01:02:03</RelTime><TrackDuration>01:30:00</TrackDuration>'
                : '<CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>',
          ),
          200,
        ),
      ),
    );
    final position = await backend.getPosition('http://speaker/control');
    expect(position!.position.inSeconds, 3723);
    expect(position.track, 3);
    expect(position.uri, 'http://phone/third');
    expect(position.resourceUri, 'http://phone/third.mp3');
    expect(position.playing, isFalse);
    expect(position.state, 'PAUSED_PLAYBACK');
  });
  test(
    'SOAP failure rejects Stop instead of allowing a false successful handoff',
    () async {
      final backend = DlnaBackend(
        client: MockClient(
          (_) async => http.Response(
            envelope(
              '<s:Fault><errorDescription>Offline</errorDescription></s:Fault>',
            ),
            200,
          ),
        ),
      );
      await expectLater(
        backend.stop('http://speaker/control'),
        throwsStateError,
      );
    },
  );
  test(
    'native queue payload includes properly encoded DIDL and one-based indices',
    () async {
      final requests = <http.Request>[];
      final backend = DlnaBackend(
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(envelope(''), 200);
        }),
      );
      const url = 'http://phone/song';
      const artwork = 'http://phone/cover.jpg?a=1&b=2';
      for (final id in [1, 2]) {
        await backend.enqueue(
          'http://speaker/control',
          url,
          DlnaBackend.metadata(
            url,
            title: 'Song',
            artist: 'A & B',
            artworkUrl: artwork,
            sonosQueueId: id,
            duration: const Duration(minutes: 3, seconds: 8),
          ),
        );
        final didl = XmlDocument.parse(
          text(XmlDocument.parse(requests.last.body), 'EnqueuedURIMetaData'),
        );
        expect(didl.findAllElements('item').single.getAttribute('id'), '$id');
        expect(text(didl, 'title'), 'Song');
        expect(text(didl, 'creator'), 'A & B');
        expect(text(didl, 'albumArtURI'), artwork);
        expect(text(didl, 'desc'), 'RINCON_AssociatedZPUDN');
        expect(didl.findAllElements('desc').single.getAttribute('id'), 'cdudn');
        expect(
          didl.findAllElements('res').single.getAttribute('duration'),
          '00:03:08',
        );
      }
      await backend.removeQueueTail('http://speaker/control', 3, 2);
      expect(text(XmlDocument.parse(requests.last.body), 'StartingIndex'), '3');
      expect(
        text(XmlDocument.parse(requests.last.body), 'NumberOfTracks'),
        '2',
      );
      await backend.seekTrack('http://speaker/control', 2);
      expect(text(XmlDocument.parse(requests.last.body), 'Unit'), 'TRACK_NR');
    },
  );
}
