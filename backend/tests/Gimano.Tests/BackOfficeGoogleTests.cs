using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication.Google;
using Gimano.BackOffice.Components.Account;
using Microsoft.AspNetCore.Identity;

namespace Gimano.Tests;

public class BackOfficeGoogleTests
{
    [Fact]
    public void Google_v3_userinfo_maps_verified_email_for_login()
    {
        var options = new GoogleOptions();
        GoogleMaintainerLogin.ConfigureClaims(options);
        using var payload = JsonDocument.Parse("""{"sub":"google-subject","email":"moderator@gmail.com","email_verified":true}""");
        var identity = new ClaimsIdentity();
        foreach (var action in options.ClaimActions)
            action.Run(payload.RootElement, identity, "Google");
        var info = new ExternalLoginInfo(new ClaimsPrincipal(identity), "Google", "google-subject", "Google");
        Assert.Equal("moderator@gmail.com", GoogleMaintainerLogin.VerifiedEmail(info));
    }

    [Theory]
    [InlineData("Google", "true", "moderator@gmail.com", true)]
    [InlineData("Google", "false", "moderator@gmail.com", false)]
    [InlineData("Google", "", "moderator@gmail.com", false)]
    [InlineData("Other", "true", "moderator@gmail.com", false)]
    [InlineData("Google", "true", "moderator@external.example", false)]
    [InlineData("Google", "true", "moderator@gmail.com.evil.example", false)]
    public void Auto_link_requires_google_verified_authoritative_email(string provider, string verified, string email, bool allowed)
    {
        var principal = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Email, email), new Claim("google:email_verified", verified)]));
        var info = new ExternalLoginInfo(principal, provider, "google-subject", provider);
        Assert.Equal(allowed ? email : null, GoogleMaintainerLogin.VerifiedEmail(info));
    }

    [Theory]
    [InlineData("/Account/Register")]
    [InlineData("/account/resetpassword/")]
    [InlineData("/Account/Manage/SetPassword")]
    [InlineData("/Account/Manage/ChangePassword")]
    [InlineData("/Account/Manage/Email")]
    [InlineData("/Account/Manage/LinkExternalLogin")]
    public void Old_password_and_identity_change_routes_are_retired(string path) => Assert.True(PasswordlessRoutes.IsRetired(path));

    [Theory]
    [InlineData("/Account/Login")]
    [InlineData("/signin-google")]
    [InlineData("/Account/Manage/Passkeys")]
    public void Passwordless_routes_remain_available(string path) => Assert.False(PasswordlessRoutes.IsRetired(path));
}
