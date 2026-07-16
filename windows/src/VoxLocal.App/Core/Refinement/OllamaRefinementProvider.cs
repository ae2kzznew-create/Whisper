using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VoxLocal.Core.Refinement;

/// <summary>
/// Refines transcripts through a local Ollama server. Privacy guarantee:
/// the endpoint must resolve to a loopback host, otherwise construction
/// fails with NonLocalEndpointException — no request leaves the machine.
/// </summary>
public sealed class OllamaRefinementProvider : ITextRefinementProvider
{
    public Uri Endpoint { get; }
    public string Model { get; }
    private readonly HttpClient _http;

    internal static readonly HashSet<string> LoopbackHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "127.0.0.1", "localhost", "::1", "[::1]",
    };

    public OllamaRefinementProvider(string endpoint, string model, HttpClient? http = null)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var url) || string.IsNullOrEmpty(url.Host))
        {
            throw new NonLocalEndpointException(endpoint);
        }
        if (!IsLoopback(url.Host))
        {
            throw new NonLocalEndpointException(endpoint);
        }
        Endpoint = url;
        Model = model;
        // Refuse every HTTP redirect. Without this, a process answering on
        // the loopback port could 307-redirect the transcript POST to a
        // remote host — AllowAutoRedirect=false delivers the 3xx as-is and
        // never follows it (same guarantee as NoRedirectDelegate on macOS).
        _http = http ?? new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        })
        {
            Timeout = TimeSpan.FromSeconds(120),
        };
    }

    public static bool IsLoopback(string host) => LoopbackHosts.Contains(host);

    // ---- Availability ----

    private sealed class TagsResponse
    {
        [JsonPropertyName("models")]
        public List<ModelEntry>? Models { get; set; }

        public sealed class ModelEntry
        {
            [JsonPropertyName("name")]
            public string Name { get; set; } = "";
        }
    }

    public async Task<RefinementAvailability> CheckAvailabilityAsync()
    {
        try
        {
            var names = await InstalledModelsAsync().ConfigureAwait(false);
            if (names.Any(n => n == Model || n.StartsWith(Model + ":", StringComparison.Ordinal)))
            {
                return new RefinementAvailability.Available();
            }
            return new RefinementAvailability.ModelMissing(names);
        }
        catch (Exception e)
        {
            return new RefinementAvailability.ServerUnreachable(e.Message);
        }
    }

    /// <summary>Model names installed on the local Ollama server (/api/tags).</summary>
    public async Task<IReadOnlyList<string>> InstalledModelsAsync(CancellationToken cancellationToken = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromSeconds(5));
        using var response = await _http.GetAsync(new Uri(Endpoint, "api/tags"), cts.Token).ConfigureAwait(false);
        if ((int)response.StatusCode != 200)
        {
            throw new RefinementUnavailableException($"HTTP {(int)response.StatusCode}");
        }
        var json = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
        var decoded = JsonSerializer.Deserialize<TagsResponse>(json);
        return (decoded?.Models ?? new()).Select(m => m.Name).ToList();
    }

    // ---- Refinement ----

    internal sealed record ChatMessage(
        [property: JsonPropertyName("role")] string Role,
        [property: JsonPropertyName("content")] string Content);

    internal sealed record ChatOptions(
        [property: JsonPropertyName("temperature")] double Temperature,
        [property: JsonPropertyName("num_predict")] int NumPredict);

    internal sealed record ChatRequest(
        [property: JsonPropertyName("model")] string Model,
        [property: JsonPropertyName("messages")] IReadOnlyList<ChatMessage> Messages,
        [property: JsonPropertyName("stream")] bool Stream,
        [property: JsonPropertyName("options")] ChatOptions Options);

    private sealed class ChatResponse
    {
        [JsonPropertyName("message")]
        public ResponseMessage? Message { get; set; }

        public sealed class ResponseMessage
        {
            [JsonPropertyName("content")]
            public string? Content { get; set; }
        }
    }

    /// <summary>Builds the /api/chat request body (exposed for unit tests).</summary>
    public static byte[] RequestBody(string model, string transcript, RefinementContext context)
    {
        var request = new ChatRequest(
            model,
            new[]
            {
                new ChatMessage("system", RefinementPromptBuilder.SystemPrompt(context)),
                new ChatMessage("user", RefinementPromptBuilder.UserPrompt(transcript)),
            },
            Stream: false,
            // Cap generation relative to input so a runaway model cannot
            // produce unbounded output.
            new ChatOptions(Temperature: 0.2, NumPredict: Math.Max(256, transcript.Length)));
        return JsonSerializer.SerializeToUtf8Bytes(request);
    }

    public async Task<string> RefineAsync(
        string transcript,
        RefinementContext context,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(Endpoint, "api/chat"))
        {
            Content = new ByteArrayContent(RequestBody(Model, transcript, context)),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromSeconds(context.TimeoutSeconds));

        HttpResponseMessage response;
        string body;
        try
        {
            response = await _http.SendAsync(request, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw; // session cancelled — the pipeline maps this to a fallback
        }
        catch (OperationCanceledException)
        {
            throw new RefinementTimeoutException();
        }
        catch (HttpRequestException e)
        {
            throw new RefinementUnavailableException(e.Message);
        }

        using (response)
        {
            if ((int)response.StatusCode != 200)
            {
                throw new RefinementInvalidResponseException($"HTTP {(int)response.StatusCode}");
            }
            body = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
        }

        ChatResponse? decoded;
        try
        {
            decoded = JsonSerializer.Deserialize<ChatResponse>(body);
        }
        catch (JsonException)
        {
            decoded = null;
        }
        if (decoded?.Message?.Content is not { } content)
        {
            throw new RefinementInvalidResponseException("unexpected /api/chat payload");
        }
        return content;
    }
}
