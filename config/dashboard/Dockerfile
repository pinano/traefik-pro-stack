FROM python:3.11-alpine

WORKDIR /app

RUN pip install --no-cache-dir flask==3.0.0 PyYAML==6.0.1 tldextract==5.1.0 gunicorn==21.2.0 Flask-Limiter==3.5.0 Flask-WTF==1.2.1

COPY . .

# We will need docker to restart the stack, but actually we will call the host script
# So we might need docker client or just exec into the host via socket if possible
# To keep it simple, we assume the script can be run if we mount the socket and have docker cli
# Install dependencies and mkcert
RUN apk add --no-cache docker-cli docker-compose bash ncurses openssl nss wget && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then MKCERT_ARCH="amd64"; else MKCERT_ARCH="arm64"; fi && \
    wget -O /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-$MKCERT_ARCH && \
    chmod +x /usr/local/bin/mkcert

EXPOSE 5000

CMD ["gunicorn", "--workers", "1", "--threads", "4", "--timeout", "600", "--bind", "0.0.0.0:5000", "app:app"]
