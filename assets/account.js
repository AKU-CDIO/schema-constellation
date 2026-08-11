(() => {
  const nav = document.querySelector(".nav, #app > header");
  if (!nav) return;

  fetch("/auth/session", {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  })
    .then((response) => {
      if (!response.ok) throw new Error("No authenticated session");
      return response.json();
    })
    .then((session) => {
      if (!session.authenticated || !session.email) return;

      const email = String(session.email);
      const initials = getInitials(email);
      const account = document.createElement("details");
      account.className = "user-account";
      account.innerHTML = `
        <summary aria-label="Open account menu for ${escapeHtml(email)}">
          <span class="user-avatar" aria-hidden="true">${escapeHtml(initials)}</span>
          <span class="user-summary-copy">
            <small>AKU CDIO account</small>
            <b>${escapeHtml(email)}</b>
          </span>
          <span class="user-chevron" aria-hidden="true">⌄</span>
        </summary>
        <section class="user-menu" aria-label="Account options">
          <header class="user-profile">
            <span class="user-avatar user-avatar-large" aria-hidden="true">${escapeHtml(initials)}</span>
            <span>
              <strong>Google Workspace profile</strong>
              <small>${escapeHtml(email)}</small>
              <em>Authenticated by Google Cloud</em>
            </span>
          </header>
          <nav class="user-menu-links" aria-label="Profile management">
            <a href="https://myaccount.google.com/personal-info" target="_blank" rel="noopener noreferrer">
              <span class="user-menu-icon" aria-hidden="true">●</span>
              <span><b>Personal information</b><small>Update your name, photo and contact details</small></span>
              <span class="user-menu-arrow" aria-hidden="true">↗</span>
            </a>
            <a href="https://myaccount.google.com/security" target="_blank" rel="noopener noreferrer">
              <span class="user-menu-icon" aria-hidden="true">◆</span>
              <span><b>Password &amp; security</b><small>Manage your password and account protection</small></span>
              <span class="user-menu-arrow" aria-hidden="true">↗</span>
            </a>
          </nav>
          <footer class="user-menu-footer">
            <span>Profile details are managed by AKU Google Workspace.</span>
            <a class="user-signout" href="/auth/signout">Sign out of this platform</a>
          </footer>
        </section>`;
      nav.appendChild(account);

      document.addEventListener("click", (event) => {
        if (!account.contains(event.target)) account.removeAttribute("open");
      });
      document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          account.removeAttribute("open");
          account.querySelector("summary")?.focus();
        }
      });
    })
    .catch(() => {
      // Google Cloud IAP owns the production sign-in flow. If there is no
      // authenticated session, the server blocks the protected platform.
    });

  function getInitials(email) {
    const localPart = email.split("@")[0];
    const parts = localPart.split(/[._-]+/).filter(Boolean);
    if (parts.length > 1) return `${parts[0][0]}${parts[1][0]}`.toUpperCase();
    return localPart.slice(0, 2).toUpperCase();
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "'": "&#39;",
      '"': "&quot;",
    })[character]);
  }
})();

