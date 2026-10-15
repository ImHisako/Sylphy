import unittest

from verify_android_release import signing_certificates, verify_release_continuity


class AndroidReleaseTests(unittest.TestCase):
    def test_parses_old_and_current_android_build_tools_certificates(self):
        digest = 'abcdef01' * 8
        for prefix in ('Signer #1', 'Signer #2', 'V2 Signer:', 'V3.1 Signer:'):
            with self.subTest(prefix=prefix):
                self.assertEqual(signing_certificates(prefix + ' certificate SHA-256 digest: ' + digest.upper()), {digest})
        self.assertEqual(signing_certificates('not a verified signature'), set())

    def setUp(self):
        self.current = ('com.sylphy', 3, '1.2.0', {'release-certificate'})

    def test_same_package_update(self):
        previous = ('com.sylphy', 2, '1.1.0', {'release-certificate'})
        self.assertIn('verified', verify_release_continuity(self.current, previous))

    def test_legacy_package_requires_separate_installation(self):
        previous = ('com.example.sylphy', 2, '1.1.0', {'release-certificate'})
        self.assertIn('separate installation required', verify_release_continuity(self.current, previous))

    def test_rejects_unexpected_package_and_reverse_transition(self):
        for current, previous in [
            (self.current, ('com.other.app', 2, '1.1.0', {'release-certificate'})),
            (('com.example.sylphy', 3, '1.2.0', {'release-certificate'}),
             ('com.sylphy', 2, '1.1.0', {'release-certificate'})),
        ]:
            with self.subTest(current=current[0], previous=previous[0]), self.assertRaises(ValueError):
                verify_release_continuity(current, previous)

    def test_rejects_changed_signer_or_non_increasing_build_for_both_packages(self):
        for package in ('com.sylphy', 'com.example.sylphy'):
            for build, certificates in [(2, {'other-certificate'}), (2, set()),
                                        (3, {'release-certificate'}), (4, {'release-certificate'})]:
                with self.subTest(package=package, build=build, certificates=certificates):
                    with self.assertRaises(ValueError):
                        verify_release_continuity(self.current, (package, build, '1.1.0', certificates))


if __name__ == '__main__':
    unittest.main()
