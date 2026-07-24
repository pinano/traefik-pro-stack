/* 
 * Shared Utility Functions
 * Automatically extracted from dashboard scripts
 */

/** Calculate the root domain from a full domain string */
function getRootDomain(domain) {
    if (!domain) return '';
    const parts = domain.split('.');
    if (parts.length < 2) return domain;
    return parts.slice(-2).join('.');
}

/** Escape user/server-supplied strings before injecting them via innerHTML. */
function escapeHtml(str) {
    if (str == null) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/** Show a toast notification */
function showToast(message, type = 'info', persistent = false, details = []) {
    const toast = document.getElementById('toast');
    if (!toast) return;

    let content = '';

    if (persistent) {
        content += `
            <div class="toast-header">
                <span>Notification</span>
                <button class="toast-close" title="Dismiss">&times;</button>
            </div>`;
    }

    content += `<div class="toast-body">${escapeHtml(message)}`;

    if (details.length > 0) {
        content += `<ul class="error-list">`;
        details.forEach(detail => {
            content += `<li>${escapeHtml(detail)}</li>`;
        });
        content += `</ul>`;
    }

    content += `</div>`;

    toast.innerHTML = content;
    toast.className = `toast show alert-${type}`;

    const closeBtn = toast.querySelector('.toast-close');
    if (closeBtn) {
        closeBtn.onclick = () => toast.classList.remove('show');
    }

    if (!persistent) {
        setTimeout(() => toast.classList.remove('show'), 4000);
    }
}

/** Sanitize domain payload for API */
function getCleanPayload(domainObj) {
    return {
        domain: (domainObj.domain || '').trim().toLowerCase(),
        redirection: (domainObj.redirection || '').trim().toLowerCase(),
        service_name: (domainObj.service_name || '').trim(),
        anubis_subdomain: (domainObj.anubis_subdomain || '').trim().toLowerCase(),
        rate: (domainObj.rate || '').trim(),
        burst: (domainObj.burst || '').trim(),
        concurrency: (domainObj.concurrency || '').trim(),
        enabled: !!domainObj.enabled
    };
}

/** Close the help modal */
function closeHelp() {
    const helpModal = document.getElementById('help-modal');
    if (helpModal) {
        helpModal.classList.remove('show');
    }
}

/** Generic SSE stream launcher — used for both Soft Restart and Hot Reload */
function initiateStream(streamUrl, modalTitle, successMsg) {
    const restartModalTitle = document.getElementById('restart-modal-title');
    const restartModal = document.getElementById('restart-modal');
    const logContainer = document.getElementById('log-container');
    const closeModalBtn = document.getElementById('close-modal-btn');
    const deployNotification = document.getElementById('deploy-notification');
    const deployBtn = document.getElementById('deploy-btn');
    const deployBanner = document.getElementById('deploy-needed-banner');

    if (restartModalTitle) restartModalTitle.textContent = modalTitle;
    if (restartModal) restartModal.classList.add('show');
    if (logContainer) logContainer.textContent = 'Connecting...\n';
    if (closeModalBtn) closeModalBtn.style.display = 'none';

    // Hide notifications
    if (deployNotification) {
        deployNotification.classList.remove('show');
        deployNotification.classList.remove('is-restart');
    }
    document.body.classList.remove('has-notification');
    
    if (deployBtn) {
        deployBtn.classList.remove('btn-deploy-needed');
        deployBtn.classList.remove('is-restart');
        deployBtn.disabled = true;
        deployBtn.title = "Deployment in progress...";
    }
    
    if (deployBanner) {
        deployBanner.classList.remove('show');
    }

    if (typeof updateNotificationPadding === 'function') {
        updateNotificationPadding();
    }

    const eventSource = new EventSource(streamUrl);

    eventSource.onmessage = (event) => {
        const line = event.data;

        if (logContainer) {
            if (logContainer.textContent === 'Connecting...\n') {
                logContainer.textContent = '';
            }

            if (line.trim() === '[Process finished with code 0]') {
                logContainer.textContent += `\n${successMsg}\n`;
                if (closeModalBtn) closeModalBtn.style.display = 'block';
                eventSource.close();
            } else if (line.includes('[Process finished with code')) {
                logContainer.textContent += `\n❌ ${line}\n`;
                if (closeModalBtn) closeModalBtn.style.display = 'block';
                if (deployBtn) deployBtn.disabled = false;
                eventSource.close();
            } else {
                logContainer.textContent += line + '\n';
                if (logContainer.parentElement) {
                    logContainer.parentElement.scrollTop = logContainer.parentElement.scrollHeight;
                }
            }
        }
    };

    eventSource.onerror = () => {
        if (logContainer) logContainer.textContent += '\n\n🔄 Connection closed. This is expected as Traefik reloads the new configuration.\n✅ The stack should be up in a few seconds.';
        if (closeModalBtn) closeModalBtn.style.display = 'block';
        eventSource.close();
    };
}
