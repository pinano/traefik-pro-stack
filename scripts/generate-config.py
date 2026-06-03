import sys
import os

# Check for virtual environment redirection if dependencies are missing
try:
    import tldextract
    import yaml
except ImportError:
    script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for venv in ['.venv', 'venv']:
        venv_python = os.path.join(script_dir, venv, 'bin', 'python3')
        if os.path.exists(venv_python):
            if venv_python != sys.executable:
                os.execv(venv_python, [venv_python] + sys.argv)
    print("❌ Error: Missing required dependencies 'tldextract' and/or 'pyyaml'.", file=sys.stderr)
    print("👉 Please run 'make init' to set up the virtual environment.", file=sys.stderr)
    sys.exit(1)

def load_dotenv():
    # Look for .env in current directory or parent directory
    for path in ['.env', '../.env']:
        if os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith('#'):
                            continue
                        if line.startswith('export '):
                            line = line[7:]
                        if '=' in line:
                            key, val = line.split('=', 1)
                            key = key.strip()
                            val = val.strip()
                            # Strip quotes if present
                            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                                val = val[1:-1]
                            if key not in os.environ:
                                os.environ[key] = val
            except Exception:
                pass
            break

load_dotenv()

import csv
import re
from collections import defaultdict


# =============================================================================
# CONSTANTS & FILE PATHS
# =============================================================================

INPUT_FILE = 'domains.csv'
BASE_FILENAME = 'docker-compose-anubis.yaml'
OUTPUT_COMPOSE = 'docker-compose-anubis-generated.yaml'
OUTPUT_TRAEFIK = 'config/traefik/dynamic-config/routers-generated.yaml'
CAPTCHA_KEYS_FILE = 'config/crowdsec/captcha_keys.csv'

# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

CROWDSEC_LAPI_KEY = os.getenv('CROWDSEC_LAPI_KEY')
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD')
CROWDSEC_ENABLE = os.getenv('CROWDSEC_ENABLE', 'true').lower() == 'true'
CROWDSEC_APPSEC_ENABLE = os.getenv('CROWDSEC_APPSEC_ENABLE', 'true').lower() == 'true'
CROWDSEC_CAPTCHA_GRACE_PERIOD = int(os.getenv('CROWDSEC_CAPTCHA_GRACE_PERIOD', 3600))
BACKREST_ENABLE = os.getenv('BACKREST_ENABLE', 'true').lower() == 'true'
TRAEFIK_ENV_TYPE = os.getenv('TRAEFIK_ACME_ENV_TYPE', 'staging')
IS_LOCAL_DEV = (TRAEFIK_ENV_TYPE == 'local')
TRAEFIK_CERT_RESOLVER = os.getenv('TRAEFIK_CERT_RESOLVER', 'le')

# =============================================================================
# CAPTCHA REGISTRY LOAD
# =============================================================================
captcha_registry = {}
if os.path.exists(CAPTCHA_KEYS_FILE):
    try:
        with open(CAPTCHA_KEYS_FILE, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            for row in reader:
                if not row: continue
                row = [col.strip() for col in row]
                if not row[0] or row[0].startswith('#'): continue
                if len(row) >= 4:
                    root_dom = row[0].lower()
                    provider = row[1].lower()
                    site_key = row[2]
                    secret_key = row[3]
                    if provider in ['turnstile', 'recaptcha', 'hcaptcha'] and site_key and secret_key:
                        captcha_registry[root_dom] = {
                            'provider': provider,
                            'site_key': site_key,
                            'secret_key': secret_key
                        }
    except Exception as e:
        print(f"    ⚠️ Warning: Error loading {CAPTCHA_KEYS_FILE}: {e}")

# Blocked Paths (Comma-separated list of regex patterns)
BLOCKED_PATHS_STR = os.getenv('TRAEFIK_BLOCKED_PATHS', '').strip()

# Bad User Agents (Comma-separated list of regex patterns)
BAD_USER_AGENTS_STR = os.getenv('TRAEFIK_BAD_USER_AGENTS', '').strip()

# Good User Agents (Comma-separated list of regex patterns)
GOOD_USER_AGENTS_STR = os.getenv('TRAEFIK_GOOD_USER_AGENTS', '').strip()

# Frame Ancestors (for iframes)
FRAME_ANCESTORS = os.getenv('TRAEFIK_FRAME_ANCESTORS', '').strip()

# Apache Host IP and Port (docker0 bridge on Linux = 172.17.0.1:8080)
APACHE_HOST_IP   = os.getenv('APACHE_HOST_IP',   '172.17.0.1').strip()
APACHE_HOST_PORT = os.getenv('APACHE_HOST_PORT',  '8080').strip()
APACHE_SVC_NAME  = f'apache-host-{APACHE_HOST_PORT}'  # Traefik service name, derived from port

# CrowdSec Whitelist IPs (CIDR list)
CROWDSEC_WHITELIST_IPS_STR = os.getenv('CROWDSEC_WHITELIST_IPS', '').strip()
DEFAULT_TRUSTED_IPS = ['127.0.0.1/32', '172.16.0.0/12', '10.0.0.0/8', '192.168.0.0/16']
TRUSTED_IPS = list(DEFAULT_TRUSTED_IPS)

if CROWDSEC_WHITELIST_IPS_STR:
    for entry in CROWDSEC_WHITELIST_IPS_STR.split(','):
        entry = entry.strip().strip('"').strip("'")
        if not entry: continue
        # Normalize to CIDR if it's a single IP
        if '/' not in entry:
            entry = f"{entry}/32"
        if entry not in TRUSTED_IPS:
            TRUSTED_IPS.append(entry)


# Robust stripping of surrounding quotes
if (BLOCKED_PATHS_STR.startswith('"') and BLOCKED_PATHS_STR.endswith('"')) or \
   (BLOCKED_PATHS_STR.startswith("'") and BLOCKED_PATHS_STR.endswith("'")):
    BLOCKED_PATHS_STR = BLOCKED_PATHS_STR[1:-1]

if (BAD_USER_AGENTS_STR.startswith('"') and BAD_USER_AGENTS_STR.endswith('"')) or \
   (BAD_USER_AGENTS_STR.startswith("'") and BAD_USER_AGENTS_STR.endswith("'")):
    BAD_USER_AGENTS_STR = BAD_USER_AGENTS_STR[1:-1]

if (GOOD_USER_AGENTS_STR.startswith('"') and GOOD_USER_AGENTS_STR.endswith('"')) or \
   (GOOD_USER_AGENTS_STR.startswith("'") and GOOD_USER_AGENTS_STR.endswith("'")):
    GOOD_USER_AGENTS_STR = GOOD_USER_AGENTS_STR[1:-1]

BLOCKED_PATHS = [p.strip().strip('"').strip("'") for p in BLOCKED_PATHS_STR.split(',') if p.strip()]

BAD_USER_AGENTS = [p.strip().strip('"').strip("'") for p in BAD_USER_AGENTS_STR.split(',') if p.strip()]
GOOD_USER_AGENTS = [p.strip().strip('"').strip("'") for p in GOOD_USER_AGENTS_STR.split(',') if p.strip()]

# TLS Chunking Limit (Let's Encrypt max is 100)
TRAEFIK_TLS_BATCH_SIZE = int(os.getenv('TRAEFIK_TLS_BATCH_SIZE', 30))

# CrowdSec & Traefik Settings (with defaults)
try:
    CS_UPDATE_INTERVAL = int(os.getenv('CROWDSEC_UPDATE_INTERVAL', 60))
    T_ACTIVE = int(os.getenv('TRAEFIK_TIMEOUT_ACTIVE', 60))
    T_IDLE = int(os.getenv('TRAEFIK_TIMEOUT_IDLE', 90))
    G_RATE_AVG = int(os.getenv('TRAEFIK_GLOBAL_RATE_AVG', 60))
    G_RATE_BURST = int(os.getenv('TRAEFIK_GLOBAL_RATE_BURST', 120))
    G_CONCURRENCY = int(os.getenv('TRAEFIK_GLOBAL_CONCURRENCY', 25))
    HSTS_SECONDS = int(os.getenv('TRAEFIK_HSTS_MAX_AGE', 31536000))
except ValueError:
    # Fallback defaults if parsing fails
    CS_UPDATE_INTERVAL = 60
    T_ACTIVE = 60
    T_IDLE = 90
    G_RATE_AVG = 60
    G_RATE_BURST = 120
    G_CONCURRENCY = 25
    HSTS_SECONDS = 31536000

# Regex for validating Docker/Traefik service names
VALID_SERVICE_NAME_REGEX = re.compile(r'^[a-z0-9-]+$')

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

if CROWDSEC_ENABLE and not CROWDSEC_LAPI_KEY:
    print("    ❌ FATAL ERROR: CROWDSEC_LAPI_KEY environment variable not found.")
    exit(1)

if not REDIS_PASSWORD:
    print("    ❌ FATAL ERROR: REDIS_PASSWORD environment variable not found.")
    exit(1)

# =============================================================================
# HELPER CLASSES & FUNCTIONS
# =============================================================================

# Custom Dumper to avoid excessive indentation
class IndentDumper(yaml.Dumper):
    def increase_indent(self, flow=False, indentless=False):
        return super(IndentDumper, self).increase_indent(flow, False)

# Extract root domains
def get_root_domain(domain):
    extracted = tldextract.extract(domain)
    if extracted.suffix:
        return f"{extracted.domain}.{extracted.suffix}"
    return domain

def sanitize_name(name):
    return name.replace('.', '-').replace('_', '-').lower()

def atomic_write_yaml(data, filepath, header=None):
    # Prepare new content in memory
    import io
    import tempfile
    
    stream = io.StringIO()
    if header:
        stream.write(f"{header}\n")
    yaml.dump(data, stream, Dumper=IndentDumper, default_flow_style=False, sort_keys=False)
    new_content = stream.getvalue()

    # Check if file already exists and has identical content
    if os.path.exists(filepath):
        # We read the existing file to avoid unnecessary mtime updates
        try:
            with open(filepath, 'r') as f:
                if f.read() == new_content:
                    # No changes, do not touch the file (preserves mtime and doesn't trigger inotify)
                    return
        except Exception:
            pass # If reading fails (e.g. corruption), proceed to overwrite

    # Perform a TRULY atomic write: 
    # 1. Write to a temporary file in the same directory
    # 2. Sync to disk (optional but safer)
    # 3. Use os.replace to swap it instantly (atomic operation on most filesystems)
    
    target_dir = os.path.dirname(filepath)
    if target_dir:
        os.makedirs(target_dir, exist_ok=True)
    
    # Create temp file in the same directory to ensure it's on the same partition
    fd, temp_path = tempfile.mkstemp(dir=target_dir or ".", text=True)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(new_content)
        
        # Enforce read permissions for all (0o644) so Traefik (non-root) can read it
        os.chmod(temp_path, 0o644)
        
        # Atomic replacement
        try:
            os.replace(temp_path, filepath)
        except OSError as e:
            import errno
            if e.errno == errno.EBUSY:
                # Fallback to non-atomic write if target is a bind mount
                with open(filepath, 'w') as f_out:
                    f_out.write(new_content)
                os.remove(temp_path)
            else:
                raise
    except Exception as e:
        # Cleanup temp file on failure
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass
        print(f"    ❌ Error writing to {filepath}: {e}")
        # We don't raise so the script can continue with other files

# Unifies SSL/TLS configuration for any router
def apply_tls_config(router_conf, domain, domain_to_cert_def):
    # Only use Let's Encrypt if NOT in local dev mode
    if not IS_LOCAL_DEV:
        router_conf['tls']['certResolver'] = TRAEFIK_CERT_RESOLVER
        
        # Inject TLS domains if specific batch exists
        if domain in domain_to_cert_def:
            router_conf['tls']['domains'] = [domain_to_cert_def[domain]]
    else:
        # Defaults for local dev (self-signed)
        router_conf['tls'] = {}

def process_router(entry, http_section, domain_to_cert_def):
    domain = entry['domain']
    service = entry['service']
    anubis_sub = entry['anubis_sub']
    extra = entry['extra']
    root = entry['root']

    safe_domain = sanitize_name(domain)
    router_name = f"router-{safe_domain}"

    mw_list = []
    if CROWDSEC_ENABLE:
        if root in captcha_registry:
            safe_root = sanitize_name(root)
            mw_list.append(f"crowdsec-check-{safe_root}")
        else:
            mw_list.append('crowdsec-check')
    
    # Protecting against Slowloris ASAP
    mw_list.append('global-buffering')
    
    mw_list.append('security-headers')

    if 'rate' in extra or 'burst' in extra:
        custom_rl_name = f"rl-{safe_domain}"
        avg = extra.get('rate', G_RATE_AVG)
        burst = extra.get('burst', G_RATE_BURST)
        http_section['middlewares'][custom_rl_name] = {
            'rateLimit': {'average': avg, 'burst': burst}
        }
        mw_list.append(custom_rl_name)
    else:
        mw_list.append('global-ratelimit')

    if 'concurrency' in extra:
        custom_conc_name = f"conc-{safe_domain}"
        http_section['middlewares'][custom_conc_name] = {
            'inFlightReq': {'amount': extra['concurrency']}
        }
        mw_list.append(custom_conc_name)
    else:
        mw_list.append('global-concurrency')

    if anubis_sub:
        safe_root = sanitize_name(root)
        safe_auth = sanitize_name(anubis_sub)
        mw_auth_name = f"anubis-mw-{safe_root}-{safe_auth}"
        mw_list.append(mw_auth_name)

    # Compression and Protocol headers last
    mw_list.append('global-compress')

    # -------------------------------------------------------------------------
    # Redirection Middleware
    # -------------------------------------------------------------------------
    redirection = entry.get('redirection')
    if redirection:
        redirect_mw_name = f"redirect-{safe_domain}"
        
        # Normalize target to have protocol
        target = redirection
        if not target.startswith("http"):
            target = f"https://{target}"
            
        escaped_domain = re.escape(domain)
        http_section['middlewares'][redirect_mw_name] = {
            'redirectRegex': {
                'regex': f"^https?://{escaped_domain}/(.*)",
                'replacement': f"{target}/${{1}}",
                'permanent': True
            }
        }
        mw_list.append(redirect_mw_name)

    if service == 'apache-host':
        mw_list.append('apache-forward-headers')
        target_service = APACHE_SVC_NAME
    else:
        target_service = f"{service}@docker"

    # Router config
    router_conf = {
        'rule': f"Host(`{domain}`)",
        'entryPoints': ["websecure"],
        'service': target_service,
        'tls': {}, 
        'middlewares': mw_list
    }
    
    # Apply SSL/TLS settings
    apply_tls_config(router_conf, domain, domain_to_cert_def)

    # -------------------------------------------------------------------------
    # 1. Bypass Router (Good User Agents - No CrowdSec) - Priority 15000
    # -------------------------------------------------------------------------
    if GOOD_USER_AGENTS:
        bypass_router_name = f"good-user-agents-{safe_domain}"
        
        # Create a copy of the middleware list MINUS crowdsec-check (including any root-domain specific ones)
        bypass_mw_list = [mw for mw in mw_list if not mw.startswith('crowdsec-check')]
        
        allowed_ua_rule = " || ".join([f"HeaderRegexp(`User-Agent`, `{p}`)" for p in GOOD_USER_AGENTS])
        
        bypass_conf = {
            'rule': f"Host(`{domain}`) && ({allowed_ua_rule})",
            'entryPoints': ["websecure"],
            'service': target_service,
            'priority': 15000, 
            'tls': router_conf['tls'], # Reuse TLS config
            'middlewares': bypass_mw_list
        }
        http_section['routers'][bypass_router_name] = bypass_conf

    # -------------------------------------------------------------------------
    # 2. User-Agent Blocking Router (Per-Domain) - Priority 12000
    # -------------------------------------------------------------------------
    if BAD_USER_AGENTS:
        ua_block_router_name = f"bad-user-agents-{safe_domain}"
        # Match any of the regex patterns in the User-Agent header
        ua_rules = " || ".join([f"HeaderRegexp(`User-Agent`, `{p}`)" for p in BAD_USER_AGENTS])
        
        final_ua_rule = f"({ua_rules})"
        if GOOD_USER_AGENTS:
            allowed_ua_rules = " || ".join([f"HeaderRegexp(`User-Agent`, `{p}`)" for p in GOOD_USER_AGENTS])
            final_ua_rule = f"({ua_rules}) && !({allowed_ua_rules})"

        http_section['routers'][ua_block_router_name] = {
            'rule': f"Host(`{domain}`) && {final_ua_rule}",
            'entryPoints': ["websecure"],
            'service': "api@internal",
            'priority': 12000, 
            'tls': router_conf['tls'],
            'middlewares': ["block-unwanted-user-agents"]
        }

    # -------------------------------------------------------------------------
    # 3. Path Blocking Router (Per-Domain) - Priority 11000
    # -------------------------------------------------------------------------
    # Creates a higher priority router to intercept blocked paths
    if BLOCKED_PATHS:
        path_block_router_name = f"path-blocker-{safe_domain}"
        paths_rule = " || ".join([f"PathRegexp(`.*{p}.*`)" for p in BLOCKED_PATHS])
        http_section['routers'][path_block_router_name] = {
            'rule': f"Host(`{domain}`) && ({paths_rule})",
            'entryPoints': ["websecure"],
            'service': "api@internal",
            'priority': 11000,
            'tls': router_conf['tls'],
            'middlewares': ["block-unwanted-paths"]
        }
        
    # -------------------------------------------------------------------------
    # 4. Main Router (Standard Processing) - Default Priority
    # -------------------------------------------------------------------------
    http_section['routers'][router_name] = router_conf

# =============================================================================
# MAIN LOGIC
# =============================================================================

def generate_configs():
    if not os.path.exists(INPUT_FILE):
        print(f"    ❌ FATAL ERROR: {INPUT_FILE} not found.")
        sys.exit(1)

    raw_entries = []
    error_count = 0
    stats = {'standard': 0, 'anubis': 0, 'apache': 0}

    print(f"   📂 Processing {INPUT_FILE}...")
    try:
        with open(INPUT_FILE, 'r') as f:
            # Use DictReader to handle headers more robustly
            # We first peek to skip comments and detect headers
            lines = [line for line in f if line.strip() and not line.strip().startswith('#')]
            if not lines:
                print("    ℹ️ No valid entries found (domains.csv is empty or comments only).")
            else:
                # Use csv.reader but manually handle indices for flexibility
                reader = csv.reader(lines, skipinitialspace=True)
                for line_num, row in enumerate(reader, 1):
                    # Clean the row
                    row = [col.strip() for col in row]
                    
                    if not row: continue

                    if len(row) < 3:
                        print(f"    ⚠️ Line {line_num}: Ignored (Missing mandatory columns: domain, redirection/blank, service).")
                        error_count += 1
                        continue

                    domain = row[0]
                    redirection = row[1] if row[1] else ""
                    service = row[2].lower() 
                    anubis_sub = row[3].lower() if len(row) > 3 else ""

                    if not domain:
                        print(f"    ⚠️ Line {line_num}: Ignored (Empty domain field).")
                        error_count += 1
                        continue

                    # Skip header row if it's not a real domain
                    if domain.lower() == 'domain' and service.lower() == 'service':
                        continue

                    # --- Robustness Check: Docker Service Name Format ---
                    if service != 'apache-host' and not VALID_SERVICE_NAME_REGEX.match(service):
                        print(f"    ❌ Line {line_num}: Error - Service name '{service}' invalid. Use only a-z, 0-9 and hyphens.")
                        error_count += 1
                        continue

                    extra = {}
                    def get_int(idx):
                        if len(row) > idx and row[idx]:
                            try: return int(row[idx])
                            except ValueError: return None
                        return None

                    rate = get_int(4)
                    if rate: extra['rate'] = rate
                    burst = get_int(5)
                    if burst: extra['burst'] = burst
                    concurrency = get_int(6)
                    if concurrency: extra['concurrency'] = concurrency

                    raw_entries.append({
                        'domain': domain,
                        'redirection': redirection,
                        'service': service,
                        'anubis_sub': anubis_sub,
                        'extra': extra,
                        'root': get_root_domain(domain)
                    })

                    # Stats tracking
                    if service == 'apache-host': stats['apache'] += 1
                    elif anubis_sub: stats['anubis'] += 1
                    else: stats['standard'] += 1

    except Exception as e:
        print(f"    ❌ Error reading CSV: {e}")
        return

    # -------------------------------------------------------------------------
    # Synthetic Dashboard Entry
    # -------------------------------------------------------------------------
    DASHBOARD_SUBDOMAIN = os.getenv('DASHBOARD_SUBDOMAIN', 'dashboard')
    DOMAIN = os.getenv('DOMAIN', 'mydomain.com')
    dashboard_domain = f"{DASHBOARD_SUBDOMAIN}.{DOMAIN}"
    
    dashboard_anubis_sub = os.getenv('DASHBOARD_ANUBIS_SUBDOMAIN', '').strip().lower()
    
    # Look for any existing entry for the dashboard service to migrate it in-memory if needed
    dashboard_csv_entry = None
    for entry in raw_entries:
        if entry['service'] == 'dashboard':
            dashboard_csv_entry = entry
            break

    if dashboard_csv_entry:
        if dashboard_csv_entry['domain'].lower() != dashboard_domain.lower():
            print(f"   🔄 Auto-migrating dashboard domain in config from '{dashboard_csv_entry['domain']}' to '{dashboard_domain}'")
            dashboard_csv_entry['domain'] = dashboard_domain
            dashboard_csv_entry['root'] = get_root_domain(dashboard_domain)
    else:
        # Fallback synthetic entry if no dashboard service exists in CSV
        dashboard_entry = {
            'domain': dashboard_domain,
            'redirection': '',
            'service': 'dashboard',
            'anubis_sub': dashboard_anubis_sub,
            'extra': {},
            'root': get_root_domain(dashboard_domain)
        }
        raw_entries.append(dashboard_entry)
        
        if dashboard_anubis_sub:
            stats['anubis'] += 1
        else:
            stats['standard'] += 1

        # Automatically append the missing dashboard entry to domains.csv physically so it is persisted
        try:
            with open(INPUT_FILE, 'a', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                writer.writerow([
                    dashboard_domain,
                    '',
                    'dashboard',
                    dashboard_anubis_sub,
                    '',
                    '',
                    ''
                ])
            print(f"   📝 Automatically added missing dashboard entry to {INPUT_FILE}: {dashboard_domain} (Anubis: {dashboard_anubis_sub or 'None'})")
        except Exception as e:
            print(f"   ⚠️ Warning: Could not automatically write dashboard entry to {INPUT_FILE}: {e}")



    if raw_entries:
        print(f"   ✅ Successfully processed {len(raw_entries)} domains:")
        if stats['standard'] > 0: print(f"      ➜ {stats['standard']} Standard Traefik proxies")
        if stats['anubis'] > 0:   print(f"      ➜ {stats['anubis']} Anubis protected instances")
        if stats['apache'] > 0:   print(f"      ➜ {stats['apache']} Apache legacy hosts")
    
    if error_count > 0:
        print(f"    ⚠️ Total: {error_count} lines skipped due to errors.")

    print(f"   ⚙️ Traefik Global Config: Rate={G_RATE_AVG}/{G_RATE_BURST}, HSTS={HSTS_SECONDS}s")

    if GOOD_USER_AGENTS:
        print(f"   😇 Good User-Agents Whitelisted: {len(GOOD_USER_AGENTS)}")

    if BAD_USER_AGENTS:
        print(f"   🚫 Bad User-Agents Blacklisted: {len(BAD_USER_AGENTS)}")

    services = {}

    # -------------------------------------------------------------------------
    # Traefik Dynamic Configuration (HTTP & TLS)
    # -------------------------------------------------------------------------
    traefik_dynamic_conf = {
        'http': {
            # Timeouts for legacy backends
            'serversTransports': {
                'legacy-transport': {
                    'forwardingTimeouts': {
                        'responseHeaderTimeout': f"{T_ACTIVE}s", # Wait T_ACTIVE (default 60s) for the first byte
                        'idleConnTimeout': f"{T_IDLE}s"          # Keep idle connection a bit longer (default 90s)
                    }
                }
            },
            'middlewares': {
                # --- The Golden Chain (Execution Order) ---
                
                # 2. DDoS Protection: Buffering (Protects against Slowloris)
                'global-buffering': {
                    'buffering': {
                        'maxRequestBodyBytes': 0, # No limit for body (handled by other layers)
                        'memRequestBodyBytes': 2097152, # 2MB in memory
                        'maxResponseBodyBytes': 0,
                        'memResponseBodyBytes': 2097152 # 2MB in memory
                    }
                },
                # 3. Browser Security (Headers)
                'security-headers': {
                    'headers': {
                        'frameDeny': not bool(FRAME_ANCESTORS),
                        'browserXssFilter': True,
                        'contentTypeNosniff': True,
                        'stsIncludeSubdomains': True,
                        'stsPreload': True,
                        'stsSeconds': HSTS_SECONDS,
                        'customFrameOptionsValue': 'SAMEORIGIN' if not FRAME_ANCESTORS else '',
                        **(({'contentSecurityPolicy': f"frame-ancestors 'self' {FRAME_ANCESTORS.replace(',', ' ')}"}) if FRAME_ANCESTORS else {})
                    }
                },
                # 4. Traefik Rate Limit
                'global-ratelimit': {
                    'rateLimit': {
                        'average': G_RATE_AVG,
                        'burst': G_RATE_BURST
                    }
                },
                # 5. Traefik Concurrency
                'global-concurrency': {
                    'inFlightReq': {'amount': G_CONCURRENCY}
                },
                # 7. Global Compression (Applied late)
                'global-compress': {
                    'compress': {'minResponseBodyBytes': 1024}
                },
                # 9. Protocol Forwarder (For legacy Apache)
                'apache-forward-headers': {
                    'headers': {
                        'customRequestHeaders': {
                            'X-Forwarded-Proto': 'https'
                        }
                    }
                },

                # --- Specialized Helper Middlewares ---

                # 6. Anubis Assets Stripper
                'anubis-assets-stripper': {
                    'stripPrefix': {
                        'prefixes': ['/.within.website/x/cmd/anubis']
                    }
                },
                # 8. Anubis CSS Replacement
                'anubis-css-replace': {
                    'replacePath': {
                        'path': '/custom.min.css'
                    }
                },
                # 10. Anubis Assets Caching Headers
                'anubis-assets-headers': {
                    'headers': {
                        'customResponseHeaders': {
                            'Cache-Control': 'public, max-age=31536000, immutable'
                        }
                    }
                },
                # 11. Anubis Main Page Preload Link Headers
                'anubis-preload-headers': {
                    'headers': {
                        'customResponseHeaders': {
                            'Link': '</.within.website/x/xess/xess.min.css>; rel=preload; as=style, </.within.website/x/cmd/anubis/static/img/pensive.webp>; rel=preload; as=image'
                        }
                    }
                },
            },
            'routers': {},
            'services': {
                # 1. External Backend Service (Host Apache — configurable via APACHE_HOST_IP / APACHE_HOST_PORT)
                APACHE_SVC_NAME: {
                    'loadBalancer': {
                        'serversTransport': 'legacy-transport',
                        'servers': [{'url': f'http://{APACHE_HOST_IP}:{APACHE_HOST_PORT}'}],
                        'passHostHeader': True
                    }
                }
            }
        }
    }



    # 1. CrowdSec API Check Plugin (The very first line of defense)
    if CROWDSEC_ENABLE:
        # Base config for any CrowdSec middleware
        base_crowdsec_config = {
            'enabled': True,
            'crowdsecLapiScheme': 'http',
            'crowdsecLapiHost': 'crowdsec:8080',
            'crowdsecLapiKey': CROWDSEC_LAPI_KEY,
            'crowdsecMode': 'stream',
            # AppSec (WAF) — controlled by CROWDSEC_APPSEC_ENABLE
            'crowdsecAppsecEnabled': CROWDSEC_APPSEC_ENABLE,
            'crowdsecAppsecHost': 'crowdsec:7422',
            'crowdsecAppsecFailureBlock': False,
            'crowdsecAppsecUnreachableBlock': False,
            'updateIntervalSeconds': CS_UPDATE_INTERVAL,
            # Fail-open behavior: never block traffic if LAPI or Redis are unreachable/down
            'updateMaxFailure': -1,
            'redisCacheUnreachableBlock': False,
            # Redis Caching (highly recommended for high traffic)
            # We use the existing Redis service (Valkey) as backend
            'redisCacheEnabled': True,
            'redisCacheHost': 'redis:6379',
            'redisCachePassword': REDIS_PASSWORD,
            'redisCacheDatabase': "0",
            'forwardedHeadersTrustedIPs': TRUSTED_IPS,
            # Immediate Whitelist (Client IP)
            # These IPs bypass LAPI stream checks entirely (no blocklist lookup).
            'clientTrustedIPs': TRUSTED_IPS,
            # AppSec Whitelist (L7)
            # These IPs bypass AppSec inspection entirely.
            'crowdsecAppsecTrustedIPs': TRUSTED_IPS
        }

        # Default middleware (No CAPTCHA keys, outright ban/block fallback)
        traefik_dynamic_conf['http']['middlewares']['crowdsec-check'] = {
            'plugin': {
                'crowdsec': base_crowdsec_config.copy()
            }
        }

        # Generate domain-specific middlewares with CAPTCHA keys
        for root_dom, captcha_info in captcha_registry.items():
            safe_root = sanitize_name(root_dom)
            mw_name = f"crowdsec-check-{safe_root}"
            
            domain_config = base_crowdsec_config.copy()
            domain_config.update({
                'captchaProvider': captcha_info['provider'],
                'captchaSiteKey': captcha_info['site_key'],
                'captchaSecretKey': captcha_info['secret_key'],
                'captchaGracePeriodSeconds': CROWDSEC_CAPTCHA_GRACE_PERIOD,
                'captchaHTMLFilePath': '/captcha.html',
            })
            
            traefik_dynamic_conf['http']['middlewares'][mw_name] = {
                'plugin': {
                    'crowdsec': domain_config
                }
            }

    # Blocked Paths Middleware (Conditional)
    if BLOCKED_PATHS:
        traefik_dynamic_conf['http']['middlewares']['block-unwanted-paths'] = {
            'ipAllowList': {
                'sourceRange': ['127.0.0.1/32']
            }
        }

    # Blocked User Agents Middleware (Conditional)
    if BAD_USER_AGENTS:
        traefik_dynamic_conf['http']['middlewares']['block-unwanted-user-agents'] = {
            'ipAllowList': {
                'sourceRange': ['127.0.0.1/32'] # Reject everyone (except technically localhost if it hit this router)
            }
        }

    # -------------------------------------------------------------------------
    # TLS Grouping Logic (SAN / Chunking) - SKIPPED IN LOCAL DEV
    # -------------------------------------------------------------------------
    domain_to_cert_def = {}
    tls_configs = []

    if not IS_LOCAL_DEV:
        # 1. Group all domains by their root
        domains_by_root = defaultdict(list)
        for entry in raw_entries:
            domains_by_root[entry['root']].append(entry['domain'])

            if entry['anubis_sub']:
                full_anubis_url = f"{entry['anubis_sub']}.{entry['root']}"
                domains_by_root[entry['root']].append(full_anubis_url)

        # 2. Generate the chunked 'tls.domains' configuration
        for root_domain, subdomains in domains_by_root.items():
            # Deduplicate preserving order (Python 3.7+ dicts preserve insertion order)
            subs_unicos = list(dict.fromkeys(subdomains))
            
            # Chunking loop in batches of TRAEFIK_TLS_BATCH_SIZE
            for i in range(0, len(subs_unicos), TRAEFIK_TLS_BATCH_SIZE):
                batch = subs_unicos[i:i + TRAEFIK_TLS_BATCH_SIZE]
                
                # The first one is Main, the rest are SANs
                cert_def = {"main": batch[0]}
                if len(batch) > 1:
                    cert_def["sans"] = batch[1:]
                
                tls_configs.append(cert_def)

        print(f"   🔐 Processing certificate batches (Batch Size: {TRAEFIK_TLS_BATCH_SIZE})...")
        for idx, batch in enumerate(tls_configs, 1):
            domains_in_batch = [batch['main']] + batch.get('sans', [])
            san_count = len(batch.get('sans', []))
            
            # Get the root domain for this batch to show in logs
            batch_root = get_root_domain(batch['main'])
            
            if san_count > 0:
                print(f"      🔐 Batch #{idx} [{batch_root}]: {batch['main']} (+{san_count} SANs)")
            else:
                print(f"      🔐 Batch #{idx} [{batch_root}]: {batch['main']}")
                
            for d in domains_in_batch:
                domain_to_cert_def[d] = batch
                
        print(f"   ✅ TLS Config: Generated {len(tls_configs)} certificates.")
    else:
        print("   🏠 Local Dev Mode: Skipping TLS grouping.")

    protected_groups = {}
    anubis_service_names = set() 

    for entry in raw_entries:
        if entry['anubis_sub']:
            key = (entry['root'], entry['anubis_sub'])
            if key not in protected_groups:
                protected_groups[key] = []
            protected_groups[key].append(entry)

        # Pass the reference to the HTTP section of the config AND the cert map
        process_router(entry, traefik_dynamic_conf['http'], domain_to_cert_def)

    # -------------------------------------------------------------------------
    # API & Dozzle Routers (Conditionally Generated inheriting Dashboard security)
    # -------------------------------------------------------------------------
    # Retrieve the base middleware chain generated for the dashboard by process_router
    safe_dash_domain = sanitize_name(dashboard_domain)
    base_router_name = f"router-{safe_dash_domain}"
    
    # We copy the base middlewares that contain crowdsec, anubis, etc.
    base_middlewares = traefik_dynamic_conf['http']['routers'][base_router_name]['middlewares'].copy()
    sso_middlewares = ["dashboard-error@docker", "dashboard-auth@docker"]
    
    # --- Traefik API Router ---
    api_mw = base_middlewares.copy()
    # Insert SSO and strip middlewares right before global-compress (which is the last one)
    for mw in ["traefik-strip"] + sso_middlewares:
        api_mw.insert(-1, mw)
        
    traefik_dynamic_conf['http']['routers']['traefik-dashboard'] = {
        'rule': f"Host(`{dashboard_domain}`) && (PathPrefix(`/traefik`) || PathPrefix(`/api`) || PathPrefix(`/dashboard`))",
        'entryPoints': ["websecure"],
        'service': "api@internal",
        'priority': 100,
        'tls': traefik_dynamic_conf['http']['routers'][base_router_name]['tls'],
        'middlewares': api_mw
    }

    traefik_dynamic_conf['http']['middlewares']['traefik-strip'] = {
        'stripPrefix': {
            'prefixes': ['/traefik']
        }
    }
    
    # --- Dozzle Router ---
    dozzle_mw = base_middlewares.copy()
    if 'global-compress' in dozzle_mw:
        dozzle_mw.remove('global-compress')
    if 'global-buffering' in dozzle_mw:
        dozzle_mw.remove('global-buffering')
    dozzle_mw.extend(sso_middlewares)
        
    traefik_dynamic_conf['http']['routers']['traefik-dozzle'] = {
        'rule': f"Host(`{dashboard_domain}`) && PathPrefix(`/dozzle`)",
        'entryPoints': ["websecure"],
        'service': "dozzle@docker",
        'priority': 100,
        'tls': traefik_dynamic_conf['http']['routers'][base_router_name]['tls'],
        'middlewares': dozzle_mw
    }

    # --- Grafana Router ---
    grafana_mw = base_middlewares.copy()
    for mw in sso_middlewares:
        grafana_mw.insert(-1, mw)

    traefik_dynamic_conf['http']['routers']['grafana-frontend'] = {
        'rule': f"Host(`{dashboard_domain}`) && PathPrefix(`/grafana`)",
        'entryPoints': ["websecure"],
        'service': "grafana-frontend@docker",
        'priority': 100,
        'tls': traefik_dynamic_conf['http']['routers'][base_router_name]['tls'],
        'middlewares': grafana_mw
    }

    # --- CrowdSec Web UI Router (only when CrowdSec is enabled) ---
    if CROWDSEC_ENABLE:
        cswebui_mw = base_middlewares.copy()
        for mw in sso_middlewares:
            cswebui_mw.insert(-1, mw)

        traefik_dynamic_conf['http']['routers']['crowdsec-web-ui'] = {
            'rule': f"Host(`{dashboard_domain}`) && PathPrefix(`/crowdsec`)",
            'entryPoints': ["websecure"],
            'service': "crowdsec-web-ui@docker",
            'priority': 100,
            'tls': traefik_dynamic_conf['http']['routers'][base_router_name]['tls'],
            'middlewares': cswebui_mw
        }

    # --- Backrest Router (only when BACKREST_ENABLE=true) ---
    if BACKREST_ENABLE:
        # Pattern: same as other SSO-protected sub-routes.
        # Insert redirect + SSO middlewares before the last entry (global-compress),
        # then add the strip prefix after SSO so the backend receives paths without /backrest.
        backrest_mw = base_middlewares.copy()
        if 'global-buffering' in backrest_mw:
            backrest_mw.remove('global-buffering')
        for mw in ['backrest-redirect'] + sso_middlewares + ['backrest-strip']:
            backrest_mw.insert(-1, mw)

        traefik_dynamic_conf['http']['routers']['backrest-frontend'] = {
            'rule': f"Host(`{dashboard_domain}`) && PathPrefix(`/backrest`)",
            'entryPoints': ["websecure"],
            'service': "backrest@docker",
            'priority': 100,
            'tls': traefik_dynamic_conf['http']['routers'][base_router_name]['tls'],
            'middlewares': backrest_mw
        }

        traefik_dynamic_conf['http']['middlewares']['backrest-redirect'] = {
            'redirectRegex': {
                'regex': '^https?://([^/]+)/backrest$',
                'replacement': 'https://${1}/backrest/',
                'permanent': True
            }
        }

        traefik_dynamic_conf['http']['middlewares']['backrest-strip'] = {
            'stripPrefix': {
                'prefixes': ['/backrest']
            }
        }

    # -------------------------------------------------------------------------
    # Anubis Services & Routers Generation
    # -------------------------------------------------------------------------
    for (root, auth_sub), entries in protected_groups.items():
        safe_root = sanitize_name(root)
        safe_auth = sanitize_name(auth_sub)

        anubis_service_name = f"anubis-{safe_root}-{safe_auth}"
        anubis_service_names.add(anubis_service_name)

        all_subdomains = [e['domain'] for e in entries]
        redirect_domains_str = ",".join(all_subdomains)
        auth_domain = f"{auth_sub}.{root}"
        public_url = f"https://{auth_domain}"

        services[anubis_service_name] = {
            'extends': {
                'file': BASE_FILENAME,
                'service': 'anubis-base'
            },
            'environment': [
                f"PUBLIC_URL={public_url}",
                f"REDIRECT_DOMAINS={redirect_domains_str}",
                f"COOKIE_PREFIX={safe_root}"
            ],
            'labels': [
                "traefik.enable=true",
                "traefik.docker.network=traefik",
                f"traefik.http.services.{anubis_service_name}.loadbalancer.server.port=8080"
            ],
            'networks': [
                "traefik",
                "anubis-backend"
            ]
        }

        # Middleware for Anubis
        mw_auth_name = f"anubis-mw-{safe_root}-{safe_auth}"
        traefik_dynamic_conf['http']['middlewares'][mw_auth_name] = {
            'forwardAuth': {
                'address': f"http://{anubis_service_name}:8080/.within.website/x/cmd/anubis/api/check",
                'trustForwardHeader': True,
                'authResponseHeaders': ["X-Anubis-Ray-Id"],
                'maxResponseBodySize': 1048576  # 1MB – Anubis challenge HTML is always small
            }
        }

        # 1. Anubis: Router for Images
        assets_router_name = f"anubis-assets-img-{safe_root}-{safe_auth}"
        traefik_dynamic_conf['http']['routers'][assets_router_name] = {
            'rule': f"Host(`{auth_sub}.{root}`) && (Path(`/.within.website/x/cmd/anubis/static/img/pensive.webp`) || Path(`/.within.website/x/cmd/anubis/static/img/reject.webp`))",
            'entryPoints': ["websecure"],
            'service': "anubis-assets@docker", 
            'priority': 2000, 
            'tls': {},
            'middlewares': ["security-headers", "anubis-assets-stripper", "anubis-assets-headers", "global-compress"]
        }
        apply_tls_config(traefik_dynamic_conf['http']['routers'][assets_router_name], auth_domain, domain_to_cert_def)

        # 2. Anubis: Router for CSS
        css_router_name = f"anubis-assets-css-{safe_root}-{safe_auth}"
        traefik_dynamic_conf['http']['routers'][css_router_name] = {
            'rule': f"Host(`{auth_sub}.{root}`) && Path(`/.within.website/x/xess/xess.min.css`)",
            'entryPoints': ["websecure"],
            'service': "anubis-assets@docker", 
            'priority': 2000, 
            'tls': {},
            'middlewares': ["security-headers", "anubis-css-replace", "anubis-assets-headers", "global-compress"]
        }
        apply_tls_config(traefik_dynamic_conf['http']['routers'][css_router_name], auth_domain, domain_to_cert_def)

        # 3. Anubis: Main Router
        panel_router_name = f"anubis-panel-{safe_root}-{safe_auth}"
        traefik_dynamic_conf['http']['routers'][panel_router_name] = {
            'rule': f"Host(`{auth_sub}.{root}`)",
            'entryPoints': ["websecure"],
            'service': f"{anubis_service_name}@docker",
            'tls': {}, 
            'middlewares': ["security-headers", "anubis-preload-headers"]
        }
        apply_tls_config(traefik_dynamic_conf['http']['routers'][panel_router_name], auth_domain, domain_to_cert_def)

    if services:
        compose_yaml = { 
            'services': services,
            'networks': {
                'traefik': {'name': 'traefik', 'external': True},
                'anubis-backend': {'external': True}
            }
        }
        atomic_write_yaml(compose_yaml, OUTPUT_COMPOSE, "# AUTOMATICALLY GENERATED BY PYTHON")
        print(f"   ✅ Docker Compose: Generated {len(services)} Anubis instances.")
    else:
        compose_yaml = { 
            'services': {},
            'networks': {
                'traefik': {'name': 'traefik', 'external': True},
                'anubis-backend': {'external': True}
            }
        }
        atomic_write_yaml(compose_yaml, OUTPUT_COMPOSE, "# AUTOMATICALLY GENERATED - NO ANUBIS INSTANCES")
        print("   ℹ️ Docker Compose: No Anubis instances needed.")

    os.makedirs(os.path.dirname(OUTPUT_TRAEFIK), exist_ok=True)
    atomic_write_yaml(traefik_dynamic_conf, OUTPUT_TRAEFIK, "# AUTOMATICALLY GENERATED BY PYTHON")

    print("   ✅ Traefik: Dynamic configuration generated.")

def generate_policy_file():
    input_policy = 'config/anubis/botPolicy.yaml'
    output_policy = 'config/anubis/botPolicy-generated.yaml'

    if not os.path.exists(input_policy):
        print(f"   ⚠️ WARN: {input_policy} not found, skipping policy generation.")
        return

    print(f"   🛡  Anubis: Generating security policy...")

    try:
        with open(input_policy, 'r') as f:
            policy_data = yaml.safe_load(f)

        if REDIS_PASSWORD:
            policy_data['store']['parameters']['url'] = f"redis://:{REDIS_PASSWORD}@redis:6379/1"
        else:
            print("   ⚠️ WARN: REDIS_PASSWORD not set. Redis will be exposed.")
            policy_data['store']['parameters']['url'] = "redis://redis:6379/1"

        atomic_write_yaml(policy_data, output_policy, "# AUTOMATICALLY GENERATED - DO NOT EDIT")

    except Exception as e:
        print(f"   ❌ Error generating policy: {e}")

def generate_minified_css():
    import tempfile
    assets_dir = 'config/anubis/assets'
    css_path = os.path.join(assets_dir, 'custom.css')
    css_dist_path = os.path.join(assets_dir, 'custom.css.dist')
    min_css_path = os.path.join(assets_dir, 'custom.min.css')

    # Read from custom.css if exists, else from custom.css.dist
    src_path = None
    if os.path.exists(css_path):
        src_path = css_path
    elif os.path.exists(css_dist_path):
        src_path = css_dist_path
    
    if not src_path:
        print("   ⚠️  Anubis: Neither custom.css nor custom.css.dist was found. Skipping minification.")
        return

    try:
        with open(src_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Simple CSS Minification regex
        # 1. Remove comments
        minified = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
        # 2. Remove whitespace around delimiters ({ } : ; ,)
        minified = re.sub(r'\s*([\{\}:;,])\s*', r'\1', minified)
        # 3. Collapse multiple whitespace chars to single space
        minified = re.sub(r'\s+', ' ', minified)
        # 4. Trim
        minified = minified.strip()

        # Atomic write
        temp_fd, temp_path = tempfile.mkstemp(dir=assets_dir, text=True)
        try:
            with os.fdopen(temp_fd, 'w', encoding='utf-8') as f:
                f.write(minified)
            os.chmod(temp_path, 0o644)
            os.replace(temp_path, min_css_path)
            orig_size = os.path.getsize(src_path)
            min_size = len(minified.encode('utf-8'))
            reduction = ((orig_size - min_size) / orig_size) * 100
            print(f"   ⚡ Anubis CSS Minified: {orig_size} B ➜ {min_size} B (-{reduction:.1f}%) saved to custom.min.css")
        except Exception as e:
            if os.path.exists(temp_path):
                os.remove(temp_path)
            raise e

    except Exception as e:
        print(f"   ❌ Anubis: Error minifying CSS: {e}")

if __name__ == "__main__":
    generate_configs()
    generate_minified_css()
    generate_policy_file()