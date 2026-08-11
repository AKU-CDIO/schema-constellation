const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = __dirname;
const PORT = Number(process.env.PORT || 8080);
const IS_CLOUD_RUN = Boolean(process.env.K_SERVICE);
const ALLOWED_EMAIL_DOMAIN = String(
  process.env.AUTH_ALLOWED_EMAIL_DOMAIN || "gcp.cdio.aku.edu"
).trim().toLowerCase();
const PUBLIC_FILES = new Set([
  "404.html",
  "explorer.html",
  "index.html",
  "mapping.html",
  "robots.txt",
  "sitemap.xml",
  "sp-review.html",
  "sps.html",
  "sql.html",
  "topics.html",
]);
const PUBLIC_DIRECTORIES = new Set(["assets", "data"]);

const MIME_TYPES = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
};

function stripIdentityPrefix(value = "") {
  return String(value).replace(/^[^:]+:/, "").trim();
}

function getIdentity(request) {
  const email = stripIdentityPrefix(request.headers["x-goog-authenticated-user-email"]);
  const id = stripIdentityPrefix(request.headers["x-goog-authenticated-user-id"]);

  if (email && id) {
    const normalizedEmail = email.toLowerCase();
    const allowed = normalizedEmail.endsWith(`@${ALLOWED_EMAIL_DOMAIN}`);
    if (!IS_CLOUD_RUN || allowed) return { email, id };
    return null;
  }
  if (!IS_CLOUD_RUN) {
    return {
      email: process.env.LOCAL_AUTH_EMAIL || "local.developer@aku.edu",
      id: "local-development-user",
    };
  }
  return null;
}

function setSecurityHeaders(response) {
  response.setHeader("Content-Security-Policy", [
    "default-src 'self'",
    "base-uri 'self'",
    "connect-src 'self'",
    "font-src 'self' data:",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "img-src 'self' data:",
    "object-src 'none'",
    "script-src 'self' 'unsafe-inline'",
    "style-src 'self' 'unsafe-inline'",
  ].join("; "));
  response.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  response.setHeader("Cross-Origin-Resource-Policy", "same-origin");
  response.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  response.setHeader("Referrer-Policy", "same-origin");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("X-Frame-Options", "DENY");
  response.setHeader("X-Permitted-Cross-Domain-Policies", "none");
  if (IS_CLOUD_RUN) {
    response.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  }
}

function sendJson(response, statusCode, body) {
  const payload = JSON.stringify(body);
  response.writeHead(statusCode, {
    "Cache-Control": "private, no-store",
    "Content-Length": Buffer.byteLength(payload),
    "Content-Type": "application/json; charset=utf-8",
  });
  response.end(payload);
}

function sendUnauthorized(request, response) {
  const acceptsHtml = String(request.headers.accept || "").includes("text/html");
  if (!acceptsHtml) {
    sendJson(response, 401, { error: "Authentication required" });
    return;
  }

  const payload = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Sign-in required</title><style>body{font-family:system-ui,sans-serif;background:#07101f;color:#eef4ff;display:grid;place-items:center;min-height:100vh;margin:0}.card{max-width:34rem;padding:2rem;border:1px solid #24344e;border-radius:18px;background:#101c30}h1{margin-top:0;color:#f0c24b}p{line-height:1.6;color:#bdc9dc}</style><main class="card"><h1>Sign-in required</h1><p>This AKU CDIO platform is protected by Google Cloud. Open the approved platform address and sign in with an account that has been granted access.</p></main></html>`;
  response.writeHead(401, {
    "Cache-Control": "private, no-store",
    "Content-Length": Buffer.byteLength(payload),
    "Content-Type": "text/html; charset=utf-8",
  });
  response.end(payload);
}

function resolveStaticFile(pathname) {
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }

  if (decoded === "/") decoded = "/index.html";
  if (decoded.endsWith("/")) decoded += "index.html";

  const relativePath = decoded.replace(/^\/+/, "");
  const firstSegment = relativePath.split("/")[0];
  if (!PUBLIC_FILES.has(relativePath) && !PUBLIC_DIRECTORIES.has(firstSegment)) return null;
  if (relativePath.split("/").some((segment) => segment.startsWith("."))) return null;

  const candidate = path.resolve(ROOT, `.${decoded}`);
  if (candidate !== ROOT && !candidate.startsWith(`${ROOT}${path.sep}`)) return null;
  return candidate;
}

function serveStatic(request, response, pathname) {
  const requestedFile = resolveStaticFile(pathname);
  let filePath = requestedFile;
  let statusCode = 200;

  if (!filePath || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    filePath = path.join(ROOT, "404.html");
    statusCode = 404;
  }

  const extension = path.extname(filePath).toLowerCase();
  const contentType = MIME_TYPES[extension] || "application/octet-stream";
  const stat = fs.statSync(filePath);
  const isDocumentOrData = extension === ".html" || extension === ".js" || extension === ".xml";

  response.writeHead(statusCode, {
    "Cache-Control": isDocumentOrData
      ? "private, no-cache, no-store, must-revalidate"
      : "private, max-age=3600, must-revalidate",
    "Content-Length": stat.size,
    "Content-Type": contentType,
  });

  if (request.method === "HEAD") {
    response.end();
    return;
  }
  fs.createReadStream(filePath).pipe(response);
}

const server = http.createServer((request, response) => {
  setSecurityHeaders(response);

  if (request.method !== "GET" && request.method !== "HEAD") {
    response.setHeader("Allow", "GET, HEAD");
    sendJson(response, 405, { error: "Method not allowed" });
    return;
  }

  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  const identity = getIdentity(request);
  if (!identity) {
    sendUnauthorized(request, response);
    return;
  }

  if (url.pathname === "/auth/session") {
    sendJson(response, 200, {
      authenticated: true,
      email: identity.email,
      id: identity.id,
      provider: IS_CLOUD_RUN ? "Google Cloud IAP" : "Local development",
      allowed_domain: ALLOWED_EMAIL_DOMAIN,
    });
    return;
  }

  if (url.pathname === "/auth/signout") {
    response.writeHead(302, {
      "Cache-Control": "private, no-store",
      Location: "/?gcp-iap-mode=CLEAR_LOGIN_COOKIE",
    });
    response.end();
    return;
  }

  serveStatic(request, response, url.pathname);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Schema Constellation listening on port ${PORT}`);
});

