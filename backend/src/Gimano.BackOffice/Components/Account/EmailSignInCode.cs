using System.Collections.Concurrent;
using System.Net;
using Azure.Communication.Email;
using Gimano.BackOffice.Data;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Options;

namespace Gimano.BackOffice.Components.Account;

/// <summary>The emailed sign-in code (BackOffice:EmailCode). Every sign-in, by password or passkey, ends with it.</summary>
public sealed class EmailCodeOptions
{
    public const string Section = "BackOffice:EmailCode";
    /// <summary>Azure Communication Services connection string (prod: the same DIGEST_ACS_CONNECTION_STRING as the digest).</summary>
    public string? AcsConnectionString { get; set; }
    /// <summary>A sender on a domain verified in that ACS resource.</summary>
    public string From { get; set; } = "DoNotReply@bukitbunga.com";
    /// <summary>
    /// Off only on a back office nobody else can reach (dev on the tailnet without ACS). When on and ACS is not configured,
    /// nobody can sign in: it fails closed.
    /// </summary>
    public bool Required { get; set; } = true;

    public bool CanSend => !string.IsNullOrWhiteSpace(AcsConnectionString);
}

/// <summary>
/// Six-digit codes from the user's security stamp (Identity's TOTP: a 3-minute step, accepted for a few minutes). Unlike
/// Identity's EmailTokenProvider it doesn't need a confirmed email: maintainer accounts exist only for allowlisted invites.
/// </summary>
public sealed class EmailSignInCodeProvider : TotpSecurityStampBasedTokenProvider<ApplicationUser>
{
    public const string Name = "EmailCode";

    public override async Task<bool> CanGenerateTwoFactorTokenAsync(UserManager<ApplicationUser> manager, ApplicationUser user) =>
        !string.IsNullOrWhiteSpace(await manager.GetEmailAsync(user));

    public override async Task<string> GetUserModifierAsync(string purpose, UserManager<ApplicationUser> manager, ApplicationUser user) =>
        $"{Name}:{purpose}:{await manager.GetEmailAsync(user)}";
}

/// <summary>
/// Makes the emailed code part of every sign-in: two-factor is always on, passkeys don't skip it, and no browser is remembered.
/// </summary>
public sealed class MaintainerSignInManager(UserManager<ApplicationUser> userManager, IHttpContextAccessor contextAccessor,
    IUserClaimsPrincipalFactory<ApplicationUser> claimsFactory, IOptions<IdentityOptions> optionsAccessor,
    ILogger<SignInManager<ApplicationUser>> logger, IAuthenticationSchemeProvider schemes, IUserConfirmation<ApplicationUser> confirmation,
    IOptions<EmailCodeOptions> emailCode, MaintainerAllowlist allowlist)
    : SignInManager<ApplicationUser>(userManager, contextAccessor, claimsFactory, optionsAccessor, logger, schemes, confirmation)
{
    public override Task<SignInResult> PasswordSignInAsync(string userName, string password, bool isPersistent, bool lockoutOnFailure) =>
        Task.FromResult(SignInResult.NotAllowed);

    public override Task<SignInResult> PasswordSignInAsync(ApplicationUser user, string password, bool isPersistent, bool lockoutOnFailure) =>
        Task.FromResult(SignInResult.NotAllowed);

    public override async Task<bool> CanSignInAsync(ApplicationUser user) =>
        allowlist.Allows(user.Email) && await base.CanSignInAsync(user);

    private bool Required => emailCode.Value.Required;

    public override async Task<bool> IsTwoFactorEnabledAsync(ApplicationUser user) => Required || await base.IsTwoFactorEnabledAsync(user);

    public override async Task<bool> IsTwoFactorClientRememberedAsync(ApplicationUser user) =>
        !Required && await base.IsTwoFactorClientRememberedAsync(user);

    protected override async Task<SignInResult> SignInOrTwoFactorAsync(ApplicationUser user, bool isPersistent, string? loginProvider = null,
        bool bypassTwoFactor = false) =>
        !allowlist.Allows(user.Email) ? SignInResult.NotAllowed :
        await base.SignInOrTwoFactorAsync(user, isPersistent, loginProvider, bypassTwoFactor && !Required);
}

/// <summary>Emails a sign-in code; at most one email per account per <see cref="MinInterval"/>.</summary>
public sealed class EmailSignInCodeSender(IOptions<EmailCodeOptions> options, UserManager<ApplicationUser> users, TimeProvider clock,
    ILogger<EmailSignInCodeSender> logger)
{
    public static readonly TimeSpan MinInterval = TimeSpan.FromSeconds(45);
    private static readonly ConcurrentDictionary<string, DateTimeOffset> s_lastSent = new();
    private static EmailClient? s_client;
    private static readonly object s_lock = new();

    public enum Outcome { Sent, TooSoon, NotConfigured, Failed }

    public async Task<Outcome> SendAsync(ApplicationUser user, CancellationToken ct)
    {
        var o = options.Value;
        if (!o.CanSend) return Outcome.NotConfigured;
        var email = await users.GetEmailAsync(user);
        if (string.IsNullOrWhiteSpace(email)) return Outcome.Failed;

        var now = clock.GetUtcNow();
        var key = user.Id;
        if (s_lastSent.TryGetValue(key, out var last) && now - last < MinInterval) return Outcome.TooSoon;
        s_lastSent[key] = now;

        var code = await users.GenerateTwoFactorTokenAsync(user, EmailSignInCodeProvider.Name);
        var at = TimeZoneInfo.ConvertTime(now, Gimano.Core.Routing.ValhallaMapper.MalaysiaTime).ToString("d MMM yyyy, HH:mm");
        var text = $"""
            Your Manotu back office sign-in code is {code}

            It works for a few minutes, once. Requested at {at} (Malaysia time).
            If this wasn't you, do not share this code. Review your Google account and passkeys, and tell the other maintainers.
            """;
        var html = $"""
            <p>Your Manotu back office sign-in code is</p>
            <p style="font-size:28px;font-weight:700;letter-spacing:6px;font-family:monospace">{WebUtility.HtmlEncode(code)}</p>
            <p>It works for a few minutes, once. Requested at {WebUtility.HtmlEncode(at)} (Malaysia time).</p>
            <p>If this wasn't you, do not share this code. Review your Google account and passkeys, and tell the other maintainers.</p>
            """;
        try
        {
            var message = new EmailMessage(o.From, email, new EmailContent($"Manotu back office code: {code}") { PlainText = text, Html = html });
            await Client(o.AcsConnectionString!).SendAsync(Azure.WaitUntil.Started, message, ct);
            return Outcome.Sent;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            s_lastSent.TryRemove(key, out _);
            // Never the code or the address.
            logger.LogWarning("Sign-in code email failed: {Type}", ex.GetType().Name);
            return Outcome.Failed;
        }
    }

    private static EmailClient Client(string connectionString)
    {
        lock (s_lock) return s_client ??= new EmailClient(connectionString);
    }
}
