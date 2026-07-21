import os
import shutil
import subprocess
import tempfile
import yaml
from pathlib import Path

# The path to the script relative to the project root
SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'scripts', 'generate-config.py'))

def test_generate_config_basic(tmp_path):
    """
    Tests that generate-config.py correctly generates routers for a standard domains.csv
    """
    # Create the necessary folder structure in the temp dir so the script doesn't fail
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    # Write a mock domains.csv
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text(
        "domain, redirection, docker_service, anubis_subdomain, rate, burst, concurrency\n"
        "example.com, , web-app, , 100, 200, 50\n"
        "secure.example.com, , auth-app, auth, , ,\n"
    )

    # Set up environment variables to mimic start.sh
    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key-123'
    env['REDIS_PASSWORD'] = 'test-redis-pass'
    env['DASHBOARD_SUBDOMAIN'] = 'dashboard'
    env['DOMAIN'] = 'example.com'
    env['TRAEFIK_ACME_ENV_TYPE'] = 'staging'
    
    # Execute the script in the temp directory
    result = subprocess.run(
        ['python3', SCRIPT_PATH],
        cwd=str(tmp_path),
        env=env,
        capture_output=True,
        text=True
    )
    
    # Check that it executed successfully
    assert result.returncode == 0, f"Script failed with output:\n{result.stderr}"

    # Verify the generated Traefik routers file exists
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    assert routers_yaml.exists(), "routers-generated.yaml was not created"
    
    # Parse the YAML to verify logic
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    routers = config.get('http', {}).get('routers', {})
    
    # 1. Check example.com router
    assert 'router-example-com' in routers
    assert routers['router-example-com']['rule'] == "Host(`example.com`)"
    assert routers['router-example-com']['service'] == "web-app@docker"
    
    # 2. Check secure.example.com router (Anubis protected)
    assert 'router-secure-example-com' in routers
    assert routers['router-secure-example-com']['rule'] == "Host(`secure.example.com`)"
    assert routers['router-secure-example-com']['service'] == "auth-app@docker"
    
    # Check that Anubis middleware was injected
    middlewares = routers['router-secure-example-com']['middlewares']
    assert any('anubis-mw' in mw for mw in middlewares), "Anubis middleware missing from secure route"
    
    # 3. Check Synthetic Dashboard route
    assert 'router-dashboard-example-com' in routers
    assert routers['router-dashboard-example-com']['service'] == "dashboard@docker"


def test_generate_config_waf_disabled(tmp_path):
    """
    Tests that setting CROWDSEC_APPSEC_ENABLE=false removes WAF middlewares.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nexample.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['CROWDSEC_APPSEC_ENABLE'] = 'false'
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    crowdsec_plugin = config['http']['middlewares']['crowdsec-check']['plugin']['crowdsec']
    assert crowdsec_plugin['crowdsecAppsecEnabled'] is False


def test_generate_config_bad_user_agents(tmp_path):
    """
    Tests that bad user agents create a dedicated blocking router.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nexample.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['TRAEFIK_BAD_USER_AGENTS'] = 'MJ12bot, AhrefsBot'
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    routers = config['http']['routers']
    assert 'bad-user-agents-example-com' in routers
    assert 'MJ12bot' in routers['bad-user-agents-example-com']['rule']
    assert routers['bad-user-agents-example-com']['priority'] == 12000

