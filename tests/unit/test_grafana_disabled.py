import subprocess
import os
import yaml
from pathlib import Path

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

def test_compose_files_grafana_enabled():
    """
    Verify that compose-files.sh includes docker-compose-observability.yaml by default
    and when GRAFANA_ENABLED=true.
    """
    proc = subprocess.run(
        ['bash', '-c', 'source scripts/compose-files.sh && echo "$COMPOSE_FILES"'],
        cwd=PROJECT_ROOT,
        env={**os.environ, 'GRAFANA_ENABLED': 'true'},
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    assert 'docker-compose-observability.yaml' in proc.stdout

def test_compose_files_grafana_disabled():
    """
    Verify that compose-files.sh excludes docker-compose-observability.yaml when GRAFANA_ENABLED=false.
    """
    for val in ['false', '"false"', "'false'", 'FALSE', 'False ']:
        proc = subprocess.run(
            ['bash', '-c', 'source scripts/compose-files.sh && echo "$COMPOSE_FILES"'],
            cwd=PROJECT_ROOT,
            env={**os.environ, 'GRAFANA_ENABLED': val},
            capture_output=True,
            text=True
        )
        assert proc.returncode == 0
        assert 'docker-compose-observability.yaml' not in proc.stdout, f"Failed for GRAFANA_ENABLED={val}"

def test_generate_config_grafana_disabled(tmp_path):
    """
    Verify that generate-config.py does NOT generate the grafana-frontend router when GRAFANA_ENABLED=false.
    """
    script_path = os.path.join(PROJECT_ROOT, 'scripts', 'generate-config.py')
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\napp.example.com, , web-app\n")

    env = os.environ.copy()
    env['GRAFANA_ENABLED'] = 'false'
    env['CROWDSEC_ENABLE'] = 'false'
    env['DOMAIN'] = 'example.com'
    env['DASHBOARD_SUBDOMAIN'] = 'dashboard'
    env['REDIS_PASSWORD'] = 'test-pass'

    proc = subprocess.run(['python3', script_path], cwd=str(tmp_path), env=env, capture_output=True, text=True)
    assert proc.returncode == 0, f"Script failed: {proc.stderr}"

    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)

    routers = config.get('http', {}).get('routers', {})
    assert 'grafana-frontend' not in routers

def test_makefile_grafana_targets_disabled():
    """
    Verify that Grafana-specific make targets are blocked when GRAFANA_ENABLED=false.
    """
    proc = subprocess.run(
        ['make', 'GRAFANA_ENABLED=false', 'grafana-setup-telegram'],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True
    )
    assert proc.returncode != 0
    assert "Grafana tasks are disabled because GRAFANA_ENABLED=false" in proc.stdout or "Grafana tasks are disabled because GRAFANA_ENABLED=false" in proc.stderr

def test_redis_exporter_excluded_when_grafana_disabled():
    """
    Verify that redis-exporter is defined in observability compose and not in security compose,
    ensuring it does not boot when GRAFANA_ENABLED=false.
    """
    proc = subprocess.run(
        ['bash', '-c', 'source scripts/compose-files.sh && docker compose $COMPOSE_FILES config --services'],
        cwd=PROJECT_ROOT,
        env={**os.environ, 'GRAFANA_ENABLED': 'false'},
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    services = proc.stdout.split()
    assert 'redis-exporter' not in services
    assert 'grafana' not in services
    assert 'loki' not in services
    assert 'alloy' not in services
    assert 'prometheus' not in services


