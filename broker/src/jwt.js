// App JWT for GitHub App authentication (RS256), with WebCrypto only.
// The key arrives as a PKCS#8 PEM (the App's PKCS#1 key, converted once with
// `openssl pkcs8 -topk8 -nocrypt`, because WebCrypto imports PKCS#8 only).

let cached = { pem: null, key: null };

function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlJson(obj) {
  return b64url(new TextEncoder().encode(JSON.stringify(obj)));
}

function pemToDer(pem) {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const der = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}

async function importKey(pem) {
  if (cached.pem === pem && cached.key) return cached.key;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  cached = { pem, key };
  return key;
}

// appJwt(appId, pkcs8Pem, nowSec): a 9-minute JWT, backdated 60 s for clock skew.
export async function appJwt(appId, pkcs8Pem, nowSec) {
  const header = b64urlJson({ alg: "RS256", typ: "JWT" });
  const payload = b64urlJson({ iat: nowSec - 60, exp: nowSec + 540, iss: String(appId) });
  const data = new TextEncoder().encode(`${header}.${payload}`);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await importKey(pkcs8Pem), data);
  return `${header}.${payload}.${b64url(new Uint8Array(sig))}`;
}
