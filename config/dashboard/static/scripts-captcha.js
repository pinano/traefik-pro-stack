// State Management
let initialData = [];
let currentData = [];
let hasUnsavedChanges = false;
let currentSort = { column: 'root_domain', direction: 'asc' };
let confirmAction = 'delete';
let rowIdToDelete = null;

// Searchable Dropdown State
let allRootDomains = [];

// Selectors
const captchaBody = document.getElementById('captcha-body');
const saveBtn = document.getElementById('save-btn');
const deployBtn = document.getElementById('deploy-btn');
const searchInput = document.getElementById('search-input');
const unsavedBanner = document.getElementById('unsaved-notification');
const deployBanner = document.getElementById('deploy-notification');
const deployBannerText = document.getElementById('deploy-notification-text');
const restartModal = document.getElementById('restart-modal');
const logContainer = document.getElementById('log-container');
const closeModalBtn = document.getElementById('close-modal-btn');
const toastEl = document.getElementById('toast');


// Helper to manage body padding when fixed top banners are visible
function updateNotificationPadding() {
    const hasUnsaved = unsavedBanner.classList.contains('show');
    const hasDeploy = deployBanner.classList.contains('show');
    if (hasUnsaved || hasDeploy) {
        document.body.classList.add('has-notification');
    } else {
        document.body.classList.remove('has-notification');
    }
}

// Helper to get root domain
function getRootDomain(domain) {
    if (!domain) return '';
    const parts = domain.split('.');
    if (parts.length < 2) return domain;
    return parts.slice(-2).join('.');
}

// Event Listeners
document.addEventListener('DOMContentLoaded', () => {
    // Header Sticky Logic
    const header = document.querySelector('header');
    let headerSpacer = document.createElement('div');
    headerSpacer.className = 'header-spacer';
    header.after(headerSpacer);

    window.addEventListener('scroll', () => {
        if (window.innerWidth > 768) { // Only on desktop
            const stickyThreshold = 50;
            if (window.scrollY > stickyThreshold) {
                header.classList.add('header-scrolled');
                headerSpacer.style.display = 'block';
                headerSpacer.style.height = header.offsetHeight + 'px';
            } else {
                header.classList.remove('header-scrolled');
                headerSpacer.style.display = 'none';
            }
        } else {
            header.classList.remove('header-scrolled');
            headerSpacer.style.display = 'none';
        }
    });

    loadCaptchas();


    saveBtn.addEventListener('click', saveChanges);
    deployBtn.addEventListener('click', deployChanges);
    searchInput.addEventListener('input', handleSearch);

    // Sorting event listeners
    document.querySelectorAll('.sortable').forEach(th => {
        th.addEventListener('click', () => {
            const column = th.getAttribute('data-sort');
            handleSort(column);
        });
    });

    closeModalBtn.addEventListener('click', () => {
        restartModal.classList.remove('show');
    });

    // Confirmation modal buttons
    const confirmModal = document.getElementById('confirm-modal');
    const confirmModalTitle = document.getElementById('confirm-modal-title');
    const confirmMsg = document.getElementById('confirm-msg');
    const cancelConfirmBtn = document.getElementById('cancel-confirm-btn');
    const confirmDeleteBtn = document.getElementById('confirm-delete-btn');
    const confirmDeployBtn = document.getElementById('confirm-deploy-btn');

    cancelConfirmBtn.addEventListener('click', () => confirmModal.classList.remove('show'));

    // Help Modal Logic
    const helpBtn = document.getElementById('help-btn');
    const helpModal = document.getElementById('help-modal');
    const closeHelpBtn = document.getElementById('close-help-btn');
    const closeHelpFooterBtn = document.getElementById('close-help-footer-btn');

    if (helpBtn && helpModal) {
        helpBtn.addEventListener('click', () => {
            helpModal.classList.add('show');
        });
        const closeHelp = () => helpModal.classList.remove('show');
        if (closeHelpBtn) closeHelpBtn.addEventListener('click', closeHelp);
        if (closeHelpFooterBtn) closeHelpFooterBtn.addEventListener('click', closeHelp);
    }

    confirmDeleteBtn.addEventListener('click', () => {
        confirmModal.classList.remove('show');
        if (confirmAction === 'delete' && rowIdToDelete) {
            deleteRow(rowIdToDelete);
        } else if (confirmAction === 'permanent-delete' && rowIdToDelete) {
            permanentlyDeleteRow(rowIdToDelete);
        }
        rowIdToDelete = null;
    });

    confirmDeployBtn.addEventListener('click', () => {
        confirmModal.classList.remove('show');
        initiateStream(
            `/dm-api/apply-config-stream?csrf_token=${csrfToken}`,
            '✅ CAPTCHA configurations successfully applied in real-time!'
        );
    });

    deployBtn.addEventListener('click', () => {
        confirmModalTitle.textContent = 'Hot Reload — Zero Downtime';
        confirmMsg.textContent = 'This will regenerate the Traefik dynamic config and apply CAPTCHA settings in-place. No containers will be stopped — traffic continues uninterrupted.';
        confirmDeleteBtn.style.display = 'none';
        confirmDeployBtn.style.display = 'inline-flex';
        if (window.lucide) lucide.createIcons({ root: confirmModal });
        confirmModal.classList.add('show');
    });

    // Input changes event delegation
    captchaBody.addEventListener('input', (e) => {
        const input = e.target;
        const tr = input.closest('tr');
        
        // Clear error highlights on editing
        input.classList.remove('input-error');
        if (tr && !tr.querySelector('.input-error')) {
            tr.classList.remove('row-error');
        }

        if (!tr) return;
        const id = tr.dataset.id;
        const row = currentData.find(r => r._id === id);
        if (!row) return;

        if (input.classList.contains('site-key-input')) {
            row.site_key = input.value.trim();
            checkForChanges();
        } else if (input.classList.contains('secret-key-input')) {
            row.secret_key = input.value.trim();
            checkForChanges();
        }
    });

    captchaBody.addEventListener('change', (e) => {
        const input = e.target;
        const tr = input.closest('tr');
        
        // Clear error highlights on change
        input.classList.remove('input-error');
        if (tr && !tr.querySelector('.input-error')) {
            tr.classList.remove('row-error');
        }

        if (!tr) return;
        const id = tr.dataset.id;
        const row = currentData.find(r => r._id === id);
        if (!row) return;

        if (input.classList.contains('provider-select')) {
            row.provider = input.value;
            checkForChanges();
            renderTables();
        }
    });

    captchaBody.addEventListener('click', (e) => {
        const clearBtn = e.target.closest('.clear-keys-btn');
        if (clearBtn) {
            const tr = clearBtn.closest('tr');
            if (tr) {
                const id = tr.dataset.id;
                const row = currentData.find(r => r._id === id);
                if (row) {
                    row.site_key = '';
                    row.secret_key = '';
                    checkForChanges();
                    renderTables();
                }
            }
        }
    });
});

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

// Toast Helper
function showToast(message, type = 'success', errors = []) {
    toastEl.className = 'toast';
    if (type === 'danger') toastEl.classList.add('alert-danger');
    if (type === 'warning') toastEl.classList.add('alert-warning');
    
    let title = 'Notification';
    if (type === 'danger') title = 'Validation Error';
    else if (type === 'warning') title = 'Validation Warning';
    
    let html = `
        <div class="toast-header">
            <span>${title}</span>
            <button onclick="hideToast()" class="toast-close" title="Dismiss">&times;</button>
        </div>
        <div class="toast-body">
            <p>${escapeHtml(message)}</p>
    `;
    
    if (errors.length > 0) {
        html += '<ul class="error-list">';
        errors.forEach(err => {
            html += `<li>${escapeHtml(err)}</li>`;
        });
        html += '</ul>';
    }
    
    html += '</div>';
    toastEl.innerHTML = html;
    toastEl.classList.add('show');

    // Auto close after 5 seconds if not error or warning
    if (type !== 'danger' && type !== 'warning') {
        setTimeout(hideToast, 5000);
    }
}

window.hideToast = function() {
    toastEl.classList.remove('show');
}

// Load CAPTCHAs from API
async function loadCaptchas() {
    try {
        const domainsResponse = await fetch('/dm-api/domains');
        if (!domainsResponse.ok) throw new Error('Failed to fetch domains list');
        const domainsData = await domainsResponse.json();
        const roots = domainsData.filter(d => d.enabled).map(d => getRootDomain(d.domain)).filter(r => r && r.trim() !== '');
        
        // Ensure the dashboard's native root domain is always available
        const stackRoot = getRootDomain(stackDomain);
        if (stackRoot && stackRoot.trim() !== '') {
            roots.push(stackRoot);
        }

        allRootDomains = [...new Set(roots)].sort((a, b) => a.localeCompare(b));

        const response = await fetch('/dm-api/captchas');
        if (!response.ok) throw new Error('Failed to fetch data');
        const data = await response.json();

        currentData = [];
        const existingMap = new Map();
        data.forEach(d => {
            if (d.root_domain && d.enabled !== false) {
                existingMap.set(d.root_domain.toLowerCase(), d);
            }
        });

        allRootDomains.forEach(domain => {
            const existing = existingMap.get(domain);
            if (existing) {
                currentData.push({ ...existing, _id: crypto.randomUUID() });
                existingMap.delete(domain);
            } else {
                currentData.push({
                    _id: crypto.randomUUID(),
                    root_domain: domain,
                    provider: 'turnstile',
                    site_key: '',
                    secret_key: '',
                    enabled: true
                });
            }
        });

        existingMap.forEach((existing, domain) => {
            currentData.push({ ...existing, _id: crypto.randomUUID(), isOrphan: true });
        });

        initialData = JSON.parse(JSON.stringify(currentData));

        renderTables();
        checkForChanges();
        lucide.createIcons();
    } catch (err) {
        showToast('Error loading CAPTCHA keys: ' + err.message, 'danger');
    }
}

// Render active and deleted tables
function renderTables() {
    const query = searchInput.value.toLowerCase().trim();
    let sortedData = [...currentData];

    if (currentSort.column) {
        sortedData.sort((a, b) => {
            let valA = (a[currentSort.column] || '').toString().toLowerCase();
            let valB = (b[currentSort.column] || '').toString().toLowerCase();
            if (valA < valB) return currentSort.direction === 'asc' ? -1 : 1;
            if (valA > valB) return currentSort.direction === 'asc' ? 1 : -1;
            return 0;
        });
    }

    if (query) {
        sortedData = sortedData.filter(row => {
            return (row.root_domain || '').toLowerCase().includes(query) ||
                   (row.provider || '').toLowerCase().includes(query);
        });
    }

    document.querySelectorAll('.sortable').forEach(th => {
        th.classList.remove('asc', 'desc');
        const column = th.getAttribute('data-sort');
        if (column === currentSort.column) {
            th.classList.add(currentSort.direction);
        }
    });

    captchaBody.innerHTML = '';
    if (sortedData.length === 0) {
        captchaBody.innerHTML = `
            <tr>
                <td colspan="5" style="text-align: center; color: var(--text-muted); padding: 2rem;">
                    No CAPTCHA configurations found.
                </td>
            </tr>
        `;
    } else {
        sortedData.forEach((row) => {
            const tr = document.createElement('tr');
            tr.dataset.id = row._id;
            
            const orig = initialData.find(o => o._id === row._id);
            const isUnsaved = !orig || 
                               orig.provider !== row.provider || 
                               orig.site_key !== row.site_key || 
                               orig.secret_key !== row.secret_key;
                              
            const isConfigured = row.site_key && row.secret_key;

            if (isUnsaved) {
                tr.style.backgroundColor = 'rgba(245, 158, 11, 0.15)'; // Unsaved orange tint
            } else if (isConfigured) {
                tr.style.backgroundColor = 'rgba(16, 185, 129, 0.05)'; // Green tint
            } else {
                tr.style.backgroundColor = 'rgba(239, 68, 68, 0.05)'; // Red tint
            }

            const statusIcon = isConfigured ? 
                '<i data-lucide="shield-check" style="color: var(--success-color); min-width: 18px; min-height: 18px; width: 18px; height: 18px;"></i>' : 
                '<i data-lucide="shield-off" style="color: var(--danger-color); min-width: 18px; min-height: 18px; width: 18px; height: 18px;"></i>';
            const orphanLabel = row.isOrphan ? '<span style="color: var(--danger-color); font-size: 0.7rem; margin-left: 5px;">(Orphan)</span>' : '';

            tr.innerHTML = `
                <td data-label="Root Domain">
                    <div style="display: flex; align-items: center; gap: 8px;">
                        <div style="flex-shrink: 0; display: flex; align-items: center;">
                            ${statusIcon}
                        </div>
                        <span style="font-weight: 500; color: var(--text-color); word-break: break-word;">${escapeHtml(row.root_domain)}</span>
                        ${orphanLabel}
                    </div>
                </td>
                <td data-label="CAPTCHA Provider">
                    <select class="data-input provider-select">
                        <option value="turnstile" ${row.provider === 'turnstile' ? 'selected' : ''}>turnstile (Cloudflare)</option>
                        <option value="recaptcha" ${row.provider === 'recaptcha' ? 'selected' : ''}>recaptcha (Google)</option>
                        <option value="hcaptcha" ${row.provider === 'hcaptcha' ? 'selected' : ''}>hcaptcha</option>
                    </select>
                </td>
                <td data-label="Site Key">
                    <input type="text" class="data-input site-key-input" value="${escapeHtml(row.site_key)}" placeholder="Site Key">
                </td>
                <td data-label="Secret Key">
                    <input type="text" class="data-input secret-key-input" value="${escapeHtml(row.secret_key)}" placeholder="Secret Key">
                </td>
                <td data-label="Action" style="text-align: center;">
                    <button class="btn btn-danger btn-xs clear-keys-btn" title="Clear keys (Disable CAPTCHA)">
                        <i data-lucide="x-circle"></i>
                    </button>
                </td>
            `;
            captchaBody.appendChild(tr);
        });
    }

    lucide.createIcons();
}

// Check if current state differs from the last saved state
function checkForChanges() {
    let changed = false;

    for (const row of currentData) {
        const orig = initialData.find(o => o._id === row._id);
        if (!orig || 
            orig.provider !== row.provider ||
            orig.site_key !== row.site_key ||
            orig.secret_key !== row.secret_key) {
            changed = true;
            break;
        }
    }

    hasUnsavedChanges = changed;
    saveBtn.disabled = !changed;

    if (changed) {
        unsavedBanner.classList.add('show');
        deployBanner.classList.remove('show');
        deployBtn.disabled = true;
    } else {
        unsavedBanner.classList.remove('show');
    }
    updateNotificationPadding();
}

// Validation before save (only for active rows)
function validateData() {
    const errors = [];

    captchaBody.querySelectorAll('tr').forEach(tr => {
        tr.classList.remove('row-error');
        tr.querySelectorAll('.input-error').forEach(el => el.classList.remove('input-error'));
    });

    currentData.forEach((row, i) => {
        const dom = (row.root_domain || '').trim().toLowerCase();
        const tr = captchaBody.querySelector(`tr[data-id="${row._id}"]`);
        let rowHasError = false;
        
        // If both empty, it's valid (means disabled)
        if (!row.site_key.trim() && !row.secret_key.trim()) {
            return;
        }

        if (!row.site_key.trim()) {
            errors.push(`Row '${dom}': Site Key cannot be empty if Secret Key is provided.`);
            rowHasError = true;
            if (tr) {
                const input = tr.querySelector('.site-key-input');
                if (input) input.classList.add('input-error');
            }
        }
        if (!row.secret_key.trim()) {
            errors.push(`Row '${dom}': Secret Key cannot be empty if Site Key is provided.`);
            rowHasError = true;
            if (tr) {
                const input = tr.querySelector('.secret-key-input');
                if (input) input.classList.add('input-error');
            }
        }

        if (rowHasError && tr) {
            tr.classList.add('row-error');
        }
    });

    return errors;
}

// Build the payload for a single row to send to the API
function getCleanPayload(row) {
    return {
        root_domain: (row.root_domain || '').trim().toLowerCase(),
        provider:    (row.provider    || '').trim().toLowerCase(),
        site_key:    (row.site_key    || '').trim(),
        secret_key:  (row.secret_key  || '').trim(),
        enabled:     row.enabled !== false  // default true
    };
}

// Save back to CSV via POST
async function saveChanges() {
    const errors = validateData();
    if (errors.length > 0) {
        showToast('Validation failed. Please correct the errors below.', 'danger', errors);
        return;
    }

    saveBtn.disabled = true;
    saveBtn.innerHTML = '<i class="animate-spin" data-lucide="loader-2"></i> Saving...';
    lucide.createIcons();

    try {
        // Send all entries: active (enabled=true) + disabled (enabled=false)
        const payload = currentData.filter(r => r.site_key.trim() && r.secret_key.trim()).map(getCleanPayload);
        const response = await fetch('/dm-api/captchas', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRFToken': csrfToken
            },
            body: JSON.stringify(payload)
        });

        const result = await response.json();
        if (!response.ok) {
            // Apply server-side errors to rows/inputs
            if (result.errors && result.errors.length > 0) {
                result.errors.forEach(err => {
                    // Match pattern like "[domain] error description"
                    const match = err.match(/^\[([^\]]+)\]\s*(.*)$/);
                    if (match) {
                        const domain = match[1].trim().toLowerCase();
                        const msg = match[2];
                        
                        // Find row matching this domain
                        const row = currentData.find(r => (r.root_domain || '').trim().toLowerCase() === domain);
                        if (row) {
                            const tr = captchaBody.querySelector(`tr[data-id="${row._id}"]`);
                            if (tr) {
                                tr.classList.add('row-error');
                                
                                // Which field has the error?
                                if (msg.toLowerCase().includes('site key') || msg.toLowerCase().includes('sitekey')) {
                                    const siteKeyInput = tr.querySelector('.site-key-input');
                                    if (siteKeyInput) siteKeyInput.classList.add('input-error');
                                } else if (msg.toLowerCase().includes('secret key') || msg.toLowerCase().includes('secretkey') || msg.toLowerCase().includes('clave secreta')) {
                                    const secretKeyInput = tr.querySelector('.secret-key-input');
                                    if (secretKeyInput) secretKeyInput.classList.add('input-error');
                                } else if (msg.toLowerCase().includes('dominio') || msg.toLowerCase().includes('domain')) {
                                    const domainInput = tr.querySelector('.domain-input');
                                    if (domainInput) domainInput.classList.add('input-error');
                                } else {
                                    // Highlight both keys if unspecified
                                    tr.querySelectorAll('.data-input').forEach(el => el.classList.add('input-error'));
                                }
                            }
                        }
                    }
                });
            }

            // Apply duplicate domain errors if returned
            if (result.duplicates && result.duplicates.length > 0) {
                result.duplicates.forEach(domain => {
                    const matchedRows = currentData.filter(r => (r.root_domain || '').trim().toLowerCase() === domain.trim().toLowerCase());
                    matchedRows.forEach(row => {
                        const tr = captchaBody.querySelector(`tr[data-id="${row._id}"]`);
                        if (tr) {
                            tr.classList.add('row-error');
                            const domainInput = tr.querySelector('.domain-input');
                            if (domainInput) domainInput.classList.add('input-error');
                        }
                    });
                });
            }

            showToast(result.message || 'Failed to save changes', 'danger', result.errors || []);
            saveBtn.disabled = false;
            return;
        }

        if (result.warnings && result.warnings.length > 0) {
            showToast('Changes saved with warnings. Please review the connection issues below.', 'warning', result.warnings);
        } else {
            showToast('Changes saved successfully. The system is ready to apply configurations.', 'success');
        }

        // Remove the isNew flag from all saved entries
        initialData = JSON.parse(JSON.stringify(currentData));
        hasUnsavedChanges = false;
        
        unsavedBanner.classList.remove('show');
        deployBanner.classList.add('show');
        deployBannerText.textContent = "Changes saved. Ready to deploy.";
        deployBtn.disabled = false;
        updateNotificationPadding();
        
        renderTables();
    } catch (err) {
        showToast(err.message, 'danger');
        saveBtn.disabled = false;
    } finally {
        saveBtn.innerHTML = '<i data-lucide="save"></i> Save Changes';
        lucide.createIcons();
    }
}

// Deploy Changes: show confirmation modal first (wired in DOMContentLoaded)
function deployChanges() {
    // Handled entirely through the confirmDeployBtn listener in DOMContentLoaded.
    // This stub is kept as a no-op so any legacy references don't break.
}

/**
 * Launch a streaming SSE session and display output in the progress modal.
 * Mirrors the initiateStream() pattern used in the Domain Manager.
 *
 * @param {string} streamUrl  - Full SSE endpoint URL (must include csrf_token query param)
 * @param {string} successMsg - Message appended when the process exits with code 0
 */
function initiateStream(streamUrl, successMsg) {
    const restartModalTitle = document.getElementById('restart-modal-title');
    if (restartModalTitle) restartModalTitle.textContent = 'Hot Reload Config Progress';

    closeModalBtn.style.display = 'none';
    logContainer.textContent = 'Connecting...\n';
    restartModal.classList.add('show');

    // Hide the deploy banner while the stream is running
    deployBanner.classList.remove('show');
    deployBtn.disabled = true;
    updateNotificationPadding();

    const eventSource = new EventSource(streamUrl);

    eventSource.onmessage = (event) => {
        const line = event.data;

        if (line.trim() === '[Process finished with code 0]') {
            logContainer.textContent += `\n${successMsg}\n`;
            closeModalBtn.style.display = 'block';
            eventSource.close();
        } else if (line.includes('[Process finished with code')) {
            logContainer.textContent += `\n❌ ${line}\n`;
            closeModalBtn.style.display = 'block';
            deployBtn.disabled = false;
            eventSource.close();
        } else {
            logContainer.textContent += line + '\n';
        }
        logContainer.scrollTop = logContainer.scrollHeight;
    };

    eventSource.onerror = () => {
        logContainer.textContent += '\n\n🔄 Connection closed. This is expected as Traefik reloads the new configuration.\n✅ The stack should be up in a few seconds.';
        closeModalBtn.style.display = 'block';
        eventSource.close();
    };
}

// Search and Sorting handlers
function handleSearch() {
    renderTables();
}

function handleSort(column) {
    if (currentSort.column === column) {
        currentSort.direction = currentSort.direction === 'asc' ? 'desc' : 'asc';
    } else {
        currentSort.column = column;
        currentSort.direction = 'asc';
    }
    renderTables();
}

