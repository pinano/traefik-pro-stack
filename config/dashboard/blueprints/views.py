import os
import json
from collections import defaultdict
from flask import Blueprint, render_template
from blueprints.auth import login_required
from config import DOMAIN, TRAEFIK_RATE_AVG, TRAEFIK_RATE_BURST, TRAEFIK_CONCURRENCY, ACME_FILE
from utils.csv_manager import read_csv, get_root_domain
from utils.certs_manager import parse_certificate_data

views_bp = Blueprint('views', __name__)

@views_bp.route('/')
@login_required
def dashboard():
    cs_enable = os.environ.get('CROWDSEC_ENABLE', 'true').lower() == 'true'
    certs_enabled = os.environ.get('TRAEFIK_ACME_ENV_TYPE', 'production').lower() != 'local'
    backrest_enabled = os.environ.get('BACKREST_ENABLE', 'true').lower() == 'true'
    phpmyadmin_enabled = os.environ.get('PHPMYADMIN_ENABLE', 'true').lower() == 'true'
    filebrowser_enabled = os.environ.get('FILEBROWSER_ENABLE', 'true').lower() == 'true'
    return render_template('index.html', domain=DOMAIN, crowdsec_enabled=cs_enable, certs_enabled=certs_enabled, backrest_enabled=backrest_enabled, phpmyadmin_enabled=phpmyadmin_enabled, filebrowser_enabled=filebrowser_enabled)

@views_bp.route('/domains')
@login_required
def index():
    return render_template('domains.html', 
                           domain=DOMAIN,
                           rate_avg=TRAEFIK_RATE_AVG,
                           rate_burst=TRAEFIK_RATE_BURST,
                           concurrency=TRAEFIK_CONCURRENCY)

@views_bp.route('/certs')
@login_required
def certs_view():
    expected_domains = set()
    csv_data = read_csv()
    for row in csv_data:
        if row.get('enabled', True):
             d = row.get('domain', '').strip().lower()
             if d:
                 expected_domains.add(d)
             
             anubis = row.get('anubis_subdomain', '').strip()
             if anubis and d:
                 root = get_root_domain(d)
                 expected_domains.add(f"{anubis}.{root}".lower())

    acme_data = {}
    if os.path.exists(ACME_FILE) and os.path.getsize(ACME_FILE) > 0:
        try:
            with open(ACME_FILE, 'r') as f:
                acme_data = json.load(f)
        except Exception as e:
            print(f"Error loading acme.json: {e}")

    covered_domains = set()
    certificates_details = []

    for resolver_name, resolver_data in acme_data.items():
        if isinstance(resolver_data, dict) and isinstance(resolver_data.get('Certificates'), list):
            for cert in resolver_data['Certificates']:
                if 'domain' in cert and cert.get('certificate'):
                    cert_info = parse_certificate_data(cert['certificate'])
                    
                    real_main = cert_info['cn'].lower() if cert_info['cn'] else "unknown"
                    real_sans = [s.lower() for s in cert_info['sans']]
                    
                    ui_sans = sorted(list(set([real_main] + real_sans))) if real_main != 'unknown' else sorted(real_sans)
                    
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
                        'valid_days': cert_info['valid_days'],
                        'expiration_timestamp': cert_info.get('expiration_timestamp', 0),
                        'status': status,
                        'superseded': False
                    })

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

    certs_by_domains = defaultdict(list)
    for cert in certificates_details:
        cert_doms = frozenset([cert['main']] + cert['sans'])
        certs_by_domains[cert_doms].append(cert)
    
    final_certificates = []
    
    for cert_doms, certs in certs_by_domains.items():
        certs.sort(key=lambda x: x.get('expiration_timestamp', 0), reverse=True)
        
        for i, cert in enumerate(certs):
            cert_domains = frozenset([cert['main']] + cert['sans'])
            is_valid_batch = cert_domains in expected_batch_sets
            is_valid_single = len(cert_domains) == 1 and list(cert_domains)[0] in all_valid_domains
            
            if i > 0 or not (is_valid_batch or is_valid_single):
                cert['superseded'] = True
                cert['status'] = 'superseded'
        
        final_certificates.extend(certs)
    
    final_certificates.sort(key=lambda x: (x['root'], x['main']))

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
    
    return render_template('certs.html', 
                           domain=DOMAIN,
                           certificates=final_certificates,
                           total_certs=total_certs,
                           total_unique_domains=total_unique_domains,
                           missing_count=missing_count,
                           missing_domains=sorted(list(missing_domains)))

@views_bp.route('/captchas')
@login_required
def captchas_view():
    return render_template('captchas.html', domain=DOMAIN)
