using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Gimano.Core.Community;

/// <summary>Object storage for photos. Keys are content hashes (immutable), plus "uploads/{id}" for originals awaiting processing.</summary>
public interface IMediaStore
{
    Task PutAsync(string key, byte[] data, string contentType, CancellationToken ct = default);
    Task<byte[]?> GetAsync(string key, CancellationToken ct = default);
    Task DeleteAsync(string key, CancellationToken ct = default);
}

public static class MediaKeys
{
    public static string Upload(Guid photoId) => $"uploads/{photoId:N}";
    public static string Webp(string hash) => $"{hash}.webp";
    /// <summary>Private appeal evidence: never served by /media (not a content hash), read only by maintainers.</summary>
    public static string Appeal(Guid ownerId, int index) => $"appeals/{ownerId:N}/{index}";
    /// <summary>Public URL path served by the API: <c>/media/{hash}.webp</c>.</summary>
    public static string? Url(string? hash) => hash is null ? null : $"/media/{hash}.webp";
    public static bool IsValidHash(string s) => s.Length == 32 && s.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}

/// <summary>Default: files on a local volume (compose volume <c>media</c>).</summary>
public sealed class LocalMediaStore(string root) : IMediaStore
{
    private string PathFor(string key)
    {
        if (key.Contains("..") || Path.IsPathRooted(key)) throw new ArgumentException("Invalid media key.", nameof(key));
        // Shard by the first two hex chars to keep directories small.
        var file = key.StartsWith("uploads/", StringComparison.Ordinal) ? key : Path.Combine(key[..2], key);
        return Path.Combine(root, file);
    }

    public async Task PutAsync(string key, byte[] data, string contentType, CancellationToken ct = default)
    {
        var path = PathFor(key);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        await File.WriteAllBytesAsync(tmp, data, ct);
        File.Move(tmp, path, overwrite: true);
    }

    public async Task<byte[]?> GetAsync(string key, CancellationToken ct = default)
    {
        var path = PathFor(key);
        return File.Exists(path) ? await File.ReadAllBytesAsync(path, ct) : null;
    }

    public Task DeleteAsync(string key, CancellationToken ct = default)
    {
        var path = PathFor(key);
        if (File.Exists(path)) File.Delete(path);
        return Task.CompletedTask;
    }
}

public sealed class S3Options
{
    public string Endpoint { get; set; } = "";      // e.g. https://s3.ap-southeast-1.amazonaws.com or http://minio:9000
    public string Bucket { get; set; } = "";
    public string Region { get; set; } = "us-east-1";
    public string AccessKey { get; set; } = "";
    public string SecretKey { get; set; } = "";
    public bool PathStyle { get; set; } = true;
}

/// <summary>Minimal S3-compatible store (PUT/GET/DELETE object with AWS Signature V4). Works with AWS S3, MinIO, R2.</summary>
public sealed class S3MediaStore(HttpClient http, S3Options o) : IMediaStore
{
    public async Task PutAsync(string key, byte[] data, string contentType, CancellationToken ct = default)
    {
        using var req = Sign(HttpMethod.Put, key, data, contentType);
        using var resp = await http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
    }

    public async Task<byte[]?> GetAsync(string key, CancellationToken ct = default)
    {
        using var req = Sign(HttpMethod.Get, key, [], null);
        using var resp = await http.SendAsync(req, ct);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    public async Task DeleteAsync(string key, CancellationToken ct = default)
    {
        using var req = Sign(HttpMethod.Delete, key, [], null);
        using var resp = await http.SendAsync(req, ct);
    }

    internal HttpRequestMessage Sign(HttpMethod method, string key, byte[] body, string? contentType, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        var amzDate = t.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var date = amzDate[..8];
        var endpoint = new Uri(o.Endpoint.TrimEnd('/'));
        var host = o.PathStyle ? endpoint.Authority : $"{o.Bucket}.{endpoint.Authority}";
        var path = (o.PathStyle ? $"/{o.Bucket}/" : "/") + string.Join('/', key.Split('/').Select(Uri.EscapeDataString));
        var payloadHash = Hex(SHA256.HashData(body));

        var canonicalHeaders = $"host:{host}\nx-amz-content-sha256:{payloadHash}\nx-amz-date:{amzDate}\n";
        const string signedHeaders = "host;x-amz-content-sha256;x-amz-date";
        var canonicalRequest = $"{method.Method}\n{path}\n\n{canonicalHeaders}\n{signedHeaders}\n{payloadHash}";
        var scope = $"{date}/{o.Region}/s3/aws4_request";
        var stringToSign = $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{Hex(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)))}";
        var kDate = Hmac(Encoding.UTF8.GetBytes("AWS4" + o.SecretKey), date);
        var kSigning = Hmac(Hmac(Hmac(kDate, o.Region), "s3"), "aws4_request");
        var signature = Hex(Hmac(kSigning, stringToSign));

        var req = new HttpRequestMessage(method, new Uri($"{endpoint.Scheme}://{host}{path}"));
        req.Headers.Host = host;
        req.Headers.TryAddWithoutValidation("x-amz-date", amzDate);
        req.Headers.TryAddWithoutValidation("x-amz-content-sha256", payloadHash);
        req.Headers.TryAddWithoutValidation("Authorization",
            $"AWS4-HMAC-SHA256 Credential={o.AccessKey}/{scope}, SignedHeaders={signedHeaders}, Signature={signature}");
        if (method == HttpMethod.Put)
        {
            req.Content = new ByteArrayContent(body);
            if (contentType is not null) req.Content.Headers.ContentType = new(contentType);
        }
        return req;
    }

    private static byte[] Hmac(byte[] key, string data) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(data));
    private static string Hex(byte[] b) => Convert.ToHexStringLower(b);
}

public static class MediaStoreRegistration
{
    /// <summary><c>Media:Provider</c> = local (default, <c>Media:Root</c>) | s3 (<c>Media:S3:*</c>).</summary>
    public static IServiceCollection AddGimanoMedia(this IServiceCollection services, IConfiguration config)
    {
        if (string.Equals(config["Media:Provider"], "s3", StringComparison.OrdinalIgnoreCase))
        {
            var o = config.GetSection("Media:S3").Get<S3Options>() ?? new S3Options();
            services.AddHttpClient("media-s3");
            services.AddSingleton<IMediaStore>(sp => new S3MediaStore(sp.GetRequiredService<IHttpClientFactory>().CreateClient("media-s3"), o));
        }
        else
        {
            var root = config["Media:Root"] ?? Path.Combine(AppContext.BaseDirectory, "media");
            services.AddSingleton<IMediaStore>(new LocalMediaStore(root));
        }
        return services;
    }
}
