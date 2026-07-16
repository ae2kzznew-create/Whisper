namespace VoxLocal.App;

/// <summary>
/// Process entry point (VoxLocalMain analogue). WPF requires an STA thread.
/// The macOS activation policy (.accessory / LSUIElement, no Dock icon) is
/// replaced by a tray-only App: no main window and
/// ShutdownMode.OnExplicitShutdown (see App.xaml.cs in module 8).
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main()
    {
        var app = new App();
        return app.Run();
    }
}
