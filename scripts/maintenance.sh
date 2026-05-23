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
    
    # Start the maintenance container explicitly and reload traefik
    echo "Starting maintenance container..."
    make rebuild
    make restart
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
    
    echo "Restarting stack to resume normal operations..."
    make rebuild
    make restart
    echo "✅ Maintenance Mode is now OFF."

else
    echo "Usage: make maintenance-on | make maintenance-off"
    exit 1
fi
