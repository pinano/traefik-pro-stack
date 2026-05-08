cimport json
import csv
import os
import tldextract
import argparse
import base64
import sys
import subprocess
from datetime import datetime

def extract_domains_from_cert(cert_b64):
    try:
        cert_pem = base64.b64decode(cert_b64).decode('utf-8')
        cmd = ['openssl', 'x509', '-noout', '-ext', 'subjectAltName']
        process = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        stdout, _ = process.communicate(input=cert_pem)
        if process.returncode == 0:
            actual_domains = []
            for line in stdout.splitlines():
                line = line.strip()
                if line.startswith('DNS:'):
                    for part in line.split(','):
                        part = part.strip()
                        if part.startswith('DNS:'):
                            actual_domains.append(part[4:].lower())
            return actual_domains
    except Exception:
        pass
    return []

from collections import defaultdict

ACME_FILE = 'config/traefik/acme.json'
DOMAINS_FILE = 'domains.csv'

def get_root_domain(domain):
    extracted = tldextract.extract(domain)
    if extracted.suffix:
        return f"{extracted.domain}.{extracted.suffix}"
    return domain

def load_expected_batch_sets():
    """
    Identifies the exact sets of domains that should be covered by certificates.
    Returns a set of frozensets.
    """
    expected_batch_sets = set()
    csv_raw_domains = []
    
    # 1. Load from domains.csv (Exactly as generate-config.py does)
    if os.path.exists(DOMAINS_FILE):
        try:
            with open(DOMAINS_FILE, 'r') as f:
                lines = [line for line in f if line.strip() and not line.strip().startswith('#')]
                reader = csv.reader(lines, skipinitialspace=True)
                for row in reader:
                    if not row or len(row) < 1: continue
                    domain = row[0].strip().lower()
                    if not domain: continue
                    
                    root = get_root_domain(domain)
                    csv_raw_domains.append({'domain': domain, 'root': root})
                    
                    if len(row) > 3 and row[3].strip():
                        anubis_sub = row[3].strip().lower()
                        csv_raw_domains.append({'domain': f"{anubis_sub}.{root}", 'root': root})
        except Exception as e:
            print(f"❌ Error reading {DOMAINS_FILE}: {e}")
    
    # Group by root and chunk into batches (Matching generate-config.py logic)
    domains_by_root = defaultdict(list)
    for entry in csv_raw_domains:
        domains_by_root[entry['root']].append(entry['domain'])

    batch_size = int(os.getenv('TLS_BATCH_SIZE', 30))
    all_valid_domains = set()

    for root_domain, subdomains in domains_by_root.items():
        subs_unicos = list(dict.fromkeys(subdomains))
        all_valid_domains.update(subs_unicos)
        
        for i in range(0, len(subs_unicos), batch_size):
            batch = subs_unicos[i:i + batch_size]
            expected_batch_sets.add(frozenset(batch))
            
    # 2. Add System Domains as single-domain batches
    domain_env = os.getenv('DOMAIN', '').lower()
    dash_sub = os.getenv('DASHBOARD_SUBDOMAIN', '').lower()
    
    if domain_env:
        if dash_sub:
            dash_fqdn = f"{dash_sub}.{domain_env}"
            all_valid_domains.add(dash_fqdn)
            expected_batch_sets.add(frozenset([dash_fqdn]))
        else:
            # If no dashboard subdomain, the dashboard is on the bare domain
            all_valid_domains.add(domain_env)
            expected_batch_sets.add(frozenset([domain_env]))
                
    return expected_batch_sets, all_valid_domains

def prune_certs(dry_run=True):
    action = "Dry-run pruning" if dry_run else "Pruning"
    print(f"🧹 {action} Certificates in {ACME_FILE}...")
    
    if not os.path.exists(ACME_FILE) or os.path.getsize(ACME_FILE) == 0:
        print(f"⚠️  {ACME_FILE} is empty or missing. Nothing to prune.")
        return

    try:
        with open(ACME_FILE, 'r') as f:
            acme_data = json.load(f)
    except Exception as e:
        print(f"❌ Error parsing {ACME_FILE}: {e}")
        return

    expected_batch_sets, all_valid_domains = load_expected_batch_sets()
    if not expected_batch_sets:
        print("❌ No expected domains or batches found. Aborting.")
        return

    print(f"✅ Calculated {len(expected_batch_sets)} expected certificate configurations.")
    
    modified = False
    new_acme_data = {}

    for resolver_name, resolver_data in acme_data.items():
        if not isinstance(resolver_data, dict) or 'Certificates' not in resolver_data:
            new_acme_data[resolver_name] = resolver_data
            continue

        certs = resolver_data.get('Certificates', [])
        if not certs:
            new_acme_data[resolver_name] = resolver_data
            continue

        kept_certs = []
        removed_count = 0
        
        # Group by frozenset of domains to detect exact duplicates
        certs_by_domains = defaultdict(list)
        for cert in certs:
            main = cert.get('domain', {}).get('main', '').lower()
            sans = [s.lower() for s in cert.get('domain', {}).get('sans', [])]
            cert_b64 = cert.get('certificate', '')
            actual_domains = extract_domains_from_cert(cert_b64)
            if actual_domains:
                cert_doms = frozenset(actual_domains)
            else:
                cert_doms = frozenset([main] + sans if main else sans)
            certs_by_domains[cert_doms].append(cert)
            
        for cert_domains, grouped_certs in certs_by_domains.items():
            # Try to parse expiration to sort, if fails default to 0
            def get_ts(c):
                try:
                    cert_pem = base64.b64decode(c.get('certificate', '')).decode('utf-8')
                    cmd = ['openssl', 'x509', '-noout', '-enddate']
                    process = subprocess.Popen(
                        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
                    )
                    stdout, _ = process.communicate(input=cert_pem)
                    if process.returncode == 0 and '=' in stdout:
                        date_str = stdout.strip().split('=', 1)[1]
                        dt = datetime.strptime(date_str, '%b %d %H:%M:%S %Y GMT')
                        return dt.timestamp()
                except Exception:
                    pass
                return 0
                
            grouped_certs.sort(key=get_ts, reverse=True)
            
            for i, cert in enumerate(grouped_certs):
                main = cert.get('domain', {}).get('main', '').lower()
                sans = [s.lower() for s in cert.get('domain', {}).get('sans', [])]
                
                cert_b64 = cert.get('certificate', '')
                actual_domains = extract_domains_from_cert(cert_b64)
                if actual_domains:
                    cert_domains = frozenset(actual_domains)
                    if main not in actual_domains:
                        main = actual_domains[0]
                    sans = [d for d in actual_domains if d != main]
                else:
                    cert_domains = frozenset([main] + sans if main else sans)

                
                is_valid_batch = cert_domains in expected_batch_sets
                is_valid_single = len(cert_domains) == 1 and list(cert_domains)[0] in all_valid_domains
                
                if i == 0 and (is_valid_batch or is_valid_single):
                    kept_certs.append(cert)
                else:
                    removed_count += 1
                    if i > 0:
                        reason = "Superseded (Older duplicate)"
                    else:
                        unknown = [d for d in cert_domains if d not in all_valid_domains]
                        if unknown:
                            reason = f"Unknown domains: {', '.join(unknown)}"
                        else:
                            reason = "Superseded (Obsolete grouping or batching)"
                    
                    print(f"   🗑️  Removing: {main} (Reason: {reason})")
                    modified = True

        resolver_data['Certificates'] = kept_certs
        new_acme_data[resolver_name] = resolver_data
        
        if removed_count > 0:
            print("\n📊 PRUNE SUMMARY:")
            print(f"   - Kept active certificates:   {len(kept_certs)}")
            print(f"   - Removed dirty certificates: {removed_count}")

    if not modified:
        print("\n✨ All certificates are 100% active. acme.json is already clean.")
        sys.exit(0)

    if dry_run:
        print("\n⚠️  DRY RUN: No changes were written to disk.")
        print("👉 Run 'make certs-prune-force' to apply changes.")
        sys.exit(0)
    else:
        # Backup before writing
        backup_path = f"{ACME_FILE}.{datetime.now().strftime('%Y%m%d%H%M%S')}.bak"
        try:
            import shutil
            shutil.copy2(ACME_FILE, backup_path)
            print(f"📦 Backup created: {backup_path}")
            
            with open(ACME_FILE, 'w') as f:
                json.dump(new_acme_data, f, indent=2)
            
            # Ensure permissions 600
            os.chmod(ACME_FILE, 0o600)
            print("✅ Successfully updated acme.json")
            print("👉 IMPORTANT: Restart Traefik to apply changes: 'make restart traefik'")
            sys.exit(0)
        except Exception as e:
            print(f"❌ Error writing {ACME_FILE}: {e}")
            sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prune Traefik acme.json of unused certificates.")
    parser.add_argument("--force", action="store_true", help="Actually apply the changes (default is dry-run)")
    args = parser.parse_args()
    
    # We need environment variables for load_expected_domains
    # If they are not set, we might delete too much.
    # The Makefile loads .env, so if run via make it should be fine.
    
    prune_certs(dry_run=not args.force)
