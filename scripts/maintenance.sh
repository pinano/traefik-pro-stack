#!/bin/bash
set -e

ACTION=$1

if [ "$ACTION" == "on" ]; then
    if [ -f ".maintenance_mode" ]; then
        echo "Status: Maintenance mode is already ON."
        exit 0
    fi
    echo "Enabling Maintenance Mode..."
    touch .maintenance_mode
    
    # Load environment
    if [ -f .env ]; then
        set -a
        source .env
        set +a
    fi
    source scripts/compose-files.sh
    DOCKER_COMPOSE="docker compose -p ${PROJECT_NAME:-traefik-stack} $COMPOSE_FILES"
    
    # Start the maintenance container explicitly
    echo "Starting maintenance container..."
    $DOCKER_COMPOSE up -d maintenance
    echo "✅ Maintenance Mode is now ON."
    echo "All traffic (except for DOMAIN) is being redirected to the maintenance page."

elif [ "$ACTION" == "off" ]; then
    if [ ! -f ".maintenance_mode" ]; then
        echo "Status: Maintenance mode is already OFF."
        exit 0
    fi
    echo "Disabling Maintenance Mode..."
    rm .maintenance_mode
    
    # We must explicitly stop the maintenance container since compose might not clean it up
    # just by omitting it from the COMPOSE_FILES list.
    DOCKER_COMPOSE="docker compose -p ${PROJECT_NAME:-traefik-stack} -f docker-compose-maintenance.yaml"
    $DOCKER_COMPOSE down || true
    
    echo "✅ Maintenance Mode is now OFF. Traefik will instantly restore normal routing."

else
    echo "Usage: make maintenance-on | make maintenance-off"
    exit 1
fi
