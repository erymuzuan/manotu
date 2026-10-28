using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Google;
using Gimano.BackOffice.Data;
using Microsoft.AspNetCore.Identity;

namespace Gimano.BackOffice.Components.Account;

/// <summary>Only explicitly approved, Google-verified Gmail identities can provision/link an account.</summary>
public sealed class GoogleMaintainerLogin(SignInManager<ApplicationUser> signIn, UserManager<ApplicationUser> users,
    MaintainerAllowlist allowlist)
{
    public static void ConfigureClaims(GoogleOptions options) =>
        options.ClaimActions.MapJsonKey("google:email_verified", "email_verified");

    public static string? VerifiedEmail(ExternalLoginInfo? info)
    {
        if (info?.LoginProvider != "Google" || string.IsNullOrWhiteSpace(info.ProviderKey) ||
            !string.Equals(info.Principal.FindFirstValue("google:email_verified"), "true", StringComparison.OrdinalIgnoreCase)) return null;
        var email = info.Principal.FindFirstValue(ClaimTypes.Email)?.Trim();
        // Gmail is authoritative at Google. Do not auto-link third-party email addresses.
        return email?.EndsWith("@gmail.com", StringComparison.OrdinalIgnoreCase) == true ? email : null;
    }

    public async Task<SignInResult> SignInAsync()
    {
        var info = await signIn.GetExternalLoginInfoAsync();
        var email = VerifiedEmail(info);
        if (email is null || !allowlist.Allows(email)) return SignInResult.NotAllowed;
        var linked = await users.FindByLoginAsync("Google", info!.ProviderKey);
        if (linked is not null && !string.Equals(linked.Email, email, StringComparison.OrdinalIgnoreCase))
            return SignInResult.NotAllowed;
        var user = linked ?? await users.FindByEmailAsync(email);
        if (user is null)
        {
            user = new ApplicationUser { UserName = email, Email = email, EmailConfirmed = true };
            if (!(await users.CreateAsync(user)).Succeeded) return SignInResult.NotAllowed;
        }
        if (!await signIn.CanSignInAsync(user) || await users.IsLockedOutAsync(user)) return SignInResult.NotAllowed;
        if (linked is null)
        {
            var existing = await users.GetLoginsAsync(user);
            if (existing.Any(l => l.LoginProvider == "Google" && l.ProviderKey != info.ProviderKey))
                return SignInResult.NotAllowed;
            if (!(await users.AddLoginAsync(user, info)).Succeeded) return SignInResult.NotAllowed;
        }
        return await signIn.ExternalLoginSignInAsync("Google", info.ProviderKey, false, bypassTwoFactor: false);
    }
}

public static class PasswordlessRoutes
{
    private static readonly HashSet<string> Retired = new(StringComparer.OrdinalIgnoreCase)
    {
        "/Account/Register", "/Account/ForgotPassword", "/Account/ForgotPasswordConfirmation",
        "/Account/ResetPassword", "/Account/ResetPasswordConfirmation",
        "/Account/Manage/ChangePassword", "/Account/Manage/SetPassword", "/Account/Manage/Email",
        "/Account/Manage/ExternalLogins", "/Account/Manage/LinkExternalLogin", "/Account/ConfirmEmailChange"
    };
    public static bool IsRetired(string? path) => path is not null && Retired.Contains(path.TrimEnd('/'));
}
