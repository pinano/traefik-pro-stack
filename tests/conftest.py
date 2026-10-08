import os
import pytest

# Variables that shouldn't leak from host .env into unit tests
STACK_ENV_VARS = [
    'DASHBOARD_SECRET_KEY',
    'REDIS_PASSWORD',
    'CROWDSEC_DB_PASSWORD',
    'CROWDSEC_WEB_UI_PASSWORD',
    'CROWDSEC_LAPI_KEY',
    'ANUBIS_REDIS_PRIVATE_KEY',
    'PROMETHEUS_REMOTE_WRITE_TOKEN',
    'CROWDSEC_ENABLE',
    'CROWDSEC_APPSEC_ENABLE',
    'GRAFANA_ENABLED',
    'GRAFANA_ENABLE',
    'WATCHDOG_ENABLE',
    'WATCHDOG_ENABLED',
    'TRAEFIK_BAD_USER_AGENTS',
    'TRAEFIK_BLOCKED_PATHS',
    'TRAEFIK_TRUSTED_IPS',
    'DOMAIN',
    'DASHBOARD_SUBDOMAIN',
    'TRAEFIK_ACME_ENV_TYPE',
]

@pytest.fixture(autouse=True)
def clean_stack_env(monkeypatch):
    """Ensure host .env variables do not pollute unit tests."""
    for var in STACK_ENV_VARS:
        if var in os.environ:
            monkeypatch.delenv(var, raising=False)
