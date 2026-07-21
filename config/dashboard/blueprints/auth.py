import os
import hmac
import secrets
import logging
from urllib.parse import urlparse
from functools import wraps
from flask import Blueprint, request, session, redirect, url_for, render_template, jsonify, Response, current_app
from extensions import limiter
from config import DOMAIN, DASHBOARD_SUBDOMAIN

log = logging.getLogger(__name__)

auth_bp = Blueprint('auth', __name__)

ADMIN_USER = os.environ.get('DASHBOARD_ADMIN_USER', 'admin')
ADMIN_PASS = os.environ.get('DASHBOARD_ADMIN_PASSWORD', 'admin')

def generate_csrf_token():
    if 'csrf_token' not in session:
        session['csrf_token'] = secrets.token_hex(32)
    return session['csrf_token']

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            if request.path.startswith('/dm-api/') or request.path == '/dm-api/restart-stream':
                return jsonify({'error': 'Unauthorized', 'message': 'Authentication required'}), 401
            return redirect(url_for('auth.login', next=request.path))
        return f(*args, **kwargs)
    return decorated_function

@auth_bp.before_app_request
def check_csrf():
    if request.endpoint == 'auth.login':
        return
    
    if request.method == "POST":
        token = (
            request.headers.get('X-CSRFToken')
            or request.form.get('csrf_token')
        )
        if not token or token != session.get('csrf_token'):
            return jsonify({'error': 'CSRF token missing or invalid'}), 403

    if request.endpoint in ('api.restart_stream', 'api.apply_config_stream', 'restart_stream', 'apply_config_stream'):
        token = request.args.get('csrf_token')
        if not token or token != session.get('csrf_token'):
            return jsonify({'error': 'CSRF token missing or invalid'}), 403

@auth_bp.app_context_processor
def inject_csrf_token():
    return dict(csrf_token=generate_csrf_token)

@auth_bp.route('/login', methods=['GET', 'POST'])
@limiter.limit("5 per minute")
def login():
    if request.method == 'POST':
        user = request.form.get('username', '')
        pw = request.form.get('password', '')
        
        next_url = request.form.get('next')
        if not next_url:
            next_url = request.headers.get('X-Replaced-Path')
        
        if not next_url and request.referrer:
            referrer = request.referrer
            if DOMAIN in referrer:
                try:
                    parsed = urlparse(referrer)
                    if parsed.path and parsed.path != '/login':
                        next_url = parsed.path
                except Exception:
                    pass
        
        user_ok = hmac.compare_digest(user, ADMIN_USER)
        pass_ok = hmac.compare_digest(pw, ADMIN_PASS)
        if user_ok and pass_ok:
            session.clear()
            session['logged_in'] = True
            session.permanent = (request.form.get('remember') == 'on')
            
            if next_url:
                parsed = urlparse(next_url)
                if parsed.scheme in ('', 'https', 'http') and not parsed.netloc and parsed.path.startswith('/'):
                    return redirect(next_url)
            
            return redirect(url_for('views.dashboard'))
        
        log.warning(f"SECURITY: Failed login attempt for user '{user}' from {request.remote_addr}")
        return render_template('login.html', error='Invalid credentials', domain=DOMAIN, dashboard_subdomain=DASHBOARD_SUBDOMAIN, next=next_url)
    
    next_url = request.args.get('next') or request.headers.get('X-Replaced-Path') or request.referrer
    if next_url and '/login' in next_url:
        next_url = None
    
    return render_template('login.html', domain=DOMAIN, dashboard_subdomain=DASHBOARD_SUBDOMAIN, next=next_url)

@auth_bp.route('/logout', methods=['POST'])
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('auth.login'))

@auth_bp.route('/auth-check')
@limiter.exempt
def auth_check():
    if session.get('logged_in'):
        resp = Response("OK", status=200)
        resp.headers['X-Webauth-User'] = ADMIN_USER
        resp.headers['X-Webauth-Role'] = 'Admin'
        return resp
    return Response("Unauthorized", status=401)
