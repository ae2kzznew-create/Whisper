using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using VoxLocal.Core.Models;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Transcription;

/// <summary>
/// Manages local ggml model files: discovery, integrity validation and
/// downloads with progress. Models live in %LOCALAPPDATA%\VoxLocal\models.
/// </summary>
public sealed class ModelManager : INotifyPropertyChanged
{
    public sealed record InstalledModel(string Name, string Path, long SizeBytes);

    /// <summary>ggml container magic ("ggml" read as a little-endian UInt32).</summary>
    internal const uint GgmlMagic = 0x6767_6D6C;
    internal const long MinimumModelBytes = 1_000_000;

    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    private IReadOnlyList<InstalledModel> _installedModels = Array.Empty<InstalledModel>();
    private double? _downloadProgress;
    private string? _downloadingModel;
    private CancellationTokenSource? _downloadCts;
    private readonly SynchronizationContext? _ownerContext = SynchronizationContext.Current;

    public string ModelsDirectory { get; }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised after the installed models list is rescanned (marshalled
    /// to the owner's synchronization context when one was present at construction).</summary>
    public event Action? ModelsChanged;

    public ModelManager(string? modelsDirectory = null)
    {
        ModelsDirectory = modelsDirectory ?? System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VoxLocal", "models");
        Directory.CreateDirectory(ModelsDirectory);
        RefreshInstalledModels();
    }

    public IReadOnlyList<InstalledModel> InstalledModels
    {
        get => _installedModels;
        private set { _installedModels = value; OnPropertyChanged(); RaiseModelsChanged(); }
    }

    public double? DownloadProgress
    {
        get => _downloadProgress;
        private set { _downloadProgress = value; OnPropertyChanged(); }
    }

    public string? DownloadingModel
    {
        get => _downloadingModel;
        private set { _downloadingModel = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsDownloading)); }
    }

    public bool IsDownloading => DownloadingModel is not null;

    // ---- Discovery & validation ----

    public void RefreshInstalledModels()
    {
        var models = new List<InstalledModel>();
        foreach (var path in Directory.EnumerateFiles(ModelsDirectory, "*.bin"))
        {
            if (ValidateModelFile(path) != ValidationResult.Valid) continue;
            models.Add(new InstalledModel(
                ModelName(System.IO.Path.GetFileName(path)), path, new FileInfo(path).Length));
        }
        InstalledModels = models.OrderBy(m => m.SizeBytes).ToList();
    }

    public static string ModelName(string fileName)
    {
        var name = fileName;
        if (name.StartsWith("ggml-", StringComparison.Ordinal)) name = name[5..];
        if (name.EndsWith(".bin", StringComparison.Ordinal)) name = name[..^4];
        return name;
    }

    public enum ValidationResult { Valid, Missing, TooSmall, BadMagic }

    /// <summary>Checks existence, a minimum plausible size and the ggml magic number.</summary>
    public static ValidationResult ValidateModelFile(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) return ValidationResult.Missing;
        if (info.Length < MinimumModelBytes) return ValidationResult.TooSmall;

        Span<byte> head = stackalloc byte[4];
        try
        {
            using var stream = File.OpenRead(path);
            if (stream.Read(head) != 4) return ValidationResult.BadMagic;
        }
        catch (IOException)
        {
            return ValidationResult.BadMagic;
        }
        var magic = BinaryPrimitives.ReadUInt32LittleEndian(head);
        return magic == GgmlMagic ? ValidationResult.Valid : ValidationResult.BadMagic;
    }

    /// <summary>Path where a model with the given name is expected.</summary>
    public string ExpectedPath(string modelName) =>
        System.IO.Path.Combine(ModelsDirectory, $"ggml-{modelName}.bin");

    /// <summary>Resolves the model selected in settings to a validated file path.</summary>
    public string ResolveModel(string name)
    {
        var path = ExpectedPath(name);
        return ValidateModelFile(path) switch
        {
            ValidationResult.Valid => path,
            ValidationResult.Missing => throw new VoxLocalException(new VoxLocalError.ModelMissing(path)),
            _ => throw new VoxLocalException(new VoxLocalError.ModelInvalid(path)),
        };
    }

    // ---- Download ----

    /// <summary>
    /// Downloads a catalog model. The UI must show info.SizeLabel and get
    /// explicit user confirmation before calling this.
    /// </summary>
    public async Task<string> DownloadAsync(WhisperModelInfo info, CancellationToken cancellationToken = default)
    {
        if (IsDownloading)
        {
            throw new InvalidOperationException(L10n.T("models.download.busy"));
        }
        DownloadingModel = info.Name;
        DownloadProgress = 0;
        _downloadCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        var holding = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(), $"voxlocal-model-{Guid.NewGuid()}.bin");
        try
        {
            Log.Shared.Info($"model download started: {info.Name} (~{info.ApproxMB} MB)");
            using var response = await Http.GetAsync(
                info.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, _downloadCts.Token).ConfigureAwait(false);
            if ((int)response.StatusCode != 200)
            {
                throw new HttpRequestException($"HTTP {(int)response.StatusCode}");
            }

            var total = response.Content.Headers.ContentLength ?? -1L;
            await using (var source = await response.Content.ReadAsStreamAsync(_downloadCts.Token).ConfigureAwait(false))
            await using (var target = File.Create(holding))
            {
                var buffer = new byte[1 << 16];
                long written = 0;
                int read;
                while ((read = await source.ReadAsync(buffer, _downloadCts.Token).ConfigureAwait(false)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, read), _downloadCts.Token).ConfigureAwait(false);
                    written += read;
                    if (total > 0) DownloadProgress = (double)written / total;
                }
            }

            var destination = ExpectedPath(info.Name);
            File.Delete(destination); // no-op when the file does not exist
            File.Move(holding, destination);

            if (ValidateModelFile(destination) != ValidationResult.Valid)
            {
                File.Delete(destination);
                throw new VoxLocalException(new VoxLocalError.ModelInvalid(destination));
            }
            Log.Shared.Info($"model download finished: {info.Name}");
            RefreshInstalledModels();
            return destination;
        }
        finally
        {
            try { if (File.Exists(holding)) File.Delete(holding); } catch { /* best effort */ }
            _downloadCts.Dispose();
            _downloadCts = null;
            DownloadingModel = null;
            DownloadProgress = null;
        }
    }

    public void CancelDownload() => _downloadCts?.Cancel();

    private void RaiseModelsChanged()
    {
        var context = _ownerContext;
        if (context is not null && !ReferenceEquals(SynchronizationContext.Current, context))
        {
            context.Post(_ => ModelsChanged?.Invoke(), null);
        }
        else
        {
            ModelsChanged?.Invoke();
        }
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
