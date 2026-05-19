// State Management
let initialData = [];
let currentData = [];
let deletedData = [];
let hasUnsavedChanges = false;
let currentSort = { column: 'root_domain', direction: 'asc' };
let confirmAction = 'delete';
let rowIdToDelete = null;

// Searchable Dropdown State
let allRootDomains = [];
let activeDomainInput = null;
let highlightedDomainIndex = -1;

// Selectors
const captchaBody = document.getElementById('captcha-body');
const deletedCaptchaBody = document.getElementById('deleted-captcha-body');
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

const globalDomainDropdown = document.getElementById('global-domain-dropdown');

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

    document.getElementById('add-row-btn').addEventListener('click', () => addNewRow());
    document.getElementById('add-row-top-btn').addEventListener('click', () => addNewRow(true));
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
        } else if (input.classList.contains('domain-input')) {
            activeDomainInput = input;
            const filter = input.value;
            highlightedDomainIndex = filter ? 0 : -1;
            renderGlobalDomainDropdown(filter);
            updateGlobalDomainDropdownPosition();
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

    captchaBody.addEventListener('focusin', (e) => {
        if (e.target.classList.contains('domain-input')) {
            activeDomainInput = e.target;
            renderGlobalDomainDropdown('');
            updateGlobalDomainDropdownPosition();
        }
    });

    captchaBody.addEventListener('click', (e) => {
        const input = e.target;
        if (input.classList.contains('domain-input')) {
            activeDomainInput = input;
            renderGlobalDomainDropdown('');
            updateGlobalDomainDropdownPosition();
            return;
        }

        const deleteBtn = e.target.closest('.delete-row-btn');
        if (deleteBtn) {
            const tr = deleteBtn.closest('tr');
            if (tr) {
                const id = tr.dataset.id;
                const row = currentData.find(r => r._id === id);
                if (row) {
                    if (row.isNew) {
                        deleteRow(id);
                    } else {
                        rowIdToDelete = id;
                        confirmAction = 'delete';
                        confirmModalTitle.textContent = 'Confirm Deletion';
                        confirmMsg.textContent = `Are you sure you want to delete ${row.root_domain && !row.root_domain.startsWith('new-domain-') ? row.root_domain : 'this record'}?`;
                        confirmDeleteBtn.textContent = 'Delete';
                        confirmDeleteBtn.style.display = 'inline-flex';
                        confirmDeployBtn.style.display = 'none';
                        if (window.lucide) lucide.createIcons({ root: confirmModal });
                        confirmModal.classList.add('show');
                    }
                }
            }
        }
    });

    captchaBody.addEventListener('focusout', (e) => {
        if (e.target.classList.contains('domain-input')) {
            const input = e.target;
            setTimeout(() => {
                validateDomainInput(input);
                if (activeDomainInput === input) {
                    globalDomainDropdown.classList.remove('show');
                    activeDomainInput = null;
                }
            }, 200);
        }
    });

    captchaBody.addEventListener('keydown', (e) => {
        if (e.target.classList.contains('domain-input')) {
            if (!globalDomainDropdown.classList.contains('show')) return;

            const items = globalDomainDropdown.querySelectorAll('.dropdown-item');
            if (items.length === 0) return;

            if (e.key === 'ArrowDown') {
                e.preventDefault();
                highlightedDomainIndex = (highlightedDomainIndex + 1) % items.length;
                updateDomainDropdownHighlight(items);
            } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                highlightedDomainIndex = (highlightedDomainIndex - 1 + items.length) % items.length;
                updateDomainDropdownHighlight(items);
            } else if (e.key === 'Enter') {
                e.preventDefault();
                if (highlightedDomainIndex >= 0 && highlightedDomainIndex < items.length) {
                    items[highlightedDomainIndex].dispatchEvent(new MouseEvent('mousedown'));
                } else if (items.length > 0) {
                    items[0].dispatchEvent(new MouseEvent('mousedown'));
                }
            } else if (e.key === 'Escape') {
                globalDomainDropdown.classList.remove('show');
                activeDomainInput = null;
            }
        }
    });

    deletedCaptchaBody.addEventListener('click', (e) => {
        const restoreBtn = e.target.closest('.restore-row-btn');
        if (restoreBtn) {
            const tr = restoreBtn.closest('tr');
            if (tr) restoreRow(tr.dataset.id);
        }

        const permanentDeleteBtn = e.target.closest('.permanent-delete-btn');
        if (permanentDeleteBtn) {
            const tr = permanentDeleteBtn.closest('tr');
            if (tr) {
                const id = tr.dataset.id;
                const row = deletedData.find(r => r._id === id);
                rowIdToDelete = id;
                confirmAction = 'permanent-delete';
                confirmModalTitle.textContent = 'Confirm Permanent Deletion';
                confirmMsg.textContent = `Are you sure you want to PERMANENTLY delete ${row ? row.root_domain : 'this record'}? This cannot be undone.`;
                confirmDeleteBtn.textContent = 'Delete';
                confirmDeleteBtn.style.display = 'inline-flex';
                confirmDeployBtn.style.display = 'none';
                if (window.lucide) lucide.createIcons({ root: confirmModal });
                confirmModal.classList.add('show');
            }
        }
    });

    // Close global dropdown when clicking outside
    document.addEventListener('click', (e) => {
        if (activeDomainInput && !activeDomainInput.contains(e.target) && !globalDomainDropdown.contains(e.target)) {
            globalDomainDropdown.classList.remove('show');
            activeDomainInput = null;
        }
    });

    // Reposition on window resize
    window.addEventListener('resize', () => {
        if (globalDomainDropdown.classList.contains('show')) {
            updateGlobalDomainDropdownPosition();
        } else {
            activeDomainInput = null;
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
        // Fetch domains first to get all root domains from domains.csv
        const domainsResponse = await fetch('/dm-api/domains');
        if (!domainsResponse.ok) throw new Error('Failed to fetch domains list');
        const domainsData = await domainsResponse.json();
        // Ignore commented/disabled domains
        const roots = domainsData.filter(d => d.enabled).map(d => getRootDomain(d.domain)).filter(r => r && r.trim() !== '');
        allRootDomains = [...new Set(roots)].sort((a, b) => a.localeCompare(b));

        const response = await fetch('/dm-api/captchas');
        if (!response.ok) throw new Error('Failed to fetch data');
        const data = await response.json();

        // Assign internal IDs and split into active / disabled
        data.forEach(d => { if (!d._id) d._id = crypto.randomUUID(); });

        currentData = data.filter(d => d.enabled !== false);
        deletedData  = data.filter(d => d.enabled === false);

        initialData = JSON.parse(JSON.stringify(data)); // Full snapshot (active + disabled)

        renderTables();
        checkForChanges();
        lucide.createIcons();
    } catch (err) {
        showToast('Error loading CAPTCHA keys: ' + err.message, 'danger');
    }
}

// Render active and deleted tables
function renderTables() {
    // 1. Sort active data
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

    // 2. Filter active data based on search
    if (query) {
        sortedData = sortedData.filter(row => {
            return (row.root_domain || '').toLowerCase().includes(query) ||
                   (row.provider || '').toLowerCase().includes(query);
        });
    }

    // Update Sorting Headers
    document.querySelectorAll('.sortable').forEach(th => {
        th.classList.remove('asc', 'desc');
        const column = th.getAttribute('data-sort');
        if (column === currentSort.column) {
            th.classList.add(currentSort.direction);
        }
    });

    // Render active rows
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
            
            // Check if row has unsaved modifications
            const orig = initialData.find(o => o._id === row._id || o.root_domain === row.root_domain);
            const isUnsaved = !orig || 
                               orig.provider !== row.provider || 
                               orig.site_key !== row.site_key || 
                               orig.secret_key !== row.secret_key ||
                               orig.root_domain !== row.root_domain;
                              
            if (isUnsaved) {
                tr.style.backgroundColor = 'rgba(245, 158, 11, 0.08)'; // Unsaved orange tint
            }

            const visibleDomain = (row.root_domain || '').startsWith('new-domain-') ? '' : row.root_domain;

            tr.innerHTML = `
                <td data-label="Root Domain">
                    <input type="text" class="data-input domain-input" value="${escapeHtml(visibleDomain)}" placeholder="example.com" autocomplete="off">
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
                    <button class="btn btn-danger btn-xs delete-row-btn" title="Delete record">
                        <i data-lucide="trash-2"></i>
                    </button>
                </td>
            `;
            captchaBody.appendChild(tr);
        });
    }

    // Render deleted rows
    deletedCaptchaBody.innerHTML = '';
    if (deletedData.length === 0) {
        deletedCaptchaBody.innerHTML = `
            <tr>
                <td colspan="5" style="text-align: center; color: var(--text-muted); padding: 1rem;">
                    No disabled CAPTCHA keys.
                </td>
            </tr>
        `;
    } else {
        deletedData.forEach(row => {
            const tr = document.createElement('tr');
            tr.dataset.id = row._id;
            tr.innerHTML = `
                <td data-label="Root Domain"><input type="text" class="data-input" value="${escapeHtml(row.root_domain)}" disabled></td>
                <td data-label="CAPTCHA Provider"><input type="text" class="data-input" value="${escapeHtml(row.provider)}" disabled></td>
                <td data-label="Site Key"><input type="text" class="data-input" value="${escapeHtml(row.site_key)}" disabled></td>
                <td data-label="Secret Key"><input type="text" class="data-input" value="${escapeHtml(row.secret_key)}" disabled></td>
                <td data-label="Action" style="text-align: center;">
                    <div style="display: flex; gap: 0.25rem; justify-content: center;">
                        <button class="btn btn-success btn-xs restore-row-btn" title="Restore record">
                            <i data-lucide="rotate-ccw"></i>
                        </button>
                        <button class="btn btn-danger btn-xs permanent-delete-btn" title="Delete permanently">
                            <i data-lucide="trash-2"></i>
                        </button>
                    </div>
                </td>
            `;
            deletedCaptchaBody.appendChild(tr);
        });
    }

    lucide.createIcons();
}

// Add a brand new empty row
function addNewRow(atTop = false) {
    // Reset active sort so the top/bottom placement is preserved visually
    currentSort.column = null;
    currentSort.direction = 'asc';

    const tempDomain = `new-domain-${Date.now()}.com`;
    const newEntry = {
        _id: crypto.randomUUID(),
        root_domain: tempDomain,
        provider: 'turnstile',
        site_key: '',
        secret_key: '',
        enabled: true,
        isNew: true
    };

    if (atTop) {
        currentData.unshift(newEntry);
    } else {
        currentData.push(newEntry);
    }

    renderTables();
    checkForChanges();

    // Focus the newly added row's domain input and scroll it into view
    setTimeout(() => {
        const tr = captchaBody.querySelector(`tr[data-id="${newEntry._id}"]`);
        if (tr) {
            const input = tr.querySelector('.domain-input');
            if (input) {
                input.focus();
                input.select();
            }
            tr.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
    }, 50);
}

// Soft-delete: mark as disabled and move to deletedData
// New (unsaved) rows are discarded immediately without moving to deleted list
function deleteRow(id) {
    const rowIndex = currentData.findIndex(r => r._id === id);
    if (rowIndex > -1) {
        const row = currentData.splice(rowIndex, 1)[0];
        if (!row.isNew) {
            row.enabled = false;
            deletedData.push(row);
        }
        renderTables();
        checkForChanges();
    }
}

// Restore: re-enable and move back to currentData
function restoreRow(id) {
    const rowIndex = deletedData.findIndex(r => r._id === id);
    if (rowIndex > -1) {
        const row = deletedData.splice(rowIndex, 1)[0];
        row.enabled = true;
        currentData.push(row);
        renderTables();
        checkForChanges();
    }
}

// Permanently remove from deletedData (won't be written to CSV)
function permanentlyDeleteRow(id) {
    const rowIndex = deletedData.findIndex(r => r._id === id);
    if (rowIndex > -1) {
        deletedData.splice(rowIndex, 1);
        renderTables();
        checkForChanges();
    }
}

// Check if current state differs from the last saved state
function checkForChanges() {
    let changed = false;

    // Compare active + disabled counts against initial snapshot
    const totalNow = currentData.length + deletedData.length;
    const totalInit = initialData.length;

    if (totalNow !== totalInit) {
        changed = true;
    } else {
        // Check if any active row changed
        for (const row of currentData) {
            const orig = initialData.find(o => o._id === row._id);
            if (!orig || orig.enabled === false) { changed = true; break; }
            if (orig.provider !== row.provider ||
                orig.site_key !== row.site_key ||
                orig.secret_key !== row.secret_key ||
                orig.root_domain !== row.root_domain) { changed = true; break; }
        }
        // Check if disabled list changed
        if (!changed) {
            for (const row of deletedData) {
                const orig = initialData.find(o => o._id === row._id);
                if (!orig || orig.enabled !== false) { changed = true; break; }
            }
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

    // Clear previous error highlighting
    captchaBody.querySelectorAll('tr').forEach(tr => {
        tr.classList.remove('row-error');
        tr.querySelectorAll('.input-error').forEach(el => el.classList.remove('input-error'));
    });

    currentData.forEach((row, i) => {
        const dom = (row.root_domain || '').trim().toLowerCase();
        const tr = captchaBody.querySelector(`tr[data-id="${row._id}"]`);
        let rowHasError = false;

        if (!dom || dom.includes('new-domain-')) {
            errors.push(`Row ${i + 1}: Root Domain is required.`);
            rowHasError = true;
            if (tr) {
                const input = tr.querySelector('.domain-input');
                if (input) input.classList.add('input-error');
            }
        } else if (!dom.includes('.') || dom.includes(' ') || dom.startsWith('.') || dom.endsWith('.')) {
            errors.push(`Row ${i + 1} ('${dom}'): Domain format is invalid. Must be a root domain (e.g. example.com).`);
            rowHasError = true;
            if (tr) {
                const input = tr.querySelector('.domain-input');
                if (input) input.classList.add('input-error');
            }
        }

        if (!row.site_key || !row.site_key.trim()) {
            errors.push(`Row ${i + 1} ('${dom}'): Site Key cannot be empty.`);
            rowHasError = true;
            if (tr) {
                const input = tr.querySelector('.site-key-input');
                if (input) input.classList.add('input-error');
            }
        }
        if (!row.secret_key || !row.secret_key.trim()) {
            errors.push(`Row ${i + 1} ('${dom}'): Secret Key cannot be empty.`);
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
        const payload = [...currentData, ...deletedData].map(getCleanPayload);
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
        currentData.forEach(r => { delete r.isNew; });
        deletedData.forEach(r => { delete r.isNew; });

        // Rebuild initialData from both lists as the new baseline
        initialData = JSON.parse(JSON.stringify([...currentData, ...deletedData]));
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

// Dynamic Search Dropdown Handlers
function renderGlobalDomainDropdown(filter = '') {
    if (!activeDomainInput) return;

    const filtered = allRootDomains.filter(d => d.toLowerCase().includes(filter.toLowerCase()));
    globalDomainDropdown.innerHTML = '';

    if (filtered.length === 0) {
        globalDomainDropdown.classList.remove('show');
        return;
    }

    // Clamp index if filtered list changed
    if (highlightedDomainIndex >= filtered.length) highlightedDomainIndex = filtered.length - 1;
    if (highlightedDomainIndex < 0 && filtered.length > 0 && filter) highlightedDomainIndex = 0;

    filtered.forEach((domain, index) => {
        const item = document.createElement('div');
        item.className = 'dropdown-item';
        if (index === highlightedDomainIndex) item.classList.add('selected');
        item.textContent = domain;
        
        // Use mousedown to ensure it fires before blur
        item.addEventListener('mousedown', (e) => {
            e.preventDefault(); // Prevent focus loss immediately
            activeDomainInput.value = domain;
            
            const tr = activeDomainInput.closest('tr');
            const id = tr.dataset.id;
            const row = currentData.find(r => r._id === id);
            if (row) {
                // Prevent duplicate root domains in captcha config
                if (currentData.some(r => r.root_domain === domain && r !== row)) {
                    activeDomainInput.value = '';
                    row.root_domain = '';
                    showToast(`Domain '${domain}' is already configured.`, 'danger');
                } else {
                    row.root_domain = domain;
                }
            }
            checkForChanges();
            renderTables();

            globalDomainDropdown.classList.remove('show');
            activeDomainInput = null;
        });
        globalDomainDropdown.appendChild(item);
    });

    globalDomainDropdown.classList.add('show');
}

function updateGlobalDomainDropdownPosition() {
    if (!activeDomainInput || !globalDomainDropdown.classList.contains('show')) return;
    const rect = activeDomainInput.getBoundingClientRect();
    globalDomainDropdown.style.top = `${rect.bottom + window.scrollY}px`;
    globalDomainDropdown.style.left = `${rect.left + window.scrollX}px`;
    globalDomainDropdown.style.width = `${rect.width}px`;
}

function updateDomainDropdownHighlight(items) {
    items.forEach((item, index) => {
        if (index === highlightedDomainIndex) {
            item.classList.add('selected');
            item.scrollIntoView({ block: 'nearest' });
        } else {
            item.classList.remove('selected');
        }
    });
}

function validateDomainInput(input) {
    const tr = input.closest('tr');
    if (!tr) return;
    const id = tr.dataset.id;
    const val = input.value.trim().toLowerCase();

    const row = currentData.find(r => r._id === id);
    if (!row) return;

    // Use row.root_domain as the last valid value since it only updates on successful selection
    const lastValid = row.root_domain || '';

    if (val === '') {
        row.root_domain = '';
        input.value = '';
    } else if (allRootDomains.length > 0 && !allRootDomains.includes(val)) {
        // Revert to last valid value
        input.value = lastValid.startsWith('new-domain-') ? '' : lastValid;
        row.root_domain = lastValid;
        showToast('Please select a valid root domain from domains.csv', 'danger');
    } else {
        // Prevent duplicate root domains in captcha config
        if (currentData.some(r => r.root_domain === val && r !== row)) {
            input.value = lastValid.startsWith('new-domain-') ? '' : lastValid;
            row.root_domain = lastValid;
            showToast(`Domain '${val}' is already configured.`, 'danger');
        } else {
            row.root_domain = val;
        }
    }
    checkForChanges();
    renderTables();
}
