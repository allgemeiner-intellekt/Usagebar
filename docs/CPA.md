# CLIProxyAPI usage source

Open the panel's settings menu and select Data source. Enter the CPA base address, without `/v8/management` or `/v0/management`, and its management key, then choose Test and enable. Authentication and account discovery must succeed before the saved connection or selected source changes. An empty authenticated account list is valid.

The global source defaults to Direct for existing installations. Switching retains both configurations, clears displayed readings, cancels old work, and fetches the selected source. Failures never fall back to local credentials. Clear saved CPA removes only the CPA connection and returns to Direct.

The connection and key are stored in the existing device-encrypted credential file. HTTPS uses system certificate verification. HTTP transmits the management key without transport encryption; use HTTPS for remote connections. Remote CPA access must be enabled in CPA itself. No certificate validation bypass or CPA configuration changes are performed.

CPA discovery uses `GET /v8/management/credentials`, with `GET /v0/management/auth-files` compatibility when the v8 route is absent. Quotas use account-pinned `POST /v8/management/requests/api-call` or legacy `POST /v0/management/api-call`. Authentication rejection does not trigger version probing. These operations only read account lists and provider quota endpoints. Usagebar never starts CPA, logs in accounts, or changes routing, account flags, or credentials.

Codex, Kimi Code, Grok Build and Claude quota responses are normalized into independent account windows. Cursor and z.ai accounts remain visible with an explicit unsupported-quota message because the current CPA account authentication does not establish the cookie or dashboard authentication required by these direct integrations. Provider names alone do not establish endpoint compatibility. Missing or incomplete quota responses show an error rather than zero usage.

Single accounts retain compact cards. Multiple accounts show stable identities and independent readings inside the provider card. Disabled and expired accounts remain visible without quota requests. Failures retain same-source readings with their original success time. Account discovery reconciles successful lists and preserves existing accounts on failure. The existing visibility cadence, power suspension and per-account retry policy apply.

References: [v8 management API](https://help.router-for.me/management/apiv8), [legacy management API](https://help.router-for.me/management/api).
