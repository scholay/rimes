#!/usr/bin/env python3
"""Verify the exact package before transmitting it to Apple."""
import hashlib, json, plistlib, subprocess, sys, tempfile, zipfile
from pathlib import Path
ipa, version, build = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
with tempfile.TemporaryDirectory() as tmp:
    with zipfile.ZipFile(ipa) as archive:
        archive.extractall(tmp)
    app = next((Path(tmp) / 'Payload').glob('*.app'))
    bundles = [app, *app.glob('PlugIns/*.appex')]
    assert len(bundles) == 2, 'Expected app and keyboard extension'
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] in ['org.scholay.rimes.ios', 'org.scholay.rimes.ios.keyboard']
        assert info['CFBundleShortVersionString'] == version
        assert info['CFBundleVersion'] == build
        assert info['UIDeviceFamily'] == [1]
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')]))
        assert profile['TeamIdentifier'] == ['585J2TL9U6']
        assert 'ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices')
        assert not profile['Entitlements'].get('get-task-allow')
        assert (bundle / 'PrivacyInfo.xcprivacy').is_file()
    receipt = {'version': version, 'build': build, 'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(), 'bytes': ipa.stat().st_size, 'signatures': 'valid'}
    ipa.with_suffix('.verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('PASS: exact IPA versions, App Store profiles, signatures, iPhone family and privacy manifests')
