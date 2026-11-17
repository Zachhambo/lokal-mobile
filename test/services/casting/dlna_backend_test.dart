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
                ? '<Track>3</Track><TrackURI>http://phone/third</TrackURI><RelTime>01:02:03</RelTime><TrackDuration>01:30:00</TrackDuration>'
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
      final metadata = DlnaBackend.metadata('http://phone/song', title: 'Song');
      await backend.enqueue(
        'http://speaker/control',
        'http://phone/song',
        metadata,
      );
      expect(
        text(
          XmlDocument.parse(
            text(XmlDocument.parse(requests.last.body), 'EnqueuedURIMetaData'),
          ),
          'title',
        ),
        'Song',
      );
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
