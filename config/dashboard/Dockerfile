FROM python:3.11-alpine

WORKDIR /app

# Install dependencies and mkcert (cached layer)
RUN apk add --no-cache docker-cli docker-compose bash ncurses openssl nss wget && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        MKCERT_ARCH="amd64" && \
        MKCERT_SHA256="6d31c65b03972c6dc4a14ab429f2928300518b26503f58723e532d1b0a3bbb52"; \
    else \
        MKCERT_ARCH="arm64" && \
        MKCERT_SHA256="b98f2cc69fd9147fe4d405d859c57504571adec0d3611c3eefd04107c7ac00d0"; \
    fi && \
    wget -O /usr/local/bin/mkcert "https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-$MKCERT_ARCH" && \
    echo "$MKCERT_SHA256  /usr/local/bin/mkcert" | sha256sum -c - && \
    chmod +x /usr/local/bin/mkcert

# Install pip packages (cached layer)
RUN pip install --no-cache-dir flask==3.0.0 PyYAML==6.0.1 tldextract==5.1.0 gunicorn==21.2.0 "Flask-Limiter[redis]==3.5.0" Flask-WTF==1.2.1 requests==2.32.3

# Copy application source code (frequently modified)
COPY . .

EXPOSE 5000

CMD ["gunicorn", "--workers", "1", "--threads", "4", "--timeout", "600", "--bind", "0.0.0.0:5000", "app:app"]
