import io
import plistlib
import unittest
import tempfile
from pathlib import Path
import zipfile
from ios_widget_package import GROUP, BUNDLE, zip_widgets, directory_widgets

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

    def test_nested_or_relocated_extensions_fail_both_audits(self):
        for extra in ['PlugIns/LokalWidgets.appex/PlugIns/Extra.appex/Info.plist',
                      'Resources/Extra.appex/Info.plist']:
            data, host = self.fixture()
            with zipfile.ZipFile(data, 'a') as archive:
                archive.writestr('Payload/Runner.app/' + extra, b'fixture')
            with zipfile.ZipFile(data) as archive:
                with self.assertRaisesRegex(ValueError, 'extensions'):
                    zip_widgets(archive, 'Payload/Runner.app/Info.plist', host)
                with tempfile.TemporaryDirectory() as folder:
                    archive.extractall(folder)
                    with self.assertRaisesRegex(ValueError, 'extensions'):
                        directory_widgets(Path(folder) / 'Payload/Runner.app', host)

    def test_exact_widget_passes_directory_audit(self):
        data, host = self.fixture()
        with zipfile.ZipFile(data) as archive, tempfile.TemporaryDirectory() as folder:
            archive.extractall(folder)
            self.assertEqual(directory_widgets(Path(folder) / 'Payload/Runner.app', host)[0]['bundle_id'], BUNDLE)

if __name__ == '__main__':
    unittest.main()
