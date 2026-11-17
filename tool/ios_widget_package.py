"""Allowlist the single shipped WidgetKit extension in both IPA audits."""
import plistlib
import re

GROUP = 'group.app.lokal.mobile.widgets'
BUNDLE = 'app.lokal.mobile.widgets'


def validate_widget_info(host, widget):
    if (host.get('LokalWidgetAppGroup') != GROUP or
            widget.get('LokalWidgetAppGroup') != GROUP or
            widget.get('CFBundleIdentifier') != BUNDLE or
            widget.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension'):
        raise ValueError('Invalid Lokal widget extension identity or App Group')
    for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
        if widget.get(key) != host.get(key):
            raise ValueError('Widget extension version differs from host: ' + key)
    executable = widget.get('CFBundleExecutable', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', executable):
        raise ValueError('Invalid widget executable')
    if widget.get('MinimumOSVersion') != host.get('MinimumOSVersion'):
        raise ValueError('Widget extension minimum iOS differs from host')
    return {'bundle_id': BUNDLE, 'app_group': GROUP,
            'executable': 'PlugIns/LokalWidgets.appex/' + executable}


def zip_widgets(archive, host_plist, host):
    prefix = host_plist.removesuffix('Info.plist')
    roots = {'/'.join(parts[:index + 1]) + '/'
             for name in archive.namelist()
             for parts in [name.rstrip('/').split('/')]
             for index, part in enumerate(parts) if part.endswith('.appex')}
    if not roots:
        if host.get('LokalWidgetAppGroup'):
            raise ValueError('Configured widget extension is missing from IPA')
        return []
    expected = prefix + 'PlugIns/LokalWidgets.appex/'
    if roots != {expected}:
        raise ValueError('Unexpected app extensions in IPA')
    widget = plistlib.loads(archive.read(expected + 'Info.plist'))
    result = validate_widget_info(host, widget)
    if prefix + result['executable'] not in archive.namelist():
        raise ValueError('Missing widget extension executable')
    return [result]


def directory_widgets(app, host):
    roots = set(app.rglob('*.appex'))
    if not roots:
        if host.get('LokalWidgetAppGroup'):
            raise ValueError('Configured widget extension is missing from app')
        return []
    expected = app / 'PlugIns/LokalWidgets.appex'
    if roots != {expected}:
        raise ValueError('Unexpected app extensions in iPhone package')
    widget = plistlib.loads((expected / 'Info.plist').read_bytes())
    result = validate_widget_info(host, widget)
    if not (app / result['executable']).is_file():
        raise ValueError('Missing widget extension executable')
    return [result]
