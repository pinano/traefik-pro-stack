/**
 * Certificates Inspector — Client-side Search, Sort, Sticky Header & Help Modal
 * Extracted from certs.html inline script for maintainability.
 */

document.addEventListener('DOMContentLoaded', () => {
    // ==========================================
    // Sticky Header Logic
    // ==========================================
    initStickyHeader();

    // ==========================================
    // Help Modal Logic
    // ==========================================
    initHelpModal();

    // ==========================================
    // Client-side Search & Sort
    // ==========================================
    const tableBody = document.getElementById('certs-body');
    const searchInput = document.getElementById('search-input');
    const headers = document.querySelectorAll('.sortable');

    let rows = Array.from(tableBody.querySelectorAll('tr'));

    // Simple Client-side Search
    searchInput.addEventListener('input', (e) => {
        const term = e.target.value.toLowerCase();
        rows.forEach(row => {
            const text = row.textContent.toLowerCase();
            row.style.display = text.includes(term) ? '' : 'none';
        });
    });

    // Simple Client-side Sort
    let currentSort = { column: null, direction: 'asc' };

    headers.forEach(header => {
        // Add sort icons if missing
        if (!header.querySelector('.sort-icon')) {
            header.innerHTML += ' <i data-lucide="chevrons-up-down" class="sort-icon default" style="width:14px; height:14px; vertical-align:middle; opacity:0.5;"></i>';
            lucide.createIcons({ root: header });
        }

        header.addEventListener('click', () => {
            const column = header.dataset.sort;
            const headerRow = header.parentElement;
            const index = Array.from(headerRow.children).indexOf(header);

            // Reset icons
            document.querySelectorAll('.sort-icon').forEach(icon => {
                icon.setAttribute('data-lucide', 'chevrons-up-down');
                icon.style.opacity = '0.5';
                icon.style.color = '';
            });
            lucide.createIcons();

            if (currentSort.column === column) {
                currentSort.direction = currentSort.direction === 'asc' ? 'desc' : 'asc';
            } else {
                currentSort.column = column;
                currentSort.direction = 'asc';
            }

            // Update current icon
            const targetIcon = header.querySelector('.sort-icon');
            if (currentSort.direction === 'asc') {
                targetIcon.setAttribute('data-lucide', 'chevron-up');
            } else {
                targetIcon.setAttribute('data-lucide', 'chevron-down');
            }
            targetIcon.style.opacity = '1';
            targetIcon.style.color = 'var(--primary-color)';
            lucide.createIcons({ root: header });

            // Sort rows
            const sortedRows = rows.sort((a, b) => {
                const aCell = a.children[index];
                const bCell = b.children[index];
                const aSortVal = aCell.getAttribute('data-sort-value');
                const bSortVal = bCell.getAttribute('data-sort-value');

                if (aSortVal !== null && bSortVal !== null) {
                    const aNum = parseFloat(aSortVal) || 0;
                    const bNum = parseFloat(bSortVal) || 0;
                    return currentSort.direction === 'asc' ? aNum - bNum : bNum - aNum;
                }

                const aVal = aCell.textContent.trim();
                const bVal = bCell.textContent.trim();

                return currentSort.direction === 'asc'
                    ? aVal.localeCompare(bVal)
                    : bVal.localeCompare(aVal);
            });

            // Re-append rows
            sortedRows.forEach(row => tableBody.appendChild(row));

            // Re-assign rows to keep current order for next ops
            rows = sortedRows;
        });
    });
});
