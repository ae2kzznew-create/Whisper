using System.Diagnostics;

namespace VoxLocal.Core.Transcription;

public sealed record SubprocessResult(int ExitCode, byte[] Stdout, byte[] Stderr);

public sealed class SubprocessTimeoutException : Exception
{
    public SubprocessTimeoutException() : base("subprocess timed out") { }
}

public sealed class SubprocessLaunchException : Exception
{
    public SubprocessLaunchException(string reason, Exception? inner = null) : base(reason, inner) { }
}

/// <summary>
/// Abstraction over <see cref="Process"/> so transcription logic can be
/// unit-tested with a mock runner.
/// </summary>
public interface ISubprocessRunner
{
    Task<SubprocessResult> RunAsync(
        string executablePath,
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);
}

public sealed class ProcessSubprocessRunner : ISubprocessRunner
{
    public async Task<SubprocessResult> RunAsync(
        string executablePath,
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executablePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var arg in arguments)
        {
            startInfo.ArgumentList.Add(arg);
        }

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new SubprocessLaunchException("process failed to start");
            }
        }
        catch (Exception ex) when (ex is not SubprocessLaunchException)
        {
            throw new SubprocessLaunchException(ex.Message, ex);
        }

        // Reading both streams concurrently avoids deadlocks when the child
        // writes more than the pipe buffer (same concern as the Swift version).
        using var stdoutBuffer = new MemoryStream();
        using var stderrBuffer = new MemoryStream();
        var stdoutTask = process.StandardOutput.BaseStream.CopyToAsync(stdoutBuffer, CancellationToken.None);
        var stderrTask = process.StandardError.BaseStream.CopyToAsync(stderrBuffer, CancellationToken.None);

        using var timeoutCts = new CancellationTokenSource();
        if (timeout > TimeSpan.Zero)
        {
            timeoutCts.CancelAfter(timeout);
        }
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(timeoutCts.Token, cancellationToken);

        var timedOut = false;
        try
        {
            await process.WaitForExitAsync(linkedCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            timedOut = timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested;
            // Windows console processes have no graceful SIGTERM equivalent;
            // Kill(entireProcessTree: true) replaces the terminate-then-SIGKILL
            // escalation of the macOS version.
            try { process.Kill(entireProcessTree: true); } catch { /* already exited */ }
        }

        await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);

        if (timedOut)
        {
            throw new SubprocessTimeoutException();
        }
        cancellationToken.ThrowIfCancellationRequested();

        return new SubprocessResult(process.ExitCode, stdoutBuffer.ToArray(), stderrBuffer.ToArray());
    }
}
