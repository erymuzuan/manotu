using Gimano.Core.Contracts;
using Gimano.Core.Support;
using Xunit;

namespace Gimano.Tests;

public class MaintainerDigestTests
{
    private static DigestCounts Counts(int feedback = 0, int untriaged = 0, int moderation = 0, TimeSpan? oldestModeration = null, int regressed = 0) =>
        new(feedback, feedback == 0 ? new Dictionary<FeedbackCategory, int>() : new() { [FeedbackCategory.Bug] = feedback },
            untriaged, untriaged == 0 ? null : TimeSpan.FromHours(30), 0, regressed, regressed, moderation, 0, oldestModeration);

    // 08:10 in Malaysia (UTC+8) = 00:10 UTC.
    private static readonly DateTimeOffset At0810Myt = new(2026, 10, 26, 0, 10, 0, TimeSpan.Zero);

    [Fact]
    public void Digest_is_due_once_inside_its_hour()
    {
        Assert.True(MaintainerDigest.DigestDue(At0810Myt, 8, null));
        Assert.False(MaintainerDigest.DigestDue(At0810Myt, 8, new DateOnly(2026, 10, 26)));
        Assert.True(MaintainerDigest.DigestDue(At0810Myt, 8, new DateOnly(2026, 10, 25)));
        Assert.False(MaintainerDigest.DigestDue(At0810Myt.AddHours(-1), 8, null));   // 07:10
        Assert.False(MaintainerDigest.DigestDue(At0810Myt.AddHours(3), 8, null));    // 11:10: a restart later in the day doesn't resend
    }

    [Fact]
    public void Moderation_alert_needs_20_hours_and_respects_the_cooldown()
    {
        var now = At0810Myt.AddHours(6);
        Assert.False(MaintainerDigest.ModerationAlertDue(Counts(moderation: 1, oldestModeration: TimeSpan.FromHours(19)), now, null));
        Assert.True(MaintainerDigest.ModerationAlertDue(Counts(moderation: 1, oldestModeration: TimeSpan.FromHours(20)), now, null));
        Assert.False(MaintainerDigest.ModerationAlertDue(Counts(moderation: 1, oldestModeration: TimeSpan.FromHours(21)), now, now.AddHours(-11)));
        Assert.True(MaintainerDigest.ModerationAlertDue(Counts(moderation: 1, oldestModeration: TimeSpan.FromHours(21)), now, now.AddHours(-12)));
        Assert.False(MaintainerDigest.ModerationAlertDue(Counts(), now, null));
    }

    [Fact]
    public void Daily_message_has_counts_in_the_subject_and_body()
    {
        var m = MaintainerDigest.Daily(Counts(feedback: 7, untriaged: 9, moderation: 3, oldestModeration: TimeSpan.FromHours(19), regressed: 1),
            At0810Myt, "https://backoffice.example");
        Assert.Equal("Manotu Mon 26 Oct: 7 feedback · 1 crash regressed · 3 to moderate", m.Subject);
        Assert.Contains("New feedback (24 h): 7 (7 bug)", m.Text);
        Assert.Contains("Feedback not yet triaged: 9, oldest 30 h", m.Text);
        Assert.Contains("Moderation waiting: 3, oldest 19 h", m.Text);
        Assert.Contains("https://backoffice.example", m.Html);
    }

    [Fact]
    public void Quiet_day_says_so()
    {
        Assert.True(Counts().IsQuiet);
        Assert.False(Counts(untriaged: 1).IsQuiet);
        Assert.EndsWith("all quiet", MaintainerDigest.Daily(Counts(), At0810Myt, "u").Subject);
    }

    [Fact]
    public void Moderation_alert_states_the_wait()
    {
        var m = MaintainerDigest.ModerationAlert(Counts(moderation: 2, oldestModeration: TimeSpan.FromHours(20.6)), "u");
        Assert.Equal("Manotu: a moderation item has waited 20 h (2 waiting)", m.Subject);
        Assert.Contains("within 24 hours", m.Text);
    }

    [Fact]
    public void Html_is_encoded()
    {
        var m = MaintainerDigest.Daily(Counts(), At0810Myt, "https://x.example/?a=1&b=<2>");
        Assert.Contains("a=1&amp;b=&lt;2&gt;", m.Html);
    }
}

public class DigestOptionsTests
{
    [Fact]
    public void Recipients_split_on_commas_and_need_a_connection_string()
    {
        var o = new Gimano.Worker.Support.DigestOptions { To = ["a@example.com, b@example.com", "A@example.com"] };
        Assert.Equal(["a@example.com", "b@example.com"], o.Recipients);
        Assert.False(o.Enabled);
        o.AcsConnectionString = "endpoint=https://x/;accesskey=y";
        Assert.True(o.Enabled);
    }
}
