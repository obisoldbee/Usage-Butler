#!/usr/bin/env python3
"""Build an offline native copy preview from a fixed tracked source tree.

No installation, SM registration, launch or formal-data writes. The two exact
preview bundle IDs remain offline even if LaunchServices drops arguments.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import tarfile
import io
import yaml

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=['Before', 'After', 'GrokBot'], required=True)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists():
        raise SystemExit('Preview destination already exists; choose a fresh directory.')
    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', args.ref + '^{commit}'], text=True).strip()
    archive = subprocess.check_output(['git', '-C', str(ROOT), 'archive', commit])
    destination.mkdir(parents=True, exist_ok=False)
    source = destination / 'source'; source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(source, filter='data')
    identifier = 'io.github.obisoldbee.UsageButler.Preview.Copy.' + args.variant
    # Baseline UI stays untouched. Both fixed trees use the identical harness.
    for relative in ['UsageButlerUI/DebugCopyPreviewScenes.swift', 'UsageButlerApp/CopyPreviewRecorder.swift']:
        (source / relative).write_bytes((ROOT / relative).read_bytes())
    mode = source / 'UsageButlerUI/Runtime/RuntimeLaunchMode.swift'
    text = mode.read_text()
    if identifier not in text:
        anchor = '        if bundleIdentifier?.hasPrefix("io.github.obisoldbee.UsageButler.Validation.History") == true {'
        if anchor not in text: raise RuntimeError('Unsupported launch-mode baseline')
        text = text.replace(anchor, '''        if ["io.github.obisoldbee.UsageButler.Preview.Copy.Before",
            "io.github.obisoldbee.UsageButler.Preview.Copy.After"].contains(bundleIdentifier ?? "") {
            return .offlineFixture
        }
''' + anchor)
        mode.write_text(text)
    entry = source / 'UsageButlerApp/UsageButlerApp.swift'; text = entry.read_text()
    if 'CopyPreviewRecorder.startIfRequested' not in text:
        anchor = '        guard let runtime else { return }\n'
        if anchor not in text: raise RuntimeError('Unsupported App entry')
        text = text.replace(anchor, anchor + '''        #if DEBUG && USAGE_BUTLER_FIXTURES
        if CopyPreviewRecorder.startIfRequested(runtime: runtime) { return }
        #endif
''', 1)
        entry.write_text(text)
    config_path = source / 'project.yml'
    config = yaml.safe_load(config_path.read_text())
    app = config['targets']['UsageButlerApp']
    if args.variant in ['After', 'GrokBot']:
        debug = config['settings']['configs']['Debug']
        debug['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] += ' UB_COPY_AFTER'

    product = 'Usage-Butler-Copy-' + args.variant
    app['productName'] = product
    app['settings']['base'].update(PRODUCT_BUNDLE_IDENTIFIER=identifier, PRODUCT_NAME=product,
                                   AGENT_SERVICE_NAME=identifier + '.unused-agent')
    # Offline previews need no discoverable helper or embedded launch-agent plist.
    app.pop('postBuildScripts', None)
    app['dependencies'] = [d for d in app['dependencies'] if d.get('target') != 'UsageButlerNetworkAgent']
    config['schemes']['UsageButler']['build']['targets'] = {'UsageButlerApp': 'all'}
    config_path.write_text(yaml.safe_dump(config, sort_keys=False, allow_unicode=True))
    info_path = source / 'Config/Info.plist'; info = plistlib.loads(info_path.read_bytes())
    info['CFBundleDisplayName'] = '额度管家 · 文案' + ('修改前' if args.variant == 'Before' else '修改后')
    info_path.write_bytes(plistlib.dumps(info))
    derived = destination / 'DerivedData'
    with (destination / 'build.log').open('x') as log:
        subprocess.run(['xcodegen', 'generate', '--quiet'], cwd=source, stdout=log, stderr=log, check=True)
        subprocess.run(['xcodebuild', '-project', 'UsageButler.xcodeproj', '-scheme', 'UsageButler',
            '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', str(derived),
            'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=', 'build'],
            cwd=source, stdout=log, stderr=log, check=True)
    bundle = derived / 'Build/Products/Debug' / (product + '.app')
    built_info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if built_info.get('CFBundleIdentifier') != identifier: raise RuntimeError('Unexpected preview identity')
    executable = bundle / 'Contents/MacOS' / built_info['CFBundleExecutable']
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    receipt = dict(variant=args.variant, sourceCommit=commit, bundle=str(bundle), bundleID=identifier,
        executable=str(executable), executableSHA256=hashlib.sha256(executable.read_bytes()).hexdigest(),
        sourceArchiveSHA256=hashlib.sha256(archive).hexdigest(), launchMode='offlineFixture',
        helperEmbedded=False, installed=False,
        harnessSHA256={relative: hashlib.sha256((source / relative).read_bytes()).hexdigest()
            for relative in ['UsageButlerUI/DebugCopyPreviewScenes.swift', 'UsageButlerApp/CopyPreviewRecorder.swift']})
    (destination / 'build-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))

if __name__ == '__main__': main()
