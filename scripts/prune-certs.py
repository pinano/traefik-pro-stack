import json
import csv
import os
import tldextract
import argparse
import base64
import sys
from datetime import datetime
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
        all_valid_domains.add(domain_env)
        expected_batch_sets.add(frozenset([domain_env]))
        if dash_sub:
            dash_fqdn = f"{dash_sub}.{domain_env}"
            all_valid_domains.add(dash_fqdn)
            expected_batch_sets.add(frozenset([dash_fqdn]))
                
    return expected_batch_sets, all_valid_domains

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

        for cert in certs:
            main = cert.get('domain', {}).get('main', '').lower()
            sans = [s.lower() for s in cert.get('domain', {}).get('sans', [])]
            
            # The complete set of domains in this certificate
            cert_domains = frozenset([main] + sans if main else sans)
            
            # A certificate is kept if:
            # 1. It exactly matches the set of domains of an expected batch.
            # 2. OR it's a single-domain cert for a domain that is still valid (safety fallback).
            is_valid_batch = cert_domains in expected_batch_sets
            is_valid_single = len(cert_domains) == 1 and list(cert_domains)[0] in all_valid_domains
            
            if is_valid_batch or is_valid_single:
                kept_certs.append(cert)
            else:
                removed_count += 1
                
                # Determine reason for logging
                unknown = [d for d in cert_domains if d not in all_valid_domains]
                if unknown:
                    reason = f"Unknown domains: {', '.join(unknown)}"
                else:
                    reason = "Superseded (Obsolete grouping or batching)"
                
                print(f"   🗑️  Removing: {main} {f'(SANs: {sans})' if sans else ''} -> {reason}")
                modified = True

        resolver_data['Certificates'] = kept_certs
        new_acme_data[resolver_name] = resolver_data
        
        if removed_count > 0:
            print(f"   ✨ Resolver '{resolver_name}': Kept {len(kept_certs)}, Removed {removed_count}")

    if not modified:
        print("✨ No certificates to prune. acme.json is already clean.")
        sys.exit(0)

    if dry_run:
        print("\n⚠️  DRY RUN: No changes were written to disk.")
        print("Run with --force to apply changes.")
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
