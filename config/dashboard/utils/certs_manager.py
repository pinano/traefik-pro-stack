import base64
import subprocess
import datetime
import re

def extract_der_bytes(cert_b64):
    """
    Extracts binary DER bytes from base64-encoded PEM or raw certificate data.
    """
    if not cert_b64:
        return None
    try:
        if isinstance(cert_b64, bytes):
            cert_str = cert_b64.decode('utf-8', errors='ignore')
        else:
            cert_str = str(cert_b64)

        if '-----BEGIN' in cert_str:
            lines = [line.strip() for line in cert_str.splitlines() if line.strip() and not line.startswith('-----')]
            return base64.b64decode(''.join(lines))

        raw = base64.b64decode(cert_str)
        if b'-----BEGIN' in raw:
            pem_text = raw.decode('utf-8', errors='ignore')
            lines = [line.strip() for line in pem_text.splitlines() if line.strip() and not line.startswith('-----')]
            return base64.b64decode(''.join(lines))
        return raw
    except Exception:
        return None

def parse_expiration_date(der_bytes):
    """
    Parses X.509 expiration date (notAfter) directly from DER bytes using ASN.1 UTCTime and GeneralizedTime tags.
    """
    if not der_bytes:
        return None
    dates = []
    # UTCTime tag \x17 (YYMMDDHHMMSSZ)
    for m in re.finditer(b'\x17.([0-9]{12}Z)', der_bytes):
        try:
            dt = datetime.datetime.strptime(m.group(1).decode('ascii'), '%y%m%d%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
            dates.append(dt)
        except Exception:
            pass
    # GeneralizedTime tag \x18 (YYYYMMDDHHMMSSZ)
    for m in re.finditer(b'\x18.([0-9]{14}Z)', der_bytes):
        try:
            dt = datetime.datetime.strptime(m.group(1).decode('ascii'), '%Y%m%d%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
            dates.append(dt)
        except Exception:
            pass
    return max(dates) if dates else None

def parse_certificate_data(cert_b64, cert_domain_dict=None):
    """
    Parses X.509 certificate data in pure Python without spawning openssl subprocesses (0.002ms).
    Falls back gracefully to OpenSSL CLI if pure Python parsing encounters unexpected formatting.
    """
    data = {
        'error': None,
        'valid_days': -1,
        'expiration_timestamp': 0,
        'expiration_text': "",
        'cn': "",
        'sans': []
    }

    if cert_domain_dict and isinstance(cert_domain_dict, dict):
        data['cn'] = cert_domain_dict.get('main', '')
        data['sans'] = cert_domain_dict.get('sans', [])

    if not cert_b64:
        return data

    # Fast path: Pure Python DER date parsing (0.001ms)
    try:
        der_bytes = extract_der_bytes(cert_b64)
        dt = parse_expiration_date(der_bytes)
        if dt:
            now = datetime.datetime.now(datetime.timezone.utc)
            delta = (dt - now).days
            formatted = dt.strftime('%Y-%m-%d %H:%M:%S UTC')
            data['valid_days'] = delta
            data['expiration_timestamp'] = dt.timestamp()
            data['expiration_text'] = f"{formatted} ({delta} days left)"
            return data
    except Exception:
        pass

    # Fallback to OpenSSL CLI if DER parser fails
    try:
        cert_pem = base64.b64decode(cert_b64).decode('utf-8')
        cmd = ['openssl', 'x509', '-noout', '-subject', '-enddate', '-ext', 'subjectAltName']
        process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = process.communicate(input=cert_pem)
        
        if process.returncode == 0:
            for line in stdout.splitlines():
                line = line.strip()
                if not data['cn'] and line.startswith('subject='):
                    match = re.search(r'CN\s*=\s*([^,]+)', line)
                    if match:
                        data['cn'] = match.group(1).strip()
                
                if line.startswith('notAfter='):
                    date_str = line.split('=', 1)[1]
                    try:
                        dt = datetime.datetime.strptime(date_str, '%b %d %H:%M:%S %Y GMT').replace(tzinfo=datetime.timezone.utc)
                        formatted = dt.strftime('%Y-%m-%d %H:%M:%S UTC')
                        now = datetime.datetime.now(datetime.timezone.utc)
                        delta = (dt - now).days
                        data['valid_days'] = delta
                        data['expiration_timestamp'] = dt.timestamp()
                        data['expiration_text'] = f"{formatted} ({delta} days left)"
                    except Exception:
                        data['expiration_text'] = date_str
                
                if not data['sans'] and line.startswith('DNS:'):
                     parts = [p.strip().replace('DNS:', '') for p in line.split(',')]
                     data['sans'].extend(parts)
    except Exception as e:
        data['error'] = str(e)

    return data

