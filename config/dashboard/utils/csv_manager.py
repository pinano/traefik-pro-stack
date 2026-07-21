import os
import csv
import re
import tempfile
import tldextract
import logging
from config import DOMAINS_CSV_PATH, CAPTCHA_CSV_PATH

log = logging.getLogger(__name__)

# CAPTCHA keys validation patterns
TURNSTILE_SITE_KEY_RE = re.compile(r'^(0x4|[123]x)[A-Za-z0-9-_]{15,30}$')
TURNSTILE_SECRET_KEY_RE = re.compile(r'^(0x4|[123]x)[A-Za-z0-9-_]{30,50}$')

HCAPTCHA_SITE_KEY_RE = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
HCAPTCHA_SECRET_KEY_RE = re.compile(r'^(0x[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')

RECAPTCHA_KEY_RE = re.compile(r'^[A-Za-z0-9-_]{35,50}$')

def validate_domain_data(entry):
    domain_pattern = re.compile(r'^[a-zA-Z0-9][-a-zA-Z0-9\.]*\.[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$')
    redir_pattern = re.compile(r'^[a-zA-Z0-9\.\-\_\/\:\?\&\=\#\%\+]+$')
    service_pattern = re.compile(r'^[a-zA-Z0-9\-\_]+$')
    anubis_pattern = re.compile(r'^[a-zA-Z0-9\-]+$')
    
    domain = entry.get('domain', '').strip()
    service_name = entry.get('service_name', '').strip()
    
    if not domain or not service_name:
        return False
        
    if not domain_pattern.match(domain):
        return False
        
    if not service_pattern.match(service_name):
        return False
        
    redir = entry.get('redirection', '').strip()
    if redir and not redir_pattern.match(redir):
        return False
        
    anubis = entry.get('anubis_subdomain', '').strip()
    if anubis and not anubis_pattern.match(anubis):
        return False
        
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

def read_csv():
    data = []
    if not os.path.exists(DOMAINS_CSV_PATH):
        return data
    with open(DOMAINS_CSV_PATH, mode='r', encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            if not row:
                continue

            enabled = True
            first_col = row[0].strip()
            
            if first_col.startswith('#'):
                clean_content = first_col.lstrip('#').strip()
                if 'domain' in clean_content.lower() and len(row) > 1 and 'redirection' in row[1].lower():
                    continue
                if ' ' in clean_content or not clean_content:
                    continue
                enabled = False
                row[0] = clean_content
            
            while len(row) < 7:
                row.append('')
            
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
            
            if validate_domain_data(entry):
                data.append(entry)

    return data

def write_csv(data):
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
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

def validate_captcha_data(entry):
    domain = entry.get('root_domain', '').strip().lower()
    domain_pattern = re.compile(r'^[a-zA-Z0-9][-a-zA-Z0-9\.]*\.[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$')
    if not domain or not domain_pattern.match(domain):
        return False
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
                if 'root_domain' in clean_content.lower():
                    continue
                if not clean_content or ' ' in clean_content:
                    continue
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
            os.chmod(CAPTCHA_CSV_PATH, 0o600)
        except OSError:
            pass
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
