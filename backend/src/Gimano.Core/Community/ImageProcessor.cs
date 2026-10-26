using System.Security.Cryptography;
using SkiaSharp;

namespace Gimano.Core.Community;

public sealed record ProcessedImage(byte[] Webp, int Width, int Height, byte[] Thumb, int ThumbWidth, int ThumbHeight)
{
    /// <summary>Content-hash keys (first 32 hex chars of SHA-256).</summary>
    public string Key => ImageProcessor.ContentKey(Webp);
    public string ThumbKey => ImageProcessor.ContentKey(Thumb);
}

public sealed class ImageRejectedException(string message, bool unsupportedFormat = false) : Exception(message)
{
    public bool UnsupportedFormat { get; } = unsupportedFormat;
}

/// <summary>
/// Photo pipeline (SkiaSharp, MIT): decode → apply EXIF orientation → re-encode, which drops all metadata incl. GPS
/// (Skia's WebP encoder writes no EXIF/XMP) → ≤ 1600 px long edge WebP q80 + 400 px thumbnail WebP q70.
/// Rejects undecodable input (HEIC where the platform codec is missing) and images under 200 px.
/// </summary>
public static class ImageProcessor
{
    public const int MaxBytes = 15 * 1024 * 1024;
    public const int MaxEdge = 1600;
    public const int ThumbEdge = 400;
    public const int MinEdge = 200;
    public const int Quality = 80;
    public const int ThumbQuality = 70;

    /// <summary>Cheap header check used synchronously at upload time (415 for formats we can't decode).</summary>
    public static (int Width, int Height) Probe(byte[] data)
    {
        using var codec = SKCodec.Create(new SKMemoryStream(data))
            ?? throw new ImageRejectedException(
                LooksLikeHeic(data)
                    ? "HEIC photos aren't supported by the server yet; please upload JPEG or WebP (the apps convert automatically)."
                    : "Unsupported or corrupt image; upload JPEG, PNG or WebP.",
                unsupportedFormat: true);
        var (w, h) = Oriented(codec.Info.Width, codec.Info.Height, codec.EncodedOrigin);
        if (Math.Min(w, h) < MinEdge) throw new ImageRejectedException($"Image is too small ({w}×{h}); at least {MinEdge} px is required.");
        return (w, h);
    }

    public static ProcessedImage Process(byte[] data)
    {
        Probe(data);
        using var codec = SKCodec.Create(new SKMemoryStream(data))!;
        var info = new SKImageInfo(codec.Info.Width, codec.Info.Height, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var decoded = new SKBitmap(info);
        var result = codec.GetPixels(info, decoded.GetPixels());
        if (result is not (SKCodecResult.Success or SKCodecResult.IncompleteInput))
            throw new ImageRejectedException($"Could not decode image ({result}).");

        using var upright = ApplyOrientation(decoded, codec.EncodedOrigin);
        var (webp, w, h) = Encode(upright, MaxEdge, Quality);
        var (thumb, tw, th) = Encode(upright, ThumbEdge, ThumbQuality);
        return new ProcessedImage(webp, w, h, thumb, tw, th);
    }

    /// <summary>
    /// The JPEG the content check sees: decoded, EXIF orientation baked in, ≤ 1024 px on the long edge. Re-encoding drops all
    /// metadata (EXIF, GPS), and it is built from the already stripped WebP, never from the original upload.
    /// </summary>
    public static byte[] ToScreeningJpeg(byte[] data)
    {
        using var codec = SKCodec.Create(new SKMemoryStream(data)) ?? throw new ImageRejectedException("Unsupported or corrupt image.");
        var info = new SKImageInfo(codec.Info.Width, codec.Info.Height, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var decoded = new SKBitmap(info);
        var result = codec.GetPixels(info, decoded.GetPixels());
        if (result is not (SKCodecResult.Success or SKCodecResult.IncompleteInput)) throw new ImageRejectedException($"Could not decode image ({result}).");
        using var upright = ApplyOrientation(decoded, codec.EncodedOrigin);
        var scale = Math.Min(1.0, (double)ContentScreening.MaxImageEdge / Math.Max(upright.Width, upright.Height));
        var w = Math.Max(1, (int)Math.Round(upright.Width * scale));
        var h = Math.Max(1, (int)Math.Round(upright.Height * scale));
        using var resized = scale < 1.0
            ? upright.Resize(new SKImageInfo(w, h, upright.ColorType, upright.AlphaType), new SKSamplingOptions(SKCubicResampler.Mitchell))
            : upright.Copy();
        using var image = SKImage.FromBitmap(resized);
        using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, 80) ?? throw new ImageRejectedException("JPEG encoding failed.");
        return encoded.ToArray();
    }

    public static string ContentKey(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes))[..32];

    private static (byte[] Bytes, int W, int H) Encode(SKBitmap src, int maxEdge, int quality)
    {
        var scale = Math.Min(1.0, (double)maxEdge / Math.Max(src.Width, src.Height));
        var w = Math.Max(1, (int)Math.Round(src.Width * scale));
        var h = Math.Max(1, (int)Math.Round(src.Height * scale));
        using var resized = scale < 1.0
            ? src.Resize(new SKImageInfo(w, h, src.ColorType, src.AlphaType), new SKSamplingOptions(SKCubicResampler.Mitchell))
            : src.Copy();
        using var image = SKImage.FromBitmap(resized);
        using var encoded = image.Encode(SKEncodedImageFormat.Webp, quality)
            ?? throw new ImageRejectedException("WebP encoding failed.");
        return (encoded.ToArray(), w, h);
    }

    private static (int, int) Oriented(int w, int h, SKEncodedOrigin o) =>
        o is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom ? (h, w) : (w, h);

    /// <summary>Bakes the EXIF orientation into the pixels so the (metadata-free) output displays upright.</summary>
    internal static SKBitmap ApplyOrientation(SKBitmap src, SKEncodedOrigin origin)
    {
        if (origin is SKEncodedOrigin.TopLeft or SKEncodedOrigin.Default) return src.Copy();
        var (w, h) = Oriented(src.Width, src.Height, origin);
        var dst = new SKBitmap(new SKImageInfo(w, h, src.ColorType, src.AlphaType));
        using var canvas = new SKCanvas(dst);
        switch (origin)
        {
            case SKEncodedOrigin.TopRight: canvas.Scale(-1, 1, w / 2f, 0); break;                          // mirror
            case SKEncodedOrigin.BottomRight: canvas.RotateDegrees(180, w / 2f, h / 2f); break;              // 180°
            case SKEncodedOrigin.BottomLeft: canvas.Scale(1, -1, 0, h / 2f); break;                          // flip
            case SKEncodedOrigin.LeftTop: canvas.Translate(w, 0); canvas.RotateDegrees(90); canvas.Translate(0, src.Height); canvas.Scale(1, -1); break; // transpose
            case SKEncodedOrigin.RightTop: canvas.Translate(w, 0); canvas.RotateDegrees(90); break;          // 90° CW
            case SKEncodedOrigin.RightBottom: canvas.Translate(w, 0); canvas.RotateDegrees(90); canvas.Translate(src.Width, 0); canvas.Scale(-1, 1); break; // transverse
            case SKEncodedOrigin.LeftBottom: canvas.Translate(0, h); canvas.RotateDegrees(270); break;       // 90° CCW
        }
        using (var img = SKImage.FromBitmap(src)) canvas.DrawImage(img, 0, 0, new SKSamplingOptions(SKFilterMode.Nearest));
        canvas.Flush();
        return dst;
    }

    private static bool LooksLikeHeic(byte[] d) =>
        d.Length > 12 && d[4] == 'f' && d[5] == 't' && d[6] == 'y' && d[7] == 'p' &&
        System.Text.Encoding.ASCII.GetString(d, 8, 4) is "heic" or "heix" or "hevc" or "heim" or "heis" or "mif1" or "msf1";
}
