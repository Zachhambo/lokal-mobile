import 'package:flutter/material.dart';

import '../../../core/theme/lokal_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../services/ios_widget_method_channel_transport.dart';
import '../../../services/ios_widget_publication_coordinator.dart';
import '../../../widgets/lokal/settings/lokal_settings_kit.dart';

class IosWidgetSettingsScreen extends StatefulWidget {
  const IosWidgetSettingsScreen({super.key});
  @override
  State<IosWidgetSettingsScreen> createState() => _IosWidgetSettingsScreenState();
}

class _IosWidgetSettingsScreenState extends State<IosWidgetSettingsScreen> {
  late Future<IosWidgetPublicationCapability> _capability =
      IosWidgetMethodChannelTransport().capability();

  @override
  Widget build(BuildContext context) => LokalSettingsScaffold(
    title: l10n.widgets,
    subtitle: lokalText('Your music on the Home Screen and Lock Screen.'),
    children: [
      LokalSettingsSection(title: lokalText('Your installation'), children: [
        FutureBuilder<IosWidgetPublicationCapability>(
          future: _capability,
          builder: (context, snapshot) => LokalSettingRow(
            label: lokalText(snapshot.data?.available == true
                ? 'Widget sharing is ready'
                : snapshot.connectionState != ConnectionState.done
                    ? 'Checking widget sharing…' : 'Widget sharing is unavailable'),
            description: lokalText(snapshot.data?.available == true
                ? 'Open Lokal and play a song to update your widgets.'
                : 'Keep Lokal Widgets when installing the app. Your signing tool must retain the matching shared App Group.'),
          ),
        ),
        TextButton.icon(
          onPressed: () => setState(() {
            _capability = IosWidgetMethodChannelTransport().capability();
          }),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(l10n.tryAgain),
        ),
      ]),
      LokalSettingsSection(title: lokalText('Choose your widget'), children: [
        _layout(context, Icons.album_outlined, 'Now Playing',
          'Artwork, playback progress and controls. Larger sizes also open your queue.'),
        _layout(context, Icons.all_inclusive_rounded, 'Flow / Radio',
          'Start your Flow or a radio based on the current song.'),
        _layout(context, Icons.library_music_outlined, 'Cover Flow',
          'A selection from your Flow. Tap a cover on larger widgets to play it.'),
      ]),
      LokalSettingsSection(title: lokalText('Add to your screens'), children: [
        LokalSettingRow(label: lokalText('Home Screen'),
          description: lokalText('Touch and hold the Home Screen, choose Edit > Add Widget, then search for Lokal.')),
        LokalSettingRow(label: lokalText('Lock Screen'),
          description: lokalText('Touch and hold the Lock Screen, choose Customize > Add Widgets, then choose Lokal.')),
        LokalSettingRow(label: lokalText('Playback controls'),
          description: lokalText('Widget actions open Lokal to complete playback. Lock Screen widgets open your player. Your iPhone may ask you to unlock it.')),
        LokalSettingRow(label: lokalText('Appearance'),
          description: lokalText('Widgets use your Lokal accent, system light or dark appearance, and system text size.')),
      ]),
    ],
  );

  Widget _layout(BuildContext context, IconData icon, String title, String detail) =>
      ListTile(leading: Icon(icon, color: context.lokal.accent),
        title: Text(lokalText(title)), subtitle: Text(lokalText(detail)));
}
