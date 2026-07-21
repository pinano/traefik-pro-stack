import os
import requests
import pytest
import time

def get_env_var(key, default=None):
    """Simple parser to extract a variable from .env"""
    env_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '.env'))
    if os.path.exists(env_path):
        with open(env_path, 'r') as f:
            for line in f:
                if line.startswith(f"{key}="):
                    val = line.split('=', 1)[1].strip()
                    return val.strip('\'"')
    return default

DOMAIN = get_env_var('DOMAIN', 'example.com')
DASHBOARD_SUBDOMAIN = get_env_var('DASHBOARD_SUBDOMAIN', 'dashboard')
TARGET_HOST = f"{DASHBOARD_SUBDOMAIN}.{DOMAIN}"

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Use localhost HTTPS to avoid 301 redirects and external DNS resolution
BASE_URL = "https://localhost:443"

def test_routing_basic():
    """
    Test that the proxy is up and routes requests correctly to the dashboard.
    It should return a 401 Unauthorized or 302 Redirect to /login
    because we don't have a valid SSO cookie.
    """
    headers = {'Host': TARGET_HOST}
    try:
        response = requests.get(BASE_URL, headers=headers, timeout=5, allow_redirects=False, verify=False)
    except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
        pytest.skip("Could not connect to Traefik on port 443. Is the stack running?")
        
    # The dashboard-error middleware intercepts 401s and returns a 302 to /login
    assert response.status_code in [302, 401], f"Expected 302/401 auth challenge, got {response.status_code}"


def test_waf_sqli_blocking():
    """
    Test that CrowdSec AppSec (WAF) blocks SQL injection payloads.
    """
    appsec_enabled = get_env_var('CROWDSEC_APPSEC_ENABLE', 'true').lower() == 'true'
    if not appsec_enabled:
        pytest.skip("CROWDSEC_APPSEC_ENABLE is false. Skipping WAF test.")

    headers = {
        'Host': TARGET_HOST,
        'X-Forwarded-For': '8.8.8.8' # Spoof external IP to bypass AppSec localhost whitelist
    }
    malicious_url = f"{BASE_URL}/login?username=admin' OR '1'='1"
    
    try:
        response = requests.get(malicious_url, headers=headers, timeout=5, verify=False)
    except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
        pytest.skip("Could not connect to Traefik on port 443. Is the stack running?")
        
    # AppSec should intercept this payload and immediately return 403
    assert response.status_code == 403, f"WAF failed to block SQLi payload. Got status {response.status_code}"
