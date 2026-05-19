document.addEventListener('DOMContentLoaded', () => {
    const domainsBody = document.getElementById('domains-body');
    const saveBtn = document.getElementById('save-btn');
    const checkBtn = document.getElementById('validate-btn');
    const exportBtn = document.getElementById('export-btn');
    const deployBtn = document.getElementById('deploy-btn');
    const deployNotification = document.getElementById('deploy-notification');
    const deployNotificationIcon = document.getElementById('deploy-notification-icon');
    const deployNotificationText = document.getElementById('deploy-notification-text');
    const searchInput = document.getElementById('search-input');
    const addRowBtn = document.getElementById('add-row-btn');
    const globalDropdown = document.getElementById('global-service-dropdown');
    const sortableHeaders = document.querySelectorAll('.sortable');
    const unsavedNotification = document.getElementById('unsaved-notification');
    const restartModal = document.getElementById('restart-modal');
    const restartModalTitle = document.getElementById('restart-modal-title');
    const logContainer = document.getElementById('log-container');
    const closeModalBtn = document.getElementById('close-modal-btn');
    const toast = document.getElementById('toast');
    const deletedDomainsBody = document.getElementById('deleted-domains-body');
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

    let activeServiceInput = null;
    let highlightedServiceIndex = -1;

    // Modal elements for Confirmation
    const confirmModal = document.getElementById('confirm-modal');
    const confirmDeleteBtn = document.getElementById('confirm-delete-btn');
    const cancelDeleteBtn = document.getElementById('cancel-delete-btn');
    const confirmMsg = document.getElementById('confirm-msg');
    const confirmTitle = document.getElementById('confirm-modal-title');

    // Help Modal elements
    const helpBtn = document.getElementById('help-btn');
    const helpModal = document.getElementById('help-modal');
    const closeHelpBtn = document.getElementById('close-help-btn');
    const closeHelpFooterBtn = document.getElementById('close-help-footer-btn');

    let allDomains = [];
    let pristineData = ''; // JSON string of domains as they exist on server
    let allServices = [];
    let currentSort = { column: '_root_domain', direction: 'asc' };
    let rowToDelete = null;
    let pendingAction = null; // 'apply' or 'restart'

    function getRootDomain(domain) {
        if (!domain) return '';
        const parts = domain.split('.');
        if (parts.length < 2) return domain;
        // Basic extraction: returns the last two parts (e.g., example.com)
        // For complex cases (e.g., .co.uk) this might need a more robust TLD list, 
        // but for this stack's typical usage, this is sufficient and clean.
        return parts.slice(-2).join('.');
    }

    // State for root domain colors
    let rootColorMap = new Map();

    function updateRootColors() {
        // Extract unique roots, filter empty/invalid, and sort consistently
        const roots = [...new Set(allDomains.map(d => d._root_domain || getRootDomain(d.domain)))]
            .filter(r => r && r !== '-')
            .sort((a, b) => a.localeCompare(b));

        rootColorMap.clear();

        if (roots.length === 0) return;

        roots.forEach((root, index) => {
            // Golden angle distribution for distinct hues (approx 137.5 degrees)
            const h = (index * 137.5) % 360;

            // Toggle lightness and saturation for alternating "tones" between adjacent groups
            const l = (index % 2 === 0) ? 94 : 88;
            const s = (index % 2 === 0) ? 80 : 90;

            rootColorMap.set(root, `hsl(${h}, ${s}%, ${l}%)`);
        });
    }

    function getColorForRoot(rootDomain) {
        if (!rootDomain || rootDomain === '-') return 'transparent';
        return rootColorMap.get(rootDomain) || 'transparent';
    }

    function showToast(message, type = 'info', persistent = false, details = []) {
        let content = '';

        if (persistent) {
            content += `
                <div class="toast-header">
                    <span>Notification</span>
                    <button class="toast-close" title="Dismiss">&times;</button>
                </div>`;
        }

        content += `<div class="toast-body">${message}`;

        if (details.length > 0) {
            content += `<ul class="error-list">`;
            details.forEach(detail => {
                content += `<li>${detail}</li>`;
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

    function debounce(func, wait) {
        let timeout;
        return function (...args) {
            clearTimeout(timeout);
            timeout = setTimeout(() => func.apply(this, args), wait);
        };
    }

    // Debounced search handler
    const debouncedSearch = debounce(() => {
        applyFilterAndSort();
    }, 250);

    searchInput.addEventListener('input', debouncedSearch);

    function getCleanPayload(domainObj) {
        return {
            domain: (domainObj.domain || '').trim().toLowerCase(),
            redirection: (domainObj.redirection || '').trim().toLowerCase(),
            service_name: (domainObj.service_name || '').trim().toLowerCase(),
            anubis_subdomain: (domainObj.anubis_subdomain || '').trim().toLowerCase(),
            rate: (domainObj.rate || '').trim(),
            burst: (domainObj.burst || '').trim(),
            concurrency: (domainObj.concurrency || '').trim(),
            enabled: !!domainObj.enabled
        };
    }

    function updateDomainField(id, key, value, tr) {
        const domainObj = allDomains.find(d => d._id === id);
        if (domainObj) {
            domainObj[key] = value.trim();
            if (key === 'domain') {
                domainObj._root_domain = getRootDomain(value.trim());
                // Update visual cell immediately
                const rootCell = tr.querySelector('.root-domain-cell');
                const newRoot = domainObj._root_domain || '-';
                if (rootCell) rootCell.textContent = newRoot;

                // Update background color
                updateRootColors();
                // Need to refresh ALL rows because relative positioning might have changed
                document.querySelectorAll('#domains-body tr').forEach(row => {
                    const r = row.querySelector('.root-domain-cell').textContent;
                    row.style.backgroundColor = getColorForRoot(r);
                });
            }
        }
    }

    // Event Delegation for Domains Table
    domainsBody.addEventListener('input', (e) => {
        if (e.target.classList.contains('data-input')) {
            const input = e.target;
            const tr = input.closest('tr');
            if (!tr) return;
            const id = tr.dataset.id;
            const key = input.dataset.key;

            // Sync value and update truth
            const val = input.value.toLowerCase();
            input.value = val;
            updateDomainField(id, key, val, tr);

            // Reset status on change
            const domainObj = allDomains.find(d => d._id === id);
            if (domainObj) {
                domainObj._status = null;
                domainObj._validation_errors = [];
                refreshRowUnsavedState(tr, domainObj);

                // If domain changed, reset status on potential duplicates too
                if (key === 'domain') {
                    const changedDomain = val.trim().toLowerCase();
                    document.querySelectorAll('#domains-body tr').forEach(row => {
                        const rowId = row.dataset.id;
                        const otherObj = allDomains.find(d => d._id === rowId);
                        if (otherObj && otherObj._id !== id && (otherObj.domain || '').trim().toLowerCase() === changedDomain) {
                            otherObj._status = null;
                            otherObj._validation_errors = [];
                            const sCell = row.querySelector('.check-status-cell');
                            if (sCell) {
                                sCell.innerHTML = '<i data-lucide="help-circle" style="color: #94a3b8; width: 1.2rem; height: 1.2rem;" title="Not validated"></i>';
                                if (window.lucide) lucide.createIcons({ root: sCell });
                            }
                            row.classList.remove('row-error');
                        }
                    });
                }
            }

            const statusCell = tr.querySelector('.check-status-cell');
            if (statusCell) {
                statusCell.innerHTML = '<i data-lucide="help-circle" style="color: #94a3b8; width: 1.2rem; height: 1.2rem;" title="Not validated"></i>';
                if (window.lucide) lucide.createIcons({ root: statusCell });
            }
            tr.classList.remove('row-error');

            refreshUnsavedUI();

            // Special handling for filtering in service input
            if (input.classList.contains('service-input')) {
                activeServiceInput = input;
                const filter = input.value;
                highlightedServiceIndex = filter ? 0 : -1;
                renderGlobalDropdown(filter);
                updateGlobalDropdownPosition();
            }
        }
    });

    domainsBody.addEventListener('focusin', (e) => {
        if (e.target.classList.contains('service-input')) {
            activeServiceInput = e.target;
            renderGlobalDropdown('');
            updateGlobalDropdownPosition();
        }
    });

    domainsBody.addEventListener('click', (e) => {
        if (e.target.classList.contains('service-input')) {
            activeServiceInput = e.target;
            renderGlobalDropdown('');
            updateGlobalDropdownPosition();
        }

        const removeBtn = e.target.closest('.remove-row-btn');
        if (removeBtn) {
            const tr = removeBtn.closest('tr');
            rowToDelete = tr;
            const domainVal = tr.querySelector('[data-key="domain"]').value || 'this record';
            confirmTitle.textContent = 'Confirm Deletion';
            confirmMsg.textContent = `Are you sure you want to delete ${domainVal}?`;
            confirmDeleteBtn.textContent = 'Delete';
            confirmAction = 'delete';
            confirmModal.classList.add('show');
        }
    });

    domainsBody.addEventListener('focusout', (e) => {
        if (e.target.classList.contains('service-input')) {
            const input = e.target;
            setTimeout(() => {
                validateServiceInput(input);
                if (activeServiceInput === input) {
                    globalDropdown.classList.remove('show');
                    activeServiceInput = null;
                }
            }, 200);
        }
    });

    domainsBody.addEventListener('keydown', (e) => {
        if (e.target.classList.contains('service-input')) {
            if (!globalDropdown.classList.contains('show')) return;

            const items = globalDropdown.querySelectorAll('.dropdown-item');
            if (items.length === 0) return;

            if (e.key === 'ArrowDown') {
                e.preventDefault();
                highlightedServiceIndex = (highlightedServiceIndex + 1) % items.length;
                updateDropdownHighlight(items);
            } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                highlightedServiceIndex = (highlightedServiceIndex - 1 + items.length) % items.length;
                updateDropdownHighlight(items);
            } else if (e.key === 'Enter') {
                e.preventDefault();
                if (highlightedServiceIndex >= 0 && highlightedServiceIndex < items.length) {
                    items[highlightedServiceIndex].dispatchEvent(new MouseEvent('mousedown'));
                } else if (items.length > 0) {
                    items[0].dispatchEvent(new MouseEvent('mousedown'));
                }
            } else if (e.key === 'Escape') {
                globalDropdown.classList.remove('show');
                activeServiceInput = null;
            }
        }
    });

    function validateServiceInput(input) {
        const tr = input.closest('tr');
        const id = tr.dataset.id;
        const val = input.value.trim();

        if (allServices.length > 0 && !allServices.includes(val)) {
            input.value = '';
            updateDomainField(id, 'service_name', '', tr);
            showToast('Please select a valid service from the list', 'danger');
        }
        const domainObj = allDomains.find(d => d._id === id);
        refreshRowUnsavedState(tr, domainObj);
        refreshUnsavedUI();
    }


    function refreshRowUnsavedState(tr, domainObj) {
        if (!domainObj) return;
        const currentState = JSON.stringify(getCleanPayload(domainObj));
        if (domainObj._original && currentState === domainObj._original) {
            tr.classList.remove('row-unsaved');
        } else {
            tr.classList.add('row-unsaved');
        }
    }

    async function loadDomains() {
        try {
            const response = await fetch('/dm-api/domains');
            const data = await response.json();
            // Assign unique IDs for reactive tracking and calculate root domain
            allDomains = data.map(d => {
                const obj = {
                    ...d,
                    _id: crypto.randomUUID(),
                    _root_domain: getRootDomain(d.domain)
                };
                obj._original = JSON.stringify(getCleanPayload(obj));
                return obj;
            });
            updateRootColors();
            // Store a "pristine" copy of the data (values only, no internal IDs)
            pristineData = JSON.stringify(allDomains.map(getCleanPayload));
            applyFilterAndSort();
            refreshUnsavedUI();
        } catch (error) {
            showToast('Error loading domains', 'danger');
        }
    }

    async function loadServices() {
        try {
            const response = await fetch('/dm-api/services');
            allServices = await response.json();
        } catch (error) {
            console.error('Error loading services:', error);
        }
    }

    function applyFilterAndSort() {
        const searchTerm = searchInput.value.toLowerCase();

        let filtered = allDomains.filter(domain => {
            return Object.values(domain).some(val =>
                String(val).toLowerCase().includes(searchTerm)
            );
        });

        if (currentSort.column) {
            filtered.sort((a, b) => {
                let valA = a[currentSort.column];
                let valB = b[currentSort.column];

                if (currentSort.column === '_status') {
                    const statusOrder = { 'invalid': 0, 'loading': 1, 'valid': 2, null: 3, undefined: 3 };
                    valA = statusOrder[valA] !== undefined ? statusOrder[valA] : 3;
                    valB = statusOrder[valB] !== undefined ? statusOrder[valB] : 3;
                } else {
                    valA = valA || '';
                    valB = valB || '';
                }

                if (!isNaN(valA) && !isNaN(valB) && valA !== '' && valB !== '' && typeof valA !== 'string' && typeof valB !== 'string') {
                    return currentSort.direction === 'asc' ? valA - valB : valB - valA;
                }

                return currentSort.direction === 'asc'
                    ? String(valA).localeCompare(String(valB))
                    : String(valB).localeCompare(String(valA));
            });
        }

        renderTable(filtered);
    }

    function renderTable(data) {
        domainsBody.innerHTML = '';
        const fragment = document.createDocumentFragment();
        data.forEach(domain => {
            if (domain.enabled !== false) {
                const tr = addRow(domain, false); // false = don't append, just return
                fragment.appendChild(tr);
            }
        });
        domainsBody.appendChild(fragment);
        renderDeletedTable();
    }

    function renderDeletedTable() {
        if (!deletedDomainsBody) return;
        deletedDomainsBody.innerHTML = '';
        const deleted = allDomains.filter(d => d.enabled === false);

        if (deleted.length === 0) {
            // Optional: Hide section or show message
        }

        deleted.forEach(data => {
            const tr = document.createElement('tr');
            const root = data._root_domain || '-';
            // Use lighter/grayed out style or same colors? User asked specifically for the table.
            // Style.css says background #f9fafb.

            tr.innerHTML = `
                <td></td>
                <td class="root-domain-cell" data-label="Root Domain">${root}</td>
                <td data-label="Domain"><input type="text" class="data-input" value="${data.domain || ''}" disabled></td>
                <td data-label="Redirection"><input type="text" class="data-input" value="${data.redirection || ''}" disabled></td>
                <td data-label="Service"><input type="text" class="data-input" value="${data.service_name || ''}" disabled></td>
                <td data-label="Anubis Subdomain"><input type="text" class="data-input" value="${data.anubis_subdomain || ''}" disabled></td>
                <td data-label="Rate"><input type="text" class="data-input" value="${data.rate || ''}" disabled></td>
                <td data-label="Burst"><input type="text" class="data-input" value="${data.burst || ''}" disabled></td>
                <td data-label="Concurrency"><input type="text" class="data-input" value="${data.concurrency || ''}" disabled></td>
                <td>
                    <div style="display: flex; gap: 0.25rem; justify-content: center;">
                        <button class="btn btn-success btn-xs btn-compact restore-row-btn" title="Restore record">
                            <i data-lucide="rotate-ccw"></i>
                        </button>
                        <button class="btn btn-danger btn-xs btn-compact permanent-delete-btn" title="Delete permanently">
                            <i data-lucide="trash-2"></i>
                        </button>
                    </div>
                </td>
            `;

            tr.dataset.id = data._id; // Ensure ID is preserved for identification

            tr.querySelector('.restore-row-btn').addEventListener('click', () => {
                // Find index in allDomains
                const idx = allDomains.findIndex(d => d._id === data._id);
                if (idx !== -1) {
                    // Remove from current position and move to end
                    const [restored] = allDomains.splice(idx, 1);
                    restored.enabled = true;
                    allDomains.push(restored);
                }
                updateRootColors();
                applyFilterAndSort();
                refreshUnsavedUI();

                // Scroll to the newly restored row in the main table
                setTimeout(() => {
                    const restoredRow = domainsBody.querySelector(`tr[data-id="${data._id}"]`);
                    if (restoredRow) {
                        restoredRow.scrollIntoView({ behavior: 'smooth', block: 'center' });
                        // Add pulse effect
                        restoredRow.classList.add('row-restore-pulse');
                        // Remove class after animation to clean up
                        setTimeout(() => restoredRow.classList.remove('row-restore-pulse'), 1000);
                    }
                }, 100);
            });

            tr.querySelector('.permanent-delete-btn').addEventListener('click', () => {
                rowToDelete = tr;
                confirmAction = 'permanent-delete';
                confirmTitle.textContent = 'Permanent Deletion';
                confirmMsg.textContent = `Are you sure you want to PERMANENTLY delete ${(data.domain || 'this record')}? This cannot be undone.`;
                confirmDeleteBtn.textContent = 'Delete Forever';
                confirmDeleteBtn.className = 'btn btn-danger';
                confirmModal.classList.add('show');
            });

            deletedDomainsBody.appendChild(tr);
            if (window.lucide) lucide.createIcons({ root: tr });
        });
    }

    function addRow(data = {}, position = 'bottom') {
        const id = data._id || crypto.randomUUID();
        if (!data._id) {
            // New row added via UI
            const newDomain = {
                _id: id,
                domain: data.domain || '',
                redirection: data.redirection || '',
                service_name: data.service_name || '',
                anubis_subdomain: data.anubis_subdomain || '',
                rate: data.rate || '',
                burst: data.burst || '',
                concurrency: data.concurrency || '',
                _root_domain: getRootDomain(data.domain || ''),
                enabled: true,
                _unsaved: true // Mark as unsaved
            };
            if (position === 'top') {
                allDomains.unshift(newDomain);
            } else {
                allDomains.push(newDomain);
            }
            refreshUnsavedUI();
        }

        const tr = document.createElement('tr');
        if (!data._id || data._unsaved) tr.classList.add('row-unsaved');
        tr.dataset.id = id;
        const root = data._root_domain || getRootDomain(data.domain);
        tr.style.backgroundColor = getColorForRoot(root);

        let statusHtml = '';
        if (data._status === 'loading') {
            statusHtml = '<i data-lucide="loader-2" class="animate-spin" style="width: 1rem; height: 1rem; color: #666;"></i>';
        } else if (data._status === 'valid') {
            statusHtml = '<i data-lucide="check-circle" style="color: #059669; width: 1.2rem; height: 1.2rem;"></i>';
        } else if (data._status === 'invalid') {
            const errors = data._validation_errors || [];
            statusHtml = `<i data-lucide="x-circle" style="color: #7f1d1d; width: 1.2rem; height: 1.2rem;" title="${errors.join('\n')}"></i>`;
            tr.classList.add('row-error');
        } else {
            statusHtml = '<i data-lucide="help-circle" style="color: #94a3b8; width: 1.2rem; height: 1.2rem;" title="Not validated"></i>';
        }

        tr.innerHTML = `
            <td class="check-status-cell" style="text-align: center;">${statusHtml}</td>
            <td class="root-domain-cell" data-label="Root Domain">${root || '-'}</td>
            <td data-label="Domain"><input type="text" class="data-input" data-key="domain" value="${data.domain || ''}" placeholder="example.com"></td>
            <td data-label="Redirection"><input type="text" class="data-input" data-key="redirection" value="${data.redirection || ''}" placeholder="www.example.com"></td>
            <td data-label="Service">
                <input type="text" class="data-input service-input" data-key="service_name" value="${data.service_name || ''}" placeholder="Type or select service" autocomplete="off">
            </td>
            <td data-label="Anubis Subdomain"><input type="text" class="data-input" data-key="anubis_subdomain" value="${data.anubis_subdomain || ''}" placeholder="anubis"></td>
            <td data-label="Rate"><input type="text" class="data-input" data-key="rate" value="${data.rate || ''}" placeholder="${defaultRateAvg}"></td>
            <td data-label="Burst"><input type="text" class="data-input" data-key="burst" value="${data.burst || ''}" placeholder="${defaultRateBurst}"></td>
            <td data-label="Concurrency"><input type="text" class="data-input" data-key="concurrency" value="${data.concurrency || ''}" placeholder="${defaultConcurrency}"></td>
            <td>
                <button class="btn btn-danger btn-sm remove-row-btn" title="Delete record">
                    <i data-lucide="trash-2"></i>
                </button>
            </td>
        `;

        if (window.lucide) lucide.createIcons({ root: tr });

        if (position === 'top') {
            domainsBody.prepend(tr);
        } else if (position === 'bottom') {
            domainsBody.appendChild(tr);
        }
        // If position is anything else (like false), we don't append, just return
        return tr;
    }

    async function validateAllRows() {
        const rows = Array.from(domainsBody.querySelectorAll('tr'));
        let allValid = true;
        let globalErrors = [];

        // 1. Pre-calculate duplicates across only ENABLED domains
        const domainCounts = {};
        allDomains.forEach(d => {
            if (d.enabled !== false) {
                const dom = (d.domain || '').trim().toLowerCase();
                if (dom) domainCounts[dom] = (domainCounts[dom] || 0) + 1;
            }
        });

        const rowsToValidate = rows.filter(row => {
            const domainInput = row.querySelector('input[data-key="domain"]');
            const serviceInput = row.querySelector('input[data-key="service_name"]');
            const redirectionInput = row.querySelector('input[data-key="redirection"]');
            const anubisInput = row.querySelector('input[data-key="anubis_subdomain"]');
            return (domainInput && domainInput.value.trim() !== '') ||
                (serviceInput && serviceInput.value.trim() !== '') ||
                (redirectionInput && redirectionInput.value.trim() !== '') ||
                (anubisInput && anubisInput.value.trim() !== '');
        });

        if (rowsToValidate.length === 0) {
            return { isValid: true, errors: [] };
        }

        // 2. Local checks (duplicates, mandatory fields) + show spinners
        const rowMeta = [];  // [{row, domain, redirection, serviceName, anubisSubdomain, domainId, rowLabel, localError}]

        rowsToValidate.forEach((row, index) => {
            const domainInput = row.querySelector('input[data-key="domain"]');
            const redirectionInput = row.querySelector('input[data-key="redirection"]');
            const serviceInput = row.querySelector('input[data-key="service_name"]');
            const statusCell = row.querySelector('.check-status-cell');

            const domain = domainInput ? domainInput.value.trim().toLowerCase() : '';
            const redirection = redirectionInput ? redirectionInput.value.trim() : '';
            const serviceName = serviceInput ? serviceInput.value.trim() : '';
            const anubisSubdomain = row.querySelector('input[data-key="anubis_subdomain"]')?.value.trim() || '';

            const rowLabel = domain || `Row ${index + 1}`;
            const domainId = row.dataset.id;
            const domainObj = allDomains.find(d => d._id === domainId);

            // Show loading spinner
            if (statusCell) {
                statusCell.innerHTML = '<i data-lucide="loader-2" class="animate-spin" style="width: 1rem; height: 1rem; color: #666;"></i>';
                if (window.lucide) lucide.createIcons({ root: statusCell });
            }
            if (domainObj) domainObj._status = 'loading';

            // Clear previous errors
            row.classList.remove('row-error');
            row.querySelectorAll('.input-error').forEach(el => el.classList.remove('input-error'));

            // Basic mandatory + duplicate check
            let localErrors = [];
            if (!domain) {
                localErrors.push(`${rowLabel}: Domain is required`);
                globalErrors.push(`${rowLabel} (Domain): Required`);
                if (domainInput) domainInput.classList.add('input-error');
            } else if (domainCounts[domain] > 1) {
                localErrors.push(`${rowLabel}: Duplicate domain detected`);
                globalErrors.push(`${rowLabel} (Domain): Duplicate detected`);
                if (domainInput) domainInput.classList.add('input-error');
            }

            if (!serviceName) {
                localErrors.push(`${rowLabel}: Service is required`);
                globalErrors.push(`${rowLabel} (Service): Required`);
                if (serviceInput) serviceInput.classList.add('input-error');
            }

            if (localErrors.length > 0) {
                if (statusCell) {
                    statusCell.innerHTML = `<i data-lucide="x-circle" style="color: #7f1d1d; width: 1.2rem; height: 1.2rem;" title="${localErrors.join('\n')}"></i>`;
                    if (window.lucide) lucide.createIcons({ root: statusCell });
                }
                row.classList.add('row-error');
                if (domainObj) { domainObj._status = 'invalid'; domainObj._validation_errors = localErrors; }
                allValid = false;
            }

            rowMeta.push({ row, domain, redirection, serviceName, anubisSubdomain, domainId, rowLabel, domainObj, localErrors });
        });

        // 3. Single batch request for all rows that passed local checks
        const batchEntries = rowMeta
            .filter(m => m.localErrors.length === 0)
            .map(m => ({ domain: m.domain, redirection: m.redirection, service_name: m.serviceName, anubis_subdomain: m.anubisSubdomain }));

        if (batchEntries.length === 0) {
            return { isValid: allValid, errors: globalErrors };
        }

        let batchResults;
        try {
            const response = await fetch('/dm-api/check-domains-batch', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-CSRFToken': csrfToken },
                body: JSON.stringify(batchEntries)
            });
            if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
            batchResults = await response.json();
        } catch (err) {
            console.error('Batch validation failed', err);
            // Graceful degradation: mark all pending rows as failed
            rowMeta.filter(m => m.localErrors.length === 0).forEach(m => {
                const statusCell = m.row.querySelector('.check-status-cell');
                if (statusCell) {
                    statusCell.innerHTML = '<i data-lucide="help-circle" style="color: #6b7280; width: 1.2rem; height: 1.2rem;" title="Check failed"></i>';
                    if (window.lucide) lucide.createIcons({ root: statusCell });
                }
                globalErrors.push(`${m.rowLabel}: Batch resolution check failed (${err.message})`);
            });
            allValid = false;
            return { isValid: allValid, errors: globalErrors };
        }

        // 4. Apply batch results back to each row (same order as batchEntries)
        let batchIdx = 0;
        rowMeta.forEach(m => {
            if (m.localErrors.length > 0) return;  // already handled above

            const data = batchResults[batchIdx++];
            const row = m.row;
            const statusCell = row.querySelector('.check-status-cell');
            const domainInput = row.querySelector('input[data-key="domain"]');
            const redirectionInput = row.querySelector('input[data-key="redirection"]');
            const serviceInput = row.querySelector('input[data-key="service_name"]');

            let tooltip = [];
            let isError = false;

            if (data.domain.status === 'mismatch' || data.domain.status === 'error') {
                const msg = data.domain.message || `Domain IP Mismatch`;
                tooltip.push(msg);
                globalErrors.push(`${m.rowLabel} (Domain): ${msg}`);
                if (domainInput) domainInput.classList.add('input-error');
                isError = true;
            }

            if (data.redirection.status === 'mismatch' || data.redirection.status === 'error') {
                const msg = data.redirection.message || `Redirection IP Mismatch`;
                tooltip.push(msg);
                globalErrors.push(`${m.rowLabel} (Redirection): ${msg}`);
                if (redirectionInput) redirectionInput.classList.add('input-error');
                isError = true;
            }

            if (data.service.status === 'missing' || data.service.status === 'error') {
                tooltip.push('Service validation failed');
                globalErrors.push(`${m.rowLabel} (Service): Service validation failed`);
                if (serviceInput) serviceInput.classList.add('input-error');
                isError = true;
            }

            if (data.anubis.status === 'mismatch' || data.anubis.status === 'error') {
                const msg = data.anubis.message || `Anubis DNS Mismatch`;
                tooltip.push(msg);
                globalErrors.push(`${m.rowLabel} (Anubis): ${msg}`);
                const anubisInput = row.querySelector('input[data-key="anubis_subdomain"]');
                if (anubisInput) anubisInput.classList.add('input-error');
                isError = true;
            }

            if (isError || data.status === 'mismatch') {
                if (statusCell) {
                    statusCell.innerHTML = `<i data-lucide="x-circle" style="color: #7f1d1d; width: 1.2rem; height: 1.2rem;" title="${tooltip.join('\n')}"></i>`;
                }
                row.classList.add('row-error');
                if (m.domainObj) { m.domainObj._status = 'invalid'; m.domainObj._validation_errors = tooltip; }
                allValid = false;
            } else {
                if (statusCell) {
                    statusCell.innerHTML = '<i data-lucide="check-circle" style="color: #22c55e; width: 1.2rem; height: 1.2rem;"></i>';
                }
                if (m.domainObj) m.domainObj._status = 'valid';
            }
            if (statusCell && window.lucide) lucide.createIcons({ root: statusCell });
        });

        return { isValid: allValid, errors: globalErrors };
    }


    function determinePostSaveAction(oldDataStr, newDataStr) {
        if (!oldDataStr || !newDataStr) return 'restart'; // Failsafe

        try {
            const oldData = JSON.parse(oldDataStr);
            const newData = JSON.parse(newDataStr);

            // A soft restart is required if any structural changes occurred (new domains, removed domains, or Anubis changes).
            // This is because new Anubis containers need to be created/removed via docker compose.
            const getStructuralConfigs = (data) => {
                return data
                    .filter(d => Boolean(d.enabled) && Boolean(d.domain && d.domain.trim() !== ''))
                    .map(d => `${(d.domain || '').trim().toLowerCase()}|${(d.anubis_subdomain || '').trim().toLowerCase()}`)
                    .sort()
                    .join(',');
            };

            const oldStruct = getStructuralConfigs(oldData);
            const newStruct = getStructuralConfigs(newData);

            if (oldStruct !== newStruct) {
                return 'restart';
            }
        } catch (e) {
            console.error("Error parsing payload for action determination", e);
            return 'restart';
        }

        // If no Anubis-related structural changes occurred, a hot-reload is sufficient.
        return 'apply';
    }

    async function saveDomains(showSuccess = true) {
        // Disable save button and show state
        saveBtn.disabled = true;
        const originalText = saveBtn.innerHTML;
        saveBtn.innerHTML = '<i data-lucide="loader-2" class="animate-spin"></i> Validating...';
        if (window.lucide) lucide.createIcons({ root: saveBtn });

        const { isValid, errors } = await validateAllRows();

        if (!isValid) {
            showToast('Cannot save: some records are invalid. Please check the highlighted fields.', 'danger', true, errors);
            saveBtn.innerHTML = originalText;
            if (window.lucide) lucide.createIcons({ root: saveBtn });
            saveBtn.disabled = false;
            return;
        }

        saveBtn.innerHTML = '<i data-lucide="loader-2" class="animate-spin"></i> Saving...';
        if (window.lucide) lucide.createIcons({ root: saveBtn });

        // Strip internal IDs and temporary fields before saving and filter empty domains
        const payload = allDomains
            .filter(d => d.domain && d.domain.trim() !== '' && d.service_name && d.service_name.trim() !== '')
            .map(getCleanPayload);

        try {
            const response = await fetch('/dm-api/domains', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': csrfToken
                },
                body: JSON.stringify(payload)
            });
            if (response.ok) {
                if (showSuccess) showToast('Changes saved successfully');

                // Update original state and clear unsaved flag for all rows
                allDomains.forEach(d => {
                    if (d.domain && d.domain.trim() !== '') {
                        d._original = JSON.stringify(getCleanPayload(d));
                        d._unsaved = false;
                    }
                });

                // Determine if an action is required before we update state
                const currentPayloadStr = JSON.stringify(payload);
                const actionRequired = currentPayloadStr !== pristineData 
                    ? determinePostSaveAction(pristineData, currentPayloadStr) 
                    : null;
                
                // Update pristineData immediately so refreshUnsavedUI knows there are no unsaved changes
                pristineData = currentPayloadStr;

                // Force UI to clear all unsaved highlights and hide the unsaved banner
                clearUnsavedChanges();

                // Now it is safe to display the post-save banners without being suppressed
                if (actionRequired) {
                    updateDeployUI(actionRequired);
                }
            } else {
                showToast('Error saving changes', 'danger');
                saveBtn.disabled = false;
            }
        } catch (error) {
            showToast('Network error', 'danger');
            saveBtn.disabled = false;
        } finally {
            saveBtn.innerHTML = originalText;
            if (window.lucide) lucide.createIcons({ root: saveBtn });
        }
    }

    saveBtn.addEventListener('click', () => saveDomains(true));

    checkBtn.addEventListener('click', async () => {
        const originalText = checkBtn.innerHTML;
        checkBtn.disabled = true;
        checkBtn.innerHTML = '<i data-lucide="loader-2" class="animate-spin"></i> Validating...';
        if (window.lucide) lucide.createIcons({ root: checkBtn });

        const { isValid, errors } = await validateAllRows();

        if (!isValid) {
            showToast('Validation failed: some records have issues. Please check the highlighted fields.', 'danger', true, errors);
        } else {
            showToast('All records validated successfully', 'success');
        }

        checkBtn.innerHTML = originalText;
        if (window.lucide) lucide.createIcons({ root: checkBtn });
        checkBtn.disabled = false;
    });

    exportBtn.addEventListener('click', () => {
        // Headers matching the CSV structure in the backend
        const headers = ['domain', 'redirection', 'service_name', 'anubis_subdomain', 'rate', 'burst', 'concurrency'];
        const csvContent = "# " + headers.join(', ') + "\n\n"
            + allDomains.map(d => {
                let rowData = headers.map(header => d[header] || '').join(',');
                if (d.enabled === false) {
                    return '# ' + rowData;
                }
                return rowData;
            }).join('\n');

        const encodedUri = "data:text/csv;charset=utf-8," + encodeURIComponent(csvContent);
        const link = document.createElement("a");
        link.setAttribute("href", encodedUri);
        link.setAttribute("download", `${stackDomain}-domains.csv`);
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
    });

    deployBtn.addEventListener('click', () => {
        rowToDelete = null;
        if (pendingAction === 'restart') {
            confirmTitle.textContent = 'Confirm Soft Restart';
            confirmMsg.textContent = 'This will regenerate config and deploy new/removed Anubis containers. Existing services will NOT be stopped or recreated.';
            confirmDeleteBtn.textContent = 'Soft Restart';
            confirmDeleteBtn.className = 'btn btn-danger';
            confirmAction = 'restart';
        } else {
            confirmTitle.textContent = 'Hot Reload (Zero Downtime)';
            confirmMsg.textContent = 'This will regenerate the Traefik dynamic config and apply it in-place. No containers will be stopped — traffic continues uninterrupted.\n\nUse this for: changing rate limits, concurrencies, or editing existing traffic rules.';
            confirmDeleteBtn.textContent = 'Apply';
            confirmDeleteBtn.className = 'btn btn-apply';
            confirmAction = 'apply-config';
        }
        confirmModal.classList.add('show');
    });


    let confirmAction = 'delete'; // 'delete', 'restart', 'apply-config', or 'permanent-delete'

    confirmDeleteBtn.addEventListener('click', () => {
        if (confirmAction === 'delete') {
            if (rowToDelete) {
                const id = rowToDelete.dataset.id;
                const domainObj = allDomains.find(d => d._id === id);
                if (domainObj) {
                    domainObj.enabled = false; // Soft delete
                    updateRootColors();
                    applyFilterAndSort(); // Re-renders active table
                    renderDeletedTable(); // Updates deleted table
                    refreshUnsavedUI();
                }
                rowToDelete = null;
            }
            confirmModal.classList.remove('show');
        } else if (confirmAction === 'permanent-delete') {
            if (rowToDelete) {
                const id = rowToDelete.dataset.id;
                allDomains = allDomains.filter(d => d._id !== id);
                updateRootColors();
                applyFilterAndSort(); // Re-renders active table
                renderDeletedTable(); // Updates deleted table
                refreshUnsavedUI();
                rowToDelete = null;
            }
            confirmModal.classList.remove('show');
            // Reset state
            confirmDeleteBtn.textContent = 'Delete';
            confirmAction = 'delete';
        } else if (confirmAction === 'restart') {
            confirmModal.classList.remove('show');
            initiateStream(
                `/dm-api/restart-stream?csrf_token=${csrfToken}`,
                'Soft Restart Progress',
                '✅ Soft restart completed successfully.'
            );
        } else if (confirmAction === 'apply-config') {
            confirmModal.classList.remove('show');
            initiateStream(
                `/dm-api/apply-config-stream?csrf_token=${csrfToken}`,
                'Hot Reload — Zero Downtime',
                '✅ Config applied. Traefik is hot-reloading the new rules.'
            );
        }
    });

    /**
     * Generic SSE stream launcher — used for both Soft Restart and Hot Reload.
     * @param {string} streamUrl  - The SSE endpoint URL (with CSRF token already appended)
     * @param {string} modalTitle - Title displayed in the progress modal
     * @param {string} successMsg - Message shown on process exit code 0
     */
    function initiateStream(streamUrl, modalTitle, successMsg) {
        if (restartModalTitle) restartModalTitle.textContent = modalTitle;
        restartModal.classList.add('show');
        logContainer.textContent = 'Connecting...\n';
        closeModalBtn.style.display = 'none';

        // Hide notifications
        deployNotification.classList.remove('show');
        deployNotification.classList.remove('is-restart');
        document.body.classList.remove('has-notification');
        deployBtn.classList.remove('btn-deploy-needed');
        deployBtn.classList.remove('is-restart');
        
        // Disable deploy button
        deployBtn.disabled = true;
        deployBtn.title = "Deployment in progress...";
        pendingAction = null;

        const eventSource = new EventSource(streamUrl);

        eventSource.onmessage = (event) => {
            if (event.data.trim() === "[Process finished with code 0]") {
                logContainer.textContent += `\n${successMsg}\n`;
                closeModalBtn.style.display = 'block';
                eventSource.close();
            } else if (event.data.includes("[Process finished with code")) {
                logContainer.textContent += `\n❌ ${event.data}\n`;
                closeModalBtn.style.display = 'block';
                eventSource.close();
            } else {
                logContainer.textContent += event.data + '\n';
                logContainer.parentElement.scrollTop = logContainer.parentElement.scrollHeight;
            }
        };

        eventSource.onerror = () => {
            logContainer.textContent += '\n\n🔄 Connection closed. This is expected as Traefik reloads the new configuration.\n✅ The stack should be up in a few seconds.';
            closeModalBtn.style.display = 'block';
            eventSource.close();
        };
    }

    // Keep backward-compatible alias
    function initiateRestart() {
        initiateStream(
            `/dm-api/restart-stream?csrf_token=${csrfToken}`,
            'Soft Restart Progress',
            '✅ Soft restart completed successfully.'
        );
    }

    closeModalBtn.addEventListener('click', () => {
        restartModal.classList.remove('show');
    });

    cancelDeleteBtn.addEventListener('click', () => {
        rowToDelete = null;
        confirmModal.classList.remove('show');
        // Reset state
        confirmAction = 'delete';
        confirmDeleteBtn.textContent = 'Delete';
        confirmDeleteBtn.className = 'btn btn-danger';
    });

    const addRowTopBtn = document.getElementById('add-row-top-btn');
    if (addRowTopBtn) {
        addRowTopBtn.addEventListener('click', () => {
            const tr = addRow({}, 'top');
            const firstInput = tr.querySelector('input');
            if (firstInput) firstInput.focus();
        });
    }

    addRowBtn.addEventListener('click', () => {
        const tr = addRow({}, 'bottom'); // addRow appends by default
        const firstInput = tr.querySelector('input');
        if (firstInput) {
            firstInput.focus();
            tr.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
    });

    // Old search listener removed in favor of debounced one above


    sortableHeaders.forEach(header => {
        header.addEventListener('click', () => {
            const column = header.dataset.sort;
            if (currentSort.column === column) {
                currentSort.direction = currentSort.direction === 'asc' ? 'desc' : 'asc';
            } else {
                currentSort.column = column;
                currentSort.direction = 'asc';
            }

            sortableHeaders.forEach(h => h.classList.remove('asc', 'desc'));
            header.classList.add(currentSort.direction);

            applyFilterAndSort();
        });
    });

    function updateDeployUI(action) {
        pendingAction = action;

        if (action === 'restart') {
            deployNotificationText.textContent = 'Structural changes detected. Click "Deploy Changes" for a Soft Restart.';
            deployNotificationIcon.dataset.lucide = 'alert-triangle';
            deployBtn.title = "Soft Restart: Required for adding/removing domains or Anubis updates.";
            deployNotification.classList.add('is-restart');
            deployBtn.classList.add('is-restart');
        } else {
            deployNotificationText.textContent = 'Routing changes saved. Click "Deploy Changes" for a Hot Reload (Zero Downtime).';
            deployNotificationIcon.dataset.lucide = 'zap';
            deployBtn.title = "Hot Reload: Zero-downtime config update.";
            deployNotification.classList.remove('is-restart');
            deployBtn.classList.remove('is-restart');
        }

        if (window.lucide) lucide.createIcons({ root: deployNotification });

        // Only show notification if not currently showing unsaved changes (priority to unsaved)
        if (!unsavedNotification.classList.contains('show')) {
            deployNotification.classList.add('show');
            document.body.classList.add('has-notification');
        }

        deployBtn.classList.add('btn-deploy-needed');
        deployBtn.disabled = false;
    }

    // Help Modal Event Listeners
    if (helpBtn && helpModal) {
        helpBtn.addEventListener('click', () => {
            helpModal.classList.add('show');
            if (window.lucide) lucide.createIcons({ root: helpModal });
        });

        const closeHelp = () => helpModal.classList.remove('show');
        if (closeHelpBtn) closeHelpBtn.addEventListener('click', closeHelp);
        if (closeHelpFooterBtn) closeHelpFooterBtn.addEventListener('click', closeHelp);

        // Close on clicking overlay
        helpModal.addEventListener('click', (e) => {
            if (e.target === helpModal) closeHelp();
        });
    }

    function refreshUnsavedUI() {
        const payload = allDomains
            .filter(d => d.domain && d.domain.trim() !== '' && d.service_name && d.service_name.trim() !== '')
            .map(getCleanPayload);

        const hasDataChanges = JSON.stringify(payload) !== pristineData;
        const hasUnsavedRows = document.querySelectorAll('.row-unsaved').length > 0;
        const hasChanges = hasDataChanges || hasUnsavedRows;

        if (hasChanges) {
            unsavedNotification.classList.add('show');
            deployNotification.classList.remove('show');
            document.body.classList.add('has-notification');
            saveBtn.classList.add('btn-save-needed');
            saveBtn.disabled = false;
        } else {
            unsavedNotification.classList.remove('show');
            saveBtn.classList.remove('btn-save-needed');
            saveBtn.disabled = true;
            // Banner is gone, so if no other notification, remove the margin
            if (!deployNotification.classList.contains('show')) {
                document.body.classList.remove('has-notification');
            }
        }
    }

    // Deprecated in favor of refreshUnsavedUI
    function markUnsavedChanges() { refreshUnsavedUI(); }
    function clearUnsavedChanges() {
        // Force reset
        document.querySelectorAll('.row-unsaved').forEach(row => row.classList.remove('row-unsaved'));
        refreshUnsavedUI();
    }
    function renderGlobalDropdown(filter = '') {
        if (!activeServiceInput) return;

        const filtered = allServices.filter(s => s.toLowerCase().includes(filter.toLowerCase()));
        globalDropdown.innerHTML = '';

        if (filtered.length === 0) {
            globalDropdown.classList.remove('show');
            return;
        }

        // Clamp index if filtered list changed
        if (highlightedServiceIndex >= filtered.length) highlightedServiceIndex = filtered.length - 1;
        if (highlightedServiceIndex < 0 && filtered.length > 0 && filter) highlightedServiceIndex = 0;

        filtered.forEach((service, index) => {
            const item = document.createElement('div');
            item.className = 'dropdown-item';
            if (index === highlightedServiceIndex) item.classList.add('selected');
            item.textContent = service;
            // Use mousedown to ensure it fires before blur
            item.addEventListener('mousedown', (e) => {
                e.preventDefault(); // Prevent focus loss immediately
                activeServiceInput.value = service;
                // Update truth and mark unsaved directly since validation is passed
                const tr = activeServiceInput.closest('tr');
                const id = tr.dataset.id;
                const domainObj = allDomains.find(d => d._id === id);
                if (domainObj) {
                    domainObj['service_name'] = service;
                    refreshRowUnsavedState(tr, domainObj);
                }
                refreshUnsavedUI();

                globalDropdown.classList.remove('show');
                activeServiceInput = null;
            });
            globalDropdown.appendChild(item);
        });

        globalDropdown.classList.add('show');
    }

    function updateGlobalDropdownPosition() {
        if (!activeServiceInput || !globalDropdown.classList.contains('show')) return;
        const rect = activeServiceInput.getBoundingClientRect();
        globalDropdown.style.top = `${rect.bottom + window.scrollY}px`;
        globalDropdown.style.left = `${rect.left + window.scrollX}px`;
        globalDropdown.style.width = `${rect.width}px`;
    }

    // Close global dropdown when clicking outside
    document.addEventListener('click', (e) => {
        if (activeServiceInput && !activeServiceInput.contains(e.target) && !globalDropdown.contains(e.target)) {
            globalDropdown.classList.remove('show');
            activeServiceInput = null;
        }
    });

    // Reposition on window resize (optional but good)
    window.addEventListener('resize', () => {
        if (globalDropdown.classList.contains('show')) {
            updateGlobalDropdownPosition();
        } else {
            activeServiceInput = null;
        }
    });

    loadDomains();
    loadServices();
});
