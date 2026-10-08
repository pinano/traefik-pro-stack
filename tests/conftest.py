import os
import pytest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

def get_stack_env_keys():
    """Extract all configuration keys defined in .env.dist plus known prefixes."""
    keys = set()
    dist_file = os.path.join(PROJECT_ROOT, '.env.dist')
    if os.path.exists(dist_file):
        with open(dist_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    keys.add(line.split('=', 1)[0].strip())
    return keys

STACK_KEYS = get_stack_env_keys()

@pytest.fixture(autouse=True)
def clean_stack_env(monkeypatch):
    """Ensure host .env variables do not pollute unit tests."""
    for key in STACK_KEYS:
        if key in os.environ:
            monkeypatch.delenv(key, raising=False)

    prefixes = (
        'CROWDSEC_', 'TRAEFIK_', 'GRAFANA_', 'WATCHDOG_', 'ANUBIS_',
        'DASHBOARD_', 'PROMETHEUS_', 'BACKREST_', 'FILEBROWSER_',
        'PHPMYADMIN_', 'VALKEY_', 'REDIS_'
    )
    for var in list(os.environ.keys()):
        if var.startswith(prefixes):
            monkeypatch.delenv(var, raising=False)
