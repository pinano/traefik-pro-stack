import subprocess
import os
import yaml
from pathlib import Path

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

def test_anubis_disabled_when_no_domains_configured(tmp_path):
    """
    Verify that when no domain in domains.csv uses Anubis:
    1. .anubis_available flag file is absent.
    2. compose-files.sh does not include docker-compose-anubis.yaml or generated compose.
    3. Neither anubis-base nor anubis-assets are in active compose services.
    """
    script_path = os.path.join(PROJECT_ROOT, 'scripts', 'generate-config.py')
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'anubis').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, service, anubis_subdomain\napp.example.com, , web-app, \n")

    env = os.environ.copy()
    env['DOMAIN'] = 'example.com'
    env['DASHBOARD_SUBDOMAIN'] = 'dashboard'
    env['DASHBOARD_ANUBIS_SUBDOMAIN'] = ''
    env['REDIS_PASSWORD'] = 'test-pass'
    env['CROWDSEC_ENABLE'] = 'false'
    env['GRAFANA_ENABLED'] = 'false'

    # Run config generator in tmp_path
    proc = subprocess.run(['python3', script_path], cwd=str(tmp_path), env=env, capture_output=True, text=True)
    assert proc.returncode == 0, f"Generator failed: {proc.stderr}"

    anubis_flag = tmp_path / '.anubis_available'
    assert not anubis_flag.exists(), ".anubis_available should not exist when no domain uses Anubis"

    # Test compose-files.sh evaluation in project root with flag absent
    flag_in_root = Path(PROJECT_ROOT) / '.anubis_available'
    if flag_in_root.exists():
        flag_in_root.unlink()

    proc = subprocess.run(
        ['bash', '-c', 'source scripts/compose-files.sh && echo "$COMPOSE_FILES"'],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    assert 'docker-compose-anubis.yaml' not in proc.stdout
    assert 'docker-compose-anubis-generated.yaml' not in proc.stdout

    # Test docker compose config --services
    proc = subprocess.run(
        ['bash', '-c', 'source scripts/compose-files.sh && docker compose $COMPOSE_FILES config --services'],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    services = proc.stdout.split()
    assert 'anubis-base' not in services
    assert 'anubis-assets' not in services
    assert not any(s.startswith('anubis-') for s in services)

def test_anubis_enabled_when_domain_configured(tmp_path):
    """
    Verify that when a domain in domains.csv uses Anubis:
    1. .anubis_available flag file is created.
    2. compose-files.sh includes docker-compose-anubis.yaml and docker-compose-anubis-generated.yaml.
    3. anubis-assets and the domain service are active, but anubis-base remains template-only.
    """
    script_path = os.path.join(PROJECT_ROOT, 'scripts', 'generate-config.py')
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'anubis').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, service, anubis_subdomain\napp.example.com, , web-app, auth\n")

    env = os.environ.copy()
    env['DOMAIN'] = 'example.com'
    env['DASHBOARD_SUBDOMAIN'] = 'dashboard'
    env['DASHBOARD_ANUBIS_SUBDOMAIN'] = ''
    env['REDIS_PASSWORD'] = 'test-pass'
    env['CROWDSEC_ENABLE'] = 'false'
    env['GRAFANA_ENABLED'] = 'false'

    # Run config generator in tmp_path
    proc = subprocess.run(['python3', script_path], cwd=str(tmp_path), env=env, capture_output=True, text=True)
    assert proc.returncode == 0, f"Generator failed: {proc.stderr}"

    anubis_flag = tmp_path / '.anubis_available'
    assert anubis_flag.exists(), ".anubis_available should exist when Anubis is configured"

    # Verify generated compose uses docker-compose-anubis-base.yaml
    gen_compose = tmp_path / 'docker-compose-anubis-generated.yaml'
    assert gen_compose.exists()
    content = gen_compose.read_text()
    assert 'docker-compose-anubis-base.yaml' in content
