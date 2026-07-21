from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import os

_redis_pass = os.environ.get('REDIS_PASSWORD', '')
_limiter_storage = f"redis://:{_redis_pass}@redis:6379/2" if _redis_pass else "memory://"

limiter = Limiter(
    key_func=get_remote_address,
    default_limits=["200 per day", "50 per hour"],
    storage_uri=_limiter_storage,
    in_memory_fallback_enabled=True,
)
