import io
import plistlib
import unittest
import zipfile
from ios_widget_package import GROUP, BUNDLE, zip_widgets

class WidgetPackageTests(unittest.TestCase):
    def fixture(self, change=None, extra=False):
        host = {'LokalWidgetAppGroup': GROUP, 'CFBundleVersion': '200',
                'CFBundleShortVersionString': '1.2.3', 'MinimumOSVersion': '16.0'}
        widget = {**host, 'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'LokalWidgets',
                  'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}}
        if change:
            widget.update(change)
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('Payload/Runner.app/Info.plist', plistlib.dumps(host))
            archive.writestr('Payload/Runner.app/PlugIns/LokalWidgets.appex/Info.plist', plistlib.dumps(widget))
            archive.writestr('Payload/Runner.app/PlugIns/LokalWidgets.appex/LokalWidgets', b'fixture')
            if extra:
                archive.writestr('Payload/Runner.app/PlugIns/Extra.appex/Info.plist', b'fixture')
        data.seek(0)
        return data, host

    def test_exact_widget_is_allowlisted(self):
        data, host = self.fixture()
        with zipfile.ZipFile(data) as archive:
            result = zip_widgets(archive, 'Payload/Runner.app/Info.plist', host)
        self.assertEqual(result[0]['bundle_id'], BUNDLE)
        self.assertEqual(result[0]['app_group'], GROUP)

    def test_mismatched_versions_groups_floor_and_arbitrary_extensions_fail(self):
        for change in [{'CFBundleVersion': '199'}, {'LokalWidgetAppGroup': 'group.other'},
                       {'MinimumOSVersion': '17.0'}, {'CFBundleExecutable': '../Runner'},
                       {'CFBundleIdentifier': 'app.other.widgets'}]:
            data, host = self.fixture(change)
            with self.subTest(change=change), zipfile.ZipFile(data) as archive, self.assertRaises(ValueError):
                zip_widgets(archive, 'Payload/Runner.app/Info.plist', host)
        data, host = self.fixture(extra=True)
        with zipfile.ZipFile(data) as archive, self.assertRaisesRegex(ValueError, 'extensions'):
            zip_widgets(archive, 'Payload/Runner.app/Info.plist', host)

if __name__ == '__main__':
    unittest.main()
