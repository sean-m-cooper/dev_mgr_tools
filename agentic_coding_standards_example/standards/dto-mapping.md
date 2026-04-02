# DTO & Mapping Conventions

> **Load when:** Creating DTOs, request/response objects, view models, or mapping logic

---

## DTO Types & When to Use Each

| Type | Use For | Naming | Example |
|---|---|---|---|
| **Response DTO** | Data returned from API endpoints | `*Response` | `OrderResponse` |
| **Request DTO** | Data received by API endpoints | `*Request` | `UpdateAccountInfoRequest` |
| **Dto** | Data transferred between Web app and API | `*Dto` | `GroupedPendingOrderDto` |
| **ViewModel** | Data bound to MVC views/partials | `*ViewModel` | `NewOrderViewModel` |
| **Model** | Internal API-layer models (not exposed) | `*Model` | `OrderModel` |

---

## DTO Structure

### API Response DTOs

`sealed record` with `init` properties. Use `required` for critical fields. No validation attributes.

```csharp
namespace MyApp.API.Responses;

public sealed record OrderResponse
{
    public required int Id { get; init; }
    public required Guid BundleLinkKey { get; init; }
    public required string AccountName { get; init; }
    public required DateTime CreatedDate { get; init; }
    public required IReadOnlyList<string> ProductTitles { get; init; }
    public string? Website { get; init; }
}
```

### API Request DTOs

`sealed record` with `init` properties **and** validation attributes.

```csharp
namespace MyApp.API.Requests;

public sealed record UpdateAccountInfoRequest
{
    [Required]
    public int AccountNumber { get; init; }

    [Required]
    [StringLength(255)]
    public string AccountName { get; init; } = null!;

    [StringLength(20)]
    [Phone]
    public string? BusinessPhone { get; init; }

    [Url]
    public string? Website { get; init; }

    [EmailAddress]
    public string? Email { get; init; }
}
```

### Web DTOs (MVC ↔ API)

`sealed record` with `required` for critical fields. Mirror the API response shape.

```csharp
namespace MyApp.Web.Models.Api;

public sealed record GroupedPendingOrderDto
{
    public required Guid BundleLinkKey { get; init; }
    public required IReadOnlyList<string> ProductTitles { get; init; }
    public required int AccountNumber { get; init; }
    public required string AccountName { get; init; }
    public IReadOnlyList<ProductDocumentsDto> Documents { get; init; } = [];
}
```

### ViewModels (MVC Views)

Classes are acceptable for ViewModels that need two-way binding. Use `sealed class` when possible.

```csharp
namespace MyApp.Web.Models.NewOrder;

public sealed class NewOrderViewModel
{
    public int UserId { get; set; }
    public string AccountName { get; set; } = string.Empty;
    public List<ProductPartialViewModel> Products { get; set; } = [];
}
```

---

## Rules

| Rule | Details |
|---|---|
| **Always `sealed`** | All DTOs, requests, responses, and view models should be `sealed` |
| **Prefer `record`** | Use `sealed record` for all DTOs except ViewModels needing two-way binding |
| **`required` for critical fields** | Mark fields that must always have a value; optional fields are nullable or have defaults |
| **`IReadOnlyList<T>` for collections** | Never expose `List<T>` on response DTOs — use `IReadOnlyList<T>` |
| **No EF entities across boundaries** | Always map entities to DTOs before returning from services or controllers |
| **Validation on requests only** | Use `[Required]`, `[StringLength]`, `[Phone]`, `[Url]`, `[EmailAddress]` on request DTOs |

---

## Project Placement

```
MyApp.API/
├── Requests/         ← API request DTOs (with validation)
├── Responses/        ← API response DTOs (no validation)
└── Models/           ← Internal models (not exposed via endpoints)

MyApp.Web/
├── Models/Api/       ← DTOs for API communication
├── Models/{Feature}/ ← ViewModels grouped by feature
└── Models/Components/← Shared UI component ViewModels

MyApp.ExternalApi/
└── Models/           ← Integration DTOs
```

---

## Mapping

### Mapperly (Preferred)

Use Mapperly (`[Mapper]` attribute) for straightforward property-to-property mapping. It generates source code at compile time — no runtime reflection.

```csharp
using Riok.Mapperly.Abstractions;

namespace MyApp.API.Mapping;

[Mapper]
public partial class EmployeeMapper
{
    public partial EmployeeResponse MapToResponse(Employee entity);

    [MapperIgnoreSource(nameof(Employee.InternalField))]
    public partial EmployeeResponse MapFromFull(FullEmployee entity);
}
```

### Static Mapper Methods (Complex Scenarios)

Use static mapper classes when mapping requires custom logic, null handling, or data from multiple sources.

```csharp
namespace MyApp.API.Mapping;

public static class ProductMapper
{
    public static ProductResponse MapToResponse(
        ActiveProductResult source,
        IReadOnlyDictionary<string, string> regionCodeMap)
    {
        return new ProductResponse
        {
            ProductId = source.ProductId,
            DisplayText = $"{source.ZipCode} | {source.City} | {source.State}",
            IsAdmin = source.IsAdmin == 1
        };
    }

    public static List<ProductResponse> MapToResponseList(
        IEnumerable<ActiveProductResult> sources,
        IReadOnlyDictionary<string, string> regionCodeMap)
    {
        return sources
            .Select(s => MapToResponse(s, regionCodeMap))
            .ToList();
    }
}
```

### When to Use Each

| Scenario | Use |
|---|---|
| Simple 1:1 property mapping | Mapperly `[Mapper]` partial class |
| Custom logic, null coalescing, type conversion | Static mapper method |
| Mapping needs external data (dictionaries, lookups) | Static mapper method with extra parameters |

### Rules

- **Never map in controllers** — mapping belongs in mapper classes or cached repositories
- **One mapper per domain area** — e.g., `EmployeeMapper`, `ProductMapper`
- **Mapper registration** — Mapperly mappers: `AddSingleton`; static mappers need no registration
