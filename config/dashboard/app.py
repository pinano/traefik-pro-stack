import os
import logging
from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix
from extensions import limiter
from blueprints.auth import auth_bp
from blueprints.views import views_bp
from blueprints.api import api_bp
from config import BASE_DIR, APP_VERSION

log = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get('FLASK_SECRET_KEY') or os.environ.get('DASHBOARD_SECRET_KEY') or os.urandom(32).hex()

app.config.update(
    SESSION_COOKIE_NAME='dashboard_session',
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_SAMESITE='Lax',
    PERMANENT_SESSION_LIFETIME=604800,
    SESSION_COOKIE_PATH='/',
    MAX_CONTENT_LENGTH=1 * 1024 * 1024,
)

limiter.init_app(app)

app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

@app.context_processor
def inject_version():
    app_path = os.getenv('DASHBOARD_APP_PATH_HOST', '/app')
    maintenance_active = os.path.exists(os.path.join(app_path, 'config', '.maintenance_mode'))
    return dict(app_version=APP_VERSION, maintenance_active=maintenance_active)

@app.after_request
def set_security_headers(response):
    response.headers.setdefault('X-Content-Type-Options', 'nosniff')
    response.headers.setdefault('X-Frame-Options', 'DENY')
    response.headers.setdefault('Referrer-Policy', 'strict-origin-when-cross-origin')
    response.headers.setdefault(
        'Content-Security-Policy',
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline' https://unpkg.com; "
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "font-src 'self' https://fonts.gstatic.com; "
        "img-src 'self' data:; "
        "connect-src 'self' https://raw.githubusercontent.com https://unpkg.com; "
        "frame-ancestors 'none';"
    )
    return response

app.register_blueprint(auth_bp)
app.register_blueprint(views_bp)
app.register_blueprint(api_bp)

if __name__ == '__main__':
    log.debug(f"Startup - URL Map: {app.url_map}")
    app.run(host='0.0.0.0', port=5000)
