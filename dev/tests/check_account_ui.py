from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PAGES = ["index.html", "explorer.html", "topics.html", "sql.html", "sps.html", "sp-review.html", "404.html"]


def main() -> None:
    script = (ROOT / "assets" / "account.js").read_text(encoding="utf-8")
    styles = (ROOT / "assets" / "account.css").read_text(encoding="utf-8")

    assert 'className = "user-account"' in script
    assert "Personal information" in script
    assert "https://myaccount.google.com/personal-info" in script
    assert "Password &amp; security" in script
    assert "https://myaccount.google.com/security" in script
    assert 'href="/auth/signout"' in script
    assert 'event.key === "Escape"' in script
    assert ".user-avatar" in styles
    assert ".user-signout" in styles

    for page in PAGES:
        html = (ROOT / page).read_text(encoding="utf-8")
        assert 'href="assets/account.css?v=1"' in html, page
        assert 'src="assets/account.js?v=1"' in html, page
        assert 'assets/auth.js' not in html, page

    print("PASS account UI: avatar, profile management, security, and sign-out")


if __name__ == "__main__":
    main()

