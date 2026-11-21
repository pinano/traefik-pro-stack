"""Tests for utils.system.redact_secrets (audit M9)."""
import importlib.util
import os
import sys
import unittest

_DASHBOARD_DIR = os.path.join(os.path.dirname(__file__), '..', '..', 'config', 'dashboard')

# Force-load the REAL dashboard config module: other tests in this suite stub
# sys.modules['config'] with fakes, and utils.system does `from config import ...`.
_spec = importlib.util.spec_from_file_location(
    'config', os.path.join(_DASHBOARD_DIR, 'config.py')
)
_config_mod = importlib.util.module_from_spec(_spec)
sys.modules['config'] = _config_mod
_spec.loader.exec_module(_config_mod)

sys.path.insert(0, _DASHBOARD_DIR)
from utils.system import redact_secrets  # noqa: E402


class TestRedactSecrets(unittest.TestCase):
    def test_replaces_password_values(self):
        env = {'DASHBOARD_ADMIN_PASSWORD': 'super-secret-value'}
        self.assertNotIn('super-secret-value', redact_secrets('error near "super-secret-value"', env))

    def test_replaces_all_marker_types(self):
        env = {
            'REDIS_PASSWORD': 'valkey-pass-12345',
            'PROMETHEUS_REMOTE_WRITE_TOKEN': 'rw-token-abcdef-99',
            'CROWDSEC_LAPI_KEY': 'lapi-key-zzzz-40-chars-long-aaaa',
            'ANUBIS_REDIS_PRIVATE_KEY': 'anubis-key-1234567890abcdef',
        }
        text = ' '.join(env.values())
        redacted = redact_secrets(text, env)
        for value in env.values():
            self.assertNotIn(value, redacted)
        self.assertIn('REDACTED', redacted)

    def test_short_values_are_ignored(self):
        """Values shorter than 8 chars are too generic to redact safely."""
        env = {'SOME_TOKEN': 'ab'}
        self.assertEqual(redact_secrets('ab', env), 'ab')

    def test_non_secret_vars_untouched(self):
        env = {'DOMAIN': 'example.com', 'TZ': 'UTC'}
        self.assertEqual(redact_secrets('domain example.com', env), 'domain example.com')

    def test_longest_values_first(self):
        """A value that contains another secret must be redacted first."""
        env = {'A_SECRET': 'x', 'B_SECRET': 'x-contains-a-secret-too'}
        self.assertEqual(redact_secrets('x-contains-a-secret-too', env), '▪▪▪REDACTED▪▪▪')

    def test_falls_back_to_os_environ(self):
        os.environ['TEST_REDACT_SECRET_XYZ'] = 'my-secret-value-99'
        try:
            self.assertNotIn('my-secret-value-99', redact_secrets('leak: my-secret-value-99'))
        finally:
            del os.environ['TEST_REDACT_SECRET_XYZ']


if __name__ == '__main__':
    unittest.main()
