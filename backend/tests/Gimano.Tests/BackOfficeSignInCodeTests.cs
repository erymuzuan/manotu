using System.Reflection;
using Gimano.BackOffice.Components.Account;
using Gimano.BackOffice.Data;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection;

namespace Gimano.Tests;

/// <summary>The emailed sign-in code is part of every back-office sign-in (password and passkey), and only the right code works.</summary>
public class BackOfficeSignInCodeTests
{
    private const string Email = "maintainer@example.com", Password = "A long enough passw0rd!";

    private static async Task<(IServiceProvider Services, ApplicationUser User)> SetupAsync(bool required = true)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddDataProtection();
        services.Configure<EmailCodeOptions>(o => o.Required = required);
        services.AddAuthentication(o =>
            {
                o.DefaultScheme = IdentityConstants.ApplicationScheme;
                o.DefaultSignInScheme = IdentityConstants.ExternalScheme;
            })
            .AddIdentityCookies();
        services.AddSingleton<IUserStore<ApplicationUser>, MemoryUserStore>();
        services.AddIdentityCore<ApplicationUser>()
            .AddSignInManager<MaintainerSignInManager>()
            .AddDefaultTokenProviders()
            .AddTokenProvider<EmailSignInCodeProvider>(EmailSignInCodeProvider.Name);
        var http = new DefaultHttpContext();
        // A plain field: HttpContextAccessor's AsyncLocal would not flow out of this async setup into the test.
        services.AddSingleton<IHttpContextAccessor>(new FixedContext(http));
        var sp = services.BuildServiceProvider();
        http.RequestServices = sp.CreateScope().ServiceProvider;

        var users = http.RequestServices.GetRequiredService<UserManager<ApplicationUser>>();
        var user = new ApplicationUser { UserName = Email, Email = Email };
        Assert.True((await users.CreateAsync(user, Password)).Succeeded);
        return (http.RequestServices, user);
    }

    [Fact]
    public async Task Password_sign_in_always_needs_the_emailed_code()
    {
        var (sp, _) = await SetupAsync();
        var signIn = sp.GetRequiredService<SignInManager<ApplicationUser>>();
        Assert.IsType<MaintainerSignInManager>(signIn);

        var result = await signIn.PasswordSignInAsync(Email, Password, isPersistent: false, lockoutOnFailure: true);

        Assert.True(result.RequiresTwoFactor);
        Assert.False(result.Succeeded);
    }

    [Fact]
    public async Task Passkey_sign_in_does_not_skip_the_code()
    {
        var (sp, user) = await SetupAsync();
        var signIn = sp.GetRequiredService<SignInManager<ApplicationUser>>();
        // PasskeySignInAsync ends with SignInOrTwoFactorAsync(user, false, bypassTwoFactor: true) (aspnetcore 10).
        var method = typeof(SignInManager<ApplicationUser>).GetMethod("SignInOrTwoFactorAsync", BindingFlags.Instance | BindingFlags.NonPublic)!;

        var result = await (Task<SignInResult>)method.Invoke(signIn, [user, false, null, true])!;

        Assert.True(result.RequiresTwoFactor);
    }

    [Fact]
    public async Task Only_the_emailed_code_completes_the_sign_in()
    {
        var (sp, user) = await SetupAsync();
        var signIn = sp.GetRequiredService<SignInManager<ApplicationUser>>();
        var users = sp.GetRequiredService<UserManager<ApplicationUser>>();
        Assert.True((await signIn.PasswordSignInAsync(Email, Password, false, true)).RequiresTwoFactor);

        var code = await users.GenerateTwoFactorTokenAsync(user, EmailSignInCodeProvider.Name);
        Assert.Matches(@"^\d{6}$", code);
        var wrong = code == "000000" ? "111111" : "000000";

        Assert.False((await signIn.TwoFactorSignInAsync(EmailSignInCodeProvider.Name, wrong, false, rememberClient: false)).Succeeded);
        Assert.True((await signIn.TwoFactorSignInAsync(EmailSignInCodeProvider.Name, code, false, rememberClient: false)).Succeeded);
    }

    [Fact]
    public async Task Code_needs_no_confirmed_email_and_is_tied_to_the_account()
    {
        var (sp, user) = await SetupAsync();
        var users = sp.GetRequiredService<UserManager<ApplicationUser>>();
        Assert.False(user.EmailConfirmed);
        var provider = new EmailSignInCodeProvider();
        Assert.True(await provider.CanGenerateTwoFactorTokenAsync(users, user));

        var code = await users.GenerateTwoFactorTokenAsync(user, EmailSignInCodeProvider.Name);
        Assert.True(await users.VerifyTwoFactorTokenAsync(user, EmailSignInCodeProvider.Name, code));
        // A new security stamp (password change, "sign out everywhere") voids outstanding codes.
        await users.UpdateSecurityStampAsync(user);
        Assert.False(await users.VerifyTwoFactorTokenAsync(user, EmailSignInCodeProvider.Name, code));
    }

    [Fact]
    public async Task Without_the_requirement_password_alone_signs_in()
    {
        var (sp, _) = await SetupAsync(required: false);
        var signIn = sp.GetRequiredService<SignInManager<ApplicationUser>>();

        Assert.True((await signIn.PasswordSignInAsync(Email, Password, false, true)).Succeeded);
    }

    private sealed class FixedContext(HttpContext http) : IHttpContextAccessor
    {
        public HttpContext? HttpContext { get; set; } = http;
    }

    private sealed class MemoryUserStore : IUserPasswordStore<ApplicationUser>, IUserSecurityStampStore<ApplicationUser>, IUserEmailStore<ApplicationUser>
    {
        private readonly Dictionary<string, ApplicationUser> _users = [];

        public void Dispose() { }
        public Task<string> GetUserIdAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.Id);
        public Task<string?> GetUserNameAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.UserName);
        public Task SetUserNameAsync(ApplicationUser user, string? userName, CancellationToken ct) { user.UserName = userName; return Task.CompletedTask; }
        public Task<string?> GetNormalizedUserNameAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.NormalizedUserName);
        public Task SetNormalizedUserNameAsync(ApplicationUser user, string? name, CancellationToken ct) { user.NormalizedUserName = name; return Task.CompletedTask; }
        public Task<IdentityResult> CreateAsync(ApplicationUser user, CancellationToken ct) { _users[user.Id] = user; return Task.FromResult(IdentityResult.Success); }
        public Task<IdentityResult> UpdateAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(IdentityResult.Success);
        public Task<IdentityResult> DeleteAsync(ApplicationUser user, CancellationToken ct) { _users.Remove(user.Id); return Task.FromResult(IdentityResult.Success); }
        public Task<ApplicationUser?> FindByIdAsync(string userId, CancellationToken ct) => Task.FromResult(_users.GetValueOrDefault(userId));
        public Task<ApplicationUser?> FindByNameAsync(string name, CancellationToken ct) =>
            Task.FromResult(_users.Values.FirstOrDefault(u => u.NormalizedUserName == name));
        public Task SetPasswordHashAsync(ApplicationUser user, string? hash, CancellationToken ct) { user.PasswordHash = hash; return Task.CompletedTask; }
        public Task<string?> GetPasswordHashAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.PasswordHash);
        public Task<bool> HasPasswordAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.PasswordHash is not null);
        public Task SetSecurityStampAsync(ApplicationUser user, string stamp, CancellationToken ct) { user.SecurityStamp = stamp; return Task.CompletedTask; }
        public Task<string?> GetSecurityStampAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.SecurityStamp);
        public Task SetEmailAsync(ApplicationUser user, string? email, CancellationToken ct) { user.Email = email; return Task.CompletedTask; }
        public Task<string?> GetEmailAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.Email);
        public Task<bool> GetEmailConfirmedAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.EmailConfirmed);
        public Task SetEmailConfirmedAsync(ApplicationUser user, bool confirmed, CancellationToken ct) { user.EmailConfirmed = confirmed; return Task.CompletedTask; }
        public Task<ApplicationUser?> FindByEmailAsync(string email, CancellationToken ct) =>
            Task.FromResult(_users.Values.FirstOrDefault(u => u.NormalizedEmail == email));
        public Task<string?> GetNormalizedEmailAsync(ApplicationUser user, CancellationToken ct) => Task.FromResult(user.NormalizedEmail);
        public Task SetNormalizedEmailAsync(ApplicationUser user, string? email, CancellationToken ct) { user.NormalizedEmail = email; return Task.CompletedTask; }
    }
}
