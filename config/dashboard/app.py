
import os
import csv
import hmac
import subprocess
import secrets
import re
import requests
import socket
import logging
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import Flask, render_template, request, redirect, url_for, session, jsonify, Response
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from functools import wraps
import json
import base64
import datetime
import tldextract
from collections import defaultdict
from urllib.parse import urlparse
from werkzeug.middleware.proxy_fix import ProxyFix

log = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get('FLASK_SECRET_KEY') or os.environ.get('DASHBOARD_SECRET_KEY') or secrets.token_hex(32)

# --- Hardened Session Settings ---
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,  # In production via Traefik HTTPS
    SESSION_COOKIE_SAMESITE='Lax',
    PERMANENT_SESSION_LIFETIME=604800,  # 7 days (reduced from 30 to limit stolen-token window)
    SESSION_COOKIE_PATH='/',  # Ensure cookie is valid for all subpaths
    # Reject incoming request bodies larger than 1 MB to prevent memory exhaustion attacks.
    MAX_CONTENT_LENGTH=1 * 1024 * 1024,
)

# --- App Version ---
APP_VERSION = "Unknown"
try:
    version_file = os.path.join(os.getenv('DASHBOARD_APP_PATH_HOST', '/app'), 'VERSION')
    if os.path.exists(version_file):
        with open(version_file, 'r') as f:
            APP_VERSION = f.read().strip()
except Exception as e:
    log.warning(f"Could not read VERSION file: {e}")

@app.context_processor
def inject_version():
    app_path = os.getenv('DASHBOARD_APP_PATH_HOST', '/app')
    maintenance_active = os.path.exists(os.path.join(app_path, 'config', '.maintenance_mode'))
    return dict(app_version=APP_VERSION, maintenance_active=maintenance_active)

@app.after_request
def set_security_headers(response):
    """Inject defensive HTTP response headers on every reply.

    Traefik already adds these on the external edge via security-headers@file,
    but we also set them here so that direct hits to port 5000 (e.g. from other
    containers or during local development) are equally protected.
    """
    # Prevent browsers from MIME-sniffing the content type
    response.headers.setdefault('X-Content-Type-Options', 'nosniff')
    # Deny embedding in any frame (clickjacking protection)
    response.headers.setdefault('X-Frame-Options', 'DENY')
    # Limit referrer information sent to third-party origins
    response.headers.setdefault('Referrer-Policy', 'strict-origin-when-cross-origin')
    # CSP: allow inline styles/scripts (required by current template structure) but
    # restrict external resources to known trusted origins only.
    response.headers.setdefault(
        'Content-Security-Policy',
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline' https://unpkg.com; "
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "font-src 'self' https://fonts.gstatic.com; "
        "img-src 'self' data:; "
        "connect-src 'self' https://raw.githubusercontent.com; "
        "frame-ancestors 'none';"
    )
    return response

# Apply ProxyFix to handle X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host, X-Forwarded-Prefix
# x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

# --- Rate Limiter Setup ---
# Use Redis as the backing store so rate-limit counters survive container restarts.
# A restart would otherwise reset all counters, creating a brute-force window.
# Falls back to in-memory if REDIS_PASSWORD is not set (e.g. during local dev).
_redis_pass = os.environ.get('REDIS_PASSWORD', '')
_limiter_storage = f"redis://:{_redis_pass}@redis:6379/2" if _redis_pass else "memory://"
limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=["200 per day", "50 per hour"],
    storage_uri=_limiter_storage,
)

ADMIN_USER = os.environ.get('DASHBOARD_ADMIN_USER', 'admin')
ADMIN_PASS = os.environ.get('DASHBOARD_ADMIN_PASSWORD', 'admin')

# Security check: warn if using default credentials
if ADMIN_PASS in ('password', 'admin', ''):
    print("=" * 60)
    print("⚠️  WARNING: Dashboard is using a DEFAULT PASSWORD!")
    print("   Run 'make init' or update DASHBOARD_ADMIN_PASSWORD")
    print("   in your .env file to set a secure password.")
    print("=" * 60)

# Mirror the host path inside the container
BASE_DIR = os.environ.get('DASHBOARD_APP_PATH_HOST', os.path.abspath(os.path.join(os.path.dirname(__file__), '../../')))
DOMAINS_CSV_PATH = os.path.join(BASE_DIR, 'domains.csv')
CAPTCHA_CSV_PATH = os.path.join(BASE_DIR, 'config/crowdsec/captcha_keys.csv')
START_SCRIPT = os.path.join(BASE_DIR, 'scripts/start.sh')
RESTART_INTERNAL_SCRIPT = os.path.join(BASE_DIR, 'scripts/restart-internal.sh')
GENERATE_CONFIG_SCRIPT = os.path.join(BASE_DIR, 'scripts/generate-config.py')
ACME_FILE = os.path.join(BASE_DIR, 'config/traefik/acme.json')

log.debug(f"BASE_DIR={BASE_DIR}")
log.debug(f"DOMAINS_CSV_PATH={DOMAINS_CSV_PATH}")
log.debug(f"START_SCRIPT={START_SCRIPT}")

DOMAIN = os.environ.get('DOMAIN', 'localhost')
TRAEFIK_RATE_AVG = os.environ.get('TRAEFIK_GLOBAL_RATE_AVG', '60')
TRAEFIK_RATE_BURST = os.environ.get('TRAEFIK_GLOBAL_RATE_BURST', '120')
TRAEFIK_CONCURRENCY = os.environ.get('TRAEFIK_GLOBAL_CONCURRENCY', '25')
TRAEFIK_ACME_ENV_TYPE = os.environ.get('TRAEFIK_ACME_ENV_TYPE', 'production')
DASHBOARD_SUBDOMAIN = os.environ.get('DASHBOARD_SUBDOMAIN', 'dashboard')
ENV = os.environ.copy()
ENV['TERM'] = 'xterm'

def generate_csrf_token():
    if 'csrf_token' not in session:
        session['csrf_token'] = secrets.token_hex(32)
    return session['csrf_token']

app.jinja_env.globals['csrf_token'] = generate_csrf_token

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            if request.path.startswith('/dm-api/') or request.path == '/dm-api/restart-stream':
                return jsonify({'error': 'Unauthorized', 'message': 'Authentication required'}), 401
            return redirect(url_for('login', next=request.path))
        return f(*args, **kwargs)
    return decorated_function

@app.before_request
def check_csrf():
    if request.path == '/':
         log.debug(f"app.view_functions keys: {list(app.view_functions.keys())}")

    if request.endpoint == 'login':
        return
    
    # Standard POST check: accept token from header (AJAX) or form body (traditional forms)
    if request.method == "POST":
        token = (
            request.headers.get('X-CSRFToken')
            or request.form.get('csrf_token')
        )
        if not token or token != session.get('csrf_token'):
            return jsonify({'error': 'CSRF token missing or invalid'}), 403

    # Special check for SSE streams (GET side-effects)
    if request.endpoint in ('restart_stream', 'apply_config_stream'):
        token = request.args.get('csrf_token')
        if not token or token != session.get('csrf_token'):
            return jsonify({'error': 'CSRF token missing or invalid'}), 403

def _read_dotenv():
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

def get_subprocess_env():
    """
    Constructs a complete environment mapping by combining current process env
    with variables parsed from the .env file. This ensures calls to Docker
    Compose have all necessary labels/variables to remain Up-to-date.
    Used for: generate-config.py (which needs .env vars via os.getenv).
    """
    local_env = ENV.copy()
    local_env.update(_read_dotenv())
    
    # Critical Hardenization: Ensure labels using these variables don't shift
    acme_type = local_env.get('TRAEFIK_ACME_ENV_TYPE', 'staging').lower()
    if 'TRAEFIK_CERT_RESOLVER' not in local_env:
        if acme_type != 'local':
            local_env['TRAEFIK_CERT_RESOLVER'] = 'le'
        else:
            local_env['TRAEFIK_CERT_RESOLVER'] = ''
            
    # Ensure PROJECT_NAME is consistent
    if 'PROJECT_NAME' not in local_env:
        local_env['PROJECT_NAME'] = 'stack'
        
    # Normalize path if present to avoid trailing slash discrepancies that trigger recreations
    if 'DASHBOARD_APP_PATH_HOST' in local_env:
        local_env['DASHBOARD_APP_PATH_HOST'] = local_env['DASHBOARD_APP_PATH_HOST'].rstrip('/')
            
    # Add common environment variables for well-behaved subprocesses
    local_env['TERM'] = 'xterm-256color'
    local_env['PYTHONUNBUFFERED'] = '1'
    
    # Forensic Log: Only log keys to avoid leaking secrets
    log.info(f"Subprocess env prepared. Critical keys: {[k for k in local_env.keys() if 'TRAEFIK' in k or 'DOMAIN' in k]}")
    return local_env

def build_compose_env():
    """
    Build a CLEAN environment for `docker compose` that matches host execution.

    The critical insight: when `make start` runs on the host, the process env
    contains only system vars + sourced .env vars. When restarting from inside
    the container, os.environ has container-specific vars (FLASK_SECRET_KEY,
    DASHBOARD_INTERNAL, etc.) that were NOT present on the host.
    Docker Compose includes everything from the process env when resolving
    ${VAR} placeholders in compose files. Any difference → container recreation.

    This function builds an env dict from ONLY:
    1. System essentials (PATH, HOME, etc.) needed for docker CLI
    2. All variables from .env (the single source of truth)
    3. Computed fallbacks for vars that start.sh normally exports
    """
    env = {}

    # 1. System essentials for docker CLI to function
    for key in ('PATH', 'HOME', 'USER', 'DOCKER_HOST', 'DOCKER_CONFIG',
                'DOCKER_CERT_PATH', 'DOCKER_TLS_VERIFY', 'TMPDIR',
                'XDG_RUNTIME_DIR', 'DOCKER_BUILDKIT', 'DASHBOARD_APP_PATH_HOST'):
        if key in os.environ:
            env[key] = os.environ[key]

    # 2. Read ALL vars from .env (source of truth, shared with host)
    env.update(_read_dotenv())

    # 3. Ensure computed vars have correct values
    #    TRAEFIK_CERT_RESOLVER should now be in .env (persisted by start.sh)
    #    but we provide a fallback just in case.
    if 'TRAEFIK_CERT_RESOLVER' not in env:
        acme_type = env.get('TRAEFIK_ACME_ENV_TYPE', 'staging').lower()
        env['TRAEFIK_CERT_RESOLVER'] = '' if acme_type == 'local' else 'le'

    if 'PROJECT_NAME' not in env:
        env['PROJECT_NAME'] = 'stack'

    # Normalize path to prevent trailing-slash drift
    if 'DASHBOARD_APP_PATH_HOST' in env:
        env['DASHBOARD_APP_PATH_HOST'] = env['DASHBOARD_APP_PATH_HOST'].rstrip('/')

    # Subprocess execution essentials
    env['TERM'] = 'xterm-256color'
    env['PYTHONUNBUFFERED'] = '1'

    log.info(f"Clean compose env: {len(env)} vars. "
             f"TRAEFIK_CERT_RESOLVER={env.get('TRAEFIK_CERT_RESOLVER', '?')}, "
             f"PROJECT_NAME={env.get('PROJECT_NAME', '?')}")
    return env

def validate_domain_data(entry):
    # Strict validation to ensure no malicious content in CSV or shell injection.
    # We apply specific regex patterns to each type of field.
    
    # Domain: Standard FQDN format (no slashes, no spaces, requires at least one dot)
    domain_pattern = re.compile(r'^[a-zA-Z0-9][-a-zA-Z0-9\.]*\.[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$')
    
    # Redirection: Allows standard URLs, including http/https prefix, path, query parameters, anchors, and encoding
    redir_pattern = re.compile(r'^[a-zA-Z0-9\.\-\_\/\:\?\&\=\#\%\+]+$')
    
    # Service Name: Docker service names can only contain alphanumeric, hyphens, and underscores
    service_pattern = re.compile(r'^[a-zA-Z0-9\-\_]+$')
    
    # Anubis Subdomain: Standard subdomain label (alphanumeric and hyphens only)
    anubis_pattern = re.compile(r'^[a-zA-Z0-9\-]+$')
    
    domain = entry.get('domain', '').strip()
    service_name = entry.get('service_name', '').strip()
    
    if not domain or not service_name:
        return False # Domain and Service are mandatory
        
    # Validate Domain
    if not domain_pattern.match(domain):
        return False
        
    # Validate Service Name
    if not service_pattern.match(service_name):
        return False
        
    # Validate Redirection (if present)
    redir = entry.get('redirection', '').strip()
    if redir and not redir_pattern.match(redir):
        return False
        
    # Validate Anubis Subdomain (if present)
    anubis = entry.get('anubis_subdomain', '').strip()
    if anubis and not anubis_pattern.match(anubis):
        return False
        
    # Numeric fields: must be purely digits if provided
    for field in ['rate', 'burst', 'concurrency']:
        val = entry.get(field, '')
        if val and not str(val).isdigit():
            return False
            
    return True

def get_root_domain(domain):
    extracted = tldextract.extract(domain)
    if extracted.suffix:
        return f"{extracted.domain}.{extracted.suffix}"
    return domain

# Parse certificate details (CN, SANs, Expiration) using OpenSSL
def parse_certificate_data(cert_b64):
    try:
        # Decode base64 to get PEM
        cert_pem = base64.b64decode(cert_b64).decode('utf-8')
        
        # Use openssl to extract info
        # -subject: extracts Subject (Owner)
        # -enddate: extracts Expiration
        # -ext subjectAltName: extracts SANs
        cmd = ['openssl', 'x509', '-noout', '-subject', '-enddate', '-ext', 'subjectAltName']
        process = subprocess.Popen(
            cmd, 
            stdin=subprocess.PIPE, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = process.communicate(input=cert_pem)
        
        if process.returncode != 0:
            return {
                'error': f"Error: {stderr.strip()}",
                'valid_days': -1,
                'expiration_text': "Error",
                'cn': "Unknown",
                'sans': []
            }

        # Defaults
        data = {
            'error': None,
            'valid_days': -1,
            'expiration_timestamp': 0, # For precise sorting
            'expiration_text': "",
            'cn': "",
            'sans': []
        }

        # Parse Line by Line
        for line in stdout.splitlines():
            line = line.strip()
            # 1. Subject/CN
            # format: subject=CN = softest2023.sailti.com
            if line.startswith('subject='):
                # Extract CN
                match = re.search(r'CN\s*=\s*([^,]+)', line)
                if match:
                    data['cn'] = match.group(1).strip()
            
            # 2. Expiration
            # format: notAfter=May 17 12:14:44 2026 GMT
            if line.startswith('notAfter='):
                date_str = line.split('=', 1)[1]
                try:
                    dt = datetime.datetime.strptime(date_str, '%b %d %H:%M:%S %Y GMT')
                    formatted = dt.strftime('%Y-%m-%d %H:%M:%S')
                    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
                    delta = dt - now
                    data['valid_days'] = delta.days
                    data['expiration_timestamp'] = dt.timestamp()
                    data['expiration_text'] = f"{formatted} ({delta.days} days left)"
                except Exception:
                    data['expiration_text'] = date_str
            
            # 3. SANs
            # format: DNS:domain1.com, DNS:domain2.com, ...
            # it might be on the line following "X509v3 Subject Alternative Name:" or inline depending on openssl version/format
            # But with -ext subjectAltName, typically output starts with the header then the content
            if line.startswith('DNS:'):
                 # Splitting by comma
                 parts = [p.strip().replace('DNS:', '') for p in line.split(',')]
                 data['sans'].extend(parts)

        # Fallback if SANs were on a new line (common in some openssl versions)
        # output of -ext is usually:
        # X509v3 Subject Alternative Name: 
        #    DNS:a.com, DNS:b.com
        if not data['sans'] and 'Subject Alternative Name' in stdout:
             # Find the block
             # Check distinct lines again or regex the whole blob
             sans_match = re.search(r'Subject Alternative Name:\s*\n\s*(.*)', stdout, re.MULTILINE)
             if sans_match:
                 san_line = sans_match.group(1).strip()
                 parts = [p.strip().replace('DNS:', '') for p in san_line.split(',')]
                 data['sans'].extend(parts)
        
        return data

    except Exception as e:
         return {
                'error': f"Exception: {e}",
                'valid_days': -1,
                'expiration_timestamp': 0,
                'expiration_text': str(e),
                'cn': "Error",
                'sans': []
            }


def read_csv():
    data = []
    if not os.path.exists(DOMAINS_CSV_PATH):
        return data
    with open(DOMAINS_CSV_PATH, mode='r', encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            if not row:
                continue

            # Determine if enabled (not commented) or disabled (commented)
            enabled = True
            first_col = row[0].strip()
            
            # 1. Handle Commented Lines (Disabled Domains OR Pure Comments)
            if first_col.startswith('#'):
                # Remove the leading # and whitespace
                clean_content = first_col.lstrip('#').strip()
                
                # A. Detect Header: matches "domain" and "redirection"
                #    (Checking row[1] index safely requires checking length first)
                if 'domain' in clean_content.lower() and len(row) > 1 and 'redirection' in row[1].lower():
                    continue

                # B. Detect Pure Comments / Separators (e.g. "---", "Section Title")
                #    If it doesn't look like a domain (has spaces, no dots, etc), skip it.
                #    Simple heuristic: valid domains don't usually have spaces.
                if ' ' in clean_content or not clean_content:
                    continue

                # C. It's a disabled domain
                enabled = False
                row[0] = clean_content
            
            # 2. Ensure row has enough columns (pad if necessary)
            # domain, redirection, service_name, anubis_subdomain, rate, burst, concurrency
            while len(row) < 7:
                row.append('')
            
            # 3. Create Entry Object
            entry = {
                'domain': row[0].strip(),
                'redirection': row[1].strip(),
                'service_name': row[2].strip(),
                'anubis_subdomain': row[3].strip(),
                'rate': row[4].strip(),
                'burst': row[5].strip(),
                'concurrency': row[6].strip(),
                'enabled': enabled
            }
            
            # 4. Final Validation (Skip garbage that might have slipped through)
            #    We reuse the same validation logic we use for writing.
            #    This prevents "----------------" or other junk from breaking the UI.
            if validate_domain_data(entry):
                data.append(entry)

    return data

def write_csv(data):
    """Atomically write domains.csv using a temp file + os.replace().

    Writing directly to the target file truncates it immediately, meaning a
    crash mid-write leaves an empty or corrupt CSV and wipes the entire Traefik
    configuration.  os.replace() is atomic on POSIX — the old file stays intact
    until the new one is fully written and flushed.
    """
    header = "# domain, redirection, service_name, anubis_subdomain, rate, burst, concurrency"
    dest_dir = os.path.dirname(DOMAINS_CSV_PATH)

    tmp_fd, tmp_path = tempfile.mkstemp(dir=dest_dir, suffix='.tmp', prefix='domains_')
    try:
        with os.fdopen(tmp_fd, mode='w', encoding='utf-8', newline='') as f:
            f.write(header + '\n\n')
            writer = csv.writer(f)
            for entry in data:
                if not validate_domain_data(entry):
                    log.warning("Skipping invalid entry during write: %s", entry.get('domain', '?'))
                    continue

                domain_val = entry['domain']
                if not entry.get('enabled', True):
                    domain_val = f"# {domain_val}"
            
                writer.writerow([
                    domain_val,
                    entry['redirection'],
                    entry['service_name'],
                    entry['anubis_subdomain'],
                    entry['rate'],
                    entry['burst'],
                    entry['concurrency']
                ])
            f.flush()
            os.fsync(f.fileno())
        # Atomic replacement (POSIX). Falls back to copy on bind mount EBUSY.
        try:
            os.replace(tmp_path, DOMAINS_CSV_PATH)
        except OSError:
            import shutil
            shutil.copyfile(tmp_path, DOMAINS_CSV_PATH)
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    except Exception:
        # Clean up the temp file if anything went wrong, then re-raise so the
        # caller (HTTP endpoint) gets a 500 instead of silently returning 200
        # with data that was never actually written.
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
# CAPTCHA keys validation patterns
TURNSTILE_SITE_KEY_RE = re.compile(r'^(0x4|[123]x)[A-Za-z0-9-_]{15,30}$')
TURNSTILE_SECRET_KEY_RE = re.compile(r'^(0x4|[123]x)[A-Za-z0-9-_]{30,50}$')

HCAPTCHA_SITE_KEY_RE = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
HCAPTCHA_SECRET_KEY_RE = re.compile(r'^(0x[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')

RECAPTCHA_KEY_RE = re.compile(r'^[A-Za-z0-9-_]{35,50}$')

def verify_secret_key_online(provider, secret_key):
    """
    Query the provider's /siteverify API with the secret key and a dummy response.
    Returns (True, None) if the key is valid/not explicitly rejected.
    Returns (False, error_msg) if explicitly rejected by the provider (invalid-input-secret).
    Returns (None, warning_msg) on connection error/timeout (fail-open).
    """
    endpoints = {
        'turnstile': 'https://challenges.cloudflare.com/turnstile/v0/siteverify',
        'hcaptcha': 'https://api.hcaptcha.com/siteverify',
        'recaptcha': 'https://www.google.com/recaptcha/api/siteverify'
    }
    url = endpoints.get(provider.lower())
    if not url:
        return False, "Proveedor desconocido"
    try:
        # Pass a dummy token so the API evaluates the secret key
        res = requests.post(url, data={'secret': secret_key, 'response': 'dummy_response_token'}, timeout=4)
        if res.status_code != 200:
            # Let's check: Turnstile returns 400 for bad secrets, which is expected
            if res.status_code == 400 and provider.lower() == 'turnstile':
                try:
                    res_json = res.json()
                    error_codes = res_json.get('error-codes', [])
                    if 'invalid-input-secret' in error_codes:
                        return False, "Clave secreta inválida (rechazada por Cloudflare)"
                except Exception:
                    pass
            return None, f"El API del proveedor respondió con estado HTTP {res.status_code}"
            
        res_json = res.json()
        error_codes = res_json.get('error-codes', [])
        if 'invalid-input-secret' in error_codes:
            return False, f"Clave secreta inválida (rechazada por {provider})"
            
        return True, None
    except requests.Timeout:
        return None, "Tiempo de espera agotado al conectar con el proveedor"
    except Exception as e:
        return None, f"Error de conexión: {str(e)}"

def validate_captcha_data(entry):
    """Validate a captcha entry. Disabled entries only need a valid domain."""
    domain = entry.get('root_domain', '').strip().lower()
    # Use standard FQDN regex check to ensure no HTML tags or space characters
    domain_pattern = re.compile(r'^[a-zA-Z0-9][-a-zA-Z0-9\.]*\.[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$')
    if not domain or not domain_pattern.match(domain):
        return False
    # Disabled (commented-out) entries don't need keys — they are preserved as stubs
    if not entry.get('enabled', True):
        return True
    provider = entry.get('provider', '').strip().lower()
    site_key = entry.get('site_key', '').strip()
    secret_key = entry.get('secret_key', '').strip()
    if provider not in ['recaptcha', 'turnstile', 'hcaptcha']:
        return False
    if not site_key or not secret_key:
        return False
    return True

def read_captcha_csv():
    """Read captcha_keys.csv and return all entries including disabled (commented) ones.

    Disabled entries are prefixed with '#' in the CSV and are returned with
    ``enabled=False`` — matching the same pattern as read_csv() for domains.
    """
    data = []
    if not os.path.exists(CAPTCHA_CSV_PATH):
        return data
    with open(CAPTCHA_CSV_PATH, mode='r', encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            if not row:
                continue
            first_col = row[0].strip()
            enabled = True

            if first_col.startswith('#'):
                clean_content = first_col.lstrip('#').strip()
                # Skip the file header line (e.g. "# root_domain, provider, ...")
                if 'root_domain' in clean_content.lower():
                    continue
                # Skip blank/separator comments
                if not clean_content or ' ' in clean_content:
                    continue
                # It's a disabled entry
                enabled = False
                row[0] = clean_content

            while len(row) < 4:
                row.append('')
            entry = {
                'root_domain': row[0].strip().lower(),
                'provider': row[1].strip().lower(),
                'site_key': row[2].strip(),
                'secret_key': row[3].strip(),
                'enabled': enabled
            }
            if validate_captcha_data(entry):
                data.append(entry)
    return data

def write_captcha_csv(data):
    """Atomically write captcha_keys.csv using a temp file + os.replace().

    Disabled entries (enabled=False) are written with a leading '# ' on the
    root_domain column so they persist in the file but are ignored by CrowdSec.
    """
    header = "# root_domain, provider, site_key, secret_key"
    dest_dir = os.path.dirname(CAPTCHA_CSV_PATH)

    tmp_fd, tmp_path = tempfile.mkstemp(dir=dest_dir, suffix='.tmp', prefix='captcha_')
    try:
        with os.fdopen(tmp_fd, mode='w', encoding='utf-8', newline='') as f:
            f.write(header + '\n\n')
            writer = csv.writer(f)
            for entry in data:
                if not validate_captcha_data(entry):
                    log.warning("Skipping invalid captcha entry: %s", entry.get('root_domain', '?'))
                    continue
                root_domain_val = entry['root_domain'].strip().lower()
                if not entry.get('enabled', True):
                    root_domain_val = f"# {root_domain_val}"
                writer.writerow([
                    root_domain_val,
                    entry.get('provider', '').strip().lower(),
                    entry.get('site_key', '').strip(),
                    entry.get('secret_key', '').strip()
                ])
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, CAPTCHA_CSV_PATH)
        try:
            os.chmod(CAPTCHA_CSV_PATH, 0o644)
        except OSError:
            pass
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

def resolve_domain(domain):
    try:
        return socket.gethostbyname(domain)
    except socket.gaierror:
        return None

def check_host_file(domain):
    # Try /etc/hosts-host first if it exists (mounted host's hosts file in container)
    hosts_paths = ['/etc/hosts-host', '/etc/hosts']
    for path in hosts_paths:
        if not os.path.exists(path):
            continue
        try:
            with open(path, 'r') as f:
                for line in f:
                    if not line.strip().startswith('#'):
                        parts = line.split()
                        if len(parts) >= 2 and domain in parts[1:]:
                            return True
        except Exception:
            pass
    return False

def is_apache_on_host() -> bool:
    """Probe port 8080 on the Docker host to confirm Apache is actually running.

    Uses APACHE_HOST_IP (same variable as generate-config.py, default 172.17.0.1)
    so there is a single configurable source for the host gateway IP.
    Timeout is capped at 1 s to keep the UI responsive.
    """
    host_ip = os.environ.get('APACHE_HOST_IP', '172.17.0.1')
    port    = int(os.environ.get('APACHE_HOST_PORT', '8080'))
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        result = s.connect_ex((host_ip, port))
        s.close()
        return result == 0
    except Exception:
        return False

def get_external_services():
    """Return Docker container names available as proxy targets.

    Excludes containers belonging to this stack (by PROJECT_NAME label)
    and prepends 'apache-host' when Apache is detected on port 8080.
    """
    project_name = os.environ.get('PROJECT_NAME', 'stack').lower()

    services = []

    # Live port probe — works whether start.sh ran on the host or inside the container.
    if is_apache_on_host():
        services.append('apache-host')
    
    try:
        # Get container names with their compose project label
        cmd = [
            "docker", "ps", "--format",
            "{{.Names}}\t{{.Label \"com.docker.compose.project\"}}"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                if not line.strip():
                    continue
                parts = line.split('\t', 1)
                name = parts[0].strip()
                compose_project = parts[1].strip().lower() if len(parts) > 1 else ''
                
                # Skip containers belonging to our own stack
                if compose_project == project_name:
                    continue
                
                if name:
                    services.append(name)
        else:
            log.debug(f"Error running docker ps: {result.stderr}")
    except Exception as e:
        log.error(f"Error getting services: {e}")
    
    return sorted(set(services))

@app.route('/login', methods=['GET', 'POST'])
@limiter.limit("5 per minute")
def login():
    # Debug: Print headers to see what Traefik sends
    # print(f"DEBUG LOGIN HEADERS: {request.headers}")
    
    if request.method == 'POST':
        # Simple prevention of empty submissions
        user = request.form.get('username', '')
        pw = request.form.get('password', '')
        
        # Priority for next_url: Form data > X-Replaced-Path (Traefik Error Page) > Referrer (Direct Access)
        next_url = request.form.get('next')
        if not next_url:
            next_url = request.headers.get('X-Replaced-Path')
        
        # If still empty, check Referrer (this happens when user is on /dozzle and clicks Sign In)
        if not next_url and request.referrer:
            referrer = request.referrer
            # Extract path from referrer if it belongs to our domain
            if DOMAIN in referrer:
                try:
                    parsed = urlparse(referrer)
                    if parsed.path and parsed.path != '/login':
                        next_url = parsed.path
                except Exception:
                    pass
        
        log.debug("LOGIN POST: attempt received, Next=%s", next_url)

        # Use hmac.compare_digest to prevent timing-based username/password enumeration.
        user_ok = hmac.compare_digest(user, ADMIN_USER)
        pass_ok = hmac.compare_digest(pw, ADMIN_PASS)
        if user_ok and pass_ok:
            session.clear() # Clear any existing session to prevent fixation
            session['logged_in'] = True
            session.permanent = (request.form.get('remember') == 'on')
            
            # Validate next_url to prevent open-redirect attacks.
            # Reject anything with a netloc component (e.g. //evil.com or https://evil.com).
            if next_url:
                parsed = urlparse(next_url)
                if parsed.scheme in ('', 'https', 'http') and not parsed.netloc and parsed.path.startswith('/'):
                    log.debug("Redirecting to %s", next_url)
                    return redirect(next_url)
            
            log.debug("Redirecting to dashboard")
            return redirect(url_for('dashboard'))
        
        # Log failure (useful for external monitoring or security logs)
        log.warning(f"SECURITY: Failed login attempt for user '{user}' from {request.remote_addr}")
        return render_template('login.html', error='Invalid credentials', domain=DOMAIN, dashboard_subdomain=DASHBOARD_SUBDOMAIN, next=next_url)
    
    # GET: Capture 'next' from query or Referer or X-Replaced-Path
    next_url = request.args.get('next') or request.headers.get('X-Replaced-Path') or request.referrer
    
    # Ensure we don't redirect back to login itself
    if next_url and '/login' in next_url:
        next_url = None
    
    log.debug(f"LOGIN GET: Next={next_url}")
    return render_template('login.html', domain=DOMAIN, dashboard_subdomain=DASHBOARD_SUBDOMAIN, next=next_url)

@app.route('/logout', methods=['POST'])
def logout():
    """Log out the current session.

    Requires a POST with a valid CSRF token to prevent CSRF-logout attacks
    (an attacker could otherwise embed a link that silently logs the admin out).
    The CSRF token is validated by the global check_csrf() before_request hook.
    """
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/auth-check')
@limiter.exempt
def auth_check():
    """
    Forward Auth endpoint for Traefik.
    Returns 200 if user is logged in, 401 otherwise.

    When authenticated, also returns X-Webauth-User and X-Webauth-Role headers.
    Traefik is configured with authResponseHeaders to forward these downstream
    (e.g. to Grafana Auth Proxy, which auto-logs the user in as Admin).
    """
    if session.get('logged_in'):
        resp = Response("OK", status=200)
        resp.headers['X-Webauth-User'] = ADMIN_USER
        resp.headers['X-Webauth-Role'] = 'Admin'
        return resp
    return Response("Unauthorized", status=401)

@app.route('/')
@login_required
def dashboard():
    cs_enable = os.environ.get('CROWDSEC_ENABLE', 'true').lower() == 'true'
    certs_enabled = os.environ.get('TRAEFIK_ACME_ENV_TYPE', 'production').lower() != 'local'
    return render_template('index.html', domain=DOMAIN, crowdsec_enabled=cs_enable, certs_enabled=certs_enabled)

@app.route('/domains')
@login_required
def index():
    return render_template('domains.html', 
                           domain=DOMAIN,
                           rate_avg=TRAEFIK_RATE_AVG,
                           rate_burst=TRAEFIK_RATE_BURST,
                           concurrency=TRAEFIK_CONCURRENCY)

@app.route('/certs')
@login_required
def certs_view():
    # 1. Load Expected Domains from CSV
    expected_domains = set()
    csv_data = read_csv()
    for row in csv_data:
        if row.get('enabled', True): # Only check enabled domains? Or all? User said "all domains.csv are generated"
             d = row.get('domain', '').strip().lower()
             if d:
                 expected_domains.add(d)
             
             # Check for Anubis subdomain
             anubis = row.get('anubis_subdomain', '').strip()
             if anubis and d:
                 root = get_root_domain(d)
                 expected_domains.add(f"{anubis}.{root}".lower())

    # 2. Load Certificates from acme.json
    acme_data = {}
    if os.path.exists(ACME_FILE) and os.path.getsize(ACME_FILE) > 0:
        try:
            with open(ACME_FILE, 'r') as f:
                acme_data = json.load(f)
        except Exception as e:
            print(f"Error loading acme.json: {e}")

    covered_domains = set()
    certificates_details = []

    # Iterate resolvers
    for resolver_name, resolver_data in acme_data.items():
        if isinstance(resolver_data, dict) and isinstance(resolver_data.get('Certificates'), list):
            for cert in resolver_data['Certificates']:
                if 'domain' in cert:
                    # Ignore the 'main' and 'sans' from JSON keys as they might be stale
                    # Parse REAL data from the certificate
                    if cert.get('certificate'):
                        cert_info = parse_certificate_data(cert['certificate'])
                        
                        real_main = cert_info['cn'].lower() if cert_info['cn'] else "unknown"
                        real_sans = [s.lower() for s in cert_info['sans']]
                        
                        # Include main domain in SANs list for UI consistency
                        ui_sans = sorted(list(set([real_main] + real_sans))) if real_main != 'unknown' else sorted(real_sans)
                        
                        # Update stats coverage
                        for d in ui_sans:
                            if d != 'unknown':
                                covered_domains.add(d)

                        status = 'expired'
                        if cert_info['valid_days'] > 30:
                            status = 'valid'
                        elif cert_info['valid_days'] > 0:
                            status = 'warning'
                        
                        certificates_details.append({
                            'main': real_main,
                            'sans': ui_sans,
                            'root': get_root_domain(real_main) if real_main != 'unknown' else 'Unknown',
                            'expiration': cert_info['expiration_text'],
                            'valid_days': cert_info['valid_days'], # Needed for sorting context if visual
                            'expiration_timestamp': cert_info.get('expiration_timestamp', 0),
                            'status': status,
                            'superseded': False # Default
                        })
                    else:
                        # Fallback if no certificate data (shouldn't happen for valid entries)
                        continue

    # 3. Post-process to identify superseded/invalid certificates
    # Re-calculate expected batches for precise validation (like prune-certs.py)
    expected_batch_sets = set()
    domains_by_root = defaultdict(list)
    all_valid_domains = set()
    
    csv_raw_domains = []
    for row in csv_data:
        if row.get('enabled', True):
            d = row.get('domain', '').strip().lower()
            if d:
                root = get_root_domain(d)
                csv_raw_domains.append({'domain': d, 'root': root})
                anubis = row.get('anubis_subdomain', '').strip()
                if anubis:
                    csv_raw_domains.append({'domain': f"{anubis}.{root}".lower(), 'root': root})
                    
    for entry in csv_raw_domains:
        domains_by_root[entry['root']].append(entry['domain'])
        
    batch_size = int(os.environ.get('TRAEFIK_TLS_BATCH_SIZE', '30'))
    
    for root_domain, subdomains in domains_by_root.items():
        subs_unicos = list(dict.fromkeys(subdomains))
        all_valid_domains.update(subs_unicos)
        for i in range(0, len(subs_unicos), batch_size):
            batch = subs_unicos[i:i + batch_size]
            expected_batch_sets.add(frozenset(batch))
            
    domain_env = os.environ.get('DOMAIN', '').lower()
    dash_sub = os.environ.get('DASHBOARD_SUBDOMAIN', '').lower()
    if domain_env:
        if dash_sub:
            dash_fqdn = f"{dash_sub}.{domain_env}"
            all_valid_domains.add(dash_fqdn)
            expected_batch_sets.add(frozenset([dash_fqdn]))
        else:
            all_valid_domains.add(domain_env)
            expected_batch_sets.add(frozenset([domain_env]))

    # Group by exact domain set to detect duplicates flawlessly
    certs_by_domains = defaultdict(list)
    for cert in certificates_details:
        cert_doms = frozenset([cert['main']] + cert['sans'])
        certs_by_domains[cert_doms].append(cert)
    
    final_certificates = []
    
    for cert_doms, certs in certs_by_domains.items():
        # Sort descending by expiration_timestamp
        certs.sort(key=lambda x: x.get('expiration_timestamp', 0), reverse=True)
        
        for i, cert in enumerate(certs):
            # Check if this specific certificate exactly matches an expected batch or valid single domain
            cert_domains = frozenset([cert['main']] + cert['sans'])
            is_valid_batch = cert_domains in expected_batch_sets
            is_valid_single = len(cert_domains) == 1 and list(cert_domains)[0] in all_valid_domains
            
            # It's superseded/invalid if it's not the newest OR it doesn't match expected configuration
            if i > 0 or not (is_valid_batch or is_valid_single):
                cert['superseded'] = True
                cert['status'] = 'superseded'
        
        final_certificates.extend(certs)
    
    # Sort final list by root domain then main domain for display
    final_certificates.sort(key=lambda x: (x['root'], x['main']))

    # 4. Calculate Stats (using final list)
    total_certs = len(final_certificates)
    
    unique_domains = set()
    for c in final_certificates:
        if not c.get('superseded', False):
            if c['main'] != 'unknown':
                unique_domains.add(c['main'])
            unique_domains.update(c['sans'])
            
    total_unique_domains = len(unique_domains)
    
    missing_domains = expected_domains - covered_domains
    missing_count = len(missing_domains)
    
    # 5. Prepare data for template
    return render_template('certs.html', 
                           domain=DOMAIN,
                           certificates=final_certificates,
                           total_certs=total_certs,
                           total_unique_domains=total_unique_domains,
                           missing_count=missing_count,
                           missing_domains=sorted(list(missing_domains)))

@app.route('/captchas')
@login_required
def captchas_view():
    return render_template('captchas.html', domain=DOMAIN)



@app.route('/dm-api/domains', methods=['GET', 'POST'])
@login_required
def api_domains():
    if request.method == 'GET':
        return jsonify(read_csv())
    
    if request.method == 'POST':
        data = request.json
        if not isinstance(data, list):
            return jsonify({'status': 'error', 'message': 'Expected a JSON array'}), 400

        # Check for duplicates (only for enabled records)
        seen_domains = {}
        duplicates = []
        for entry in data:
            if not entry.get('enabled', True):
                continue
            domain = entry.get('domain', '').strip().lower()
            if not domain:
                continue
            if domain in seen_domains:
                if domain not in duplicates:
                    duplicates.append(domain)
            seen_domains[domain] = True
        
        if duplicates:
            return jsonify({
                'status': 'error', 
                'message': f'Duplicate domains found: {", ".join(duplicates)}',
                'duplicates': duplicates
            }), 400
            
        # --- MERGE STRATEGY: Preserve Order & Append New ---
        
        # 1. Read existing CSV to get current order
        current_data = read_csv()
        
        # 2. Index new data by domain for fast lookup
        # Key: domain (lowercase), Value: entry dict
        incoming_map = {}
        for entry in data:
            d = entry.get('domain', '').strip().lower()
            if d:
                incoming_map[d] = entry

        # 3. Construct new list
        final_list = []
        processed_domains = set()

        # 3a. Update existing entries in their original order
        for existing_entry in current_data:
            d_existing = existing_entry.get('domain', '').strip().lower()
            
            # If this valid domain exists in internal map (even if commented out in CSV)
            if d_existing in incoming_map:
                # Update it with new values from UI
                # We replace the entire text content with the new one
                final_list.append(incoming_map[d_existing])
                processed_domains.add(d_existing)
            else:
                # It's not in the new list -> It was deleted in UI
                pass 
        
        # 3b. Append NEW entries (those in incoming_map but not in processed_domains)
        # We iterate over the 'data' list from UI to respect the user's *new* addition order among themselves
        for entry in data:
            d = entry.get('domain', '').strip().lower()
            if d and d not in processed_domains:
                final_list.append(entry)
                processed_domains.add(d)
        
        try:
            write_csv(final_list)
        except Exception as e:
            log.error("Failed to write domains.csv: %s", e)
            return jsonify({'status': 'error', 'message': 'Failed to save changes to disk. Check server logs.'}), 500
        return jsonify({'status': 'success'})

@app.route('/dm-api/captchas', methods=['GET', 'POST'])
@login_required
def api_captchas():
    if request.method == 'GET':
        return jsonify(read_captcha_csv())
    
    if request.method == 'POST':
        data = request.json
        if not isinstance(data, list):
            return jsonify({'status': 'error', 'message': 'Expected a JSON array'}), 400

        # Only check active (enabled) entries for duplicates
        seen_domains = {}
        duplicates = []
        for entry in data:
            if not entry.get('enabled', True):
                continue  # Disabled entries can share domain names with no conflict
            domain = entry.get('root_domain', '').strip().lower()
            if not domain:
                continue
            if domain in seen_domains:
                if domain not in duplicates:
                    duplicates.append(domain)
            seen_domains[domain] = True

        if duplicates:
            return jsonify({
                'status': 'error',
                'message': f'Duplicate root domains found: {", ".join(duplicates)}',
                'duplicates': duplicates
            }), 400

        # Retrieve active root domains from domains.csv to check configuration alignment
        try:
            domains_data = read_csv()
            active_root_domains = {get_root_domain(d['domain']).lower() for d in domains_data if d.get('enabled', True) and d.get('domain')}
            # Dashboard synthetic domain validation
            active_root_domains.add(get_root_domain(DOMAIN).lower())
        except Exception as e:
            log.error("Failed to read domains.csv during captcha validation: %s", e)
            active_root_domains = set()

        errors = []
        warnings = []
        entries_to_verify = []

        for entry in data:
            domain = entry.get('root_domain', '').strip().lower()
            
            # Domain format check for all entries (enabled or disabled)
            domain_pattern = re.compile(r'^[a-zA-Z0-9][-a-zA-Z0-9\.]*\.[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$')
            if not domain or not domain_pattern.match(domain):
                errors.append(f"[{domain or 'Vacío'}] El dominio es inválido o está vacío.")
                continue

            # Skip key validation for disabled entries
            if not entry.get('enabled', True):
                continue

            provider = entry.get('provider', '').strip().lower()
            site_key = entry.get('site_key', '').strip()
            secret_key = entry.get('secret_key', '').strip()

            has_structural_error = False

            # Basic structure validation (empty keys, etc.)
            if not validate_captcha_data(entry):
                errors.append(f"[{domain}] Faltan la Site Key o la Secret Key.")
                has_structural_error = True
                continue

            # 1. Check if domain exists in domains.csv
            if domain not in active_root_domains:
                errors.append(f"[{domain}] El dominio no está configurado como activo en domains.csv.")
                has_structural_error = True

            # 2. Check format with Regex
            if provider == 'turnstile':
                if not TURNSTILE_SITE_KEY_RE.match(site_key):
                    errors.append(f"[{domain}] Formato de Site Key inválido para Turnstile (debe empezar por 0x4 y tener de 18 a 33 caracteres).")
                    has_structural_error = True
                if not TURNSTILE_SECRET_KEY_RE.match(secret_key):
                    errors.append(f"[{domain}] Formato de Secret Key inválido para Turnstile (debe empezar por 0x4 y tener de 33 a 53 caracteres).")
                    has_structural_error = True
            elif provider == 'hcaptcha':
                if not HCAPTCHA_SITE_KEY_RE.match(site_key):
                    errors.append(f"[{domain}] La Site Key de hCaptcha debe tener un formato UUID válido.")
                    has_structural_error = True
                if not HCAPTCHA_SECRET_KEY_RE.match(secret_key):
                    errors.append(f"[{domain}] La Secret Key de hCaptcha debe ser un UUID o empezar con 0x y tener 40 caracteres hexadecimales.")
                    has_structural_error = True
            elif provider == 'recaptcha':
                if not RECAPTCHA_KEY_RE.match(site_key):
                    errors.append(f"[{domain}] Formato de Site Key inválido para reCAPTCHA.")
                    has_structural_error = True
                if not RECAPTCHA_KEY_RE.match(secret_key):
                    errors.append(f"[{domain}] Formato de Secret Key inválido para reCAPTCHA.")
                    has_structural_error = True

            # If no structural/regex errors, queue for online verification
            if not has_structural_error:
                entries_to_verify.append((domain, provider, secret_key))

        # 3. Online verification (Parallel via ThreadPoolExecutor)
        if entries_to_verify:
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = {
                    executor.submit(verify_secret_key_online, provider, sec): (dom, provider)
                    for dom, provider, sec in entries_to_verify
                }
                for future in as_completed(futures):
                    dom, prov = futures[future]
                    try:
                        is_valid, err_msg = future.result()
                        if is_valid is False:
                            errors.append(f"[{dom}] Error en la clave secreta de {prov}: {err_msg}")
                        elif is_valid is None:
                            warnings.append(f"[{dom}] No se pudo verificar la clave secreta de {prov} online: {err_msg}")
                    except Exception as e:
                        warnings.append(f"[{dom}] Error al verificar la clave secreta de {prov}: {str(e)}")

        if errors:
            return jsonify({
                'status': 'error',
                'message': 'Falló la validación de claves CAPTCHA.',
                'errors': errors
            }), 400

        write_captcha_csv(data)
        return jsonify({
            'status': 'success',
            'warnings': warnings
        })

@app.route('/dm-api/services', methods=['GET'])
@login_required
def api_services():
    try:
        final_list = get_external_services()
        return jsonify(final_list)
    except Exception as e:
        print(f"Error getting external services: {e}")
        return jsonify([])

# ... (omitted helper funcs) ...

def _resolve_expected_ip():
    """Resolve the host IP once. Returns (expected_ip, error_response_or_None)."""
    host_domain = f"{DASHBOARD_SUBDOMAIN}.{os.environ.get('DOMAIN')}"
    expected_ip = resolve_domain(host_domain)
    if not expected_ip:
        if TRAEFIK_ACME_ENV_TYPE == 'local':
            if check_host_file(host_domain):
                return '127.0.0.1', None
            return None, {'status': 'error', 'message': f'Could not resolve host domain ({host_domain}) locally or in /etc/hosts'}
        return None, {'status': 'error', 'message': f'Could not resolve host domain ({host_domain})'}
    return expected_ip, None


def _check_single_domain(entry, expected_ip, services):
    """
    Core single-domain validation logic.
    Extracted so it can be called from both the single and batch endpoints,
    and run concurrently inside a ThreadPoolExecutor.

    :param entry:       dict with keys: domain, redirection, service_name, anubis_subdomain
    :param expected_ip: pre-resolved host IP (from _resolve_expected_ip)
    :param services:    pre-fetched list of available services (from get_external_services)
    :returns:           status_response dict (same shape as /dm-api/check-domain)
    """
    domain_to_check     = entry.get('domain', '').strip()
    redirection_to_check = entry.get('redirection', '').strip()
    service_to_check    = entry.get('service_name', '').strip()
    anubis_subdomain    = entry.get('anubis_subdomain', '').strip()

    result = {
        'status': 'match',
        'domain': {'status': 'match'},
        'redirection': {'status': 'skipped'},
        'service': {'status': 'found'},
        'anubis': {'status': 'skipped'},
    }

    # 1. Domain Check
    if not domain_to_check:
        result['domain'] = {'status': 'error', 'message': 'Empty domain'}
        result['status'] = 'mismatch'
    else:
        actual_ip = resolve_domain(domain_to_check)
        if not actual_ip:
            if TRAEFIK_ACME_ENV_TYPE == 'local' and check_host_file(domain_to_check):
                actual_ip = expected_ip
            else:
                result['domain'] = {'status': 'error', 'message': 'Resolution failed'}
                result['status'] = 'mismatch'
        elif actual_ip != expected_ip:
            result['domain'] = {'status': 'mismatch', 'expected': expected_ip, 'actual': actual_ip}
            result['status'] = 'mismatch'

    # 2. Redirection Check
    if redirection_to_check:
        redir_ip = resolve_domain(redirection_to_check)
        if not redir_ip:
            if TRAEFIK_ACME_ENV_TYPE == 'local' and check_host_file(redirection_to_check):
                redir_ip = expected_ip
            else:
                result['redirection'] = {'status': 'error', 'message': 'Resolution failed'}
                result['status'] = 'mismatch'
        elif redir_ip != expected_ip:
            result['redirection'] = {'status': 'mismatch', 'expected': expected_ip, 'actual': redir_ip}
            result['status'] = 'mismatch'
        else:
            result['redirection']['status'] = 'match'

    # 2.5. Anubis Check
    if anubis_subdomain and domain_to_check:
        root_domain = get_root_domain(domain_to_check)
        if root_domain:
            anubis_full_domain = f"{anubis_subdomain}.{root_domain}"
            anubis_ip = resolve_domain(anubis_full_domain)
            if not anubis_ip:
                if TRAEFIK_ACME_ENV_TYPE == 'local' and check_host_file(anubis_full_domain):
                    anubis_ip = expected_ip
                else:
                    result['anubis'] = {'status': 'error', 'message': f'Resolution failed for {anubis_full_domain}'}
                    result['status'] = 'mismatch'
            elif anubis_ip != expected_ip:
                result['anubis'] = {'status': 'mismatch', 'expected': expected_ip, 'actual': anubis_ip}
                result['status'] = 'mismatch'
            else:
                result['anubis']['status'] = 'match'
        else:
            result['anubis'] = {'status': 'error', 'message': 'Invalid domain for Anubis check'}
            result['status'] = 'mismatch'

    # 3. Service Check
    if service_to_check:
        if service_to_check not in services:
            result['service'] = {'status': 'missing'}
            result['status'] = 'mismatch'

    return result


@app.route('/dm-api/check-domain', methods=['POST'])
@limiter.exempt
@login_required
def check_domain():
    """Single-domain validation. Kept for backward compatibility."""
    entry = request.json
    expected_ip, err = _resolve_expected_ip()
    if err:
        return jsonify({'status': 'error', 'domain': err,
                        'redirection': {'status': 'skipped'},
                        'service': {'status': 'found'},
                        'anubis': {'status': 'skipped'}})
    services = get_external_services()
    return jsonify(_check_single_domain(entry, expected_ip, services))


@app.route('/dm-api/check-domains-batch', methods=['POST'])
@limiter.exempt
@login_required
def check_domains_batch():
    """
    Batch validation endpoint — resolves host IP and services ONCE, then
    checks all domains in parallel using a ThreadPoolExecutor.

    Accepts: JSON list of domain entry objects
             [{ domain, redirection, service_name, anubis_subdomain }, …]
    Returns: JSON list of result objects in the same order as the input,
             each with the same shape as /dm-api/check-domain.
    """
    entries = request.json
    if not isinstance(entries, list):
        return jsonify({'error': 'Expected a JSON array of domain entries'}), 400

    # --- One-time setup (shared across all domain checks) ---
    expected_ip, err = _resolve_expected_ip()
    if err:
        # Propagate the host-resolution error to every entry
        error_result = {'status': 'error', 'domain': err,
                        'redirection': {'status': 'skipped'},
                        'service': {'status': 'found'},
                        'anubis': {'status': 'skipped'}}
        return jsonify([error_result] * len(entries))

    services = get_external_services()  # docker ps + TCP probe — done ONCE

    # --- Parallel DNS resolution ---
    # We preserve input order by using a dict keyed on index.
    results = [None] * len(entries)

    max_workers = min(30, len(entries)) if entries else 1
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_idx = {
            executor.submit(_check_single_domain, entry, expected_ip, services): idx
            for idx, entry in enumerate(entries)
        }
        for future in as_completed(future_to_idx):
            idx = future_to_idx[future]
            try:
                results[idx] = future.result()
            except Exception as exc:
                log.error(f"Batch check error for index {idx}: {exc}")
                results[idx] = {
                    'status': 'error',
                    'domain': {'status': 'error', 'message': str(exc)},
                    'redirection': {'status': 'skipped'},
                    'service': {'status': 'found'},
                    'anubis': {'status': 'skipped'},
                }

    return jsonify(results)

@app.route('/dm-api/apply-config-stream')
@login_required
def apply_config_stream():
    """
    Zero-downtime hot reload.
    Runs generate-config.py only — Traefik detects the changed dynamic-config files
    via its file-watcher and hot-reloads them without any container restart.
    Suitable for changes to: rate, burst, concurrency, domain routing, middlewares.
    NOT suitable for: new Anubis containers, traefik.yaml static config changes.
    """
    def generate():
        # Determine Python interpreter (prefer venv)
        for candidate in ['.venv/bin/python3', 'venv/bin/python3', 'python3']:
            if candidate.startswith('python') or os.path.isfile(os.path.join(BASE_DIR, candidate)):
                python_cmd = candidate if candidate.startswith('python') else os.path.join(BASE_DIR, candidate)
                break
        else:
            python_cmd = 'python3'

        local_env = get_subprocess_env()

        process = subprocess.Popen(
            [python_cmd, GENERATE_CONFIG_SCRIPT],
            cwd=BASE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=local_env
        )

        for line in process.stdout:
            yield f"data: {line}\n\n"

        process.stdout.close()
        return_code = process.wait()
        yield f"data: [Process finished with code {return_code}]\n\n"

    return Response(generate(), mimetype='text/event-stream')

@app.route('/dm-api/restart', methods=['POST'])
@login_required
def restart_stack():
    """Fire-and-forget soft restart trigger (kept for API compatibility)."""
    log.info("Initiating targeted stack restart...")
    try:
        subprocess.Popen(
            ['bash', RESTART_INTERNAL_SCRIPT],
            cwd=BASE_DIR,
            env=build_compose_env()
        )
        return jsonify({'status': 'success', 'message': 'Stack restart initiated'})
    except Exception as e:
        log.error(f"Failed to start restart script: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/dm-api/restart-stream')
@login_required
def restart_stream():
    """SSE stream for the soft restart progress modal.

    Uses restart-internal.sh which regenerates config and runs
    docker compose up -d --no-recreate --remove-orphans.
    Creates new containers (Anubis), removes orphans, leaves existing
    services untouched.
    """
    def generate():
        process = subprocess.Popen(
            ['bash', RESTART_INTERNAL_SCRIPT],
            cwd=BASE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=build_compose_env()
        )

        for line in process.stdout:
            yield f"data: {line}\n\n"

        process.stdout.close()
        return_code = process.wait()
        yield f"data: [Process finished with code {return_code}]\n\n"

    return Response(generate(), mimetype='text/event-stream')

if __name__ == '__main__':
    log.debug(f"Startup - URL Map: {app.url_map}")
    app.run(host='0.0.0.0', port=5000)
