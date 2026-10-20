"""Release checks must reject private content without exposing matched bytes."""
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'release_content', Path(__file__).resolve().parents[1] / 'scripts/check-release-content.py')
release_content = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_content)


class ReleaseContentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'AIRS.app'
        self.contents = self.app / 'Contents'
        (self.contents / 'MacOS').mkdir(parents=True)
        (self.contents / 'Info.plist').write_text('fixture')
        self.executable = self.contents / 'MacOS/AIRSApp'

    def test_stable_source_path_is_allowed(self):
        self.executable.write_bytes(b'/AIRS/native/Sources/AIRSApp/main.swift')
        with contextlib.redirect_stdout(io.StringIO()):
            release_content.check(self.app)

    def test_private_path_and_credential_rejected_without_echo(self):
        for payload in (b'/Users/person/Developer/private', b'ghp_' + b'x' * 36,
                        b'-----BEGIN PRIVATE KEY-----'):
            with self.subTest(payload_type=payload[:4]):
                self.executable.write_bytes(payload)
                with self.assertRaises(ValueError) as caught:
                    release_content.check(self.app)
                self.assertNotIn(payload.decode(), str(caught.exception))

    def test_project_credential_in_owned_code_is_rejected(self):
        self.executable.write_bytes(b'sk-proj-' + b'x' * 30)
        with self.assertRaisesRegex(ValueError, 'credential marker'):
            release_content.check(self.app)

    def test_local_verification_receipt_rejected_in_bundle(self):
        self.executable.write_bytes(b'owned code')
        notice = self.contents / 'Resources/RuntimeNotices'
        notice.mkdir(parents=True)
        (notice / 'runtime-receipt.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Unshippable development file'):
            release_content.check(self.app)


class LumenSourceTests(unittest.TestCase):
    def test_private_and_authorship_markers_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Package.swift').write_text('package')
            (root / 'Sources').mkdir()
            (root / 'Sources/One.swift').write_text('owned code')
            source = root / 'Sources/Two.swift'
            for marker in ('/Users/person/project', 'Generated with ' + 'Codex',
                           'sk-proj-' + 'x' * 30):
                source.write_text(marker)
                with self.assertRaisesRegex(ValueError, 'Publication marker'):
                    release_content.check_source(root)

    def test_hidden_development_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env').write_text('fixture')
            with self.assertRaisesRegex(ValueError, 'Unexpected hidden'):
                release_content.check_source(root)
