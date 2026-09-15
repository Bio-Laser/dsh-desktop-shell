using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Toolkit.Uwp.Notifications;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Windows.UI.Notifications;

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
            webView.CoreWebView2.PermissionRequested += OnPermissionRequested;
            webView.CoreWebView2.NotificationReceived += OnNotificationReceived;
            webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            // The spawned server prints its authenticated URL (bearer-token
            // fence); navigate there so the GUI actually loads. The configured
            // URL remains the fallback for an attached server whose stdout we
            // do not own.
            webView.Source = new Uri(server.NavigateUrl ?? url);
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

    /// <summary>
    /// Grant web notifications for the local DSH origin. WebView2's default
    /// policy auto-denies every permission request, which silently breaks the
    /// Notification API inside the shell; everything else keeps the default
    /// deny, and only the loopback origin is ever allow-listed.
    /// </summary>
    private void OnPermissionRequested(object? sender, CoreWebView2PermissionRequestedEventArgs e)
    {
        try
        {
            var uri = new Uri(e.Uri);
            var loopback = uri.Host is "127.0.0.1" or "localhost" or "[::1]"
                && (uri.Scheme == "http" || uri.Scheme == "https");
            if (loopback && e.PermissionKind == CoreWebView2PermissionKind.Notifications)
            {
                e.State = CoreWebView2PermissionState.Allow;
                e.Handled = true;
            }
        }
        catch
        {
            // Malformed URI: fall through to the default deny.
        }
    }

    /// <summary>
    /// Re-render web notifications as native app toasts. The default WebView2
    /// UI attributes every banner to the page origin ("127.0.0.1:3080") and
    /// follows the system banner duration; taking over lets the banner carry
    /// the app name and a fixed 2-second lifetime.
    /// </summary>
    private void OnNotificationReceived(object? sender, CoreWebView2NotificationReceivedEventArgs e)
    {
        try
        {
            var uri = new Uri(e.SenderOrigin);
            var loopback = uri.Host is "127.0.0.1" or "localhost" or "[::1]";
            if (!loopback) return; // Non-loopback keeps the default (denied) UI path.

            var notification = e.Notification;
            var title = string.IsNullOrWhiteSpace(notification.Title) ? "DeepSeek Harness" : notification.Title;
            var body = notification.Body ?? string.Empty;
            e.Handled = true;
            BeginInvoke(() => ShowToast(title, body));
        }
        catch
        {
            // Any failure falls back to WebView2's default notification UI.
        }
    }

    /// <summary>Show one native toast attributed to the app; lifetime follows the system default (min ~5s).</summary>
    private void ShowToast(string title, string body)
    {
        try
        {
            var builder = new ToastContentBuilder().AddText(title);
            if (!string.IsNullOrWhiteSpace(body)) builder.AddText(body);
            var toast = new ToastNotification(builder.GetToastContent().GetXml());
            toast.Activated += (_, _) => BeginInvoke(() =>
            {
                if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
                Show();
                Activate();
            });

            var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
            notifier.Show(toast);
        }
        catch
        {
            // Toast plumbing unavailable (missing Start Menu shortcut, etc.):
            // silently skip; the next notification retries.
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

    private ServerLease(Process? process, string? navigateUrl)
    {
        this.process = process;
        NavigateUrl = navigateUrl;
    }

    /// <summary>Authenticated URL printed by the spawned server, when known.</summary>
    public string? NavigateUrl { get; }

    public static async Task<ServerLease> StartAsync(Uri url)
    {
        if (await IsReadyAsync(url)) return new ServerLease(null, null);

        var bin = FindDshBin();
        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "node",
            Arguments = $"{Quote(bin)} web --no-open",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(bin)!,
        }) ?? throw new InvalidOperationException("Could not start the dsh Node process.");

        // The server answers 401 until a request carries its bearer token, so
        // the authenticated URL comes from its stdout banner (`dsh web: <url>`),
        // not from a status code.
        var navigateUrl = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        process.OutputDataReceived += (_, line) =>
        {
            if (line.Data is null) return;
            var match = Regex.Match(line.Data, @"^dsh web: (\S+)");
            if (match.Success) navigateUrl.TrySetResult(match.Groups[1].Value);
        };
        process.ErrorDataReceived += (_, line) => Debug.WriteLineIf(line.Data is not null, line.Data);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < deadline)
            {
                if (process.HasExited)
                    throw new InvalidOperationException($"The dsh process exited with code {process.ExitCode}.");
                if (await IsReadyAsync(url))
                {
                    // Give the banner a short grace window; an older server
                    // without it still opens on the configured URL.
                    var banner = await Task.WhenAny(navigateUrl.Task, Task.Delay(TimeSpan.FromSeconds(3)));
                    return new ServerLease(process, banner == navigateUrl.Task ? navigateUrl.Task.Result : null);
                }
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

    /// <summary>Whether an HTTP server answers on the URL: any received status counts, including 401.</summary>
    private static async Task<bool> IsReadyAsync(Uri url)
    {
        try
        {
            using var response = await Http.GetAsync(url);
            return true;
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
