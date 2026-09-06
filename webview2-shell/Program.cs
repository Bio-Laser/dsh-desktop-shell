using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DeepSeekHarness.WebView2Shell;

internal static class Program
{
    private const string AppUserModelId = "DeepSeekAI.DeepSeekHarness";
    private const string DefaultUrl = "http://127.0.0.1:3080";

    [STAThread]
    private static void Main(string[] args)
    {
        SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
        ApplicationConfiguration.Initialize();
        Application.Run(new ShellForm(args.FirstOrDefault() ?? DefaultUrl));
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}

internal sealed class ShellForm : Form
{
    private readonly WebView2 webView = new() { Dock = DockStyle.Fill };
    private readonly string url;
    private ServerLease? server;

    public ShellForm(string url)
    {
        this.url = url;
        Text = "DeepSeek Harness";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Width = 1440;
        Height = 960;
        MinimumSize = new Size(960, 640);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(webView);
        Shown += InitializeWebViewAsync;
        FormClosed += (_, _) => server?.Dispose();
    }

    private async void InitializeWebViewAsync(object? sender, EventArgs e)
    {
        try
        {
            server = await ServerLease.StartAsync(new Uri(url));
            await webView.EnsureCoreWebView2Async();
            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
            webView.CoreWebView2.Settings.AreDevToolsEnabled = true;
            webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            webView.Source = new Uri(url);
        }
        catch (Exception error)
        {
            MessageBox.Show(
                $"DeepSeek Harness could not start its WebView2 runtime.\n\n{error.Message}",
                "DeepSeek Harness",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            Close();
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (e.IsSuccess) return;
        Debug.WriteLine($"WebView2 navigation failed: {e.WebErrorStatus}");
    }
}

/// <summary>Owns the dsh process started for one WebView2 window.</summary>
internal sealed class ServerLease : IDisposable
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(2) };
    private readonly Process? process;

    private ServerLease(Process? process)
    {
        this.process = process;
    }

    public static async Task<ServerLease> StartAsync(Uri url)
    {
        if (await IsReadyAsync(url)) return new ServerLease(null);

        var bin = FindDshBin();
        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "node",
            Arguments = $"{Quote(bin)} web --no-open",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(bin)!,
        }) ?? throw new InvalidOperationException("Could not start the dsh Node process.");

        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < deadline)
            {
                if (process.HasExited)
                    throw new InvalidOperationException($"The dsh process exited with code {process.ExitCode}.");
                if (await IsReadyAsync(url)) return new ServerLease(process);
                await Task.Delay(250);
            }
            throw new TimeoutException("The dsh Web server did not become ready within 30 seconds.");
        }
        catch
        {
            Stop(process);
            throw;
        }
    }

    public void Dispose()
    {
        if (process is not null) Stop(process);
    }

    private static async Task<bool> IsReadyAsync(Uri url)
    {
        try
        {
            using var response = await Http.GetAsync(url);
            return response.IsSuccessStatusCode;
        }
        catch (HttpRequestException)
        {
            return false;
        }
        catch (TaskCanceledException)
        {
            return false;
        }
    }

    private static string FindDshBin()
    {
        var roots = new[] { Environment.GetEnvironmentVariable("DSH_REPO_ROOT"), AppContext.BaseDirectory, Directory.GetCurrentDirectory() };
        foreach (var root in roots.Where(value => !string.IsNullOrWhiteSpace(value)))
        {
            var directory = new DirectoryInfo(root!);
            while (directory is not null)
            {
                var candidate = Path.Combine(directory.FullName, "apps", "cli", "lib", "bin.js");
                if (File.Exists(candidate)) return candidate;
                directory = directory.Parent!;
            }
        }
        throw new FileNotFoundException("Could not locate apps/cli/lib/bin.js. Set DSH_REPO_ROOT to the checkout root.");
    }

    private static string Quote(string value) => $"\"{value.Replace("\"", "\\\"")}\"";

    private static void Stop(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // The process exited between the check and Kill.
        }
        process.Dispose();
    }
}
