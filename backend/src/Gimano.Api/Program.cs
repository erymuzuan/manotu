using System.Text.Json;
using Gimano.Api;
using Gimano.Api.Admin;
using Gimano.Api.Auth;
using Gimano.Api.Endpoints;
using Gimano.Api.Health;
using Gimano.Api.Live;
using Gimano.Api.Services;
using Gimano.Core.BackOffice;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Infrastructure;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.ConfigureHttpJsonOptions(o => GimanoJson.Configure(o.SerializerOptions));
builder.Services.AddProblemDetails(o => o.CustomizeProblemDetails = c =>
{
    c.ProblemDetails.Extensions["traceId"] = c.HttpContext.TraceIdentifier;
    // problem+json titles follow Accept-Language (en default, ms when preferred).
    c.ProblemDetails.Title = Gimano.Core.Community.L10n.ProblemTitle(c.ProblemDetails.Title, c.HttpContext.Lang());
});
builder.Services.AddExceptionHandler<ApiExceptionHandler>();
builder.Services.AddOpenApi();
builder.Services.AddMemoryCache();
builder.Services.AddGimanoEdge(config, builder.Environment);
// Request bodies are small JSON except photo uploads (endpoint-specific limit) — 4 MB global cap.
builder.WebHost.ConfigureKestrel(k => k.Limits.MaxRequestBodySize = config.GetValue<long?>("Kestrel:Limits:MaxRequestBodySize") ?? 4 * 1024 * 1024);

// Infrastructure
builder.Services.AddGimanoData(config).AddGimanoSearch(config).AddGimanoMessaging(config);
// AI place check (Claude Haiku 5.5, weekly budget) and vetting launch mode.
Gimano.Core.Community.ScreeningSetup.AddGimanoScreening(builder.Services, config);
builder.Services.AddHttpClient<ValhallaClient>(c =>
{
    c.BaseAddress = new Uri((config["Valhalla:Url"] ?? "http://localhost:8002").TrimEnd('/') + "/");
    c.Timeout = TimeSpan.FromSeconds(20);
});
builder.Services.AddScoped<GeoLookup>().AddScoped<ReportService>().AddScoped<RouteService>().AddScoped<RouteMatchService>().AddScoped<PlaceService>()
    .AddScoped<PlaceCorrectionService>().AddScoped<CommunityService>().AddScoped<ReviewService>().AddScoped<PhotoService>()
    .AddScoped<SearchService>().AddScoped<SearchMissRecorder>().AddScoped<IssueService>().AddScoped<Moderation>()
    .AddScoped<RestrictedAreaService>();
builder.Services.AddSingleton<RestrictedAreaMetrics>().AddSingleton<RestrictedAreaSnapshot>();
builder.Services.AddSingleton<IssueDirectory>();
builder.Services.AddSingleton<AliasStore>().AddHostedService(sp => sp.GetRequiredService<AliasStore>());
builder.Services.AddSingleton<AreaDirectory>();
builder.Services.AddGimanoMedia(config);

// Auth: anonymous device JWTs (HS256)
builder.Services.Configure<JwtOptions>(config.GetSection(JwtOptions.Section));
if (string.IsNullOrEmpty(config["Jwt:SigningKey"]))
{
    // No key is ever committed. In Development an ephemeral random key is used (tokens die on restart);
    // everywhere else Jwt__SigningKey must be provided.
    if (!builder.Environment.IsDevelopment())
        throw new InvalidOperationException("Jwt:SigningKey is not configured (set Jwt__SigningKey, >= 32 chars).");
    var devKey = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(48));
    builder.Services.PostConfigure<JwtOptions>(o => o.SigningKey = devKey);
}
builder.Services.AddSingleton<JwtTokenService>();
// Opaque per-author handles for on-device blocking (Community:AuthorHandleKey; falls back to a key derived from the JWT key).
builder.Services.AddSingleton(sp => AuthorHandles.FromConfig(config["Community:AuthorHandleKey"],
    sp.GetRequiredService<IOptions<JwtOptions>>().Value.SigningKey));
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer()
    // AI agents (back office): "Bearer agt_…" tokens minted by a maintainer, for /admin/v1 and /mcp only.
    .AddScheme<AuthenticationSchemeOptions, AgentTokenAuthenticationHandler>(AgentTokenAuthenticationHandler.SchemeName, null);
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<IOptions<JwtOptions>>((o, jwt) =>
    {
        var j = jwt.Value;
        if (j.SigningKey.Length < 32) throw new InvalidOperationException("Jwt:SigningKey must be at least 32 characters.");
        o.MapInboundClaims = false;
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidIssuer = j.Issuer, ValidAudience = j.Audience, IssuerSigningKey = j.Key(),
            ValidateIssuerSigningKey = true, ClockSkew = TimeSpan.FromMinutes(2), NameClaimType = "name",
        };
        // SignalR WebSockets carry the token in the query string.
        o.Events = new JwtBearerEvents
        {
            OnMessageReceived = ctx =>
            {
                if (ctx.Request.Path.StartsWithSegments("/hubs") && ctx.Request.Query["access_token"] is { Count: > 0 } t)
                    ctx.Token = t;
                return Task.CompletedTask;
            },
        };
    });
builder.Services.AddAuthorization(o => o.AddPolicy(AgentTokenAuthenticationHandler.Policy, p => p
    .AddAuthenticationSchemes(AgentTokenAuthenticationHandler.SchemeName).RequireAuthenticatedUser().RequireClaim(AgentTokenAuthenticationHandler.AgentClaim)));

// Back office for AI agents (docs/back-office.md): /admin/v1 REST + the MCP server at /mcp, same rules as the Blazor app.
builder.Services.AddScoped<TriageService>();
builder.Services.Configure<AdminOptions>(config.GetSection(AdminOptions.Section));
builder.Services.AddHttpContextAccessor();
builder.Services.AddMcpServer(o => o.ServerInfo = new() { Name = "gimano-backoffice", Title = "Manotu back office", Version = "1.0.0" })
    .WithHttpTransport(o => o.Stateless = true)
    .WithTools<BackOfficeMcpTools>();

// Live
builder.Services.AddSignalR().AddJsonProtocol(o => GimanoJson.Configure(o.PayloadSerializerOptions));
builder.Services.AddSingleton<LiveSubscriptions>();
builder.Services.AddHostedService<LiveFanoutConsumer>();
builder.Services.AddSingleton<MoodCache>();
builder.Services.AddSingleton<ShareStore>();
// Event short links (docs/events.md §5.6): Postgres rows, purged hourly by the worker. Owner hash key: Drops:OwnerKey.
builder.Services.AddSingleton(sp => Gimano.Core.Events.DropOwnerKey.FromConfig(config["Drops:OwnerKey"],
    sp.GetRequiredService<IOptions<JwtOptions>>().Value.SigningKey));
builder.Services.AddScoped<Gimano.Core.Events.IDropStore, Gimano.Core.Events.EfDropStore>().AddScoped<Gimano.Core.Events.DropService>();
builder.Services.AddSingleton(new Gimano.Core.Support.ContactCrypto(config["Feedback:ContactKey"]));
builder.Services.AddSingleton<Gimano.Api.Identity.UserKeyCache>();
builder.Services.AddSingleton<Gimano.Api.Identity.ReplayCache>();
builder.Services.AddScoped<Gimano.Api.Identity.AttestationService>();
builder.Services.AddHttpClient("attestation", c => c.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddHostedService<ShareSweeper>();
builder.Services.AddSingleton<PingSessions>();
builder.Services.AddSingleton<DriverSnapshotStore>();
builder.Services.AddHostedService<DriverSnapshotConsumer>();
builder.Services.AddSingleton<LocationStreamPublisher>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<LocationStreamPublisher>());

// Health
builder.Services.AddHealthChecks()
    .AddCheck<PostgresHealthCheck>("postgres", HealthStatus.Unhealthy, ["ready"])
    .AddCheck<OpenSearchHealthCheck>("opensearch", HealthStatus.Degraded, ["ready"])
    .AddCheck<RabbitMqHealthCheck>("rabbitmq", HealthStatus.Degraded, ["ready"])
    .AddCheck<ValhallaHealthCheck>("valhalla", HealthStatus.Degraded, ["ready"]);

var app = builder.Build();

if (config.GetValue("Database:MigrateOnStartup", true))
{
    await using var scope = app.Services.CreateAsyncScope();
    var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
    var log = scope.ServiceProvider.GetRequiredService<ILogger<Program>>();
    for (var attempt = 1; ; attempt++)
    {
        try
        {
            await db.Database.MigrateAsync();
            await Gimano.Core.Community.BrandWatchlistService.EnsureSeededAsync(db);
            break;
        }
        catch (Exception ex) when (attempt < 60 && ex is Npgsql.NpgsqlException or System.Net.Sockets.SocketException or InvalidOperationException)
        {
            log.LogWarning("Database not ready ({Message}); retry {Attempt}/60", ex.Message, attempt);
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
    }
}

app.UseGimanoEdge();
app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseCors();
// /admin/v1 and /mcp: 404 when disabled, from the public edge, or outside Admin:AllowedNetworks.
app.UseMiddleware<AdminAccessMiddleware>();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.UseMiddleware<Gimano.Api.Identity.SignatureMiddleware>();

// API docs: on in Development, opt-in elsewhere (Features:ApiDocs). No Swagger/Scalar UI in Production by default.
if (config.GetValue("Features:ApiDocs", app.Environment.IsDevelopment()))
{
    app.MapOpenApi();
    app.MapScalarApiReference();
    app.MapGet("/", () => Results.Redirect("/scalar/v1")).ExcludeFromDescription();
}

app.MapHealthChecks("/healthz", new HealthCheckOptions { Predicate = _ => false, ResponseWriter = HealthWriter.WriteAsync });
app.MapHealthChecks("/readyz", new HealthCheckOptions { Predicate = c => c.Tags.Contains("ready"), ResponseWriter = HealthWriter.WriteAsync });

var api = app.MapGroup("/api/v1");
api.MapAuthAndMe().MapPlaces().MapRoutes().MapLive().MapFeedback().MapPrivacy().MapCommunity().MapShares().MapDrops().MapInbox().MapIdentity().MapCrashReports().MapAdmin().MapIssues();
app.MapMedia();
app.MapAgentAdmin();
app.MapMcp("/mcp").RequireAuthorization(AgentTokenAuthenticationHandler.Policy);

app.MapHub<LiveHub>("/hubs/live");

app.Run();

public partial class Program;
