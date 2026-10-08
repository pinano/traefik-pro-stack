import subprocess
import os
from pathlib import Path

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

def test_credentials_sync_skips_disabled_services(tmp_path):
    """
    Verify that 02-credentials.sh does NOT generate secrets for disabled services
    (CrowdSec, Anubis, Prometheus) when they are disabled.
    """
    env_file = tmp_path / '.env'
    env_file.write_text("CROWDSEC_ENABLE=false\nGRAFANA_ENABLED=false\n")
    
    script_path = os.path.join(PROJECT_ROOT, 'scripts', 'init.d', '02-credentials.sh')
    
    proc = subprocess.run(
        ['bash', script_path],
        cwd=str(tmp_path),
        env={
            **os.environ,
            'ENV_FILE': str(env_file),
            'CROWDSEC_ENABLE': 'false',
            'GRAFANA_ENABLED': 'false'
        },
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    content = env_file.read_text()
    
    assert "DASHBOARD_SECRET_KEY=" in content
    assert "REDIS_PASSWORD=" in content
    assert "CROWDSEC_WEB_UI_PASSWORD=" not in content
    assert "CROWDSEC_DB_PASSWORD=" not in content
    assert "CROWDSEC_LAPI_KEY=" not in content
    assert "ANUBIS_REDIS_PRIVATE_KEY=" not in content
    assert "PROMETHEUS_REMOTE_WRITE_TOKEN=" not in content

def test_credentials_sync_generates_when_services_enabled(tmp_path):
    """
    Verify that 02-credentials.sh generates all secrets when services are enabled.
    """
    env_file = tmp_path / '.env'
    env_file.write_text("CROWDSEC_ENABLE=true\nGRAFANA_ENABLED=true\n")
    
    # Simulate anubis active
    (tmp_path / '.anubis_available').touch()
    
    script_path = os.path.join(PROJECT_ROOT, 'scripts', 'init.d', '02-credentials.sh')
    
    proc = subprocess.run(
        ['bash', script_path],
        cwd=str(tmp_path),
        env={
            **os.environ,
            'ENV_FILE': str(env_file),
            'CROWDSEC_ENABLE': 'true',
            'GRAFANA_ENABLED': 'true'
        },
        capture_output=True,
        text=True
    )
    assert proc.returncode == 0
    content = env_file.read_text()
    
    assert "DASHBOARD_SECRET_KEY=" in content
    assert "REDIS_PASSWORD=" in content
    assert "CROWDSEC_WEB_UI_PASSWORD=" in content
    assert "CROWDSEC_DB_PASSWORD=" in content
    assert "CROWDSEC_LAPI_KEY=" in content
    assert "ANUBIS_REDIS_PRIVATE_KEY=" in content
    assert "PROMETHEUS_REMOTE_WRITE_TOKEN=" in content
