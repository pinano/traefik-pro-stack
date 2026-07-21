import os
import logging

log = logging.getLogger(__name__)

# Mirror the host path inside the container
BASE_DIR = os.environ.get('DASHBOARD_APP_PATH_HOST', os.path.abspath(os.path.join(os.path.dirname(__file__), '../../')))
DOMAINS_CSV_PATH = os.path.join(BASE_DIR, 'domains.csv')
CAPTCHA_CSV_PATH = os.path.join(BASE_DIR, 'config/crowdsec/captcha_keys.csv')
START_SCRIPT = os.path.join(BASE_DIR, 'scripts/start.sh')
RESTART_INTERNAL_SCRIPT = os.path.join(BASE_DIR, 'scripts/restart-internal.sh')
GENERATE_CONFIG_SCRIPT = os.path.join(BASE_DIR, 'scripts/generate-config.py')
ACME_FILE = os.path.join(BASE_DIR, 'config/traefik/acme.json')

DOMAIN = os.environ.get('DOMAIN', 'localhost')
TRAEFIK_RATE_AVG = os.environ.get('TRAEFIK_GLOBAL_RATE_AVG', '60')
TRAEFIK_RATE_BURST = os.environ.get('TRAEFIK_GLOBAL_RATE_BURST', '120')
TRAEFIK_CONCURRENCY = os.environ.get('TRAEFIK_GLOBAL_CONCURRENCY', '25')
TRAEFIK_ACME_ENV_TYPE = os.environ.get('TRAEFIK_ACME_ENV_TYPE', 'production')
DASHBOARD_SUBDOMAIN = os.environ.get('DASHBOARD_SUBDOMAIN', 'dashboard')

APP_VERSION = "Unknown"
try:
    version_file = os.path.join(os.getenv('DASHBOARD_APP_PATH_HOST', '/app'), 'VERSION')
    if os.path.exists(version_file):
        with open(version_file, 'r') as f:
            APP_VERSION = f.read().strip()
except Exception as e:
    log.warning(f"Could not read VERSION file: {e}")

ENV = os.environ.copy()
ENV['TERM'] = 'xterm'

def read_dotenv():
    """Parse .env file into a dict. Strips quotes and whitespace."""
    result = {}
    env_path = os.path.join(BASE_DIR, '.env')
    if os.path.isfile(env_path):
        try:
            with open(env_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        k, v = line.split('=', 1)
                        v = v.strip()
                        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                            v = v[1:-1]
                        result[k.strip()] = v
        except Exception as e:
            log.error(f"Error reading .env: {e}")
    return result

# Initial parsing so it's available at import time if needed
DOTENV_VARS = read_dotenv()
