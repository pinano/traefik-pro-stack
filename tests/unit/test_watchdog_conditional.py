import subprocess
import os

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

def test_compose_files_watchdog_disabled():
    """
    Verify that compose-files.sh excludes docker-compose-watchdog.yaml when WATCHDOG_ENABLE=false.
    """
    for val in ['false', '"false"', "'false'", 'FALSE', 'False ']:
        proc = subprocess.run(
            ['bash', '-c', 'source scripts/compose-files.sh && echo "$COMPOSE_FILES"'],
            cwd=PROJECT_ROOT,
            env={**os.environ, 'WATCHDOG_ENABLE': val, 'TRAEFIK_ACME_ENV_TYPE': 'production'},
            capture_output=True,
            text=True
        )
        assert proc.returncode == 0
        assert 'docker-compose-watchdog.yaml' not in proc.stdout, f"Failed for WATCHDOG_ENABLE={val}"

def test_compose_files_watchdog_local_default(tmp_path):
    """
    Verify that compose-files.sh defaults to excluding watchdog when in local environment.
    """
    proc = subprocess.run(
        ['bash', '-c', f'source {os.path.join(PROJECT_ROOT, "scripts", "compose-files.sh")} && echo "$COMPOSE_FILES"'],
        cwd=str(tmp_path),
        env={**os.environ, 'TRAEFIK_ACME_ENV_TYPE': 'local', 'WATCHDOG_ENABLE': ''},
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    assert 'docker-compose-watchdog.yaml' not in proc.stdout

def test_compose_files_watchdog_production_default(tmp_path):
    """
    Verify that compose-files.sh defaults to including watchdog in production/staging.
    """
    proc = subprocess.run(
        ['bash', '-c', f'source {os.path.join(PROJECT_ROOT, "scripts", "compose-files.sh")} && echo "$COMPOSE_FILES"'],
        cwd=str(tmp_path),
        env={**os.environ, 'TRAEFIK_ACME_ENV_TYPE': 'production', 'WATCHDOG_ENABLE': ''},
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    assert 'docker-compose-watchdog.yaml' in proc.stdout
