// `npm run keys` or, on the server, `docker compose run --rm api node dist/keys.js`.
// Prints a fresh Ed25519 key pair for license tokens and a random AUTH_PEPPER.
// The private key goes only into the server's .env. The public key goes into .env and into the app
// (Sources/MacCleaner/Licensing/LicenseConfig.swift). Generate once: a new pair invalidates every issued token.
import { randomBytes } from "node:crypto";
import { generateKeyPair } from "./license.js";

const { privateKey, publicKey } = generateKeyPair();
console.log(`LICENSE_PRIVATE_KEY=${privateKey}`);
console.log(`LICENSE_PUBLIC_KEY=${publicKey}`);
console.log(`AUTH_PEPPER=${randomBytes(32).toString("base64url")}`);
console.log(`ADMIN_TOKEN=${randomBytes(24).toString("base64url")}`);
