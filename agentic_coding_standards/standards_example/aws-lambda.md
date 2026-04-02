# AWS Lambda Standards

> **Load when:** Working on AWS Lambda functions

---

## Construction Pattern

* Dual constructor pattern (parameterless + DI)
* Lazy service provider initialization

## Configuration

* appsettings.json + environment overrides
* Environment variables take precedence

## Logging

* Use `Console.WriteLine` during cold start
* Use structured logging (`ILogger<T>`) after DI
* Always log full exceptions

## Error Handling

* Try/catch at handler boundary
* Always re‑throw exceptions
* Include EventId / RequestId in logs

## Messaging

* Use `ISqsQueueWriterFactory`
* Use shared queue models (e.g., `NotificationQueueMessage`)
