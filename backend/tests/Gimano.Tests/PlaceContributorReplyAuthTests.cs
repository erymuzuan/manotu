using Gimano.Api.Endpoints;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;

namespace Gimano.Tests;

public sealed class PlaceContributorReplyAuthTests
{
    [Theory]
    [InlineData(null, null, 404)]
    [InlineData("short", "short", 404)]
    [InlineData("test-admin-key-at-least-24-characters", null, 401)]
    [InlineData("test-admin-key-at-least-24-characters", "wrong", 401)]
    public async Task Admin_filter_blocks_mutation_before_service_invocation(string? configured, string? supplied, int status)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Admin:Key"] = configured }).Build();
        var http = new DefaultHttpContext();
        if (supplied is not null) http.Request.Headers["X-Admin-Key"] = supplied;
        var called = false;
        var result = await new AdminKeyFilter(config).InvokeAsync(new DefaultEndpointFilterInvocationContext(http), _ =>
        {
            called = true;
            return ValueTask.FromResult<object?>(Results.Ok());
        });
        Assert.False(called);
        Assert.Equal(status, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
    }

    [Fact]
    public async Task Admin_filter_accepts_configured_key_and_audits_only_its_fingerprint()
    {
        const string key = "test-admin-key-at-least-24-characters";
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Admin:Key"] = key }).Build();
        var http = new DefaultHttpContext();
        http.Request.Headers["X-Admin-Key"] = key;
        var called = false;
        await new AdminKeyFilter(config).InvokeAsync(new DefaultEndpointFilterInvocationContext(http), _ =>
        {
            called = true;
            return ValueTask.FromResult<object?>(Results.Ok());
        });
        Assert.True(called);
        Assert.Equal(8, AdminKeyFilter.Fingerprint(http).Length);
        Assert.DoesNotContain(key, AdminKeyFilter.Fingerprint(http));
    }
}
