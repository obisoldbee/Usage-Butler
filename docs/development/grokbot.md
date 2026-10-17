# Grok Bot native source candidate

PRD 0.43 candidate. No installation, real-account acceptance or shared-pool support is implied.

The settings switch **允许只读使用 Cursor 会话** is off by default. Granting it permits only the fixed Cursor `User/globalStorage/state.vscdb` source and its `cursorAuth/accessToken` key. The adapter uses the token only in memory to make the two fixed requests below. Revoking cancels in-flight work, replaces its generation, removes retained Grok data, and performs no logout or source modification. No browser, Keychain, token refresh, model call, purchase or bot-management path exists.

- `GET https://cursor.com/api/auth/me`, requiring a subject matching the local JWT subject.
- `POST https://cursor.com/api/dashboard/get-sand-usage-status`, JSON `{}` and the same memory-only session cookie.

The file reader checks the exact path's ownership, types and write permissions, uses SQLite read-only mode with a fixed one-key query and a 250 ms SQLite budget, supports TEXT and UTF-8/UTF-16LE BLOB, and never copies or changes the source. In WAL mode it requires existing valid sidecars; it does not use an immutable fallback or create missing sidecars. A locked or unsupported source fails closed. HTTP is ephemeral without persistent cookies, credentials or cache, denies redirects, bounds each request to 5 seconds and each response to 64 KiB. Two sequential HTTP requests and bounded local reads give a finite chain budget. Account/session changes during the chain reject its result.

`ProviderSourceIdentity.transport` records HTTPS origin, adapter/schema/contract versions and fixed evidence. Grok last-good is persisted as a separate versioned encrypted envelope through the existing private descriptor-relative cache file operations (0700 directories, 0600 entries, bounded reads, atomic replacement and no symlink traversal). The three CLI Providers keep their existing v1 wire format; their payloads do not gain a Grok field.

The adapter derives an in-memory key from the entire currently authorized, locally valid exact session using system CryptoKit [HKDF-SHA256](https://developer.apple.com/documentation/cryptokit/hkdf). The normalized quota payload is sealed using [AES-GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm), a library-generated nonce and a fixed Provider/schema/version authenticated context. No key, token, Cookie, subject, session scope or bare identity/token hash is encoded. A restart may decrypt only with the same valid exact session, then binds the decoded identity graph to a new process-local scope. It restores the original successful timestamp as stale and does not claim current server authentication. Rotation, account change, expiry and absent/closed authorization safely miss; there is no sub-based fallback.

Revocation cancels work and clears memory and disk. Clearing quota cache also invalidates the in-memory scope, preventing an old queued value from being saved afterward. Controller-stamped access revisions reject late re-enables, and the file actor checks a clear/write ticket immediately before atomic replacement. The same mechanisms prevent late startup loads from resurrecting a cleared value. File permission/I/O/corrupt/schema failures publish no cached data and enter existing persistence health with fixed safe codes; an absent file or unconfirmed session association is a normal miss. An authentication-tag failure cannot distinguish damaged ciphertext from a rotated session and remains a safe miss. No raw error text is recorded.

`cursor-sand` is separate from the `legacyCursor`, `xShared` and `unknown` metering systems. Live reads always remain `unknown`, because neither verified endpoint establishes the account's migration status. The card labels them as source readings and says the shared weekly pool is unsupported. An explicitly supplied `xShared` fixture suppresses the numeric balance. Unknown Sand data cannot trigger quota alerts. No account is inferred from matching email, percentage or reset time.

Source fields, missing/zero/invalid percentages, availability and included-limit flags remain distinct. `includedLimitZero` overrides the older inverse flag. Trial expiry is an entitlement event; JWT expiry is authentication evidence. A recurring reset stays a server-reported time, even when already past. Failure retains same-account last-good with its original successful timestamp, except when its identity cannot be established. There is no authoritative negative-subscription inference from empty responses or HTTP failures.

OpenAI credits continue using `account/rateLimits/read`. Decimal strings are checked as complete numeric values, `null` stays unknown, numeric zero stays zero, `unlimited` is independent, and `hasCredits` never supplies a balance. The existing reset-count/detail disclosure is retained. Batch expiry and email import remain outside this candidate.

Reference implementation inspected at [CodexBar 910dc82e](https://github.com/steipete/CodexBar/tree/910dc82e78e212f8904f3725a756ad03fa86c551): `CursorAppAuth.swift`, `CursorSandUsage.swift`, `CursorStatusProbe.swift`. Peter Steinberger's MIT notice is retained in [CodexBar-MIT.txt](../licenses/CodexBar-MIT.txt). Public reference code is endpoint/schema evidence, not proof of real-account behavior.

For a native offline preview, commit the candidate and run:

```sh
python3 script/build_copy_preview.py --variant GrokBot --ref HEAD --destination .build/grokbot-preview
```

The build receipt identifies an exact isolated bundle `io.github.obisoldbee.UsageButler.Preview.Copy.GrokBot`. It has no embedded helper. This identity resolves to offline mode even without arguments. To capture, open that exact bundle path with `--args --grokbot-output=<new empty task directory>`. Its recorder returns before shortcut installation and uses synthetic inputs and volatile preference defaults. Screenshots are fixture UI evidence only.

Real acceptance remains pending until the user enables the source in the product and authorizes comparison against the same account's official page at the same time, including metering system, usage, reset, trial expiry and authentication behavior. The current candidate must first pass manager review and an independently authorized integration/install gate.
