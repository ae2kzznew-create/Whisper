using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using VoxLocal.Core.History;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

/// <summary>
/// Wispr-Flow-style history window: shows the most recent dictation results
/// so the text can be recovered (copied) even when insertion into the target
/// app failed. Data comes from the local-only HistoryStore.
/// </summary>
public partial class HistoryWindow : Window
{
    private readonly HistoryStore _history;
    private readonly Action _onChanged;

    public HistoryWindow(HistoryStore history)
    {
        InitializeComponent();
        _history = history;
        Title = L10n.T("history.title");
        NoteText.Text = L10n.T("history.note");
        ClearButton.Content = L10n.T("history.clear");

        _onChanged = () => Dispatcher.BeginInvoke(new Action(Rebuild));
        _history.Changed += _onChanged;
        Closed += (_, _) => _history.Changed -= _onChanged;

        Rebuild();
    }

    private void Rebuild()
    {
        ItemsHost.Children.Clear();
        var entries = _history.Entries;
        ClearButton.IsEnabled = entries.Count > 0;

        if (entries.Count == 0)
        {
            ItemsHost.Children.Add(new TextBlock
            {
                Text = L10n.T("history.empty"),
                Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(4, 8, 4, 0),
            });
            return;
        }

        foreach (var entry in entries)
        {
            ItemsHost.Children.Add(BuildCard(entry));
        }
    }

    private UIElement BuildCard(HistoryEntry entry)
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };

        var copy = new Button
        {
            Content = L10n.T("history.copy"),
            Padding = new Thickness(10, 3, 10, 3),
            Margin = new Thickness(12, 0, 0, 0),
        };
        DockPanel.SetDock(copy, Dock.Right);
        copy.Click += async (_, _) =>
        {
            try
            {
                Clipboard.SetText(entry.Text);
            }
            catch (Exception)
            {
                return; // clipboard briefly locked by another app
            }
            var original = copy.Content;
            copy.Content = L10n.T("history.copied");
            await Task.Delay(1500);
            copy.Content = original;
        };
        header.Children.Add(copy);

        header.Children.Add(new TextBlock
        {
            Text = entry.TimestampUtc.ToLocalTime().ToString("dd.MM.yyyy HH:mm"),
            Foreground = new SolidColorBrush(Color.FromArgb(0x73, 0xFF, 0xFF, 0xFF)),
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
        });

        // Read-only TextBox so the text is selectable with the mouse.
        var text = new TextBox
        {
            Text = entry.Text,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            CaretBrush = Brushes.White,
            Padding = new Thickness(0),
        };

        var stack = new StackPanel();
        stack.Children.Add(header);
        stack.Children.Add(text);

        return new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(0x24, 0x21, 0x30)),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 10, 14, 12),
            Margin = new Thickness(0, 0, 0, 10),
            Child = stack,
        };
    }

    private void OnClearClick(object sender, RoutedEventArgs e) => _history.Clear();
}
