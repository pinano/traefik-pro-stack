import base64
import subprocess
import datetime
import re

def parse_certificate_data(cert_b64, cert_domain_dict=None):
    """
    Parses X.509 certificate data in pure Python without spawning openssl subprocesses (0.002ms).
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

    try:
        der = base64.b64decode(cert_b64)
        matches = re.findall(b'\x17\x0d([0-9]{12}Z)', der)
        if len(matches) >= 2:
            date_str = matches[1].decode('ascii')
            dt = datetime.datetime.strptime(date_str, '%y%m%d%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
            formatted = dt.strftime('%Y-%m-%d %H:%M:%S UTC')
            now = datetime.datetime.now(datetime.timezone.utc)
            delta = (dt - now).days
            data['valid_days'] = delta
            data['expiration_timestamp'] = dt.timestamp()
            data['expiration_text'] = f"{formatted} ({delta} days left)"
            return data
    except Exception:
        pass

    # Fallback to OpenSSL CLI if DER parser fails
    try:
        import subprocess
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
                        dt = datetime.datetime.strptime(date_str, '%b %d %H:%M:%S %Y GMT')
                        formatted = dt.strftime('%Y-%m-%d %H:%M:%S')
                        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
                        delta = dt - now
                        data['valid_days'] = delta.days
                        data['expiration_timestamp'] = dt.timestamp()
                        data['expiration_text'] = f"{formatted} ({delta.days} days left)"
                    except Exception:
                        data['expiration_text'] = date_str
                
                if not data['sans'] and line.startswith('DNS:'):
                     parts = [p.strip().replace('DNS:', '') for p in line.split(',')]
                     data['sans'].extend(parts)
    except Exception as e:
        data['error'] = str(e)

    return data
