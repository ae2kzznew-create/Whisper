using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using VoxLocal.Core.Audio;
using VoxLocal.Core.Hotkeys;
using VoxLocal.Core.Insertion;
using VoxLocal.Core.Refinement;
using VoxLocal.Core.Settings;
using VoxLocal.Core.Transcription;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

public partial class SettingsWindow : Window
{
    private readonly SettingsDependencies _deps;
    private SettingsStore Settings => _deps.Settings;
    private bool _recordingHotkey;
    private bool _loading;

    public SettingsWindow(SettingsDependencies deps)
    {
        InitializeComponent();
        _deps = deps;
        PreviewKeyDown += Window_PreviewKeyDown;
        _deps.ModelManager.ModelsChanged += RefreshModels;
        Closed += (_, _) => _deps.ModelManager.ModelsChanged -= RefreshModels;
        ApplyLocalization();
        LoadValues();
    }

    private void ApplyLocalization()
    {
        GeneralTab.Header = L10n.T("settings.tab.general");
        TranscriptionTab.Header = L10n.T("settings.tab.transcription");
        RefinementTab.Header = L10n.T("settings.tab.refinement");
        PrivacyTab.Header = L10n.T("settings.tab.privacy");

        HotkeyGroup.Header = L10n.T("settings.hotkey.section");
        HotkeyLabel.Text = L10n.T("settings.hotkey");
        ModeLabel.Text = L10n.T("settings.hotkey.mode");
        ModeHold.Content = L10n.T("settings.hotkey.mode.hold");
        ModeToggle.Content = L10n.T("settings.hotkey.mode.toggle");
        AudioGroup.Header = L10n.T("settings.audio.section");
        MicLabel.Text = L10n.T("settings.mic");
        InsertionGroup.Header = L10n.T("settings.insertion.section");
        InsertAuto.Content = L10n.T("settings.insertion.auto");
        InsertClipboard.Content = L10n.T("settings.insertion.clipboard");
        AppGroup.Header = L10n.T("settings.app.section");
        LaunchAtLoginBox.Content = L10n.T("settings.launchAtLogin");
        UiLangLabel.Text = L10n.T("settings.language.ui");

        InstalledGroup.Header = L10n.T("settings.model.installed");
        NoModelsText.Text = L10n.T("settings.model.none");
        DownloadGroup.Header = L10n.T("settings.model.download");
        RecognitionGroup.Header = L10n.T("settings.recognition.section");
        SpokenLabel.Text = L10n.T("settings.spoken");
        ArtifactsBox.Content = L10n.T("settings.artifacts");

        RefineEnabledBox.Content = L10n.T("settings.refine.enabled");
        RefineHintText.Text = L10n.T("settings.refine.hint");
        OllamaGroup.Header = L10n.T("settings.refine.ollama.section");
        CheckButton.Content = L10n.T("settings.refine.check");
        TimeoutLabel.Text = L10n.T("settings.refine.timeout");
        PresetGroup.Header = L10n.T("settings.refine.preset.section");

        PrivacyGroup.Header = L10n.T("privacy.title");
        DiagnosticsGroup.Header = L10n.T("settings.diagnostics.section");
        LogLevelLabel.Text = L10n.T("settings.loglevel");
        LogsHintText.Text = L10n.T("privacy.logs");
        OpenLogsButton.Content = L10n.T("menu.logs");
        ResetOnboardingButton.Content = L10n.T("settings.resetOnboarding");
    }

    private void LoadValues()
    {
        _loading = true;

        HotkeyButton.Content = Settings.Hotkey.DisplayString;
        ModeHold.IsChecked = Settings.HotkeyMode == HotkeyMode.PressAndHold;
        ModeToggle.IsChecked = Settings.HotkeyMode == HotkeyMode.Toggle;

        // Microphone list: default entry + WASAPI capture devices.
        MicCombo.Items.Clear();
        MicCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.mic.default"), Tag = "" });
        foreach (var device in AudioDeviceFinder.InputDevices())
        {
            MicCombo.Items.Add(new ComboBoxItem { Content = device.Name, Tag = device.Id });
        }
        SelectByTag(MicCombo, Settings.InputDeviceId ?? "");

        InsertAuto.IsChecked = Settings.InsertionMode == InsertionMode.Auto;
        InsertClipboard.IsChecked = Settings.InsertionMode == InsertionMode.ClipboardOnly;
        LaunchAtLoginBox.IsChecked = Settings.LaunchAtLogin;

        UiLangCombo.Items.Clear();
        UiLangCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.language.ui.ru"), Tag = L10n.Language.Russian });
        UiLangCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.language.ui.en"), Tag = L10n.Language.English });
        UiLangCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.language.ui.system"), Tag = L10n.Language.System });
        SelectByTag(UiLangCombo, Settings.InterfaceLanguage);

        SpokenCombo.Items.Clear();
        SpokenCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.spoken.auto"), Tag = SpokenLanguage.Auto });
        SpokenCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.spoken.ru"), Tag = SpokenLanguage.Russian });
        SpokenCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.spoken.en"), Tag = SpokenLanguage.English });
        SelectByTag(SpokenCombo, Settings.SpokenLanguage);

        ThreadsSlider.Value = Settings.WhisperThreads;
        ThreadsLabel.Text = L10n.T("settings.threads", Settings.WhisperThreads);
        ArtifactsBox.IsChecked = Settings.RemoveArtifacts;

        RefineEnabledBox.IsChecked = Settings.RefinementEnabled;
        EndpointBox.Text = Settings.OllamaEndpoint;
        OllamaModelBox.Text = Settings.OllamaModel;
        TimeoutSlider.Value = Settings.RefinementTimeout;
        TimeoutValueText.Text = $"{(int)Settings.RefinementTimeout} s";

        PresetCombo.Items.Clear();
        foreach (var preset in Enum.GetValues<RefinementPreset>())
        {
            PresetCombo.Items.Add(new ComboBoxItem { Content = L10n.T(preset.TitleKey()), Tag = preset });
        }
        SelectByTag(PresetCombo, Settings.RefinementPreset);
        CustomInstructionBox.Text = Settings.CustomInstruction;
        UpdateRefinementEnabledState();

        PrivacyPoints.Children.Clear();
        for (var i = 1; i <= 5; i++)
        {
            PrivacyPoints.Children.Add(new TextBlock
            {
                Text = "\uE73E  " + L10n.T($"privacy.p{i}"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 2),
            });
        }

        LogLevelCombo.Items.Clear();
        LogLevelCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.loglevel.off"), Tag = LogLevel.Off });
        LogLevelCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.loglevel.error"), Tag = LogLevel.Error });
        LogLevelCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.loglevel.info"), Tag = LogLevel.Info });
        LogLevelCombo.Items.Add(new ComboBoxItem { Content = L10n.T("settings.loglevel.debug"), Tag = LogLevel.Debug });
        SelectByTag(LogLevelCombo, Settings.LogLevel);

        RefreshModels();
        _loading = false;
    }

    // ---- Hotkey recorder (NSEvent local monitor analogue) ----

    private void HotkeyButton_Click(object sender, RoutedEventArgs e)
    {
        _recordingHotkey = !_recordingHotkey;
        HotkeyButton.Content = _recordingHotkey
            ? L10n.T("settings.hotkey.press")
            : Settings.Hotkey.DisplayString;
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_recordingHotkey)
        {
            return;
        }
        e.Handled = true;
        _recordingHotkey = false;
        if (e.Key == Key.Escape) // Esc cancels recording
        {
            HotkeyButton.Content = Settings.Hotkey.DisplayString;
            return;
        }
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var combo = KeyCombo.FromWpf(key, Keyboard.Modifiers);
        var error = _deps.ApplyHotkey(combo);
        if (error is not null)
        {
            HotkeyErrorText.Text = error;
            HotkeyErrorText.Visibility = Visibility.Visible;
            HotkeyButton.Content = Settings.Hotkey.DisplayString;
        }
        else
        {
            HotkeyErrorText.Visibility = Visibility.Collapsed;
            Settings.HotkeyKeyCode = combo.KeyCode;
            Settings.HotkeyModifiers = combo.Modifiers;
            HotkeyButton.Content = combo.DisplayString;
        }
    }

    // ---- Models ----

    private void RefreshModels()
    {
        var installed = _deps.ModelManager.InstalledModels;
        NoModelsText.Visibility = installed.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        ModelCombo.Items.Clear();
        foreach (var model in installed)
        {
            ModelCombo.Items.Add(new ComboBoxItem
            {
                Content = $"{model.Name} ({FormatBytes(model.SizeBytes)})",
                Tag = model.Name,
            });
        }
        if (!installed.Any(m => m.Name == Settings.WhisperModel))
        {
            ModelCombo.Items.Add(new ComboBoxItem
            {
                Content = L10n.T("settings.model.notInstalled", Settings.WhisperModel),
                Tag = Settings.WhisperModel,
            });
        }
        SelectByTag(ModelCombo, Settings.WhisperModel);

        // Download rows: name, size, state-dependent action.
        DownloadList.Children.Clear();
        foreach (var info in WhisperModelCatalog.Models)
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var name = new TextBlock { Text = info.Name, VerticalAlignment = VerticalAlignment.Center };
            if (!info.Multilingual)
            {
                name.Text += $"  ({L10n.T(\"settings.model.englishOnly\")})";
            }
            DockPanel.SetDock(name, Dock.Left);
            row.Children.Add(name);

            if (installed.Any(m => m.Name == info.Name))
            {
                var check = new TextBlock
                {
                    Text = "\uE73E", FontFamily = new System.Windows.Media.FontFamily("Segoe Fluent Icons"),
                    Foreground = System.Windows.Media.Brushes.MediumSeaGreen,
                    VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right,
                };
                DockPanel.SetDock(check, Dock.Right);
                row.Children.Add(check);
            }
            else if (_deps.ModelManager.DownloadingModel == info.Name)
            {
                var cancel = new Button { Content = L10n.T("common.cancel"), Margin = new Thickness(6, 0, 0, 0) };
                cancel.Click += (_, _) => _deps.ModelManager.CancelDownload();
                DockPanel.SetDock(cancel, Dock.Right);
                row.Children.Add(cancel);
                var progress = new ProgressBar
                {
                    Width = 90, Height = 12, Minimum = 0, Maximum = 1,
                    Value = _deps.ModelManager.DownloadProgress ?? 0,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                DockPanel.SetDock(progress, Dock.Right);
                row.Children.Add(progress);
            }
            else
            {
                var get = new Button
                {
                    Content = L10n.T("settings.model.get"),
                    IsEnabled = !_deps.ModelManager.IsDownloading,
                };
                var selected = info;
                get.Click += (_, _) => ConfirmAndDownload(selected);
                DockPanel.SetDock(get, Dock.Right);
                row.Children.Add(get);
            }

            var size = new TextBlock
            {
                Text = info.SizeLabel, Foreground = System.Windows.Media.Brushes.Gray,
                VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 0, 8, 0),
            };
            row.Children.Add(size);
            DownloadList.Children.Add(row);
        }
    }

    // Explicit size confirmation before any model download
    // (confirmationDialog analogue).
    private async void ConfirmAndDownload(WhisperModelInfo info)
    {
        var answer = MessageBox.Show(
            this,
            L10n.T("settings.model.confirm.message", info.Name, info.SizeLabel),
            L10n.T("settings.model.confirm.title"),
            MessageBoxButton.OKCancel);
        if (answer != MessageBoxResult.OK)
        {
            return;
        }
        DownloadErrorText.Visibility = Visibility.Collapsed;
        try
        {
            await _deps.ModelManager.DownloadAsync(info);
        }
        catch (OperationCanceledException)
        {
            // user cancelled — nothing to report
        }
        catch (Exception e)
        {
            DownloadErrorText.Text = L10n.T("settings.model.download.error", e.Message);
            DownloadErrorText.Visibility = Visibility.Visible;
        }
        RefreshModels();
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1_000_000_000 => $"{bytes / 1_000_000_000.0:0.#} GB",
        >= 1_000_000 => $"{bytes / 1_000_000.0:0.#} MB",
        _ => $"{bytes / 1_000.0:0.#} KB",
    };

    // ---- Ollama check ----

    private async void CheckButton_Click(object sender, RoutedEventArgs e)
    {
        AvailabilityText.Text = L10n.T("settings.refine.status.checking");
        var endpoint = Settings.OllamaEndpoint;
        var model = Settings.OllamaModel;
        try
        {
            var provider = new OllamaRefinementProvider(endpoint, model);
            var names = await provider.InstalledModelsAsync(CancellationToken.None);
            OllamaModelsCombo.Items.Clear();
            foreach (var name in names)
            {
                OllamaModelsCombo.Items.Add(new ComboBoxItem { Content = name, Tag = name });
            }
            OllamaModelsCombo.Visibility = names.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            if (model.Length == 0)
            {
                AvailabilityText.Text = L10n.T("settings.refine.status.pickModel", string.Join(", ", names));
                return;
            }
            var availability = await provider.CheckAvailabilityAsync();
            AvailabilityText.Text = availability switch
            {
                RefinementAvailability.Available => L10n.T("settings.refine.status.ok"),
                RefinementAvailability.ModelMissing missing
                    => L10n.T("settings.refine.status.nomodel", string.Join(", ", missing.AvailableModels)),
                RefinementAvailability.ServerUnreachable unreachable
                    => L10n.T("settings.refine.status.unreachable", unreachable.Reason),
                _ => "",
            };
        }
        catch (NonLocalEndpointException)
        {
            AvailabilityText.Text = L10n.T("settings.refine.nonlocal");
        }
        catch (Exception ex)
        {
            AvailabilityText.Text = L10n.T("settings.refine.status.unreachable", ex.Message);
        }
    }

    private void UpdateRefinementEnabledState()
    {
        var enabled = Settings.RefinementEnabled;
        OllamaPanel.IsEnabled = enabled;
        PresetPanel.IsEnabled = enabled;
        CustomInstructionBox.Visibility =
            Settings.RefinementPreset == RefinementPreset.Custom ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---- Simple change handlers (mirror SwiftUI two-way bindings) ----

    private void Mode_Checked(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        Settings.HotkeyMode = ModeToggle.IsChecked == true ? HotkeyMode.Toggle : HotkeyMode.PressAndHold;
    }

    private void MicCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        var id = (string?)((ComboBoxItem?)MicCombo.SelectedItem)?.Tag;
        Settings.InputDeviceId = string.IsNullOrEmpty(id) ? null : id;
    }

    private void Insertion_Checked(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        Settings.InsertionMode = InsertClipboard.IsChecked == true ? InsertionMode.ClipboardOnly : InsertionMode.Auto;
    }

    private void LaunchAtLoginBox_Click(object sender, RoutedEventArgs e) =>
        Settings.LaunchAtLogin = LaunchAtLoginBox.IsChecked == true;

    private void UiLangCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (((ComboBoxItem?)UiLangCombo.SelectedItem)?.Tag is L10n.Language lang)
        {
            Settings.InterfaceLanguage = lang;
            ApplyLocalization();
            LoadValues();
        }
    }

    private void ModelCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (((ComboBoxItem?)ModelCombo.SelectedItem)?.Tag is string name)
        {
            Settings.WhisperModel = name;
        }
    }

    private void SpokenCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (((ComboBoxItem?)SpokenCombo.SelectedItem)?.Tag is SpokenLanguage lang)
        {
            Settings.SpokenLanguage = lang;
        }
    }

    private void ThreadsSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading) return;
        Settings.WhisperThreads = (int)ThreadsSlider.Value;
        ThreadsLabel.Text = L10n.T("settings.threads", Settings.WhisperThreads);
    }

    private void ArtifactsBox_Click(object sender, RoutedEventArgs e) =>
        Settings.RemoveArtifacts = ArtifactsBox.IsChecked == true;

    private void RefineEnabledBox_Click(object sender, RoutedEventArgs e)
    {
        Settings.RefinementEnabled = RefineEnabledBox.IsChecked == true;
        UpdateRefinementEnabledState();
    }

    private void EndpointBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading) Settings.OllamaEndpoint = EndpointBox.Text;
    }

    private void OllamaModelBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading) Settings.OllamaModel = OllamaModelBox.Text;
    }

    private void OllamaModelsCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (((ComboBoxItem?)OllamaModelsCombo.SelectedItem)?.Tag is string name)
        {
            OllamaModelBox.Text = name;
        }
    }

    private void TimeoutSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading) return;
        Settings.RefinementTimeout = TimeoutSlider.Value;
        TimeoutValueText.Text = $"{(int)TimeoutSlider.Value} s";
    }

    private void PresetCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (((ComboBoxItem?)PresetCombo.SelectedItem)?.Tag is RefinementPreset preset)
        {
            Settings.RefinementPreset = preset;
            UpdateRefinementEnabledState();
        }
    }

    private void CustomInstructionBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading) Settings.CustomInstruction = CustomInstructionBox.Text;
    }

    private void LogLevelCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (((ComboBoxItem?)LogLevelCombo.SelectedItem)?.Tag is LogLevel level)
        {
            Settings.LogLevel = level;
        }
    }

    private void OpenLogsButton_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Log.Shared.Directory}\"") { UseShellExecute = true });

    private void ResetOnboardingButton_Click(object sender, RoutedEventArgs e) =>
        Settings.ResetOnboarding();

    private static void SelectByTag(ComboBox combo, object tag)
    {
        foreach (ComboBoxItem item in combo.Items)
        {
            if (Equals(item.Tag, tag))
            {
                combo.SelectedItem = item;
                return;
            }
        }
    }
}
