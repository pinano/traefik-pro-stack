<?php
/**
 * Custom dynamic server autodiscovery for phpMyAdmin.
 * Automatically scans the /userdata/projects folder for .env files,
 * extracts database credentials and project IDs to connect via the host gateway,
 * and sets up direct logins for each database.
 */

$projectsDir = '/userdata/projects';
$i = 0; // Initialize server index

// Helper function to parse .env file
if (!function_exists('parseEnvFile')) {
    function parseEnvFile($path) {
        $vars = [];
        $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if ($lines === false) return $vars;
        foreach ($lines as $line) {
            $line = trim($line);
            if (empty($line) || strpos($line, '#') === 0) {
                continue;
            }
            if (strpos($line, '=') !== false) {
                list($key, $value) = explode('=', $line, 2) + [null, null];
                if ($key !== null) {
                    $key = trim($key);
                    $value = trim($value);
                    // Strip wrapping quotes if any
                    $value = trim($value, " \t\n\r\0\x0B\"'");
                    $vars[$key] = $value;
                }
            }
        }
        return $vars;
    }
}

if (!function_exists('isDatabaseOnline')) {
    function isDatabaseOnline($host, $port) {
        // Fast TCP probe to check if the database is running and port is listening.
        // Connections to local IPs fail/succeed instantly, so 0.1s is sufficient.
        $connection = @fsockopen($host, $port, $errno, $errstr, 0.1);
        if (is_resource($connection)) {
            fclose($connection);
            return true;
        }
        return false;
    }
}

if (is_dir($projectsDir)) {
    $dirs = glob($projectsDir . '/*', GLOB_ONLYDIR);
    if ($dirs) {
        foreach ($dirs as $dir) {
            $envFile = $dir . '/.env';
            if (file_exists($envFile)) {
                $projectName = basename($dir);
                // Skip the infra stack directory itself
                if ($projectName === 'traefik' || $projectName === 'infra') {
                    continue;
                }
                
                $env = parseEnvFile($envFile);
                
                // 1. Resolve host mapped port (PROJECT_ID e.g. 100 -> 33100, or DB_PORT fallback)
                $projectId = $env['PROJECT_ID'] ?? null;
                $dbPort = null;
                if ($projectId !== null && is_numeric($projectId)) {
                    $dbPort = 33000 + (int)$projectId;
                } else {
                    // Fallback to explicit port if configured
                    $dbPort = $env['DB_PORT'] ?? $env['MYSQL_PORT'] ?? $env['DATABASE_PORT'] ?? $env['DB_HOST_PORT'] ?? $env['DATABASE_MYSQL_PORT'] ?? $env['DB_PORT_HOST'] ?? null;
                }
                
                if ($dbPort === null) {
                    error_log("phpMyAdmin autodiscovery: No database port resolved for project '$projectName'");
                    continue;
                }

                // Check if the database is online/reachable on host.docker.internal
                if (!isDatabaseOnline('host.docker.internal', $dbPort)) {
                    error_log("phpMyAdmin autodiscovery: Project '$projectName' database port $dbPort is OFFLINE or unreachable");
                    continue;
                }

                $resolvedHost = 'host.docker.internal';
                $resolvedPort = $dbPort;
                error_log("phpMyAdmin autodiscovery: Project '$projectName' database resolved to host.docker.internal:$dbPort - registering server");
                
                // Discover credentials
                // Check for Root User credentials
                $rootPass = $env['DB_ROOT_PASS'] ?? $env['DB_ROOT_PASSWORD'] ?? $env['MYSQL_ROOT_PASSWORD'] ?? $env['MYSQL_ROOT_PASS'] ?? null;
                
                // Check for regular User credentials
                $dbUser = $env['DB_USER'] ?? $env['MYSQL_USER'] ?? $env['DATABASE_USER'] ?? $env['DB_USERNAME'] ?? null;
                $dbPass = $env['DB_PASSWORD'] ?? $env['MYSQL_PASSWORD'] ?? $env['DATABASE_PASSWORD'] ?? $env['DB_PASS'] ?? null;
                $dbName = $env['DB_DATABASE'] ?? $env['MYSQL_DATABASE'] ?? $env['DATABASE_NAME'] ?? '';

                // Register server configuration: prioritize regular user, fall back to root, or use cookie auth prompt
                if ($dbUser !== null) {
                    $i++;
                    $cfg['Servers'][$i]['host'] = $resolvedHost;
                    $cfg['Servers'][$i]['port'] = $resolvedPort;
                    $cfg['Servers'][$i]['user'] = $dbUser;
                    if ($dbPass !== null) {
                        $cfg['Servers'][$i]['password'] = $dbPass;
                        $cfg['Servers'][$i]['auth_type'] = 'config';
                    } else {
                        $cfg['Servers'][$i]['auth_type'] = 'cookie';
                    }
                    $cfg['Servers'][$i]['verbose'] = $projectName . ($dbName ? " ($dbName)" : ' (user)');
                    $cfg['Servers'][$i]['compress'] = false;
                    $cfg['Servers'][$i]['AllowNoPassword'] = true;
                } elseif ($rootPass !== null) {
                    $i++;
                    $cfg['Servers'][$i]['host'] = $resolvedHost;
                    $cfg['Servers'][$i]['port'] = $resolvedPort;
                    $cfg['Servers'][$i]['user'] = 'root';
                    $cfg['Servers'][$i]['password'] = $rootPass;
                    $cfg['Servers'][$i]['auth_type'] = 'config';
                    $cfg['Servers'][$i]['verbose'] = $projectName . ' (root)';
                    $cfg['Servers'][$i]['compress'] = false;
                    $cfg['Servers'][$i]['AllowNoPassword'] = true;
                } else {
                    $i++;
                    $cfg['Servers'][$i]['host'] = $resolvedHost;
                    $cfg['Servers'][$i]['port'] = $resolvedPort;
                    $cfg['Servers'][$i]['user'] = 'root';
                    $cfg['Servers'][$i]['auth_type'] = 'cookie';
                    $cfg['Servers'][$i]['verbose'] = $projectName . ' (cookie)';
                    $cfg['Servers'][$i]['compress'] = false;
                    $cfg['Servers'][$i]['AllowNoPassword'] = true;
                }
            }
        }
    } else {
        error_log("phpMyAdmin autodiscovery: No subdirectories found in '$projectsDir'");
    }
} else {
    error_log("phpMyAdmin autodiscovery: Projects directory '$projectsDir' does not exist or is not readable");
}
