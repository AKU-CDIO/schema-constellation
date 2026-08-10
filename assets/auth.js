(() => {
  const nav = document.querySelector(".nav");
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

      const account = document.createElement("details");
      account.className = "auth-account";

      const initial = session.email.charAt(0).toUpperCase();
      account.innerHTML = `
        <summary aria-label="Signed in as ${escapeHtml(session.email)}">
          <span class="auth-avatar" aria-hidden="true">${escapeHtml(initial)}</span>
          <span class="auth-copy"><small>Signed in</small><b>${escapeHtml(session.email)}</b></span>
        </summary>
        <div class="auth-menu">
          <span>Protected by Google Cloud</span>
          <a href="/auth/signout">Switch account</a>
        </div>`;
      nav.appendChild(account);

      document.addEventListener("click", (event) => {
        if (!account.contains(event.target)) account.removeAttribute("open");
      });
    })
    .catch(() => {
      // The legacy static-bucket copy has no session endpoint. The protected
      // Cloud Run deployment is the canonical authenticated platform.
    });

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

