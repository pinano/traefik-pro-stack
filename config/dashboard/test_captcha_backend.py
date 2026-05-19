import sys
import os

sys.path.append(os.path.abspath('.'))

import app

# Let's NOT overwrite app.CAPTCHA_CSV_PATH, let it use the computed absolute path

print("--- Testing read_captcha_csv ---")
print(f"Computed CSV Path: {app.CAPTCHA_CSV_PATH}")
data = app.read_captcha_csv()
print(f"Data read: {data}")

print("\n--- Testing validation of a valid entry ---")
valid_entry = {
    'root_domain': 'example.com',
    'provider': 'turnstile',
    'site_key': '0x4AAAAAAA...',
    'secret_key': '0x4AAAAAAA...'
}
is_valid = app.validate_captcha_data(valid_entry)
print(f"Is valid? {is_valid} (Expected: True)")

print("\n--- Testing validation of an invalid entry ---")
invalid_entry = {
    'root_domain': 'invalid domain',
    'provider': 'invalid-provider',
    'site_key': '',
    'secret_key': '0x4AAAAAAA...'
}
is_invalid = app.validate_captcha_data(invalid_entry)
print(f"Is valid? {is_invalid} (Expected: False)")

print("\n--- Testing write_captcha_csv ---")
test_data = [
    {
        'root_domain': 'testdomain.org',
        'provider': 'recaptcha',
        'site_key': 'sitekey123',
        'secret_key': 'secretkey123'
    },
    {
        'root_domain': 'another.net',
        'provider': 'hcaptcha',
        'site_key': 'hsite',
        'secret_key': 'hsecret'
    }
]

app.write_captcha_csv(test_data)
print("Wrote data to config/crowdsec/captcha_keys.csv. Let's read it back:")
reread_data = app.read_captcha_csv()
print(f"Data reread: {reread_data}")

# Restore mock data afterwards
with open(app.CAPTCHA_CSV_PATH, 'w') as f:
    f.write("# root_domain, provider, site_key, secret_key\n")
    f.write("arroyosanjuan.dev, turnstile, 0x4AAAAAAAx1111111111111, 0x4AAAAAAAx2222222222222\n")

print("\nRestored original mock captcha_keys.csv")
