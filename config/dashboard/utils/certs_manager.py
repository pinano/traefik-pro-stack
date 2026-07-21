import base64
import subprocess
import datetime
import re

def parse_certificate_data(cert_b64):
    try:
        cert_pem = base64.b64decode(cert_b64).decode('utf-8')
        cmd = ['openssl', 'x509', '-noout', '-subject', '-enddate', '-ext', 'subjectAltName']
        process = subprocess.Popen(
            cmd, 
            stdin=subprocess.PIPE, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = process.communicate(input=cert_pem)
        
        if process.returncode != 0:
            return {
                'error': f"Error: {stderr.strip()}",
                'valid_days': -1,
                'expiration_text': "Error",
                'cn': "Unknown",
                'sans': []
            }

        data = {
            'error': None,
            'valid_days': -1,
            'expiration_timestamp': 0,
            'expiration_text': "",
            'cn': "",
            'sans': []
        }

        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith('subject='):
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
            
            if line.startswith('DNS:'):
                 parts = [p.strip().replace('DNS:', '') for p in line.split(',')]
                 data['sans'].extend(parts)

        if not data['sans'] and 'Subject Alternative Name' in stdout:
             sans_match = re.search(r'Subject Alternative Name:\s*\n\s*(.*)', stdout, re.MULTILINE)
             if sans_match:
                 san_line = sans_match.group(1).strip()
                 parts = [p.strip().replace('DNS:', '') for p in san_line.split(',')]
                 data['sans'].extend(parts)
        
        return data

    except Exception as e:
         return {
                'error': f"Exception: {e}",
                'valid_days': -1,
                'expiration_timestamp': 0,
                'expiration_text': str(e),
                'cn': "Error",
                'sans': []
            }
