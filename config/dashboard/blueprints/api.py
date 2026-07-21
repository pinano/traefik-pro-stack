import os
import re
import subprocess
import requests
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import Blueprint, request, jsonify, Response
from blueprints.auth import login_required
from extensions import limiter
from config import BASE_DIR, GENERATE_CONFIG_SCRIPT, RESTART_INTERNAL_SCRIPT, DASHBOARD_SUBDOMAIN, DOMAIN, TRAEFIK_ACME_ENV_TYPE
from utils.system import get_subprocess_env, build_compose_env, get_external_services, resolve_domain, check_host_file
from utils.csv_manager import read_csv, write_csv, read_captcha_csv, write_captcha_csv, validate_domain_data, validate_captcha_data, get_root_domain
from utils.csv_manager import TURNSTILE_SITE_KEY_RE, TURNSTILE_SECRET_KEY_RE, HCAPTCHA_SITE_KEY_RE, HCAPTCHA_SECRET_KEY_RE, RECAPTCHA_KEY_RE

log = logging.getLogger(__name__)

api_bp = Blueprint('api', __name__)

def verify_secret_key_online(provider, secret_key):
    endpoints = {
        'turnstile': 'https://challenges.cloudflare.com/turnstile/v0/siteverify',
        'hcaptcha': 'https://api.hcaptcha.com/siteverify',
        'recaptcha': 'https://www.google.com/recaptcha/api/siteverify'
    }
    url = endpoints.get(provider.lower())
    if not url:
        return False, "Proveedor desconocido"
    try:
        res = requests.post(url, data={'secret': secret_key, 'response': 'dummy_response_token'}, timeout=4)
        if res.status_code != 200:
            if res.status_code == 400 and provider.lower() == 'turnstile':
                try:
                    res_json = res.json()
                    error_codes = res_json.get('error-codes', [])
                    if 'invalid-input-secret' in error_codes:
                        return False, "Clave secreta inválida (rechazada por Cloudflare)"
                except Exception:
                    pass
            return None, f"El API del proveedor respondió con estado HTTP {res.status_code}"
            
        res_json = res.json()
        error_codes = res_json.get('error-codes', [])
        if 'invalid-input-secret' in error_codes:
            return False, f"Clave secreta inválida (rechazada por {provider})"
            
        return True, None
    except requests.Timeout:
        return None, "Tiempo de espera agotado al conectar con el proveedor"
    except Exception as e:
        return None, f"Error de conexión: {str(e)}"


@api_bp.route('/dm-api/domains', methods=['GET', 'POST'])
@login_required
def api_domains():
    if request.method == 'GET':
        csv_data = read_csv()
        dashboard_domain = f"{DASHBOARD_SUBDOMAIN}.{DOMAIN}".lower()
        
        dashboard_entry = None
        for entry in csv_data:
            if entry.get('service_name', '').lower() == 'dashboard':
                dashboard_entry = entry
                break
                
        if dashboard_entry:
            if dashboard_entry.get('domain', '').lower() != dashboard_domain:
                log.info(f"Auto-migrating dashboard domain in CSV from '{dashboard_entry['domain']}' to '{dashboard_domain}'")
                dashboard_entry['domain'] = dashboard_domain
        else:
            dashboard_anubis_sub = os.environ.get('DASHBOARD_ANUBIS_SUBDOMAIN', '').strip().lower()
            csv_data.append({
                'domain': dashboard_domain,
                'redirection': '',
                'service_name': 'dashboard',
                'anubis_subdomain': dashboard_anubis_sub,
                'rate': '',
                'burst': '',
                'concurrency': '',
                'enabled': True
            })

        return jsonify(csv_data)

    if request.method == 'POST':
        data = request.json
        if not isinstance(data, list):
            return jsonify({'status': 'error', 'message': 'Expected a JSON array'}), 400

        seen_domains = {}
        duplicates = []
        for entry in data:
            if not entry.get('enabled', True):
                continue
            domain = entry.get('domain', '').strip().lower()
            if not domain:
                continue
            if domain in seen_domains:
                if domain not in duplicates:
                    duplicates.append(domain)
            seen_domains[domain] = True
        
        if duplicates:
            return jsonify({
                'status': 'error', 
                'message': f'Duplicate domains found: {", ".join(duplicates)}',
                'duplicates': duplicates
            }), 400
            
        current_data = read_csv()
        incoming_map = {}
        for entry in data:
            d = entry.get('domain', '').strip().lower()
            if d:
                incoming_map[d] = entry

        final_list = []
        processed_domains = set()

        for existing_entry in current_data:
            d_existing = existing_entry.get('domain', '').strip().lower()
            if d_existing in incoming_map:
                final_list.append(incoming_map[d_existing])
                processed_domains.add(d_existing)
        
        for entry in data:
            d = entry.get('domain', '').strip().lower()
            if d and d not in processed_domains:
                final_list.append(entry)
                processed_domains.add(d)
        
        try:
            write_csv(final_list)
        except Exception as e:
            log.error("Failed to write domains.csv: %s", e)
            return jsonify({'status': 'error', 'message': 'Failed to save changes to disk. Check server logs.'}), 500
        return jsonify({'status': 'success'})

@api_bp.route('/dm-api/captchas', methods=['GET', 'POST'])
@login_required
def api_captchas():
    if request.method == 'GET':
        return jsonify(read_captcha_csv())
    
    if request.method == 'POST':
        data = request.json
        if not isinstance(data, list):
            return jsonify({'status': 'error', 'message': 'Expected a JSON array'}), 400

        seen_domains = {}
        duplicates = []
        for entry in data:
            if not entry.get('enabled', True):
                continue
            domain = entry.get('root_domain', '').strip().lower()
            if not domain:
                continue
            if domain in seen_domains:
                if domain not in duplicates:
                    duplicates.append(domain)
            seen_domains[domain] = True

        if duplicates:
            return jsonify({
                'status': 'error',
                'message': f'Duplicate root domains found: {", ".join(duplicates)}',
                'duplicates': duplicates
            }), 400

        try:
            domains_data = read_csv()
            active_root_domains = {get_root_domain(d['domain']).lower() for d in domains_data if d.get('enabled', True) and d.get('domain')}
            active_root_domains.add(get_root_domain(DOMAIN).lower())
        except Exception as e:
            log.error("Failed to read domains.csv during captcha validation: %s", e)
            active_root_domains = set()

        errors = []
        warnings = []
        entries_to_verify = []

        for entry in data:
            domain = entry.get('root_domain', '').strip().lower()
            
            domain_pattern = re.compile(r'^[a-zA-Z0-9][-a-zA-Z0-9\.]*\.[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$')
            if not domain or not domain_pattern.match(domain):
                errors.append(f"[{domain or 'Vacío'}] El dominio es inválido o está vacío.")
                continue

            if not entry.get('enabled', True):
                continue

            provider = entry.get('provider', '').strip().lower()
            site_key = entry.get('site_key', '').strip()
            secret_key = entry.get('secret_key', '').strip()

            has_structural_error = False

            if not validate_captcha_data(entry):
                errors.append(f"[{domain}] Faltan la Site Key o la Secret Key.")
                has_structural_error = True
                continue

            if domain not in active_root_domains:
                errors.append(f"[{domain}] El dominio no está configurado como activo en domains.csv.")
                has_structural_error = True

            if provider == 'turnstile':
                if not TURNSTILE_SITE_KEY_RE.match(site_key):
                    errors.append(f"[{domain}] Formato de Site Key inválido para Turnstile (debe empezar por 0x4 y tener de 18 a 33 caracteres).")
                    has_structural_error = True
                if not TURNSTILE_SECRET_KEY_RE.match(secret_key):
                    errors.append(f"[{domain}] Formato de Secret Key inválido para Turnstile (debe empezar por 0x4 y tener de 33 a 53 caracteres).")
                    has_structural_error = True
            elif provider == 'hcaptcha':
                if not HCAPTCHA_SITE_KEY_RE.match(site_key):
                    errors.append(f"[{domain}] La Site Key de hCaptcha debe tener un formato UUID válido.")
                    has_structural_error = True
                if not HCAPTCHA_SECRET_KEY_RE.match(secret_key):
                    errors.append(f"[{domain}] La Secret Key de hCaptcha debe ser un UUID o empezar con 0x y tener 40 caracteres hexadecimales.")
                    has_structural_error = True
            elif provider == 'recaptcha':
                if not RECAPTCHA_KEY_RE.match(site_key):
                    errors.append(f"[{domain}] Formato de Site Key inválido para reCAPTCHA.")
                    has_structural_error = True
                if not RECAPTCHA_KEY_RE.match(secret_key):
                    errors.append(f"[{domain}] Formato de Secret Key inválido para reCAPTCHA.")
                    has_structural_error = True

            if not has_structural_error:
                entries_to_verify.append((domain, provider, secret_key))

        if entries_to_verify:
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = {
                    executor.submit(verify_secret_key_online, provider, sec): (dom, provider)
                    for dom, provider, sec in entries_to_verify
                }
                for future in as_completed(futures):
                    dom, prov = futures[future]
                    try:
                        is_valid, err_msg = future.result()
                        if is_valid is False:
                            errors.append(f"[{dom}] Error en la clave secreta de {prov}: {err_msg}")
                        elif is_valid is None:
                            warnings.append(f"[{dom}] No se pudo verificar la clave secreta de {prov} online: {err_msg}")
                    except Exception as e:
                        warnings.append(f"[{dom}] Error al verificar la clave secreta de {prov}: {str(e)}")

        if errors:
            return jsonify({
                'status': 'error',
                'message': 'Falló la validación de claves CAPTCHA.',
                'errors': errors
            }), 400

        write_captcha_csv(data)
        return jsonify({
            'status': 'success',
            'warnings': warnings
        })

@api_bp.route('/dm-api/services', methods=['GET'])
@login_required
def api_services():
    try:
        final_list = get_external_services()
        return jsonify(final_list)
    except Exception as e:
        log.error(f"Error getting external services: {e}")
        return jsonify([])

def _resolve_expected_ip():
    host_domain = f"{DASHBOARD_SUBDOMAIN}.{DOMAIN}"
    expected_ip = resolve_domain(host_domain)
    if not expected_ip:
        if TRAEFIK_ACME_ENV_TYPE == 'local':
            if check_host_file(host_domain):
                return '127.0.0.1', None
            return None, {'status': 'error', 'message': f'Could not resolve host domain ({host_domain}) locally or in /etc/hosts'}
        return None, {'status': 'error', 'message': f'Could not resolve host domain ({host_domain})'}
    return expected_ip, None

def _check_single_domain(entry, expected_ip, services):
    domain_to_check = entry.get('domain', '').strip()
    redirection_to_check = entry.get('redirection', '').strip()
    service_to_check = entry.get('service_name', '').strip()
    anubis_subdomain = entry.get('anubis_subdomain', '').strip()

    result = {
        'status': 'match',
        'domain': {'status': 'match'},
        'redirection': {'status': 'skipped'},
        'service': {'status': 'found'},
        'anubis': {'status': 'skipped'},
    }

    if not domain_to_check:
        result['domain'] = {'status': 'error', 'message': 'Empty domain'}
        result['status'] = 'mismatch'
    else:
        actual_ip = resolve_domain(domain_to_check)
        if not actual_ip:
            if TRAEFIK_ACME_ENV_TYPE == 'local' and check_host_file(domain_to_check):
                actual_ip = expected_ip
            else:
                result['domain'] = {'status': 'error', 'message': 'Resolution failed'}
                result['status'] = 'mismatch'
        elif actual_ip != expected_ip:
            result['domain'] = {'status': 'mismatch', 'expected': expected_ip, 'actual': actual_ip}
            result['status'] = 'mismatch'

    if redirection_to_check:
        redir_ip = resolve_domain(redirection_to_check)
        if not redir_ip:
            if TRAEFIK_ACME_ENV_TYPE == 'local' and check_host_file(redirection_to_check):
                redir_ip = expected_ip
            else:
                result['redirection'] = {'status': 'error', 'message': 'Resolution failed'}
                result['status'] = 'mismatch'
        elif redir_ip != expected_ip:
            result['redirection'] = {'status': 'mismatch', 'expected': expected_ip, 'actual': redir_ip}
            result['status'] = 'mismatch'
        else:
            result['redirection']['status'] = 'match'

    if anubis_subdomain and domain_to_check:
        root_domain = get_root_domain(domain_to_check)
        if root_domain:
            anubis_full_domain = f"{anubis_subdomain}.{root_domain}"
            anubis_ip = resolve_domain(anubis_full_domain)
            if not anubis_ip:
                if TRAEFIK_ACME_ENV_TYPE == 'local' and check_host_file(anubis_full_domain):
                    anubis_ip = expected_ip
                else:
                    result['anubis'] = {'status': 'error', 'message': f'Resolution failed for {anubis_full_domain}'}
                    result['status'] = 'mismatch'
            elif anubis_ip != expected_ip:
                result['anubis'] = {'status': 'mismatch', 'expected': expected_ip, 'actual': anubis_ip}
                result['status'] = 'mismatch'
            else:
                result['anubis']['status'] = 'match'
        else:
            result['anubis'] = {'status': 'error', 'message': 'Invalid domain for Anubis check'}
            result['status'] = 'mismatch'

    if service_to_check:
        if service_to_check not in services:
            result['service'] = {'status': 'missing'}
            result['status'] = 'mismatch'

    return result


@api_bp.route('/dm-api/check-domain', methods=['POST'])
@limiter.exempt
@login_required
def check_domain():
    entry = request.json
    expected_ip, err = _resolve_expected_ip()
    if err:
        return jsonify({'status': 'error', 'domain': err,
                        'redirection': {'status': 'skipped'},
                        'service': {'status': 'found'},
                        'anubis': {'status': 'skipped'}})
    services = get_external_services()
    return jsonify(_check_single_domain(entry, expected_ip, services))


@api_bp.route('/dm-api/check-domains-batch', methods=['POST'])
@limiter.exempt
@login_required
def check_domains_batch():
    entries = request.json
    if not isinstance(entries, list):
        return jsonify({'error': 'Expected a JSON array of domain entries'}), 400

    expected_ip, err = _resolve_expected_ip()
    if err:
        error_result = {'status': 'error', 'domain': err,
                        'redirection': {'status': 'skipped'},
                        'service': {'status': 'found'},
                        'anubis': {'status': 'skipped'}}
        return jsonify([error_result] * len(entries))

    services = get_external_services()
    results = [None] * len(entries)
    max_workers = min(30, len(entries)) if entries else 1

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_idx = {
            executor.submit(_check_single_domain, entry, expected_ip, services): idx
            for idx, entry in enumerate(entries)
        }
        for future in as_completed(future_to_idx):
            idx = future_to_idx[future]
            try:
                results[idx] = future.result()
            except Exception as exc:
                log.error(f"Batch check error for index {idx}: {exc}")
                results[idx] = {
                    'status': 'error',
                    'domain': {'status': 'error', 'message': str(exc)},
                    'redirection': {'status': 'skipped'},
                    'service': {'status': 'found'},
                    'anubis': {'status': 'skipped'},
                }

    return jsonify(results)

@api_bp.route('/dm-api/apply-config-stream')
@login_required
def apply_config_stream():
    def generate():
        for candidate in ['.venv/bin/python3', 'venv/bin/python3', 'python3']:
            if candidate.startswith('python') or os.path.isfile(os.path.join(BASE_DIR, candidate)):
                python_cmd = candidate if candidate.startswith('python') else os.path.join(BASE_DIR, candidate)
                break
        else:
            python_cmd = 'python3'

        local_env = get_subprocess_env()

        process = subprocess.Popen(
            [python_cmd, GENERATE_CONFIG_SCRIPT],
            cwd=BASE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=local_env
        )

        for line in process.stdout:
            yield f"data: {line}\n\n"

        process.stdout.close()
        return_code = process.wait()
        yield f"data: [Process finished with code {return_code}]\n\n"

    return Response(generate(), mimetype='text/event-stream')

@api_bp.route('/dm-api/restart', methods=['POST'])
@login_required
def restart_stack():
    log.info("Initiating targeted stack restart...")
    try:
        subprocess.Popen(
            ['bash', RESTART_INTERNAL_SCRIPT],
            cwd=BASE_DIR,
            env=build_compose_env()
        )
        return jsonify({'status': 'success', 'message': 'Stack restart initiated'})
    except Exception as e:
        log.error(f"Failed to start restart script: {e}")
        return jsonify({'error': str(e)}), 500

@api_bp.route('/dm-api/restart-stream')
@login_required
def restart_stream():
    def generate():
        process = subprocess.Popen(
            ['bash', RESTART_INTERNAL_SCRIPT],
            cwd=BASE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=build_compose_env()
        )

        for line in process.stdout:
            yield f"data: {line}\n\n"

        process.stdout.close()
        return_code = process.wait()
        yield f"data: [Process finished with code {return_code}]\n\n"

    return Response(generate(), mimetype='text/event-stream')
