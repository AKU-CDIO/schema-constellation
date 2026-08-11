from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PAGES = [
    "index.html",
    "explorer.html",
    "topics.html",
    "sql.html",
    "mapping.html",
    "sps.html",
    "sp-review.html",
    "404.html",
]


def main() -> None:
    server = (ROOT / "server.js").read_text(encoding="utf-8")
    auth = (ROOT / "assets" / "account.js").read_text(encoding="utf-8")
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert 'x-goog-authenticated-user-email' in server
    assert 'x-goog-authenticated-user-id' in server
    assert '"/auth/session"' in server
    assert 'gcp-iap-mode=CLEAR_LOGIN_COOKIE' in server
    assert 'Content-Security-Policy' in server
    assert 'USER node' in dockerfile
    assert 'credentials: "same-origin"' in auth

    for page in PAGES:
        html = (ROOT / page).read_text(encoding="utf-8")
        assert 'src="assets/account.js?v=2"' in html, page

    print("PASS auth integration: IAP headers, session UI, protected server, and all pages")


if __name__ == "__main__":
    main()

