#!/bin/sh

# Stack Health & System Resource Check Script
# Monitors container health, Valkey/Redis cache, disk space, and memory.
# Sends Telegram alerts on warnings/failures.

# Configuration
TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}"
TELEGRAM_RECIPIENT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}"
PROJECT_NAME="${PROJECT_NAME:-stack}"
REDIS_PASSWORD="${REDIS_PASSWORD}"
SERVER_DOMAIN="${SERVER_DOMAIN}"

# Thresholds
DISK_WARNING_THRESHOLD=90     # % disk usage
HOST_MEM_WARNING_THRESHOLD=95 # % host memory usage
CONTAINER_MEM_WARNING_THRESHOLD=90 # % container memory limit usage

# Colors for local logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "🖥️ Starting stack health and system check..."

# Guard: if Telegram credentials are not configured, degrade gracefully
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_RECIPIENT_ID" ]; then
    echo "⚠️  Warning: Telegram credentials not configured — alerts will be logged locally only."
    send_telegram() { echo "[TELEGRAM DISABLED] $1"; }
else
    send_telegram() {
        MSG="$1"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
            -d text="🖥️ *WATCHDOG - System Alert*%0A🌐 *${SERVER_DOMAIN}*%0A%0A${MSG}" \
            -d parse_mode="Markdown" > /dev/null
    }
fi

# Verify docker socket is available
if [ ! -S /var/run/docker.sock ]; then
    printf '%b\n' "${RED}❌ Error: Docker socket not available.${NC}"
    send_telegram "Docker socket is not available inside the watchdog container!%0A👉 *Action Required:* Verify that \`/var/run/docker.sock\` is correctly mounted in the watchdog service volume configuration."
    exit 1
fi

ERRORS=0
ALERTS=""

# ==========================================
# 1. Container Status & Health Check
# ==========================================
echo "📋 Checking container statuses and healthchecks..."

# Get all containers belonging to this compose project
CONTAINER_IDS=$(docker ps -a -q --filter "label=com.docker.compose.project=${PROJECT_NAME}")

if [ -z "$CONTAINER_IDS" ]; then
    printf '%b\n' "${YELLOW}⚠️ No containers found for project '${PROJECT_NAME}'.${NC}"
else
    # Cache file to track container restarts
    RESTART_CACHE="/tmp/watchdog_restarts.cache"
    NEW_RESTART_CACHE=$(mktemp)
    
    for cid in $CONTAINER_IDS; do
        # Inspect container details using jq to handle missing fields (like healthcheck) safely
        C_INFO=$(docker inspect "$cid" | jq -r '.[0] | [ .Name, .Config.Labels["com.docker.compose.service"], .State.Status, (.State.Health.Status // "none"), .RestartCount ] | join("|")' 2>/dev/null)
        if [ -z "$C_INFO" ] || [ "$C_INFO" = "|||none|" ]; then
            continue
        fi
        
        c_name=$(echo "$C_INFO" | cut -d'|' -f1 | sed 's/^\///')
        c_service=$(echo "$C_INFO" | cut -d'|' -f2)
        c_status=$(echo "$C_INFO" | cut -d'|' -f3)
        c_health=$(echo "$C_INFO" | cut -d'|' -f4)
        c_restarts=$(echo "$C_INFO" | cut -d'|' -f5)
        
        # Skip if container is invalid or was removed during execution
        if [ -z "$c_name" ] || [ -z "$c_status" ]; then
            continue
        fi
        
        # 1a. Check Running Status
        # Ignore ctop since it's run on-demand
        if [ "$c_service" != "ctop" ]; then
            if [ "$c_status" != "running" ]; then
                printf '%b\n' "${RED}❌ Container $c_name ($c_service) is NOT running! Status: $c_status${NC}"
                ALERTS="${ALERTS}• *Container Down*: \`${c_name}\` (service \`${c_service}\`) is *${c_status}*!%0A"
                ERRORS=$((ERRORS + 1))
            else
                # 1b. Check Health Status
                if [ "$c_health" = "unhealthy" ]; then
                    printf '%b\n' "${RED}❌ Container $c_name ($c_service) is UNHEALTHY!${NC}"
                    ALERTS="${ALERTS}• *Container Unhealthy*: \`${c_name}\` is *unhealthy*!%0A"
                    ERRORS=$((ERRORS + 1))
                else
                    printf '%b\n' "${GREEN}✅ Container $c_name is running ($c_status / health: $c_health)${NC}"
                fi
            fi
        fi
        
        # 1c. Monitor Restarts
        # Record restart count in new cache
        echo "${c_name}=${c_restarts}" >> "$NEW_RESTART_CACHE"
        
        # If cache exists, check if restart count increased
        if [ -f "$RESTART_CACHE" ]; then
            cached_restarts=$(grep "^${c_name}=" "$RESTART_CACHE" | cut -d'=' -f2)
            if [ -n "$cached_restarts" ]; then
                if [ "$c_restarts" -gt "$cached_restarts" ]; then
                    diff=$((c_restarts - cached_restarts))
                    printf '%b\n' "${YELLOW}⚠️ Container $c_name restarted $diff times since last check! Total restarts: $c_restarts${NC}"
                    ALERTS="${ALERTS}• *Container Restarted*: \`${c_name}\` restarted *${diff}* times! (Total: ${c_restarts})%0A"
                    ERRORS=$((ERRORS + 1))
                fi
            else
                # New container not previously seen with restarts
                if [ "$c_restarts" -gt 0 ]; then
                    printf '%b\n' "${YELLOW}⚠️ Container $c_name has restarted $c_restarts times (newly tracked)${NC}"
                    ALERTS="${ALERTS}• *Container Restarted*: \`${c_name}\` has *${c_restarts}* restarts!%0A"
                    ERRORS=$((ERRORS + 1))
                fi
            fi
        fi
    done
    
    # Save the new restart cache
    cat "$NEW_RESTART_CACHE" > "$RESTART_CACHE"
    rm -f "$NEW_RESTART_CACHE"
fi


# ==========================================
# 2. Redis/Valkey Health & Memory Check
# ==========================================
echo "📋 Checking Redis/Valkey cache health..."

REDIS_CONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=${PROJECT_NAME}" --filter "label=com.docker.compose.service=redis" | head -n 1)

if [ -z "$REDIS_CONTAINER" ]; then
    printf '%b\n' "${YELLOW}⚠️ Redis/Valkey container not found.${NC}"
else
    # Ping Redis
    PING_RES=$(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | tr -d '\r')
    if [ "$PING_RES" != "PONG" ]; then
        printf '%b\n' "${RED}❌ Redis is not responding to PING! Response: $PING_RES${NC}"
        ALERTS="${ALERTS}• *Redis Unresponsive*: Redis container is running but PING returned \`${PING_RES:-empty}\`!%0A"
        ERRORS=$((ERRORS + 1))
    else
        printf '%b\n' "${GREEN}✅ Redis PING OK${NC}"
        
        # Check memory
        REDIS_MEM_INFO=$(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$REDIS_CONTAINER" redis-cli info memory 2>/dev/null)
        if [ $? -eq 0 ]; then
            used_mem=$(echo "$REDIS_MEM_INFO" | grep "^used_memory:" | cut -d: -f2 | tr -d '\r')
            max_mem=$(echo "$REDIS_MEM_INFO" | grep "^maxmemory:" | cut -d: -f2 | tr -d '\r')
            
            if [ -n "$max_mem" ] && [ "$max_mem" -gt 0 ]; then
                mem_pct=$(( used_mem * 100 / max_mem ))
                used_human=$(echo "$REDIS_MEM_INFO" | grep "^used_memory_human:" | cut -d: -f2 | tr -d '\r')
                max_human=$(echo "$REDIS_MEM_INFO" | grep "^maxmemory_human:" | cut -d: -f2 | tr -d '\r')
                
                if [ $mem_pct -gt 90 ]; then
                    printf '%b\n' "${RED}❌ Redis memory usage is critical: $used_human / $max_human ($mem_pct%)${NC}"
                    ALERTS="${ALERTS}• *Redis OOM Warning*: Redis memory at *${mem_pct}%* (${used_human} / ${max_human})!%0A"
                    ERRORS=$((ERRORS + 1))
                else
                    printf '%b\n' "${GREEN}✅ Redis memory: $used_human / $max_human ($mem_pct%)${NC}"
                fi
            else
                printf '%b\n' "${GREEN}✅ Redis memory: $(echo "$REDIS_MEM_INFO" | grep "^used_memory_human:" | cut -d: -f2 | tr -d '\r') (no maxmemory configured)${NC}"
            fi
        else
            printf '%b\n' "${YELLOW}⚠️ Could not retrieve Redis memory metrics.${NC}"
        fi
    fi
fi


# ==========================================
# 3. System Resources (Disk Space & Host Memory)
# ==========================================
echo "📋 Checking host system resources..."

# 3a. Disk Space Check
DISK_PCT=$(df -h / | tail -n 1 | awk '{print $5}' | tr -d '% ')
PROJECT_DISK_PCT=$(df -h /domains.csv | tail -n 1 | awk '{print $5}' | tr -d '% ')

if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -gt "$DISK_WARNING_THRESHOLD" ]; then
    printf '%b\n' "${RED}❌ Disk space is running low on root (/): ${DISK_PCT}%${NC}"
    ALERTS="${ALERTS}• *Disk Space Critical*: Root partition (/) is at *${DISK_PCT}%* usage!%0A"
    ERRORS=$((ERRORS + 1))
else
    printf '%b\n' "${GREEN}✅ Disk space (root /): ${DISK_PCT}%${NC}"
fi

if [ -n "$PROJECT_DISK_PCT" ] && [ "$PROJECT_DISK_PCT" -gt "$DISK_WARNING_THRESHOLD" ] && [ "$PROJECT_DISK_PCT" != "$DISK_PCT" ]; then
    printf '%b\n' "${RED}❌ Disk space is running low on project partition: ${PROJECT_DISK_PCT}%${NC}"
    ALERTS="${ALERTS}• *Disk Space Critical*: Project directory partition is at *${PROJECT_DISK_PCT}%* usage!%0A"
    ERRORS=$((ERRORS + 1))
elif [ "$PROJECT_DISK_PCT" != "$DISK_PCT" ]; then
    printf '%b\n' "${GREEN}✅ Disk space (project): ${PROJECT_DISK_PCT}%${NC}"
fi

# 3b. Host Memory Check
TOTAL_MEM=$(free -m | grep Mem | awk '{print $2}')
AVAILABLE_MEM=$(free -m | grep Mem | awk '{print $7}')

if [ -n "$TOTAL_MEM" ] && [ -n "$AVAILABLE_MEM" ] && [ "$TOTAL_MEM" -gt 0 ]; then
    USED_PCT=$(( (TOTAL_MEM - AVAILABLE_MEM) * 100 / TOTAL_MEM ))
    if [ "$USED_PCT" -gt "$HOST_MEM_WARNING_THRESHOLD" ]; then
        printf '%b\n' "${RED}❌ Host memory is critical: ${USED_PCT}% usage (${AVAILABLE_MEM}MB available of ${TOTAL_MEM}MB)${NC}"
        ALERTS="${ALERTS}• *Host Memory Critical*: Using *${USED_PCT}%* of total ${TOTAL_MEM}MB memory! (available: ${AVAILABLE_MEM}MB)%0A"
        ERRORS=$((ERRORS + 1))
    else
        printf '%b\n' "${GREEN}✅ Host memory: ${USED_PCT}% usage (${AVAILABLE_MEM}MB available of ${TOTAL_MEM}MB)${NC}"
    fi
else
    printf '%b\n' "${YELLOW}⚠️ Could not parse host memory info.${NC}"
fi


# ==========================================
# 4. Container Memory Limits vs Usage Check
# ==========================================
echo "📋 Checking container memory usage against limits..."

if [ -n "$CONTAINER_IDS" ]; then
    STATS_FILE=$(mktemp /tmp/container_stats_XXXXXX)
    # Write stats to a temp file to avoid subshell scope issues.
    # Piping into 'while' would run it in a subshell, preventing ERRORS/ALERTS
    # from propagating back to the parent process.
    docker stats --no-stream --format "{{.Name}}|{{.MemPerc}}" $CONTAINER_IDS > "$STATS_FILE" 2>/dev/null

    if [ -s "$STATS_FILE" ]; then
        while IFS='|' read -r name perc; do
            [ -z "$name" ] && continue
            val=$(echo "$perc" | cut -d. -f1 | tr -d '% ')
            if [ -n "$val" ] && [ "$val" -gt "$CONTAINER_MEM_WARNING_THRESHOLD" ]; then
                printf '%b\n' "${RED}❌ Container $name is close to memory limit: $perc${NC}"
                ALERTS="${ALERTS}• *Container Memory Limit*: \`${name}\` is using *${perc}* of its memory limit!%0A"
                ERRORS=$((ERRORS + 1))
            fi
        done < "$STATS_FILE"
    fi
    rm -f "$STATS_FILE"
fi


# ==========================================
# 5. Send Alerts
# ==========================================
if [ $ERRORS -gt 0 ]; then
    printf '%b\n' "${RED}⚠️ Stack health check completed with $ERRORS warning/error conditions. Alert sending...${NC}"
    send_telegram "System checks detected the following issue(s):%0A%0A${ALERTS}👉 *Action Required:* Access the host to inspect docker compose services and system resources."
else
    printf '%b\n' "${GREEN}✅ Stack health check completed successfully. All parameters within bounds.${NC}"
fi

echo "🖥️ Stack health check finished."
