using Gimano.BackOffice.Components;
using Gimano.BackOffice.Components.Account;
using Gimano.BackOffice.Data;
using Gimano.Core.BackOffice;
using Gimano.Core.Data;
using Gimano.Core.Infrastructure;
using Microsoft.AspNetCore.Components.Authorization;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

// Invite arguments belong to the maintenance command, not the configuration provider.
var builder = WebApplication.CreateBuilder(args is ["invite", _, ..] ? [] : args);
var config = builder.Configuration;

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

builder.Services.AddSingleton(TimeProvider.System);

// Gimano data: the same Postgres as the API. The API owns and migrates the main schema.
builder.Services.AddGimanoData(config);
// The same key as the API (Feedback:ContactKey, base64 of 32 bytes); without it contacts cannot be revealed here.
builder.Services.AddSingleton(new Gimano.Core.Support.ContactCrypto(config["Feedback:ContactKey"]));
builder.Services.AddScoped<TriageService>();
builder.Services.AddScoped<Gimano.Core.AppVersions.AppVersionService>();
builder.Services.AddScoped<Gimano.Core.Community.BrandWatchlistService>();

// Maintainer accounts: Identity with passkeys / TOTP, in the "backoffice" schema.
builder.Services.AddCascadingAuthenticationState();
builder.Services.AddScoped<IdentityRedirectManager>();
builder.Services.AddScoped<AuthenticationStateProvider, IdentityRevalidatingAuthenticationStateProvider>();
builder.Services.Configure<BackOfficeOptions>(config.GetSection(BackOfficeOptions.Section));
builder.Services.AddSingleton<MaintainerAllowlist>();
builder.Services.AddScoped<MaintainerInvites>();
// Every sign-in ends with a 6-digit code emailed through ACS (Components/Account/EmailSignInCode.cs).
builder.Services.Configure<EmailCodeOptions>(config.GetSection(EmailCodeOptions.Section));
builder.Services.AddScoped<EmailSignInCodeSender>();

// Behind IIS ARR on .13 (public URL): trust X-Forwarded-* only from Proxy:TrustedProxies, so cookies and passkeys see https.
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto | ForwardedHeaders.XForwardedHost;
    o.KnownProxies.Clear();
    o.KnownIPNetworks.Clear();
    foreach (var p in (config["Proxy:TrustedProxies"] ?? "").Split([',', ';', ' '], StringSplitOptions.RemoveEmptyEntries))
        if (System.Net.IPAddress.TryParse(p, out var ip)) o.KnownProxies.Add(ip);
    o.ForwardLimit = 1;
});

builder.Services.AddAuthentication(options =>
    {
        options.DefaultScheme = IdentityConstants.ApplicationScheme;
        options.DefaultSignInScheme = IdentityConstants.ExternalScheme;
    })
    .AddIdentityCookies(cookies => cookies.ApplicationCookie?.Configure(o =>
    {
        o.Cookie.Name = "gimano.backoffice";
        o.ExpireTimeSpan = TimeSpan.FromHours(12);
        o.SlidingExpiration = true;
        // Removing someone from BackOffice:Maintainers signs them out on their next request.
        // Keep Identity's security-stamp check (signs other sessions out after a password, 2FA or passkey change):
        // the default handler is SecurityStampValidator.ValidatePrincipalAsync, and assigning a new one would drop it.
        o.Events.OnValidatePrincipal = async ctx =>
        {
            await SecurityStampValidator.ValidatePrincipalAsync(ctx);
            if (ctx.Principal is null) return;
            var allowlist = ctx.HttpContext.RequestServices.GetRequiredService<MaintainerAllowlist>();
            if (!allowlist.Allows(ctx.Principal?.Identity?.Name))
            {
                ctx.RejectPrincipal();
                await ctx.HttpContext.RequestServices.GetRequiredService<SignInManager<ApplicationUser>>().SignOutAsync();
            }
        };
    }));
builder.Services.AddAuthorization();

// Same database and credentials as AddGimanoData (password from ConnectionStrings__Postgres or Postgres:Password, never committed).
var connectionString = config.GetConnectionString(GimanoDb.ConnectionStringName)
    ?? throw new InvalidOperationException("ConnectionStrings:Postgres is not configured (set ConnectionStrings__Postgres).");
if (config["Postgres:Password"] is { Length: > 0 } pgPassword && !connectionString.Contains("Password=", StringComparison.OrdinalIgnoreCase))
    connectionString = new Npgsql.NpgsqlConnectionStringBuilder(connectionString) { Password = pgPassword }.ConnectionString;
builder.Services.AddDbContext<ApplicationDbContext>(o => ApplicationDbContext.Configure(o, connectionString));

builder.Services.AddIdentityCore<ApplicationUser>(options =>
    {
        // No email sender on a back office: the allowlist is the gate, not email confirmation.
        options.SignIn.RequireConfirmedAccount = false;
        options.Stores.SchemaVersion = IdentitySchemaVersions.Version3;
        options.Password.RequiredLength = 12;
        options.Lockout.MaxFailedAccessAttempts = 5;
    })
    .AddEntityFrameworkStores<ApplicationDbContext>()
    .AddSignInManager<MaintainerSignInManager>()
    .AddDefaultTokenProviders()
    .AddTokenProvider<EmailSignInCodeProvider>(EmailSignInCodeProvider.Name)
    .AddUserValidator<MaintainerUserValidator>();

builder.Services.AddSingleton<IEmailSender<ApplicationUser>, IdentityNoOpEmailSender>();

// Keep cookies valid across container restarts.
if (config["DataProtection:KeysPath"] is { Length: > 0 } keys)
    builder.Services.AddDataProtection().SetApplicationName("gimano-backoffice").PersistKeysToFileSystem(new DirectoryInfo(keys));

var app = builder.Build();

if (config.GetValue("Database:MigrateOnStartup", true))
{
    await using var scope = app.Services.CreateAsyncScope();
    var identity = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
    var log = scope.ServiceProvider.GetRequiredService<ILogger<Program>>();
    for (var attempt = 1; ; attempt++)
    {
        try
        {
            await identity.Database.MigrateAsync();
            break;
        }
        catch (Exception ex) when (attempt < 60 && ex is Npgsql.NpgsqlException or System.Net.Sockets.SocketException or InvalidOperationException)
        {
            log.LogWarning("Database not ready ({Message}); retry {Attempt}/60", ex.Message, attempt);
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
    }
    if (app.Services.GetRequiredService<Microsoft.Extensions.Options.IOptions<BackOfficeOptions>>().Value.Maintainers.Length == 0)
        log.LogWarning("BackOffice:Maintainers is empty: nobody can register or sign in.");
    if (app.Services.GetRequiredService<Microsoft.Extensions.Options.IOptions<EmailCodeOptions>>().Value is { Required: true, CanSend: false })
        log.LogError("BackOffice:EmailCode:AcsConnectionString is not set: sign-in codes can't be emailed, so nobody can sign in.");
    if (!app.Services.GetRequiredService<Gimano.Core.Support.ContactCrypto>().Enabled)
        log.LogWarning("Feedback:ContactKey is not set: contact details cannot be revealed on this host.");
}

// One-time maintainer invites (no self-registration): `dotnet Gimano.BackOffice.dll invite <email>`, or on the host
// `docker compose -f deploy/docker-compose.yml run --rm backoffice invite <email>`. Prints the link once and exits.
if (args is ["invite", var inviteEmail, ..])
{
    await using var scope = app.Services.CreateAsyncScope();
    await scope.ServiceProvider.GetRequiredService<ApplicationDbContext>().Database.MigrateAsync();
    try
    {
        var sendEmail = args.Contains("--send", StringComparer.Ordinal);
        var baseUrl = (config["BackOffice:PublicUrl"] ?? "https://backoffice.manotu.app").TrimEnd('/');
        var emailOptions = scope.ServiceProvider.GetRequiredService<Microsoft.Extensions.Options.IOptions<EmailCodeOptions>>().Value;
        if (sendEmail && (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var publicUri) || publicUri.Scheme != "https" || publicUri.IsLoopback))
            throw new InvalidOperationException("Set BackOffice:PublicUrl to the public HTTPS back office before sending invitations.");
        if (sendEmail && !emailOptions.CanSend)
            throw new InvalidOperationException("Configure BackOffice:EmailCode:AcsConnectionString before sending invitations.");
        if (!scope.ServiceProvider.GetRequiredService<MaintainerAllowlist>().Allows(inviteEmail))
            throw new InvalidOperationException("The email is not listed in BackOffice:Maintainers.");
        var users = scope.ServiceProvider.GetRequiredService<UserManager<ApplicationUser>>();
        var existing = await users.FindByEmailAsync(inviteEmail.Trim());
        var resetExisting = args.Contains("--reset-existing", StringComparer.Ordinal);
        if (existing is not null && !(sendEmail && resetExisting))
            throw new InvalidOperationException("This maintainer already has an account. Use --send --reset-existing to email a password reset link without changing the account.");
        string link;
        if (existing is not null)
        {
            var code = await users.GeneratePasswordResetTokenAsync(existing);
            code = Microsoft.AspNetCore.WebUtilities.WebEncoders.Base64UrlEncode(System.Text.Encoding.UTF8.GetBytes(code));
            link = $"{baseUrl}/Account/ResetPassword?code={Uri.EscapeDataString(code)}";
        }
        else
        {
            var token = await scope.ServiceProvider.GetRequiredService<MaintainerInvites>().CreateAsync(inviteEmail);
            link = $"{baseUrl}/Account/Register?invite={Uri.EscapeDataString(token)}";
        }
        if (sendEmail)
        {
            var content = MaintainerInvitationEmail.Create(link, existing is not null);
            var client = new Azure.Communication.Email.EmailClient(emailOptions.AcsConnectionString);
            var operation = await client.SendAsync(Azure.WaitUntil.Completed,
                new Azure.Communication.Email.EmailMessage(emailOptions.From, inviteEmail.Trim(), content));
            if (operation.Value.Status != Azure.Communication.Email.EmailSendStatus.Succeeded)
                throw new InvalidOperationException("Invitation email was not accepted. Retry the invite command.");
            Console.WriteLine("Account setup email accepted by the email service. The single-use link expires in 24 hours.");
        }
        else
        {
            Console.WriteLine($"Invite for {inviteEmail.Trim()} (single use, expires in {MaintainerInvites.Lifetime.TotalHours:0} h):");
            Console.WriteLine(link);
        }
        return 0;
    }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Azure.RequestFailedException)
    {
        Console.Error.WriteLine(ex is Azure.RequestFailedException ? "Email service rejected the invitation. Check ACS configuration and retry." : ex.Message);
        return 1;
    }
}

app.UseForwardedHeaders();
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
}
app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);

// Explicitly after the re-executing handlers: the implicit ones run before them, so a re-executed /not-found or /Error
// (pages under [Authorize] in _Imports, opened with [AllowAnonymous]) would reach the endpoint without authorization
// having run, and every 404 became a 500.
app.UseAuthentication();
app.UseAuthorization();
app.UseAntiforgery();

app.MapStaticAssets();
app.MapRazorComponents<App>()
    // The production IIS ARR path closes compressed WebSocket frames (1006) before the circuit starts.
    // Keep WebSockets, but do not negotiate permessage-deflate through that proxy.
    .AddInteractiveServerRenderMode(options => options.DisableWebSocketCompression = true);

// Add additional endpoints required by the Identity /Account Razor components.
app.MapAdditionalIdentityEndpoints();

// Feedback screenshots for maintainers (never cached, never public).
app.MapGet("/screenshots/{id:guid}", async (Guid id, HttpContext http, TriageService triage, CancellationToken ct) =>
{
    if (await triage.GetScreenshotAsync(id, Actor.Maintainer(http.User.Identity!.Name!), ct) is not { } s) return Results.NotFound();
    http.Response.Headers.CacheControl = "no-store";
    return Results.File(s.Bytes, s.ContentType);
}).RequireAuthorization();

app.MapGet("/healthz", () => Results.Ok("ok")).AllowAnonymous();

app.Run();
return 0;

public partial class Program;
