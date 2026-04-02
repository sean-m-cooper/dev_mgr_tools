# Azure Functions Standards

> **Load when:** Working on Azure Functions — creating new functions, modifying triggers, or configuring host setup

---

## Platform & Model

- **Isolated worker process** — all functions use `ConfigureFunctionsWebApplication()` (not in-process)
- **.NET 8** targeting `net8.0`
- Application Insights telemetry registered in every function project

---

## Project Structure

Each Azure Function project is a standalone host with its own `Program.cs`, DI registration, and one or more function classes. Function classes are thin orchestrators — business logic lives in injected services.

```
MyApp.MyFunction/
├── Program.cs              ← Host builder, DI registration
├── appsettings.json        ← Non-sensitive configuration
├── appsettings.Development.json
├── Secrets.json            ← Local secrets (never committed)
├── MyFunction.cs           ← Function trigger class
└── Services/               ← Function-specific service classes
```

---

## Program.cs — Host Setup

Every function project follows this `HostBuilder` pattern:

```csharp
var host = new HostBuilder()
    .ConfigureFunctionsWebApplication()
    .ConfigureAppConfiguration((hostContext, config) =>
    {
        var env = hostContext.HostingEnvironment;

        config.AddJsonFile("appsettings.json", optional: true, reloadOnChange: true)
              .AddJsonFile($"appsettings.{env.EnvironmentName}.json", optional: true, reloadOnChange: true);
        config.SetBasePath(env.ContentRootPath)
              .AddJsonFile("Secrets.json", optional: true, reloadOnChange: true);
        config.AddEnvironmentVariables();

        // Remap environment-provided connection names to expected config keys
        // (e.g., Aspire AppHost injects "queues" and "blobs" env vars)
        var queueConn = Environment.GetEnvironmentVariable("queues");
        var blobConn = Environment.GetEnvironmentVariable("blobs");
        var overrides = new Dictionary<string, string?>();
        if (!string.IsNullOrEmpty(queueConn)) overrides["ConnectionStrings:AzureWebJobsStorage"] = queueConn;
        if (!string.IsNullOrEmpty(blobConn)) overrides["ConnectionStrings:BlobStorage"] = blobConn;
        if (overrides.Count > 0)
            config.AddInMemoryCollection(overrides.Where(kv => kv.Value != null)
                                                  .ToDictionary(kv => kv.Key, kv => kv.Value!));
    })
    .ConfigureServices((hostContext, services) =>
    {
        // Application Insights — required in every function project
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();

        // Azure SDK clients — guard against missing connection strings (local dev may omit them)
        var queueConnection = hostContext.Configuration.GetConnectionString("AzureWebJobsStorage");
        var blobConnection = hostContext.Configuration.GetConnectionString("BlobStorage");
        if (!string.IsNullOrEmpty(queueConnection))
            services.AddSingleton(_ => new QueueServiceClient(queueConnection));
        if (!string.IsNullOrEmpty(blobConnection))
            services.AddSingleton(_ => new BlobServiceClient(blobConnection));

        services.AddSingleton<IQueueManager, QueueManager>();
        services.AddSingleton<IBlobManager, BlobManager>();

        // DbContext — Scoped, registered only when the function needs database access
        var connString = hostContext.Configuration.GetConnectionString("AppDb");
        services.AddDbContext<AppDbContext>(options => options.UseSqlServer(connString));

        // Repositories — Scoped
        services.AddScoped<IOrderRepository, OrderRepository>();

        // Function-specific services — Scoped or Singleton depending on state
        services.AddScoped<IOrderProcessingService, OrderProcessingService>();
    })
    .ConfigureLogging(logging =>
    {
        // Suppress EF Core query noise in logs
        logging.AddFilter("Microsoft.EntityFrameworkCore", LogLevel.Warning);
    })
    .Build();

host.Run();
```

**Rules:**
- Always call `AddApplicationInsightsTelemetryWorkerService()` + `ConfigureFunctionsApplicationInsights()`
- Guard Azure SDK client registration with null/empty connection string checks
- `Secrets.json` is the local secrets file — add it to `.gitignore`, never commit it
- `AddEnvironmentVariables()` must be last so environment overrides take precedence
- EF Core noise (`Microsoft.EntityFrameworkCore`) filtered to `Warning` to reduce log volume

---

## DI Lifetime Rules

| Component | Lifetime | Reason |
|---|---|---|
| `IQueueManager`, `IBlobManager` | `Singleton` | Stateless, thread-safe wrappers |
| `QueueServiceClient`, `BlobServiceClient` | `Singleton` | Azure SDK clients are thread-safe and expensive to create |
| `IHttpClientFactory` clients | `Singleton` (via `AddHttpClient`) | Connection pool management |
| DbContext | `Scoped` (via `AddDbContext`) | EF Core DbContext is not thread-safe |
| Repositories | `Scoped` | Share a single DbContext per function invocation |
| Persistence/orchestration services | `Scoped` | Coordinate across repositories |
| Factories, mappers, validators | `Singleton` | Stateless |

---

## Configuration

### Layered Configuration (lowest to highest priority)

1. `appsettings.json` — defaults and non-sensitive settings
2. `appsettings.{Environment}.json` — environment-specific overrides
3. `Secrets.json` — local development secrets (not committed)
4. Environment variables — CI/CD and production values; always win

### Named Configuration

Read strongly-typed configuration in `Program.cs` and register as a singleton to avoid repeated `IConfiguration` reads inside services:

```csharp
var cfg = new ProcessingConfiguration
{
    ApiKey    = hostContext.Configuration.GetValue<string>("AI_API_KEY") ?? "",
    ApiUrl    = hostContext.Configuration.GetValue<string>("AI_ENDPOINT") ?? "",
    MaxRetries = hostContext.Configuration.GetValue<int>("MaxRetries", 5),
};
services.AddSingleton(cfg);
```

### HttpClient Timeout

Long-running external calls (AI APIs, third-party services) need explicit timeout configuration:

```csharp
services.AddHttpClient("external-api")
        .ConfigureHttpClient(c => c.Timeout = TimeSpan.FromMinutes(5));
```

### Rate Limiting

Use `AddRateLimiter` for functions that call rate-limited APIs (e.g., AI providers):

```csharp
services.AddRateLimiter(_ => _.AddConcurrencyLimiter("default", options =>
{
    options.PermitLimit = 2;
    options.QueueProcessingOrder = QueueProcessingOrder.OldestFirst;
}));
```

---

## Base Class Pattern

All function classes inherit from a shared base that provides common infrastructure:

```csharp
public class AppFunctionBase(
    ILogger logger,
    IConfiguration configuration,
    IQueueManager queueManager,
    IBlobManager blobManager)
{
    protected readonly ILogger _logger = logger
        ?? throw new ArgumentNullException(nameof(logger));
    protected readonly IQueueManager _queueManager = queueManager
        ?? throw new ArgumentNullException(nameof(queueManager));
    protected readonly IBlobManager _blobManager = blobManager
        ?? throw new ArgumentNullException(nameof(blobManager));

    protected readonly string _storageConnectionString =
        configuration.GetConnectionString("AzureWebJobsStorage")
        ?? throw new InvalidOperationException("AzureWebJobsStorage connection string is required.");
    protected readonly string _blobStorageConnectionString =
        configuration.GetConnectionString("BlobStorage")
        ?? throw new InvalidOperationException("BlobStorage connection string is required.");

    // Error state — set in catch blocks, read in finally
    protected string? ErrorMessage { get; set; }
    protected Exception? Exception { get; set; }

    protected static T DeserializeMessage<T>(string messageText) =>
        JsonSerializer.Deserialize<T>(messageText)!;

    protected async Task<bool> SaveMessageToQueueAsync(QueueMessageBase message, string queueName) =>
        await _queueManager.SaveMessageToQueueAsync(message.ToString(), queueName, _storageConnectionString);

    protected async Task<bool> SaveErrorMessageAsync(Guid documentId, string sourceQueue, string errorMessage)
    {
        var msg = new ErrorQueueMessage(documentId, sourceQueue, errorMessage);
        return await _queueManager.SaveMessageToQueueAsync(msg.ToString(), "errors", _storageConnectionString);
    }
}
```

**Rules:**
- Null-guard all constructor parameters with `?? throw new ArgumentNullException(...)`
- Resolve connection strings eagerly in the constructor — fail fast if missing
- `ErrorMessage` and `Exception` are set in catch blocks and consumed in `finally`
- Helper methods (`SaveMessageToQueueAsync`, `DeserializeMessage`) eliminate boilerplate in function classes

---

## Function Class Structure

### Queue Trigger (most common)

```csharp
public class OrderProcessor(
    ILogger<OrderProcessor> logger,
    IConfiguration configuration,
    IQueueManager queueManager,
    IBlobManager blobManager,
    IOrderProcessingService orderService) : AppFunctionBase(logger, configuration, queueManager, blobManager)
{
    private readonly IOrderProcessingService _orderService =
        orderService ?? throw new ArgumentNullException(nameof(orderService));

    [Function(nameof(OrderProcessor))]
    public async Task Run(
        [QueueTrigger("orders-pending", Connection = "AzureWebJobsStorage")] QueueMessage message)
    {
        _logger.LogInformation("OrderProcessor started for message: {MessageText}", message.MessageText);

        var queueMessage = DeserializeMessage<OrderQueueMessage>(message.MessageText);

        try
        {
            await _orderService.ProcessAsync(queueMessage.OrderId);
            await SaveMessageToQueueAsync(
                new OrderCompletedMessage(queueMessage.OrderId),
                "orders-processed");
        }
        catch (SqlException sqlEx)
        {
            Exception = sqlEx;
            ErrorMessage = $"Database error processing order {queueMessage.OrderId}.";
        }
        catch (HttpRequestException httpEx)
        {
            Exception = httpEx;
            ErrorMessage = $"HTTP error processing order {queueMessage.OrderId}.";
        }
        catch (Exception ex)
        {
            Exception = ex;
            ErrorMessage = $"Unexpected error processing order {queueMessage.OrderId}.";
        }
        finally
        {
            if (!string.IsNullOrEmpty(ErrorMessage))
            {
                if (Exception != null)
                    _logger.LogError(Exception, ErrorMessage);

                await SaveErrorMessageAsync(queueMessage.OrderId, "orders-pending", ErrorMessage);
            }
        }
    }
}
```

### Queue Trigger with Output Binding

Use `[QueueOutput]` on the method when the function always writes to a single output queue:

```csharp
[Function("OrderRouter")]
[QueueOutput("orders-high-priority", Connection = "AzureWebJobsStorage")]
public async Task<string?> Run(
    [QueueTrigger("orders-incoming", Connection = "AzureWebJobsStorage")] QueueMessage message)
{
    var order = DeserializeMessage<OrderQueueMessage>(message.MessageText);
    // Return value is written to the output queue
    return order.IsHighPriority ? order.ToString() : null;
}
```

### Timer Trigger (scheduled / periodic work)

```csharp
[Function("CatalogRefresher")]
public async Task Run(
    [TimerTrigger("0 0 0 */14 * *", RunOnStartup = true, UseMonitor = false)] TimerInfo timer)
{
    _logger.LogInformation("CatalogRefresher started at: {UtcNow}", DateTime.UtcNow);

    if (timer.ScheduleStatus is not null)
        _logger.LogInformation("Next scheduled run: {Next}", timer.ScheduleStatus.Next);

    await _catalogService.RefreshAsync();
}
```

**Rules:**
- Use `[Timeout("HH:MM:SS")]` on queue-triggered functions with long expected runtimes
- `RunOnStartup = true` for catalog/seed functions that should run on deploy
- `UseMonitor = false` for infrequent jobs where singleton lock monitoring is not needed

---

## Error Handling Pattern

All queue-triggered functions use the try/catch/finally pattern with error queue routing:

```
try
{
    // main work
}
catch (SpecificException specificEx)  // most specific first
{
    Exception = specificEx;
    ErrorMessage = "Descriptive context message.";
}
catch (Exception ex)                   // catch-all last
{
    Exception = ex;
    ErrorMessage = "Unexpected error context.";
}
finally
{
    if (!string.IsNullOrEmpty(ErrorMessage))
    {
        if (Exception != null)
            _logger.LogError(Exception, ErrorMessage);   // always pass exception object

        await SaveErrorMessageAsync(correlationId, "source-queue", ErrorMessage);
    }
}
```

**Rules:**
- Catch specific exception types first (`SqlException`, `HttpRequestException`, `JsonException`) before `Exception`
- Set `ErrorMessage` and `Exception` on the base class rather than logging inline — the `finally` block handles both logging and error queue routing
- Always pass the exception object as the first argument to `LogError` to capture the full stack trace
- Route errors to a dedicated error queue rather than letting the function poison-message; the error queue function handles persistence
- Never swallow exceptions silently — every catch block must either re-throw or set `ErrorMessage`
- For retry logic: track attempt count in the queue message itself (`ProcessTryCount`) and set a `MaxRetriesReached` flag when the limit is hit

---

## Logging

```csharp
// ✅ Correct — structured logging with message templates
_logger.LogInformation("Processing order {OrderId} for account {AccountNumber}", orderId, accountNumber);
_logger.LogError(ex, "Failed to process order {OrderId}", orderId);

// ❌ Wrong — string interpolation destroys structured logging
_logger.LogInformation($"Processing order {orderId}");
```

Log at the start and end of every function invocation with a UTC timestamp:

```csharp
_logger.LogInformation("OrderProcessor started at {StartTime}", DateTime.UtcNow);
// ... work ...
_logger.LogInformation("OrderProcessor completed at {EndTime}", DateTime.UtcNow);
```

---

## Checklist — New Azure Function

1. ☐ `Program.cs` follows the standard `HostBuilder` pattern with layered configuration
2. ☐ `AddApplicationInsightsTelemetryWorkerService()` + `ConfigureFunctionsApplicationInsights()` registered
3. ☐ Azure SDK clients (`QueueServiceClient`, `BlobServiceClient`) registered with null-guard
4. ☐ `Secrets.json` added to `.gitignore`
5. ☐ Function class inherits from shared base class
6. ☐ All constructor parameters null-guarded and stored in `private readonly` fields
7. ☐ Trigger binding uses named connection (`Connection = "AzureWebJobsStorage"`)
8. ☐ Try/catch/finally with error queue routing for queue-triggered functions
9. ☐ Specific exception types caught before catch-all `Exception`
10. ☐ `LogError` always receives the exception object as first argument
11. ☐ DI lifetimes follow the rules table (repositories Scoped, infrastructure Singleton)
12. ☐ `[Timeout]` attribute added for functions with long expected runtimes
