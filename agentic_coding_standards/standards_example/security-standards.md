# Security Standards

> **Load when:** Working on authentication, authorization, input handling, secrets, or any security-sensitive code

---

## Authentication

### JWT Bearer (API Projects)

- Use `JwtBearerDefaults.AuthenticationScheme`
- Validate: issuer, audience, lifetime, signing key
- Clock skew: 5 minutes maximum
- Sign with HMAC-SHA256
- Include `jti` (unique token ID) and `iat` (issued at) claims
- Load JWT settings (secret key, issuer, audience) from **AWS Secrets Manager** — never from `appsettings.json`

### Cookie Authentication (Web/MVC Projects)

- `HttpOnly = true` — always
- `SecurePolicy = Always` in non-development environments
- `SameSite = Lax` (or `Strict` where appropriate)
- Sliding expiration: 30 minutes
- Absolute expiration: 8 hours (force re-login regardless of activity)

### API Key Authentication (Internal Microservices)

- Header: `X-Api-Key`
- Use ordinal (case-sensitive) string comparison
- Skip auth for `/health` and `/swagger` endpoints only
- Log warnings for missing or invalid keys (do not log the key value itself)

---

## Authorization

- Apply `[Authorize]` at **class level** on controllers that require authentication
- Use `[AllowAnonymous]` only on specific actions that must be public (login, health check)
- Policy-based authorization for environment-specific rules (e.g., `DevelopmentOrAuthenticated`)

---

## CORS

- Configure allowed origins from `appsettings.json` — never hardcode production URLs
- Use a named policy (e.g., `"AllowWebApp"`)
- `AllowCredentials()` when cookies or auth headers are needed

```csharp
options.AddPolicy("AllowWebApp", policy =>
{
    var allowedOrigins = configuration.GetSection("Cors:AllowedOrigins")
        .Get<string[]>() ?? ["https://localhost:7029"];

    policy.WithOrigins(allowedOrigins)
          .AllowAnyMethod()
          .AllowAnyHeader()
          .AllowCredentials();
});
```

---

## Secrets Management

### AWS Secrets Manager (Required)

All secrets **must** be loaded via AWS Secrets Manager. Never store secrets in:

- `appsettings.json` (development connection strings with Integrated Security are acceptable)
- Environment variables (except to override Secrets Manager key prefix)
- Source code or comments

```csharp
var secretsManager = SecretsManager.ForWebApplication(builder, keyPrefix: "MyApp");
secretsManager.RegisterSecretsManager();

// Load connection strings from secrets
services.AddPooledResilientSqlServerDbContext<AppDbContext>(
    secretsManager.GetSecretValue("ConnectionString.App")!);
```

### What Qualifies as a Secret

- Database connection strings (production/staging)
- JWT signing keys
- API keys (internal and third-party)
- SendGrid API keys
- External API credentials
- Any password or token

---

## Input Validation

### Request DTOs

Use data annotation attributes on all request DTOs:

| Attribute | Use For |
|---|---|
| `[Required]` | Mandatory fields |
| `[StringLength(n)]` | Maximum string length |
| `[Range(min, max)]` | Numeric range constraints |
| `[RegularExpression]` | Pattern validation (e.g., zip codes: `@"^\d{5}(-\d{4})?$"`) |
| `[EmailAddress]` | Email format |
| `[Phone]` | Phone number format |
| `[Url]` | URL format |

### DAL-Level Sanitization

Use `SanitizeTextFilter` (from `BaseRepository`) for any user-provided text used in queries. Use `SanitizePhoneNumber` for phone number inputs.

### Rules

- Never build SQL strings with user input — use LINQ and parameterized queries only
- Validate at the API boundary (request DTOs) — don't rely on client-side validation
- Sanitize text at the DAL layer before using in filters or searches

---

## Anti-Forgery (CSRF)

Required for MVC web applications:

```csharp
services.AddAntiforgery(options =>
{
    options.HeaderName = "RequestVerificationToken";
    options.Cookie.Name = "MyApp.AntiForgery";
    options.Cookie.HttpOnly = true;
    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    options.Cookie.SameSite = SameSiteMode.Strict;
});
```

- Use `[ValidateAntiForgeryToken]` on POST/PUT/DELETE actions in MVC controllers
- API controllers using JWT Bearer do not need anti-forgery (token-based auth is inherently CSRF-resistant)

---

## HTTPS & Transport Security

- `app.UseHttpsRedirection()` — required in all projects
- `app.UseHsts()` — required in web/MVC projects (non-development)
- All inter-service communication must use HTTPS in non-development environments

---

## Logging Security

Never log:

- Passwords, tokens, API keys, or signing keys
- Credit card numbers or payment details
- Full request/response bodies containing PII
- Social Security Numbers or government IDs

Acceptable to log:

- Usernames (for audit trail)
- Account numbers (non-PII identifiers)
- Request IDs and correlation IDs
- HTTP status codes and error messages (without sensitive details)
