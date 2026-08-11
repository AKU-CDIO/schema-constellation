const assert = require("node:assert/strict");

process.env.K_SERVICE = "schema-constellation-test";
process.env.PORT = "8137";
require("../../server.js");

const identityHeaders = {
  "X-Goog-Authenticated-User-Email": "accounts.google.com:derick.imbati@gcp.cdio.aku.edu",
  "X-Goog-Authenticated-User-Id": "accounts.google.com:123456789",
};

async function run() {
  await new Promise((resolve) => setTimeout(resolve, 250));

  const anonymous = await fetch("http://127.0.0.1:8137/");
  assert.equal(anonymous.status, 401);

  const wrongDomain = await fetch("http://127.0.0.1:8137/", {
    headers: {
      "X-Goog-Authenticated-User-Email": "accounts.google.com:user@example.com",
      "X-Goog-Authenticated-User-Id": "accounts.google.com:987654321",
    },
  });
  assert.equal(wrongDomain.status, 401);

  const home = await fetch("http://127.0.0.1:8137/", { headers: identityHeaders });
  assert.equal(home.status, 200);
  assert.equal(home.headers.get("strict-transport-security"), "max-age=31536000; includeSubDomains");
  assert.equal(home.headers.get("cross-origin-resource-policy"), "same-origin");
  assert.match(await home.text(), /Schema Explorer/);

  const session = await fetch("http://127.0.0.1:8137/auth/session", { headers: identityHeaders });
  assert.equal(session.status, 200);
  assert.equal((await session.json()).email, "derick.imbati@gcp.cdio.aku.edu");

  const missing = await fetch("http://127.0.0.1:8137/not-a-page", { headers: identityHeaders });
  assert.equal(missing.status, 404);

  const traversal = await fetch("http://127.0.0.1:8137/%2e%2e/server.js", { headers: identityHeaders });
  assert.equal(traversal.status, 404);

  console.log("PASS auth runtime: anonymous and off-domain identities denied; IAP domain accepted; security headers and traversal verified");
  process.exit(0);
}

run().catch((error) => {
  console.error(error);
  process.exit(1);
});

