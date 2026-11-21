"""
Tests for the dashboard auth fail-closed guard (audit A4, 2026-11-21).
Imports the real config/dashboard/blueprints/auth.py with stubbed Flask
dependencies, exercising only the startup credential validation.
"""
import importlib.util
import os
import sys
import types

import pytest

SCRIPT = os.path.join(
    os.path.dirname(__file__), '..', '..', 'config', 'dashboard', 'blueprints', 'auth.py'
)


def _import_auth_module(env: dict):
    """Import auth.py with stubbed Flask deps under the given environment."""
    for key, val in env.items():
        env[key] = val
    saved_env = {k: os.environ.get(k) for k in env}
    for key, val in env.items():
        if val is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = val

    # Stub third-party and app-internal modules auth.py depends on
    def _pass_decorator(*args, **kwargs):
        def deco(f):
            return f
        return deco

    flask = types.ModuleType('flask')

    class _Blueprint:
        def __init__(self, *args, **kwargs):
            pass

        def route(self, *args, **kwargs):
            return _pass_decorator()

        def before_app_request(self, f):
            return f

        def app_context_processor(self, f):
            return f

    flask.Blueprint = _Blueprint
    for name in ('request', 'session', 'redirect', 'url_for',
                 'render_template', 'jsonify', 'Response', 'current_app'):
        setattr(flask, name, object())
    sys.modules['flask'] = flask

    extensions = types.ModuleType('extensions')
    extensions.limiter = types.SimpleNamespace(
        limit=lambda *a, **k: _pass_decorator(),
        exempt=lambda f: f,
    )
    sys.modules['extensions'] = extensions

    config_mod = types.ModuleType('config')
    config_mod.DOMAIN = 'example.com'
    config_mod.DASHBOARD_SUBDOMAIN = 'dashboard'
    sys.modules['config'] = config_mod

    try:
        spec = importlib.util.spec_from_file_location('auth_under_test', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        # Restore original environment
        for key, val in saved_env.items():
            if val is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = val


def _clean_env():
    return {
        'DASHBOARD_ADMIN_USER': None,
        'DASHBOARD_ADMIN_PASSWORD': None,
        'TRAEFIK_ACME_ENV_TYPE': None,
    }


def test_missing_password_fails_closed():
    env = _clean_env()
    env['TRAEFIK_ACME_ENV_TYPE'] = 'production'
    with pytest.raises(RuntimeError, match="not set"):
        _import_auth_module(env)


def test_trivial_password_fails_closed_outside_local():
    for trivial in ('password', 'admin', 'changeme', '12345678'):
        env = _clean_env()
        env['DASHBOARD_ADMIN_PASSWORD'] = trivial
        env['TRAEFIK_ACME_ENV_TYPE'] = 'production'
        with pytest.raises(RuntimeError, match="trivial default value"):
            _import_auth_module(env)


def test_trivial_password_fails_closed_when_env_type_unset():
    """Old .env files without TRAEFIK_ACME_ENV_TYPE must not open the hole."""
    env = _clean_env()
    env['DASHBOARD_ADMIN_PASSWORD'] = 'password'
    with pytest.raises(RuntimeError, match="trivial default value"):
        _import_auth_module(env)


def test_trivial_password_allowed_in_local():
    env = _clean_env()
    env['DASHBOARD_ADMIN_PASSWORD'] = 'password'
    env['TRAEFIK_ACME_ENV_TYPE'] = 'local'
    module = _import_auth_module(env)
    assert module.ADMIN_PASS == 'password'
    assert module.ADMIN_USER == 'admin'


def test_strong_password_starts_everywhere():
    env = _clean_env()
    env['DASHBOARD_ADMIN_PASSWORD'] = 'correct-horse-battery-staple'
    env['TRAEFIK_ACME_ENV_TYPE'] = 'production'
    module = _import_auth_module(env)
    assert module.ADMIN_PASS == 'correct-horse-battery-staple'
