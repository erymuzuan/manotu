using Gimano.Core.Community;
using Gimano.Core.Data;
using Gimano.Core.Identity;
using Gimano.Core.Messaging;
using Microsoft.Extensions.Options;

namespace Gimano.Tests;

/// <summary>A place gate for tests: a scripted screener (or none), launch mode on or off.</summary>
internal static class TestGates
{
    public sealed class Screener(Func<ScreeningInput, ScreeningResult>? answer) : IPlaceScreener
    {
        public List<ScreeningInput> Inputs { get; } = [];
        public bool Enabled => answer is not null;
        public Task<ScreeningResult> ScreenAsync(ScreeningInput input, CancellationToken ct)
        {
            Inputs.Add(input);
            return Task.FromResult(answer?.Invoke(input) ?? ScreeningResult.Off);
        }
    }

    /// <summary>The check off and launch mode off: today's vetting rules.</summary>
    public static PlaceGate Off(GimanoDbContext db, TimeProvider clock, IEventPublisher? bus = null) =>
        new(db, new Screener(null), bus ?? new NullBus(), clock, Options.Create(new VettingOptions { LaunchMode = false }));

    public static PlaceGate With(GimanoDbContext db, TimeProvider clock, IPlaceScreener screener, IEventPublisher bus, bool launchMode = true) =>
        new(db, screener, bus, clock, Options.Create(new VettingOptions { LaunchMode = launchMode }));

    private sealed class NullBus : IEventPublisher
    {
        public Task<bool> PublishAsync<T>(string routingKey, T payload, CancellationToken ct = default) => Task.FromResult(true);
    }
}
