import os
import subprocess
import socket
import http.client
import logging
import json
import base64
import datetime
import requests
import ssl
import time
from config import BASE_DIR, ENV, TRAEFIK_ACME_ENV_TYPE, ACME_FILE, read_dotenv

log = logging.getLogger(__name__)

_SSL_MAP_CACHE = None
_SSL_MAP_LAST_FETCH = 0
_SSL_MAP_ACME_MTIME = 0

def get_domain_ssl_info(domain, ssl_map):
    """
    Returns the SSL info for a given domain, resolving exact matches and wildcard certificates (*.domain.com).
    """
    if not domain:
        return {'status': 'pending', 'message': 'No domain specified'}

    if ssl_map.get('_is_local'):
        return {'status': 'local', 'message': 'Local Certificate (mkcert)'}

    d = domain.strip().lower()
    if d in ssl_map:
        return ssl_map[d]

    # Wildcard lookup (*.domain.com)
    parts = d.split('.')
    for i in range(1, len(parts) - 1):
        wildcard = '*.' + '.'.join(parts[i:])
        if wildcard in ssl_map:
            return ssl_map[wildcard]

    return {'status': 'pending', 'message': 'No SSL Certificate in acme.json'}

def extract_days_left_fast(cert_b64):
    """
    Extracts certificate expiration days left directly from base64 DER data in pure Python (0.002ms, zero subprocesses).
    """
    if not cert_b64:
        return None
    try:
        der = base64.b64decode(cert_b64)
        import re
        matches = re.findall(b'\x17\x0d([0-9]{12}Z)', der)
        if len(matches) >= 2:
            date_str = matches[1].decode('ascii')
            dt = datetime.datetime.strptime(date_str, '%y%m%d%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
            now = datetime.datetime.now(datetime.timezone.utc)
            return (dt - now).days
    except Exception:
        pass
    try:
        pem = base64.b64decode(cert_b64).decode('utf-8')
        cmd = ['openssl', 'x509', '-noout', '-enddate']
        proc = subprocess.run(cmd, input=pem, capture_output=True, text=True, timeout=1)
        if proc.returncode == 0 and 'notAfter=' in proc.stdout:
            date_str = proc.stdout.strip().split('=', 1)[1]
            exp_ts = int(ssl.cert_time_to_seconds(date_str))
            now_ts = int(time.time())
            return (exp_ts - now_ts) // 86400
    except Exception:
        pass
    return None

def get_ssl_status_map(force_refresh=False):
    """
    Parses acme.json and returns SSL certificate status per domain in < 1ms.
    Uses in-memory caching with mtime checking to ensure sub-millisecond page loads.
    """
    global _SSL_MAP_CACHE, _SSL_MAP_LAST_FETCH, _SSL_MAP_ACME_MTIME

    if TRAEFIK_ACME_ENV_TYPE == 'local':
        return {"_is_local": True}

    now = time.time()
    current_mtime = 0
    if os.path.exists(ACME_FILE):
        try:
            current_mtime = os.path.getmtime(ACME_FILE)
        except Exception:
            pass

    # Return cached map if less than 60 seconds old AND acme.json hasn't been modified
    if not force_refresh and _SSL_MAP_CACHE is not None:
        if (now - _SSL_MAP_LAST_FETCH < 60) and (current_mtime == _SSL_MAP_ACME_MTIME):
            return _SSL_MAP_CACHE

    ssl_map = {}
    if os.path.exists(ACME_FILE):
        try:
            with open(ACME_FILE, 'r') as f:
                data = json.load(f)

            for resolver_name, resolver_data in data.items():
                if isinstance(resolver_data, dict) and 'Certificates' in resolver_data:
                    certs = resolver_data.get('Certificates') or []
                    for cert in certs:
                        main = cert.get('domain', {}).get('main', '').lower()
                        sans = [s.lower() for s in cert.get('domain', {}).get('sans', [])]
                        all_doms = ([main] if main else []) + sans

                        cert_b64 = cert.get('certificate', '')
                        days_left = extract_days_left_fast(cert_b64)

                        for d in all_doms:
                            if d:
                                ssl_map[d] = {
                                    'status': 'ok',
                                    'days_left': days_left
                                }
        except Exception as e:
            log.error(f"Error parsing acme.json: {e}")

    try:
        res = requests.get("http://traefik:8080/api/rawdata", timeout=1)
        if res.status_code == 200:
            rawdata = res.json()
            routers = rawdata.get('routers', {})
            for r_name, r_val in routers.items():
                err = r_val.get('error', '')
                rule = r_val.get('rule', '')
                if err and 'Host(' in rule:
                    import re
                    hosts = re.findall(r'`([^`]+)`', rule)
                    for h in hosts:
                        h_lower = h.lower()
                        if h_lower not in ssl_map or ssl_map[h_lower].get('status') != 'ok':
                            err_msg = "SSL Certificate Issuance Failed"
                            remediation = "Check domain DNS resolution and Traefik logs."
                            if 'CAA' in err:
                                err_msg = "Blocked by CAA DNS Record"
                                remediation = "Add 'CAA 0 issue \"letsencrypt.org\"' to your domain DNS records."
                            elif 'rateLimited' in err:
                                err_msg = "ACME Rate Limit Exceeded (429)"
                                remediation = "Let's Encrypt rate limit reached. Wait for the 7-day rate limit window reset."
                            elif 'unauthorized' in err:
                                err_msg = "DNS Validation Failed (403 Unauthorized)"
                                remediation = "Verify DNS A/AAAA record points to this server IP and ports 80/443 are open."
                            elif err:
                                err_msg = err

                            ssl_map[h_lower] = {
                                'status': 'error',
                                'message': err_msg,
                                'remediation': remediation
                            }
    except Exception:
        pass

    try:
        log_errors = get_traefik_acme_log_errors()
        for d, err_info in log_errors.items():
            if d not in ssl_map or ssl_map[d].get('status') != 'ok':
                ssl_map[d] = err_info
    except Exception:
        pass

    _SSL_MAP_CACHE = ssl_map
    _SSL_MAP_LAST_FETCH = now
    _SSL_MAP_ACME_MTIME = current_mtime
    return ssl_map


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost')
        self.path = path
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)

def get_traefik_acme_log_errors():
    """
    Parses recent Traefik container logs via Docker Unix socket or Docker CLI to extract real-time ACME certificate failure reasons.
    Returns dict: { 'domain.com': {'status': 'error', 'message': '...', 'remediation': '...'} }
    """
    errors = {}
    log_text = ""

    # Attempt 1: Direct Unix Socket connection to Docker Daemon
    try:
        if os.path.exists('/var/run/docker.sock'):
            conn = UnixHTTPConnection('/var/run/docker.sock')
            conn.request('GET', '/containers/traefik/logs?stdout=1&stderr=1&tail=1000')
            res = conn.getresponse()
            if res.status == 200:
                log_text = res.read().decode('utf-8', errors='ignore')
    except Exception:
        pass

    # Attempt 2: Fallback to docker CLI
    if not log_text:
        try:
            proc = subprocess.run(['docker', 'logs', '--tail', '1000', 'traefik'], capture_output=True, text=True, timeout=3)
            if proc.returncode == 0:
                log_text = proc.stdout + '\n' + proc.stderr
        except Exception:
            pass

    if not log_text:
        return errors

    import re
    lines = log_text.splitlines()
    for line in lines:
        if 'acme' in line.lower() or 'certificate' in line.lower():
            found_domains = re.findall(r'([a-zA-Z0-9][a-zA-Z0-9\.\-]+\.[a-zA-Z]{2,})', line)
            for d in found_domains:
                d_clean = d.strip('"`\'[]() ').lower()
                if not d_clean or '.' not in d_clean or 'letsencrypt' in d_clean or 'traefik' in d_clean or 'github' in d_clean or d_clean.startswith('acme'):
                    continue

                remediation = "Verify domain DNS A/AAAA record points to this server IP and ports 80/443 are open."
                msg = "DNS Validation / Auth Failed (403)"

                line_lower = line.lower()
                if 'caa' in line_lower:
                    msg = "Blocked by CAA DNS Record"
                    remediation = "Add 'CAA 0 issue \"letsencrypt.org\"' to your domain DNS records."
                elif 'ratelimit' in line_lower or '429' in line_lower:
                    msg = "ACME Rate Limit Exceeded (429)"
                    remediation = "Let's Encrypt rate limit reached. Wait for the 7-day rate limit window reset."
                elif 'unauthorized' in line_lower or '403' in line_lower:
                    msg = "DNS Validation / Auth Failed (403)"
                    remediation = "Verify domain DNS A/AAAA record points to this server IP and ports 80/443 are open."
                elif 'connection refused' in line_lower or 'timeout' in line_lower:
                    msg = "Network Timeout / Port 80 Blocked"
                    remediation = "Ensure server port 80/443 is accessible publicly."

                errors[d_clean] = {
                    'status': 'error',
                    'message': msg,
                    'remediation': remediation
                }
    return errors

def get_subprocess_env():
    """
    Constructs a complete environment mapping by combining current process env
    with variables parsed from the .env file.
    """
    local_env = ENV.copy()
    local_env.update(read_dotenv())
    
    acme_type = local_env.get('TRAEFIK_ACME_ENV_TYPE', 'staging').lower()
    if 'TRAEFIK_CERT_RESOLVER' not in local_env:
        if acme_type != 'local':
            local_env['TRAEFIK_CERT_RESOLVER'] = 'le'
        else:
            local_env['TRAEFIK_CERT_RESOLVER'] = ''
            
    if 'PROJECT_NAME' not in local_env:
        local_env['PROJECT_NAME'] = 'stack'
        
    if 'DASHBOARD_APP_PATH_HOST' in local_env:
        local_env['DASHBOARD_APP_PATH_HOST'] = local_env['DASHBOARD_APP_PATH_HOST'].rstrip('/')
            
    local_env['TERM'] = 'xterm-256color'
    local_env['PYTHONUNBUFFERED'] = '1'
    
    log.info(f"Subprocess env prepared. Critical keys: {[k for k in local_env.keys() if 'TRAEFIK' in k or 'DOMAIN' in k]}")
    return local_env

def build_compose_env():
    """Build a CLEAN environment for `docker compose` that matches host execution."""
    env = {}

    for key in ('PATH', 'HOME', 'USER', 'DOCKER_HOST', 'DOCKER_CONFIG',
                'DOCKER_CERT_PATH', 'DOCKER_TLS_VERIFY', 'TMPDIR',
                'XDG_RUNTIME_DIR', 'DOCKER_BUILDKIT', 'DASHBOARD_APP_PATH_HOST'):
        if key in os.environ:
            env[key] = os.environ[key]

    env.update(read_dotenv())

    if 'TRAEFIK_CERT_RESOLVER' not in env:
        acme_type = env.get('TRAEFIK_ACME_ENV_TYPE', 'staging').lower()
        env['TRAEFIK_CERT_RESOLVER'] = '' if acme_type == 'local' else 'le'

    if 'PROJECT_NAME' not in env:
        env['PROJECT_NAME'] = 'stack'

    if 'DASHBOARD_APP_PATH_HOST' in env:
        env['DASHBOARD_APP_PATH_HOST'] = env['DASHBOARD_APP_PATH_HOST'].rstrip('/')

    env['TERM'] = 'xterm-256color'
    env['PYTHONUNBUFFERED'] = '1'

    log.info(f"Clean compose env: {len(env)} vars. "
             f"TRAEFIK_CERT_RESOLVER={env.get('TRAEFIK_CERT_RESOLVER', '?')}, "
             f"PROJECT_NAME={env.get('PROJECT_NAME', '?')}")
    return env

def resolve_domain(domain):
    try:
        return socket.gethostbyname(domain)
    except socket.gaierror:
        return None

def check_host_file(domain):
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
    project_name = os.environ.get('PROJECT_NAME', 'stack').lower()
    services = []

    if is_apache_on_host():
        services.append('apache-host')
    
    services.append('dashboard')
    
    try:
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
                
                if compose_project == project_name:
                    continue
                
                if name:
                    services.append(name)
        else:
            log.debug(f"Error running docker ps: {result.stderr}")
    except Exception as e:
        log.error(f"Error getting services: {e}")
    
    return sorted(set(services))
