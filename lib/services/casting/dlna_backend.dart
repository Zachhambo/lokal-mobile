import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import 'cast_device.dart';

// ponytail: pure-Dart DLNA/UPnP via RawDatagramSocket (SSDP) + AVTransport SOAP.
// No new dep; reuses http + xml like UpnpService. Covers DLNA + UPnP renderers
// (same AVTransport:1 protocol). Local media uses CastContentServer.

class DlnaBackend {
  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _st = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const _avTransportType = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _renderingControlType =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  DlnaBackend({http.Client? client}) : _client = client;
  final http.Client? _client;
  Future<http.Response> _get(Uri uri) => _client?.get(uri) ?? http.get(uri);

  Future<CastDevice?> resolve(String location) => _resolve(location);

  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    final locations = <String>{};
    try {
      socket.multicastLoopback = false;
      try {
        socket.joinMulticast(InternetAddress(_ssdpAddress));
      } catch (_) {}
      for (final target in [_st, 'urn:schemas-upnp-org:device:ZonePlayer:1']) {
        final req =
            'M-SEARCH * HTTP/1.1\r\n'
            'HOST: $_ssdpAddress:$_ssdpPort\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $target\r\n\r\n';
        socket.send(req.codeUnits, InternetAddress(_ssdpAddress), _ssdpPort);
      }
      final done = Completer<void>();
      Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram == null) return;
          final msg = String.fromCharCodes(datagram.data);
          final m = RegExp(
            r'^LOCATION\s*:\s*(.+)$',
            caseSensitive: false,
            multiLine: true,
          ).firstMatch(msg);
          if (m != null) locations.add(m.group(1)!.trim());
        }
      });
      await done.future;
    } finally {
      try {
        socket.leaveMulticast(InternetAddress(_ssdpAddress));
      } catch (_) {}
      socket.close();
    }

    final devices = <CastDevice>[];
    await Future.wait(
      locations.map((loc) async {
        final dev = await _resolve(loc);
        if (dev != null) devices.add(dev);
      }),
    );
    return {for (final device in devices) device.id: device}.values.toList();
  }

  Future<CastDevice?> _resolve(String locationUrl) async {
    try {
      final res = await _get(Uri.parse(locationUrl))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final doc = xml.XmlDocument.parse(
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );
      final friendlyName =
          doc
              .findAllElements('friendlyName', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          'Unknown';
      final udn =
          doc
              .findAllElements('UDN', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          locationUrl;
      final manufacturer =
          doc
              .findAllElements('manufacturer', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          '';
      final topology = _findServiceControlUrl(
        doc,
        locationUrl,
        'ZoneGroupTopology',
      );
      final isSonos =
          manufacturer.toLowerCase().contains('sonos') || topology != null;
      final roomName = isSonos
          ? doc.rootElement
                .findElements('device', namespaceUri: '*')
                .firstOrNull
                ?.findElements('roomName', namespaceUri: '*')
                .firstOrNull
                ?.innerText
                .trim()
          : null;
      String? controlUrl = _findServiceControlUrl(
        doc,
        locationUrl,
        'AVTransport',
      );
      if (controlUrl == null) return null;
      return CastDevice(
        id: udn,
        name: roomName != null && roomName.isNotEmpty ? roomName : friendlyName,
        backend: CastBackend.dlna,
        locationUrl: locationUrl,
        controlUrl: controlUrl,
        renderingControlUrl: _findServiceControlUrl(
          doc,
          locationUrl,
          'RenderingControl',
        ),
        isSonos: isSonos,
        topologyControlUrl: topology,
        groupRenderingControlUrl: _findServiceControlUrl(
          doc,
          locationUrl,
          'GroupRenderingControl',
        ),
      );
    } catch (_) {
      return null;
    }
  }

  String? _findServiceControlUrl(
    xml.XmlDocument doc,
    String locationUrl,
    String serviceName,
  ) {
    for (final svc in doc.findAllElements('service', namespaceUri: '*')) {
      final st =
          svc
              .findElements('serviceType', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          '';
      if (st.split(':').elementAtOrNull(3) != serviceName) continue;
      final cu = svc
          .findElements('controlURL', namespaceUri: '*')
          .firstOrNull
          ?.innerText;
      if (cu == null) continue;
      final base = doc
          .findAllElements('URLBase', namespaceUri: '*')
          .firstOrNull
          ?.innerText;
      return Uri.parse(base == null || base.isEmpty ? locationUrl : base)
          .resolve(cu)
          .toString();
    }
    return null;
  }

  Future<void> setUri(
    String controlUrl,
    String mediaUrl, {
    String? title,
    String? artist,
    String? album,
    String? artworkUrl,
    String contentType = 'audio/mpeg',
  }) async {
    final meta = metadata(
      mediaUrl,
      title: title,
      artist: artist,
      album: album,
      artworkUrl: artworkUrl,
      contentType: contentType,
    );
    await _soap(
      controlUrl,
      _avTransportType,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID><CurrentURI>${_esc(mediaUrl)}</CurrentURI><CurrentURIMetaData>${_esc(meta)}</CurrentURIMetaData>',
    );
  }

  /// DIDL is an XML string inside SOAP, so callers escape the whole result once
  /// more when placing it in CurrentURIMetaData / EnqueuedURIMetaData.
  static String metadata(
    String url, {
    String? title,
    String? artist,
    String? album,
    String? artworkUrl,
    String contentType = 'audio/mpeg',
  }) {
    String e(String? v) => (v ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0" restricted="1"><dc:title>${e(title)}</dc:title>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class><upnp:artist>${e(artist)}</upnp:artist><upnp:album>${e(album)}</upnp:album>'
        '${artworkUrl == null ? '' : '<upnp:albumArtURI>${e(artworkUrl)}</upnp:albumArtURI>'}'
        '<res protocolInfo="http-get:*:${e(contentType)}:*">${e(url)}</res></item></DIDL-Lite>';
  }

  Future<CastDevice> coordinator(CastDevice device) async {
    if (!device.isSonos || device.topologyControlUrl == null) return device;
    final result = xml.XmlDocument.parse(
      await _soap(
        device.topologyControlUrl!,
        'urn:schemas-upnp-org:service:ZoneGroupTopology:1',
        'GetZoneGroupState',
        '',
      ),
    );
    final payload = result
        .findAllElements('ZoneGroupState', namespaceUri: '*')
        .firstOrNull
        ?.innerText;
    if (payload == null)
      throw StateError('Sonos did not return room topology.');
    final topology = xml.XmlDocument.parse(payload);
    final uuid = device.id.replaceFirst('uuid:', '');
    final group = topology
        .findAllElements('ZoneGroup')
        .where(
          (g) => g
              .findAllElements('ZoneGroupMember')
              .any((m) => m.getAttribute('UUID') == uuid),
        )
        .firstOrNull;
    final masterId = group?.getAttribute('Coordinator');
    final members = group?.findAllElements('ZoneGroupMember').toList() ?? [];
    final master = members
        .where((m) => m.getAttribute('UUID') == masterId)
        .firstOrNull;
    final location = master?.getAttribute('Location');
    if (location == null)
      throw StateError('Sonos group coordinator is unavailable.');
    final target = masterId == uuid ? device : await _resolve(location);
    if (target == null)
      throw StateError('Sonos group coordinator could not be resolved.');
    return CastDevice(
      id: device.id,
      name: members.length > 1
          ? '${device.name} (${members.length} rooms)'
          : device.name,
      backend: CastBackend.dlna,
      locationUrl: target.locationUrl,
      controlUrl: target.controlUrl,
      renderingControlUrl: target.renderingControlUrl,
      isSonos: true,
      topologyControlUrl: target.topologyControlUrl,
      groupRenderingControlUrl: target.groupRenderingControlUrl,
    );
  }

  Future<void> nextUri(String control, String url, String meta) => _soap(
    control,
    _avTransportType,
    'SetNextAVTransportURI',
    '<InstanceID>0</InstanceID><NextURI>${_esc(url)}</NextURI><NextURIMetaData>${_esc(meta)}</NextURIMetaData>',
  );

  Future<void> setMetadataUri(String control, String url, String meta) => _soap(
    control,
    _avTransportType,
    'SetAVTransportURI',
    '<InstanceID>0</InstanceID><CurrentURI>${_esc(url)}</CurrentURI><CurrentURIMetaData>${_esc(meta)}</CurrentURIMetaData>',
  );

  Future<void> clearQueue(String control) => _soap(
    control,
    _avTransportType,
    'RemoveAllTracksFromQueue',
    '<InstanceID>0</InstanceID>',
  );
  Future<void> enqueue(String control, String url, String meta) => _soap(
    control,
    _avTransportType,
    'AddURIToQueue',
    '<InstanceID>0</InstanceID><EnqueuedURI>${_esc(url)}</EnqueuedURI><EnqueuedURIMetaData>${_esc(meta)}</EnqueuedURIMetaData><DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>',
  );
  Future<void> removeQueueTail(String control, int start, int count) => _soap(
    control,
    _avTransportType,
    'RemoveTrackRangeFromQueue',
    '<InstanceID>0</InstanceID><UpdateID>0</UpdateID><StartingIndex>$start</StartingIndex><NumberOfTracks>$count</NumberOfTracks>',
  );
  Future<void> seekTrack(String control, int track) => _soap(
    control,
    _avTransportType,
    'Seek',
    '<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>$track</Target>',
  );
  Future<void> queueSource(CastDevice device) async {
    final description = await _get(Uri.parse(device.locationUrl!))
        .timeout(const Duration(seconds: 5));
    final doc = xml.XmlDocument.parse(description.body);
    final uuid = doc
        .findAllElements('UDN', namespaceUri: '*')
        .first
        .innerText
        .replaceFirst('uuid:', '');
    await _soap(
      device.controlUrl!,
      _avTransportType,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:${_esc(uuid)}#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>',
    );
  }

  Future<void> playMode(String control, {required bool repeatOne}) => _soap(
    control,
    _avTransportType,
    'SetPlayMode',
    '<InstanceID>0</InstanceID><NewPlayMode>${repeatOne ? 'REPEAT_ONE' : 'NORMAL'}</NewPlayMode>',
  );

  Future<void> setDeviceVolume(CastDevice device, int volume) async {
    if (device.groupRenderingControlUrl == null)
      return setVolume(device.renderingControlUrl!, volume);
    await _soap(
      device.groupRenderingControlUrl!,
      'urn:schemas-upnp-org:service:GroupRenderingControl:1',
      'SetGroupVolume',
      '<InstanceID>0</InstanceID><DesiredVolume>${volume.clamp(0, 100)}</DesiredVolume>',
    );
  }

  Future<int?> deviceVolume(CastDevice device) async {
    if (device.groupRenderingControlUrl == null)
      return device.renderingControlUrl == null
          ? null
          : getVolume(device.renderingControlUrl!);
    final result = xml.XmlDocument.parse(
      await _soap(
        device.groupRenderingControlUrl!,
        'urn:schemas-upnp-org:service:GroupRenderingControl:1',
        'GetGroupVolume',
        '<InstanceID>0</InstanceID>',
      ),
    );
    return int.tryParse(
      result
              .findAllElements('CurrentVolume', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          '',
    );
  }

  Future<void> play(String controlUrl) => _soap(
    controlUrl,
    _avTransportType,
    'Play',
    '<InstanceID>0</InstanceID><Speed>1</Speed>',
  );
  Future<void> pause(String controlUrl) => _soap(
    controlUrl,
    _avTransportType,
    'Pause',
    '<InstanceID>0</InstanceID>',
  );
  Future<void> stop(String controlUrl) =>
      _soap(controlUrl, _avTransportType, 'Stop', '<InstanceID>0</InstanceID>');

  Future<void> seek(String controlUrl, Duration position) => _soap(
    controlUrl,
    _avTransportType,
    'Seek',
    '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${_fmtTime(position)}</Target>',
  );

  // ponytail: volume lives in RenderingControl per UPnP spec, not AVTransport.
  // Some renderers tolerate it on the wrong service; most reject it silently.
  Future<void> setVolume(String renderingControlUrl, int volume) async {
    await _soap(
      renderingControlUrl,
      _renderingControlType,
      'SetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$volume</DesiredVolume>',
    );
  }

  Future<int?> getVolume(String renderingControlUrl) async {
    try {
      final res = await _soap(
        renderingControlUrl,
        _renderingControlType,
        'GetVolume',
        '<InstanceID>0</InstanceID><Channel>Master</Channel>',
      );
      final doc = xml.XmlDocument.parse(res);
      final v = doc
          .findAllElements('CurrentVolume', namespaceUri: '*')
          .firstOrNull
          ?.innerText;
      return v == null ? null : int.tryParse(v.trim())?.clamp(0, 100);
    } catch (_) {
      return null;
    }
  }

  Future<
    ({
      Duration position,
      Duration duration,
      bool playing,
      String state,
      String uri,
      int track,
    })?
  >
  getPosition(String controlUrl) async {
    try {
      final res = await _soap(
        controlUrl,
        _avTransportType,
        'GetPositionInfo',
        '<InstanceID>0</InstanceID>',
      );
      final doc = xml.XmlDocument.parse(res);
      final posStr = doc
          .findAllElements('RelTime', namespaceUri: '*')
          .firstOrNull
          ?.innerText;
      final durStr = doc
          .findAllElements('TrackDuration', namespaceUri: '*')
          .firstOrNull
          ?.innerText;
      final tiRes = await _soap(
        controlUrl,
        _avTransportType,
        'GetTransportInfo',
        '<InstanceID>0</InstanceID>',
      );
      final tiDoc = xml.XmlDocument.parse(tiRes);
      final state =
          tiDoc
              .findAllElements('CurrentTransportState', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          '';
      return (
        position: _parseTime(posStr) ?? Duration.zero,
        duration: _parseTime(durStr) ?? Duration.zero,
        playing: state == 'PLAYING',
        state: state,
        uri:
            doc
                .findAllElements('TrackURI', namespaceUri: '*')
                .firstOrNull
                ?.innerText ??
            '',
        track:
            int.tryParse(
              doc
                      .findAllElements('Track', namespaceUri: '*')
                      .firstOrNull
                      ?.innerText ??
                  '',
            ) ??
            0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _soap(
    String controlUrl,
    String serviceType,
    String action,
    String args,
  ) async {
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">$args</u:$action></s:Body></s:Envelope>';
    final client = _client ?? http.Client();
    final res = await client
        .post(
          Uri.parse(controlUrl),
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPAction': '"$serviceType#$action"',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 5))
        .whenComplete(() {
          if (_client == null) client.close();
        });
    final doc = xml.XmlDocument.parse(res.body);
    if (res.statusCode != 200 ||
        doc.findAllElements('Fault', namespaceUri: '*').isNotEmpty) {
      final desc =
          RegExp(r'<errorDescription>([^<]*)').firstMatch(res.body)?.group(1) ??
          res.body;
      throw StateError(
        '$serviceType $action failed '
        '(HTTP ${res.statusCode}): $desc',
      );
    }
    return res.body;
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  String _fmtTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Duration? _parseTime(String? s) {
    if (s == null || s == 'NOT_IMPLEMENTED' || s == '0:00:00') {
      return s == '0:00:00' ? Duration.zero : null;
    }
    final m = RegExp(r'(\d+):(\d+):(\d+)').firstMatch(s);
    if (m == null) return null;
    return Duration(
      hours: int.parse(m.group(1)!),
      minutes: int.parse(m.group(2)!),
      seconds: int.parse(m.group(3)!),
    );
  }
}
