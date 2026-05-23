// theme.js
document.addEventListener('DOMContentLoaded', () => {
    const themeToggleBtn = document.getElementById('theme-toggle');
    if (!themeToggleBtn) return;
    
    const themeIcon = document.getElementById('theme-icon');
    
    // Check local storage for theme preference
    const currentTheme = localStorage.getItem('theme') || 'light';
    
    // Apply theme on load
    if (currentTheme === 'dark') {
        document.documentElement.setAttribute('data-theme', 'dark');
        themeIcon.setAttribute('data-lucide', 'sun');
    } else {
        document.documentElement.removeAttribute('data-theme');
        themeIcon.setAttribute('data-lucide', 'moon');
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
            themeIcon.setAttribute('data-lucide', 'moon');
            targetTheme = 'light';
        } else {
            // Switch to dark
            document.documentElement.setAttribute('data-theme', 'dark');
            themeIcon.setAttribute('data-lucide', 'sun');
            targetTheme = 'dark';
        }
        
        localStorage.setItem('theme', targetTheme);
        
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
