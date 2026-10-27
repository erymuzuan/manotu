using System.Net;
using Azure.Communication.Email;

namespace Gimano.BackOffice.Components.Account;

public static class MaintainerInvitationEmail
{
    public static EmailContent Create(string link, bool existingAccount = false)
    {
        var introduction = existingAccount
            ? "Your Manotu maintainer account already exists. Choose a new password for the back office; your account and its data will be preserved."
            : "You’re invited to the Manotu back office. Create your account and choose your password to review feedback, bugs and reported content.";
        var action = existingAccount ? "Choose a new password" : "Create account and password";
        return new(existingAccount ? "Set your Manotu back-office password" : "Set up your Manotu maintainer account")
        {
        PlainText = $"{introduction}\n\n{action}:\n{link}\n\nThis link works once and expires in 24 hours. Use the email address that received this invitation. After setup, sign in at https://backoffice.manotu.app. Every sign-in also requires an emailed verification code.\n\nIf you weren't expecting this invitation, you can ignore it.",
        Html = $"""
            <!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;background:#F5F8FD;font-family:Arial,Helvetica,sans-serif;color:#0B1B3A">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#FFFFFF;border:1px solid #DCE5F2">
            <tr><td style="padding:24px;background:#0047AB;color:#FFFFFF;font-size:28px;font-weight:bold">Manotu</td></tr>
            <tr><td style="padding:24px;font-size:16px;line-height:1.6">
            <h1 style="font-size:24px;margin:0 0 16px">Your maintainer account</h1>
            <p>{introduction}</p>
            <table role="presentation" cellpadding="0" cellspacing="0"><tr><td bgcolor="#0047AB" style="padding:14px 20px;border-radius:8px"><a href="{WebUtility.HtmlEncode(link)}" style="color:#FFFFFF;font-weight:bold;text-decoration:none">{action}</a></td></tr></table>
            <p>This link works once and expires in <strong>24 hours</strong>. Use the email address that received this invitation.</p>
            <p>After setup, sign in at <a href="https://backoffice.manotu.app" style="color:#0047AB">backoffice.manotu.app</a>. Every sign-in also requires an emailed verification code.</p>
            <p style="font-size:12px;color:#3A4A66">If you weren't expecting this invitation, you can ignore it.</p>
            </td></tr></table></td></tr></table></body></html>
            """
        };
    }
}
