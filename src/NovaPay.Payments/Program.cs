using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.ApplicationInsights.WorkerService;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NovaPay.Payments.Data;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();

        services.AddSingleton<SqlConnectionFactory>();
        services.AddScoped<TransactionalNotificationsRepository>();
        services.AddScoped<AccountValidationService>();

        // ServiceBusSender real vía SDK, no [ServiceBusOutput] sobre
        // ServiceBusMessage: ese tipo no está soportado como output
        // binding en el modelo isolated worker (confirmado por
        // Microsoft — el binding no sabe extraer el .Body real del
        // objeto y termina serializando metadata del SDK en su lugar).
        // Enviar directo con el SDK es la única forma de fijar
        // MessageId (necesario para la deduplicación nativa de Service
        // Bus) y garantizar que el body publicado sea el JSON real.
        services.AddSingleton(sp =>
        {
            var config = sp.GetRequiredService<IConfiguration>();
            var sbNamespace = config["serviceBusConnection:fullyQualifiedNamespace"]
                ?? throw new InvalidOperationException("Falta serviceBusConnection__fullyQualifiedNamespace.");
            return new ServiceBusClient(sbNamespace, new DefaultAzureCredential());
        });
        // ServiceBusSender apunta al Topic (ADR-03 U4): la cola única de
        // Entrega 2 se reemplazó por un Topic con una Subscription por
        // instancia física, filtrada por sourceInstance. Enviar a un
        // Topic usa el mismo CreateSender(entityName) que una cola — el
        // fan-out real lo hace el filtro SQL de cada Subscription, no el
        // sender.
        services.AddSingleton(sp =>
        {
            var config = sp.GetRequiredService<IConfiguration>();
            var topicName = config["ServiceBusTopicName"]
                ?? throw new InvalidOperationException("Falta ServiceBusTopicName.");
            return sp.GetRequiredService<ServiceBusClient>().CreateSender(topicName);
        });
    })
    .Build();

host.Run();
