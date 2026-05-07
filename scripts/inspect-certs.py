import json
import csv
import os
import tldextract
import argparse
from collections import defaultdict
import subprocess
import datetime
import base64

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

def get_cert_expiration(cert_b64):
    try:
        # Decode base64 to get PEM
        cert_pem = base64.b64decode(cert_b64).decode('utf-8')
        
        # Use openssl to extract end date
        cmd = ['openssl', 'x509', '-noout', '-enddate']
        process = subprocess.Popen(
            cmd, 
            stdin=subprocess.PIPE, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = process.communicate(input=cert_pem)
        
        if process.returncode != 0:
            return f"Error: {stderr.strip()}"
            
        # Format: notAfter=Feb 16 08:41:11 2026 GMT
        # Output example: notAfter=May 17 08:41:11 2026 GMT
        if '=' in stdout:
            date_str = stdout.strip().split('=', 1)[1]
            return date_str
        return stdout.strip()
    except Exception as e:
        return f"Error parsing: {e}"

def inspect_certs(verbose=False):
    print(f"🔍 Inspecting Certificates in {ACME_FILE}...")
    
    if not os.path.exists(ACME_FILE) or os.path.getsize(ACME_FILE) == 0:
        print(f"⚠️  {ACME_FILE} is empty or missing. No certificates found.")
        acme_data = {}
    else:
        try:
            with open(ACME_FILE, 'r') as f:
                acme_data = json.load(f)
        except Exception as e:
            print(f"❌ Error parsing {ACME_FILE}: {e}")
            return

    covered_domains = set()
    certificates_details = []
    
    # Traefik acme.json structure: { "resolverName": { "Certificates": [...] } }
    for resolver_name, resolver_data in acme_data.items():
        if isinstance(resolver_data, dict) and 'Certificates' in resolver_data:
            certs = resolver_data['Certificates']
            if not certs:
                continue
            for cert in certs:
                if 'domain' in cert:
                    main = cert['domain'].get('main', '').lower()
                    sans = [s.lower() for s in cert['domain'].get('sans', [])]
                    
                    if main:
                        covered_domains.add(main)
                        # Deduplicate main from SANs for display purposes
                        sans_cleaned = [s for s in sans if s != main]
                        for san in sans_cleaned:
                            covered_domains.add(san)
                        
                        certificates_details.append({
                            'resolver': resolver_name,
                            'main': main,
                            'sans': sans_cleaned,
                            'root': get_root_domain(main),
                            'certificate': cert.get('certificate', '')
                        })

    print(f"✅ Found {len(certificates_details)} certificates covering {len(covered_domains)} unique domains.")
    
    if verbose and certificates_details:
        print("\n📜 DETAILED CERTIFICATE LIST:")
        # Group by root for better readability in verbose mode
        by_root = defaultdict(list)
        for cert in certificates_details:
            by_root[cert['root']].append(cert)
            
        for root, certs in sorted(by_root.items()):
            print(f"\n📂 Root Domain: {root}")
            for i, cert in enumerate(certs, 1):
                san_str = f" (+{len(cert['sans'])} SANs)" if cert['sans'] else ""
                
                expiration = ""
                if cert['certificate']:
                     expiry_date = get_cert_expiration(cert['certificate'])
                     expiration = f" [Expires: {expiry_date}]"

                print(f"   {i}. Main: {cert['main']}{san_str}{expiration}")
                if cert['sans']:
                    for s in cert['sans']:
                        print(f"      - {s}")

    expected_batch_sets, all_valid_domains = load_expected_batch_sets()
    expected_domains = all_valid_domains
    missing_domains = expected_domains - covered_domains
    
    # Identify "Dirty" certificates (those NOT matching any expected batch or single valid domain)
    dirty_certs = []
    for cert in certificates_details:
        cert_domains = frozenset([cert['main']] + cert['sans'])
        
        is_valid_batch = cert_domains in expected_batch_sets
        is_valid_single = len(cert_domains) == 1 and list(cert_domains)[0] in all_valid_domains
        
        if not (is_valid_batch or is_valid_single):
            # Check why it's dirty
            unknown = [d for d in cert_domains if d not in expected_domains]
            cert['dirty_reason'] = f"Unknown domains: {', '.join(unknown)}" if unknown else "Superseded (Obsolete grouping or batching)"
            dirty_certs.append(cert)

    print(f"\n📊 Summary vs {DOMAINS_FILE}:")
    print(f"   - Expected domains: {len(expected_domains)}")
    print(f"   - Covered domains:  {len(expected_domains - missing_domains)}")
    print(f"   - Missing domains:  {len(missing_domains)}")
    print(f"   - Dirty certs:      {len(dirty_certs)} (superseded or containing invalid domains)")

    if missing_domains:
        print("\n❌ MISSING DOMAINS (No certificate found):")
        for d in sorted(missing_domains):
            print(f"   ➜ {d}")
    
    if dirty_certs:
        print("\n⚠️  DIRTY CERTIFICATES (Will fail renewal or are not in use):")
        for cert in dirty_certs:
            print(f"   ➜ Main: {cert['main']} (Reason: {cert['dirty_reason']})")
        print("\n   👉 Run 'make certs-prune-force' to clean them up.")

    if not missing_domains and not dirty_certs and expected_domains:
        print("\n✨ All certificates are clean and cover all expected domains.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Inspect Traefik acme.json certificates.")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show detailed certificate information")
    args = parser.parse_args()
    
    inspect_certs(verbose=args.verbose)
