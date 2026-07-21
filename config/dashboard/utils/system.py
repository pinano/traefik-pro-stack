import os
import subprocess
import socket
import logging
from config import BASE_DIR, ENV, TRAEFIK_ACME_ENV_TYPE, read_dotenv

log = logging.getLogger(__name__)

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
