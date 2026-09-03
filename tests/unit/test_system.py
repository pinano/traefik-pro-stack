import pytest
from unittest.mock import patch, mock_open
import sys
import os

# Add dashboard path to sys.path so we can import utils.system
DASHBOARD_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'config', 'dashboard'))
if DASHBOARD_PATH not in sys.path:
    sys.path.insert(0, DASHBOARD_PATH)

from utils.system import _extract_hostname, resolve_domain, check_host_file


def test_extract_hostname():
    assert _extract_hostname("https://example.com") == "example.com"
    assert _extract_hostname("http://example.com/path/to/resource") == "example.com"
    assert _extract_hostname("https://sub.domain.com:8443/test") == "sub.domain.com"
    assert _extract_hostname("//example.com/foo") == "example.com"
    assert _extract_hostname("bare-domain.org") == "bare-domain.org"
    assert _extract_hostname("https://shop.example.com/checkout?id=123&token=abc") == "shop.example.com"
    assert _extract_hostname("https://example.com/docs#installation") == "example.com"
    assert _extract_hostname("http://user:pass@example.com/secret") == "example.com"
    assert _extract_hostname("http://192.168.1.50:8080/api") == "192.168.1.50"
    assert _extract_hostname("   https://example.com/spaces   ") == "example.com"
    assert _extract_hostname("") == ""
    assert _extract_hostname(None) == ""


def test_resolve_domain_url_handling():
    with patch("socket.gethostbyname") as mock_gethost:
        mock_gethost.return_value = "93.184.216.34"
        
        # Test full URL with protocol and path
        ip = resolve_domain("https://example.com/my-page")
        assert ip == "93.184.216.34"
        mock_gethost.assert_called_with("example.com")
        
        # Test bare domain
        ip2 = resolve_domain("example.com")
        assert ip2 == "93.184.216.34"
        mock_gethost.assert_called_with("example.com")
        
        # Test empty domain
        assert resolve_domain("") is None
        assert resolve_domain(None) is None


def test_check_host_file_url_handling():
    mock_hosts_content = "127.0.0.1 localhost example.com\n"
    with patch("os.path.exists", return_value=True), \
         patch("builtins.open", mock_open(read_data=mock_hosts_content)):
        
        assert check_host_file("https://example.com/some/path") is True
        assert check_host_file("example.com") is True
        assert check_host_file("https://notfound.com") is False
