using Gimano.Core.Community;
using Gimano.Core.Infrastructure;
using Gimano.Worker.Alerts;
using Gimano.Worker.Feedback;
using Gimano.Worker.Search;
using Gimano.Worker.Traffic;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddGimanoData(builder.Configuration).AddGimanoSearch(builder.Configuration).AddGimanoMessaging(builder.Configuration);
builder.Services.AddGimanoScreening(builder.Configuration);
builder.Services.AddHostedService<Gimano.Worker.Vetting.PlaceScreeningRetry>();

builder.Services.AddSingleton<SpeedWindow>();
builder.Services.AddSingleton<Gimano.Worker.Traffic.TraversalCounter>();
builder.Services.AddHostedService<Gimano.Worker.Traffic.TraversalFlusher>();
builder.Services.AddHostedService<Gimano.Worker.Issues.IssueMaintenance>();
builder.Services.AddSingleton<TrafficMetrics>();
builder.Services.AddSingleton<DriverStore>();
builder.Services.AddSingleton<RoadIndexHolder>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<RoadIndexHolder>());
builder.Services.AddHostedService<LocationStreamConsumer>();
builder.Services.AddHostedService<DriverSnapshotPublisher>();
builder.Services.AddHostedService<JamPublisher>();
builder.Services.AddHostedService<AlertLifecycle>();
builder.Services.AddHostedService<AlertExpirySweeper>();
builder.Services.AddHostedService<SearchIndexer>();
builder.Services.AddHostedService<IssueSearchIndexer>();
builder.Services.AddGimanoMedia(builder.Configuration);
builder.Services.AddHostedService<Gimano.Worker.Photos.PhotoProcessor>();
builder.Services.AddHostedService<Gimano.Worker.Inbox.InboxGenerator>();
builder.Services.AddHostedService<Gimano.Worker.Inbox.InboxRetention>();
builder.Services.AddHostedService<Gimano.Worker.Vetting.VettingMaintenance>();
builder.Services.AddHostedService<Gimano.Worker.Support.ReportRetentionJob>();
builder.Services.AddHostedService<Gimano.Worker.Events.DropPurge>();

builder.Services.Configure<GitHubFeedbackOptions>(builder.Configuration.GetSection(GitHubFeedbackOptions.Section));
if (builder.Configuration.GetSection(GitHubFeedbackOptions.Section).Get<GitHubFeedbackOptions>() is { } gh && gh.EnabledIn(builder.Environment.EnvironmentName))
{
    builder.Services.AddHttpClient("github", c => c.Timeout = TimeSpan.FromSeconds(20));
    builder.Services.AddHostedService<GitHubFeedbackSink>();
}

// Daily counts-only email to maintainers + moderation alerts (docs/back-office.md "Maintainer digest"). Off without ACS + recipients.
builder.Services.Configure<Gimano.Worker.Support.DigestOptions>(builder.Configuration.GetSection(Gimano.Worker.Support.DigestOptions.Section));
if (builder.Configuration.GetSection(Gimano.Worker.Support.DigestOptions.Section).Get<Gimano.Worker.Support.DigestOptions>() is { Enabled: true })
{
    builder.Services.AddSingleton<Gimano.Worker.Support.IMaintainerMailer, Gimano.Worker.Support.AcsMaintainerMailer>();
    builder.Services.AddHostedService<Gimano.Worker.Support.MaintainerDigestJob>();
}

builder.Build().Run();
