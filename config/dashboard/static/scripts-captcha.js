// State Management
let initialData = [];
let currentData = [];
let deletedData = [];
let hasUnsavedChanges = false;
let currentSort = { column: 'root_domain', direction: 'asc' };

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

// Helper to get root domain
function getRootDomain(domain) {
    if (!domain) return '';
    const parts = domain.split('.');
    if (parts.length < 2) return domain;
    return parts.slice(-2).join('.');
}

// Event Listeners
document.addEventListener('DOMContentLoaded', () => {
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

    // Input changes event delegation
    captchaBody.addEventListener('input', (e) => {
        const input = e.target;
        const tr = input.closest('tr');
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
                deleteRow(id);
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
            if (tr) {
                const id = tr.dataset.id;
                restoreRow(id);
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

// Toast Helper
function showToast(message, type = 'success', errors = []) {
    toastEl.className = 'toast';
    if (type === 'danger') toastEl.classList.add('alert-danger');
    
    let html = `
        <div class="toast-header">
            <span>${type === 'danger' ? 'Validation Error' : 'Notification'}</span>
            <button onclick="hideToast()" class="toast-close" title="Dismiss">&times;</button>
        </div>
        <div class="toast-body">
            <p>${message}</p>
    `;
    
    if (errors.length > 0) {
        html += '<ul class="error-list">';
        errors.forEach(err => {
            html += `<li>${err}</li>`;
        });
        html += '</ul>';
    }
    
    html += '</div>';
    toastEl.innerHTML = html;
    toastEl.classList.add('show');

    // Auto close after 5 seconds if not error
    if (type !== 'danger') {
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
        
        // Assign internal IDs
        data.forEach(d => {
            if (!d._id) d._id = crypto.randomUUID();
        });

        initialData = JSON.parse(JSON.stringify(data)); // Deep clone
        currentData = JSON.parse(JSON.stringify(data));
        deletedData = [];
        
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
                <td>
                    <input type="text" class="data-input domain-input" value="${visibleDomain}" placeholder="example.com" autocomplete="off">
                </td>
                <td>
                    <select class="data-input provider-select">
                        <option value="turnstile" ${row.provider === 'turnstile' ? 'selected' : ''}>turnstile (Cloudflare)</option>
                        <option value="recaptcha" ${row.provider === 'recaptcha' ? 'selected' : ''}>recaptcha (Google)</option>
                        <option value="hcaptcha" ${row.provider === 'hcaptcha' ? 'selected' : ''}>hcaptcha</option>
                    </select>
                </td>
                <td>
                    <input type="text" class="data-input site-key-input" value="${row.site_key}" placeholder="Site Key">
                </td>
                <td>
                    <input type="text" class="data-input secret-key-input" value="${row.secret_key}" placeholder="Secret Key">
                </td>
                <td style="text-align: center;">
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
                    No deleted keys in this session.
                </td>
            </tr>
        `;
    } else {
        deletedData.forEach(row => {
            const tr = document.createElement('tr');
            tr.dataset.id = row._id;
            tr.innerHTML = `
                <td><input type="text" class="data-input" value="${row.root_domain}" disabled></td>
                <td><input type="text" class="data-input" value="${row.provider}" disabled></td>
                <td><input type="text" class="data-input" value="${row.site_key}" disabled></td>
                <td><input type="text" class="data-input" value="${row.secret_key}" disabled></td>
                <td style="text-align: center;">
                    <button class="btn btn-success btn-xs restore-row-btn" title="Restore record">
                        <i data-lucide="rotate-ccw"></i>
                    </button>
                </td>
            `;
            deletedCaptchaBody.appendChild(tr);
        });
    }
    
    lucide.createIcons();
}

// Add a brand new empty row
function addNewRow(atTop = false) {
    const tempDomain = `new-domain-${Date.now()}.com`;
    const newEntry = {
        _id: crypto.randomUUID(),
        root_domain: tempDomain,
        provider: 'turnstile',
        site_key: '',
        secret_key: '',
        isNew: true
    };
    
    if (atTop) {
        currentData.unshift(newEntry);
    } else {
        currentData.push(newEntry);
    }
    
    renderTables();
    checkForChanges();
}

// Delete row (soft-delete, moving to deleted data)
function deleteRow(id) {
    const rowIndex = currentData.findIndex(r => r._id === id);
    if (rowIndex > -1) {
        const deletedRow = currentData.splice(rowIndex, 1)[0];
        // Only save to deleted list if it wasn't a newly added unsaved row
        if (!deletedRow.isNew) {
            deletedData.push(deletedRow);
        }
        renderTables();
        checkForChanges();
    }
}

// Restore a soft-deleted row
function restoreRow(id) {
    const rowIndex = deletedData.findIndex(r => r._id === id);
    if (rowIndex > -1) {
        const restoredRow = deletedData.splice(rowIndex, 1)[0];
        currentData.push(restoredRow);
        renderTables();
        checkForChanges();
    }
}

// Check if current data deviates from initial data
function checkForChanges() {
    let changed = false;
    
    if (currentData.length !== initialData.length || deletedData.length > 0) {
        changed = true;
    } else {
        for (const row of currentData) {
            const orig = initialData.find(o => o._id === row._id || o.root_domain === row.root_domain);
            if (!orig) {
                changed = true;
                break;
            }
            if (orig.provider !== row.provider || 
                orig.site_key !== row.site_key || 
                orig.secret_key !== row.secret_key ||
                orig.root_domain !== row.root_domain) {
                changed = true;
                break;
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
}

// Validation before save
function validateData() {
    const errors = [];
    
    currentData.forEach((row, i) => {
        const dom = (row.root_domain || '').trim().toLowerCase();
        
        // 1. Root Domain Validation
        if (!dom || dom.includes('new-domain-')) {
            errors.push(`Row ${i + 1}: Root Domain is required.`);
        } else if (!dom.includes('.') || dom.includes(' ') || dom.startsWith('.') || dom.endsWith('.')) {
            errors.push(`Row ${i + 1} ('${dom}'): Domain format is invalid. Must be a root domain (e.g. example.com).`);
        }
        
        // 2. Keys Validation
        if (!row.site_key || !row.site_key.trim()) {
            errors.push(`Row ${i + 1} ('${dom}'): Site Key cannot be empty.`);
        }
        if (!row.secret_key || !row.secret_key.trim()) {
            errors.push(`Row ${i + 1} ('${dom}'): Secret Key cannot be empty.`);
        }
    });
    
    return errors;
}

// Helper to strip internal ids and get clean payload for API
function getCleanPayload(row) {
    return {
        root_domain: (row.root_domain || '').trim().toLowerCase(),
        provider: (row.provider || '').trim().toLowerCase(),
        site_key: (row.site_key || '').trim(),
        secret_key: (row.secret_key || '').trim()
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
        const payload = currentData.map(getCleanPayload);
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
            throw new Error(result.message || 'Failed to save changes');
        }

        showToast('Changes saved successfully. The system is ready to apply configurations.', 'success');
        
        // Reset state
        initialData = JSON.parse(JSON.stringify(currentData));
        deletedData = [];
        hasUnsavedChanges = false;
        
        unsavedBanner.classList.remove('show');
        deployBanner.classList.add('show');
        deployBannerText.textContent = "Changes saved. Ready to deploy.";
        deployBtn.disabled = false;
        
        renderTables();
    } catch (err) {
        showToast(err.message, 'danger');
        saveBtn.disabled = false;
    } finally {
        saveBtn.innerHTML = '<i data-lucide="save"></i> Save Changes';
        lucide.createIcons();
    }
}

// Deploy Changes via stream reload
function deployChanges() {
    deployBtn.disabled = true;
    closeModalBtn.style.display = 'none';
    logContainer.textContent = 'Connecting to deployment stream...';
    restartModal.classList.add('show');

    // 1. Establish EventSource connection for streaming logs
    const eventSource = new EventSource('/dm-api/apply-config-stream');

    eventSource.onmessage = function(event) {
        const line = event.data;
        
        // Append log line
        logContainer.textContent += '\n' + line;
        
        // Keep scrolled to bottom
        logContainer.scrollTop = logContainer.scrollHeight;

        if (line.includes('[STREAM_DONE]')) {
            eventSource.close();
            logContainer.textContent += '\n\n✨ CONFIGURATION HOT-RELOAD COMPLETED SUCCESSFULLY!';
            logContainer.scrollTop = logContainer.scrollHeight;
            closeModalBtn.style.display = 'inline-block';
            deployBanner.classList.remove('show');
            showToast('CAPTCHA configurations successfully applied in real-time!', 'success');
        }

        if (line.includes('[STREAM_ERROR]')) {
            eventSource.close();
            logContainer.textContent += '\n\n❌ DEPLOYMENT FAILED. Check logs above.';
            logContainer.scrollTop = logContainer.scrollHeight;
            closeModalBtn.style.display = 'inline-block';
            deployBtn.disabled = false;
            showToast('Deployment failed. Please check the logs.', 'danger');
        }
    };

    eventSource.onerror = function() {
        eventSource.close();
        logContainer.textContent += '\n\n❌ Connection error or stream interrupted.';
        logContainer.scrollTop = logContainer.scrollHeight;
        closeModalBtn.style.display = 'inline-block';
        deployBtn.disabled = false;
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
