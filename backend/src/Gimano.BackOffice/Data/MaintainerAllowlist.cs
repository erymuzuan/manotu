using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Options;

namespace Gimano.BackOffice.Data;

public sealed class BackOfficeOptions
{
    public const string Section = "BackOffice";
    /// <summary>Emails allowed to register and sign in; an entry may hold several, comma-separated. "*" allows anyone (Development only).</summary>
    public string[] Maintainers { get; set; } = [];
}

public sealed class MaintainerAllowlist(IOptionsMonitor<BackOfficeOptions> options)
{
    public bool Allows(string? email)
    {
        if (string.IsNullOrWhiteSpace(email)) return false;
        var list = options.CurrentValue.Maintainers.SelectMany(m => m.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        return list.Any(m => m == "*" || string.Equals(m, email.Trim(), StringComparison.OrdinalIgnoreCase));
    }
}

/// <summary>Rejects accounts for emails not on the allowlist, whichever page creates them.</summary>
public sealed class MaintainerUserValidator(MaintainerAllowlist allowlist) : IUserValidator<ApplicationUser>
{
    public Task<IdentityResult> ValidateAsync(UserManager<ApplicationUser> manager, ApplicationUser user) =>
        Task.FromResult(allowlist.Allows(user.Email ?? user.UserName)
            ? IdentityResult.Success
            : IdentityResult.Failed(new IdentityError { Code = "NotAMaintainer", Description = "This email is not on the Manotu maintainer list." }));
}
