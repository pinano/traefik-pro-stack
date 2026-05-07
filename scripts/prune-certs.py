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

def load_expected_batches():
    """
    Replicates the grouping and batching logic from generate-config.py
    to identify exactly which certificate configurations (Main + SANs)
    are expected to be in use.
    """
    expected_batches = set()
    csv_raw_domains = []
    
    # 1. Load ONLY from domains.csv for grouping (Exactly as generate-config.py does)
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
                    
                    # Check for Anubis subdomain
                    if len(row) > 3 and row[3].strip():
                        anubis_sub = row[3].strip().lower()
                        csv_raw_domains.append({'domain': f"{anubis_sub}.{root}", 'root': root})
        except Exception as e:
            print(f"❌ Error reading {DOMAINS_FILE}: {e}")
    
    # Group by root and chunk into batches (Matching generate-config.py logic)
    domains_by_root = defaultdict(list)
    for entry in csv_raw_domains:
        domains_by_root[entry['root']].append(entry['domain'])

    # Sync batch size logic with generate-config.py
    batch_size = int(os.getenv('TLS_BATCH_SIZE', 30))

    for root_domain, subdomains in domains_by_root.items():
        # Deduplicate preserving order
        subs_unicos = list(dict.fromkeys(subdomains))
        
        for i in range(0, len(subs_unicos), batch_size):
            batch = subs_unicos[i:i + batch_size]
            main = batch[0]
            sans = frozenset(batch[1:])
            expected_batches.add((main, sans))
            
    # 2. Add System Domains as SEPARATE single-domain batches
    # Traefik requests these based on container labels which don't use the generator's grouping.
    domain_env = os.getenv('DOMAIN', '').lower()
    dash_sub = os.getenv('DASHBOARD_SUBDOMAIN', '').lower()
    
    if domain_env:
        expected_batches.add((domain_env, frozenset()))
        if dash_sub:
            expected_batches.add((f"{dash_sub}.{domain_env}", frozenset()))
                
    return expected_batches

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

    expected_batches = load_expected_batches()
    if not expected_batches:
        print("❌ No expected domains or batches found. Aborting.")
        return

    print(f"✅ Calculated {len(expected_batches)} expected certificate batches.")
    
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
            sans = frozenset([s.lower() for s in cert.get('domain', {}).get('sans', [])])
            
            # A certificate is kept ONLY if it matches an expected batch exactly.
            # This prunes both certificates with decommissioned domains AND 
            # superseded certificates (e.g. from a previous grouping).
            is_valid_batch = (main, sans) in expected_batches
            
            if is_valid_batch:
                kept_certs.append(cert)
            else:
                removed_count += 1
                
                # Determine reason for logging
                # Check if it's a completely unknown domain or just a superseded batch
                all_domains_in_cert = [main] + list(sans)
                expected_domains = set()
                for m, s in expected_batches:
                    expected_domains.add(m)
                    expected_domains.update(s)
                
                unknown = [d for d in all_domains_in_cert if d not in expected_domains]
                if unknown:
                    reason = f"Unknown domains: {', '.join(unknown)}"
                else:
                    reason = "Superseded (Not in use / Different grouping)"
                
                print(f"   🗑️  Removing: {main} {f'(SANs: {list(sans)})' if sans else ''} -> {reason}")
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
            print("👉 IMPORTANT: Traefik will be restarted to apply changes.")
            sys.exit(2) # Exit code 2 indicates modifications were made
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
