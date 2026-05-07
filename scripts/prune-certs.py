import json
import csv
import os
import tldextract
import argparse
import base64
import sys
from datetime import datetime

ACME_FILE = 'config/traefik/acme.json'
DOMAINS_FILE = 'domains.csv'

def get_root_domain(domain):
    extracted = tldextract.extract(domain)
    if extracted.suffix:
        return f"{extracted.domain}.{extracted.suffix}"
    return domain

def load_expected_domains():
    expected = set()
    
    # 1. Load from domains.csv
    if os.path.exists(DOMAINS_FILE):
        try:
            with open(DOMAINS_FILE, 'r') as f:
                lines = [line for line in f if line.strip() and not line.strip().startswith('#')]
                reader = csv.reader(lines, skipinitialspace=True)
                for row in reader:
                    if not row or len(row) < 1:
                        continue
                    domain = row[0].strip().lower()
                    if domain:
                        expected.add(domain)
                    
                    # Check for Anubis subdomain
                    if len(row) > 3 and row[3].strip():
                        anubis_sub = row[3].strip().lower()
                        root = get_root_domain(domain)
                        expected.add(f"{anubis_sub}.{root}")
        except Exception as e:
            print(f"❌ Error reading {DOMAINS_FILE}: {e}")
    
    # 2. Load system domains from environment
    domain_env = os.getenv('DOMAIN', '').lower()
    dash_sub = os.getenv('DASHBOARD_SUBDOMAIN', '').lower()
    
    if domain_env:
        expected.add(domain_env)
        if dash_sub:
            expected.add(f"{dash_sub}.{domain_env}")
            
    return expected

def prune_certs(dry_run=True):
    print(f"🧹 Pruning Certificates in {ACME_FILE}...")
    
    if not os.path.exists(ACME_FILE) or os.path.getsize(ACME_FILE) == 0:
        print(f"⚠️  {ACME_FILE} is empty or missing. Nothing to prune.")
        return

    try:
        with open(ACME_FILE, 'r') as f:
            acme_data = json.load(f)
    except Exception as e:
        print(f"❌ Error parsing {ACME_FILE}: {e}")
        return

    expected_domains = load_expected_domains()
    if not expected_domains:
        print("❌ No expected domains found. Aborting to avoid deleting everything.")
        print("Ensure DOMAIN and DASHBOARD_SUBDOMAIN are set in your environment or domains.csv is not empty.")
        return

    print(f"✅ Loaded {len(expected_domains)} expected domains.")
    
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

        for cert in certs:
            main = cert.get('domain', {}).get('main', '').lower()
            sans = [s.lower() for s in cert.get('domain', {}).get('sans', [])]
            
            # A certificate is kept ONLY if ALL its domains (main + SANs) are in the expected list.
            # This ensures that Traefik doesn't attempt to renew certificates containing 
            # decommissioned subdomains, which would lead to renewal failures.
            all_domains_in_cert = [main] + sans
            invalid_domains = [d for d in all_domains_in_cert if d and d not in expected_domains]
            
            if not invalid_domains:
                kept_certs.append(cert)
            else:
                removed_count += 1
                reason = f"Missing in domains.csv: {', '.join(invalid_domains)}"
                print(f"   🗑️  Removing: {main} {f'(SANs: {sans})' if sans else ''} -> {reason}")
                modified = True

        resolver_data['Certificates'] = kept_certs
        new_acme_data[resolver_name] = resolver_data
        
        if removed_count > 0:
            print(f"   ✨ Resolver '{resolver_name}': Kept {len(kept_certs)}, Removed {removed_count}")

    if not modified:
        print("✨ No certificates to prune. acme.json is already clean.")
        return

    if dry_run:
        print("\n⚠️  DRY RUN: No changes were written to disk.")
        print("Run with --force to apply changes.")
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
        except Exception as e:
            print(f"❌ Error writing {ACME_FILE}: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prune Traefik acme.json of unused certificates.")
    parser.add_argument("--force", action="store_true", help="Actually apply the changes (default is dry-run)")
    args = parser.parse_args()
    
    # We need environment variables for load_expected_domains
    # If they are not set, we might delete too much.
    # The Makefile loads .env, so if run via make it should be fine.
    
    prune_certs(dry_run=not args.force)
