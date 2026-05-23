// theme.js
document.addEventListener('DOMContentLoaded', () => {
    const themeToggleBtn = document.getElementById('theme-toggle');
    if (!themeToggleBtn) return;

    // Check local storage for theme preference
    const currentTheme = localStorage.getItem('theme') || 'light';

    // Apply theme on load
    const initialIcon = document.getElementById('theme-icon');
    if (initialIcon) {
        if (currentTheme === 'dark') {
            document.documentElement.setAttribute('data-theme', 'dark');
            initialIcon.setAttribute('data-lucide', 'sun');
        } else {
            document.documentElement.removeAttribute('data-theme');
            initialIcon.setAttribute('data-lucide', 'moon');
        }
    }

    // Re-initialize lucide icons so the correct icon is rendered
    if (window.lucide) {
        lucide.createIcons();
    }

    themeToggleBtn.addEventListener('click', (e) => {
        e.preventDefault();
        let targetTheme = 'light';

        if (document.documentElement.hasAttribute('data-theme')) {
            // Switch to light
            document.documentElement.removeAttribute('data-theme');
            targetTheme = 'light';
        } else {
            // Switch to dark
            document.documentElement.setAttribute('data-theme', 'dark');
            targetTheme = 'dark';
        }

        localStorage.setItem('theme', targetTheme);

        // Lucide replaces the <i> element with an <svg>, so we must recreate the <i> tag
        const currentIcon = document.getElementById('theme-icon');
        if (currentIcon) {
            const newIcon = document.createElement('i');
            newIcon.id = 'theme-icon';
            newIcon.setAttribute('data-lucide', targetTheme === 'dark' ? 'sun' : 'moon');
            currentIcon.parentNode.replaceChild(newIcon, currentIcon);
        }

        // Render new icon
        if (window.lucide) {
            lucide.createIcons();
        }
    });
});

// Immediately apply theme before DOMContentLoaded to prevent flash of wrong theme
(function() {
    if (localStorage.getItem('theme') === 'dark') {
        document.documentElement.setAttribute('data-theme', 'dark');
    }
})();
