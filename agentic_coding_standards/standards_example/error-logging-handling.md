# Error Handling & Logging Patterns

> **Load when:** Writing error handling, catch blocks, logging statements, or exception classes

---

## Error Handling

### Controller-Level Pattern

Controllers catch exceptions and return consistent error responses. Do not let unhandled exceptions leak to the client.

```csharp
[HttpGet("{orderId:int}")]
public async Task<IActionResult> GetOrder(int orderId, CancellationToken ct)
{
    var order = await cachedOrderRepository.GetByIdAsync(orderId, ct);

    return order is null
        ? NotFound()
        : Ok(order);
}

[HttpPost]
public async Task<IActionResult> CreateOrder(
    [FromBody] CreateOrderRequest request,
    CancellationToken ct)
{
    try
    {
        var orderId = await cachedOrderRepository
            .CreateOrderAsync(request, ct);

        return CreatedAtAction(nameof(GetOrder), new { orderId },
            new CreateOrderResponse { OrderId = orderId });
    }
    catch (OperationCanceledException)
    {
        logger.LogInformation("Request cancelled for order creation");
        return StatusCode(StatusCodes.Status408RequestTimeout,
            "The request was cancelled.");
    }
    catch (Exception ex)
    {
        logger.LogError(ex,
            "Error creating order for account {AccountNumber}",
            request.AccountNumber);
        return StatusCode(StatusCodes.Status500InternalServerError,
            "An error occurred while creating the order.");
    }
}
```

### Error Response Format

API projects use a consistent error response:

```csharp
public sealed record ErrorResponse
{
    public required bool Success { get; init; }  // Always false for errors
    public required string Message { get; init; }
}
```

MVC (Web) projects return JSON for AJAX calls:

```csharp
return Json(new { success = false, message = "Description of what went wrong." });
```

### Exception Handling Rules

| Rule | Details |
|---|---|
| **Catch at boundaries** | Controllers, middleware, background service loops |
| **Don't catch to ignore** | Every catch block must log or return a meaningful response |
| **Catch specific first** | `OperationCanceledException` before `Exception` |
| **Re-throw in services** | Services should not swallow exceptions — let them bubble to the controller |
| **No custom exception classes** | Use standard .NET exceptions (`ArgumentNullException`, `InvalidOperationException`, `KeyNotFoundException`) |
| **Never expose internals** | Return generic messages to clients; log the full exception server-side |

### Status Code Usage

| Code | When to Use |
|---|---|
| `200 OK` | Successful GET, PUT |
| `201 Created` | Successful POST that creates a resource (use `CreatedAtAction`) |
| `204 No Content` | Successful DELETE |
| `400 Bad Request` | Invalid input, validation failure |
| `401 Unauthorized` | Missing or invalid authentication |
| `403 Forbidden` | Authenticated but not authorized |
| `404 Not Found` | Resource does not exist |
| `408 Request Timeout` | `OperationCanceledException` caught |
| `500 Internal Server Error` | Unexpected exception (always log full exception) |

---

## Logging

### ILogger&lt;T&gt; Injection

Every class that needs logging injects `ILogger<T>` via primary constructor:

```csharp
public class OrdersController(
    ICachedOrderRepository cachedOrderRepository,
    ILogger<OrdersController> logger) : ControllerBase
```

### Log Levels

| Level | Use For | Example |
|---|---|---|
| `LogDebug` | Detailed diagnostics, cache hits/misses, internal state | `"Starting cache refresh for key: {CacheKey}"` |
| `LogInformation` | Successful operations, business events, auth events | `"Successfully retrieved user for username: {Username}"` |
| `LogWarning` | Recoverable issues, unexpected HTTP responses, validation gaps | `"External API returned {StatusCode} for account: {AccountNumber}"` |
| `LogError` | Exceptions, operation failures — always include the exception object | `LogError(ex, "Error creating order for account {AccountNumber}", ...)` |

### Structured Logging (Message Templates)

**Always** use message templates with named parameters. Never use string interpolation.

```csharp
// ✅ Correct — structured, searchable, parameters captured as properties
logger.LogInformation(
    "Successfully retrieved user for username: {Username}. External user found: {ExternalUserFound}",
    username, externalUser != null);

logger.LogError(ex,
    "Error retrieving user for username: {Username}",
    username);

// ❌ Wrong — string interpolation destroys structured logging
logger.LogInformation($"Successfully retrieved user for {username}");
logger.LogError($"Error: {ex.Message}");
```

### Exception Logging

**Always pass the exception object as the first parameter.** This ensures the full stack trace is captured.

```csharp
// ✅ Correct — full exception + context
catch (Exception ex)
{
    logger.LogError(ex, "Error creating order for account {AccountNumber}",
        request.AccountNumber);
    return StatusCode(500, "An error occurred.");
}

// ❌ Wrong — loses stack trace
catch (Exception ex)
{
    logger.LogError("Error: {Message}", ex.Message);
}
```

### OperationCanceledException

Cancellation is expected, not an error. Log at Information level and don't re-throw from controller boundaries.

```csharp
catch (OperationCanceledException)
{
    logger.LogInformation("Request cancelled for operation: {Operation}", nameof(GetOrders));
    return StatusCode(StatusCodes.Status408RequestTimeout, "The request was cancelled.");
}
```

In background services, use cancellation to exit loops cleanly:

```csharp
catch (OperationCanceledException)
{
    logger.LogInformation("{ServiceName} cancellation requested", nameof(ProductCacheRefreshService));
    break;
}
```

### Logging Configuration

Standard `appsettings.json` configuration:

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  }
}
```

| Namespace | Level | Reason |
|---|---|---|
| `Default` | `Information` | Capture operational events |
| `Microsoft.AspNetCore` | `Warning` | Reduce framework noise |
| App namespace (e.g., `MyApp.Web`) | `Debug` | Enhanced visibility when needed |

### What NOT to Log

- Passwords, tokens, API keys, or secrets
- Full request/response bodies containing PII
- Credit card numbers or payment details
- Health check pings (use `Warning` level filter for health check endpoints)
