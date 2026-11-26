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
    assert routers['bad-user-agents-example-com']['service'] == "ping@internal"


def test_generate_config_blocked_paths(tmp_path):
    """
    Tests that blocked paths create a dedicated blocking router targeting ping@internal.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nexample.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['TRAEFIK_BLOCKED_PATHS'] = '/wp-admin,/xmlrpc.php'
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    routers = config['http']['routers']
    assert 'path-blocker-example-com' in routers
    rule = routers['path-blocker-example-com']['rule']
    assert 'wp' in rule and 'admin' in rule
    assert 'xmlrpc' in rule
    assert routers['path-blocker-example-com']['priority'] == 11000
    assert routers['path-blocker-example-com']['service'] == "ping@internal"


def test_generate_config_redirection_middleware_order(tmp_path):
    """
    Tests that redirect middleware is placed at index 0 and noop service maps to ping@internal.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service, anubis_subdomain\nredir.example.com, target.example.com, noop, auth\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    routers = config['http']['routers']
    assert 'router-redir-example-com' in routers
    mw_list = routers['router-redir-example-com']['middlewares']
    
    # Redirection middleware must be first
    assert mw_list[0] == 'redirect-redir-example-com', f"Expected redirect middleware at index 0, got {mw_list}"
    # Target service must be ping@internal for noop
    assert routers['router-redir-example-com']['service'] == "ping@internal"


def test_generate_config_trusted_proxies(tmp_path):
    """
    Tests that TRAEFIK_TRUSTED_IPS entries are added to CrowdSec forwardedHeadersTrustedIPs.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nexample.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['TRAEFIK_TRUSTED_IPS'] = '173.245.48.0/20, 1.2.3.4'
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    crowdsec_plugin = config['http']['middlewares']['crowdsec-check']['plugin']['crowdsec']
    trusted_ips = crowdsec_plugin['forwardedHeadersTrustedIPs']
    assert '173.245.48.0/20' in trusted_ips
    assert '1.2.3.4/32' in trusted_ips


def test_generate_config_no_optional_routers(tmp_path):
    """
    Tests that when TRAEFIK_BAD_USER_AGENTS and TRAEFIK_BLOCKED_PATHS are empty,
    no blocking routers are generated.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nclean.example.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['TRAEFIK_BAD_USER_AGENTS'] = ''
    env['TRAEFIK_BLOCKED_PATHS'] = ''
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    routers = config['http']['routers']
    assert 'router-clean-example-com' in routers
    assert 'bad-user-agents-clean-example-com' not in routers
    assert 'path-blocker-clean-example-com' not in routers


def test_generate_config_custom_limits(tmp_path):
    """
    Tests that custom rate, burst, and concurrency parameters in domains.csv
    generate dedicated per-domain middlewares.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)
    
    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service, anubis_subdomain, rate, burst, concurrency\ncustom.example.com, , web-app, , 15, 30, 5\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    
    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)
    
    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)
        
    middlewares = config['http']['middlewares']
    assert 'rl-custom-example-com' in middlewares
    rate_cfg = middlewares['rl-custom-example-com']['rateLimit']
    assert rate_cfg['average'] == 15
    assert rate_cfg['burst'] == 30
    
    assert 'conc-custom-example-com' in middlewares
    conn_cfg = middlewares['conc-custom-example-com']['inFlightReq']
    assert conn_cfg['amount'] == 5
    
    # Check that the router uses these custom middlewares
    router_mw = config['http']['routers']['router-custom-example-com']['middlewares']
    assert 'rl-custom-example-com' in router_mw
    assert 'conc-custom-example-com' in router_mw


def test_generate_config_crowdsec_disabled(tmp_path):
    """
    Tests that when CROWDSEC_ENABLE=false, no CrowdSec middlewares or
    crowdsec-web-ui router are generated.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\napp.example.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_ENABLE'] = 'false'
    env['DOMAIN'] = 'example.com'
    env['DASHBOARD_SUBDOMAIN'] = 'dashboard'
    env['REDIS_PASSWORD'] = 'test-pass'

    result = subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True, text=True)
    assert result.returncode == 0, f"Script failed: {result.stderr}"

    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)

    routers = config.get('http', {}).get('routers', {})
    middlewares = config.get('http', {}).get('middlewares', {})

    # crowdsec-web-ui router must NOT exist
    assert 'crowdsec-web-ui' not in routers

    # crowdsec middleware must NOT exist
    assert 'crowdsec-check' not in middlewares

    # App router middleware list should not include any crowdsec middleware
    app_router_mw = routers['router-app-example-com']['middlewares']
    assert not any('crowdsec' in mw for mw in app_router_mw)


def test_generate_config_assets_crowdsec_enforcement(tmp_path):
    """
    Tests that static-assets routers enforce CrowdSec bans via the lightweight
    'crowdsec-check-assets' middleware (AppSec disabled for performance), and
    that no crowdsec middleware is generated when CrowdSec is disabled.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nexample.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['CROWDSEC_ENABLE'] = 'true'

    result = subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True, text=True)
    assert result.returncode == 0, f"Script failed: {result.stderr}"

    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)

    middlewares = config['http']['middlewares']

    # The lightweight assets middleware exists and skips AppSec inspection
    assets_plugin = middlewares['crowdsec-check-assets']['plugin']['crowdsec']
    assert assets_plugin['crowdsecAppsecEnabled'] is False

    # The static-assets router enforces CrowdSec bans
    assets_router = config['http']['routers']['static-assets-example-com']
    assert 'crowdsec-check-assets' in assets_router['middlewares']


def test_generate_config_assets_no_crowdsec_when_disabled(tmp_path):
    """
    Tests that with CROWDSEC_ENABLE=false the assets router has no crowdsec
    middleware references.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text("domain, redirection, docker_service\nexample.com, , web-app\n")

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key'
    env['REDIS_PASSWORD'] = 'test-pass'
    env['CROWDSEC_ENABLE'] = 'false'

    subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True)

    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)

    assets_router = config['http']['routers']['static-assets-example-com']
    assert 'crowdsec-check-assets' not in assets_router['middlewares']


def test_anubis_policy_no_spoofable_ua_allow():
    """
    Guards against reintroducing user_agent_regex ALLOW rules in the Anubis
    bot policy: they are trivially spoofable and bypass the PoW challenge
    (audit finding A1, 2026-11-21).
    """
    policy_path = Path(__file__).resolve().parents[2] / 'config' / 'anubis' / 'botPolicy.yaml'
    with open(policy_path, 'r', encoding='utf-8') as f:
        policy = yaml.safe_load(f)

    for bot in policy.get('bots', []):
        if bot.get('action') == 'ALLOW':
            assert 'user_agent_regex' not in bot, (
                f"Anubis bot rule '{bot.get('name')}' uses user_agent_regex with ALLOW: "
                "trivially spoofable PoW bypass. Use path_regex or source_cidrs instead."
            )


def test_generate_config_media_stream_router(tmp_path):
    """
    Tests that media-stream-* routers are generated with priority 500,
    omit global-buffering and global-compress, and retain security, rate/concurrency
    limits, redirects, and Apache forwarding headers.
    """
    (tmp_path / 'config' / 'traefik' / 'dynamic-config').mkdir(parents=True)
    (tmp_path / 'config' / 'crowdsec' / 'parsers').mkdir(parents=True)

    domains_csv = tmp_path / 'domains.csv'
    domains_csv.write_text(
        "domain, redirection, docker_service, anubis_subdomain, rate, burst, concurrency\n"
        "podcast.example.com, , podcast-app, , 30, 60, 10\n"
        "legacy.example.com, , apache-host, , , ,\n"
        "old.example.com, podcast.example.com, noop, , , ,\n"
    )

    env = os.environ.copy()
    env['CROWDSEC_LAPI_KEY'] = 'test-key-123'
    env['REDIS_PASSWORD'] = 'test-redis-pass'
    env['CROWDSEC_ENABLE'] = 'true'

    result = subprocess.run(['python3', SCRIPT_PATH], cwd=str(tmp_path), env=env, capture_output=True, text=True)
    assert result.returncode == 0, f"Script failed: {result.stderr}"

    routers_yaml = tmp_path / 'config' / 'traefik' / 'dynamic-config' / 'routers-generated.yaml'
    with open(routers_yaml, 'r') as f:
        config = yaml.safe_load(f)

    routers = config['http']['routers']

    # 1. Standard media-stream router
    assert 'media-stream-podcast-example-com' in routers
    media_router = routers['media-stream-podcast-example-com']
    assert media_router['priority'] == 500
    assert media_router['service'] == 'podcast-app@docker'
    rule = media_router['rule']
    assert "Host(`podcast.example.com`)" in rule
    assert "(Method(`GET`) || Method(`HEAD`))" in rule
    assert "PathRegexp(`(?i)\\.(" in rule
    for ext in ('mp3', 'm4a', 'mp4', 'm3u8'):
        assert ext in rule

    media_mw = media_router['middlewares']
    assert 'global-buffering' not in media_mw
    assert 'global-compress' not in media_mw
    assert 'crowdsec-check' in media_mw
    assert 'security-headers' in media_mw
    assert 'rl-podcast-example-com' in media_mw
    assert 'conc-podcast-example-com' in media_mw

    # Main router must retain global-buffering and global-compress
    main_mw = routers['router-podcast-example-com']['middlewares']
    assert 'global-buffering' in main_mw
    assert 'global-compress' in main_mw

    # 2. Apache host media-stream router must retain apache-forward-headers
    assert 'media-stream-legacy-example-com' in routers
    assert 'apache-forward-headers' in routers['media-stream-legacy-example-com']['middlewares']

    # 3. Redirected domain media-stream router must keep redirect at index 0
    assert 'media-stream-old-example-com' in routers
    assert routers['media-stream-old-example-com']['middlewares'][0] == 'redirect-old-example-com'





