using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using VoxLocal.Core.Audio;
using VoxLocal.Core.Hotkeys;
using VoxLocal.Core.Models;
using VoxLocal.Core.Permissions;
using VoxLocal.Core.Refinement;
using VoxLocal.Core.Settings;
using VoxLocal.Core.Transcription;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

/// <summary>
/// First-run wizard: privacy model, microphone permission, engine/model
/// installation, optional Ollama setup, the shortcut and a test dictation.
/// The macOS Accessibility step is dropped — Windows has no such permission.
/// </summary>
public partial class OnboardingWindow : Window
{
    private enum Step { Welcome, Microphone, Engine, Model, Ollama, Hotkey, Test, Done }

    private readonly SettingsDependencies _deps;
    private readonly Action _onFinished;
    private Step _step = Step.Welcome;

    private PermissionStatus _micStatus = PermissionStatus.NotDetermined;
    private string? _engineFound;
    private string _testResult = "";

    public OnboardingWindow(SettingsDependencies deps, Action onFinished)
    {
        InitializeComponent();
        _deps = deps;
        _onFinished = onFinished;
        _deps.Dictation.StateChanged += OnDictationState;
        Closed += (_, _) => _deps.Dictation.StateChanged -= OnDictationState;
        RefreshStatuses();
        Render();
    }

    private void RefreshStatuses()
    {
        _micStatus = _deps.Permissions.MicrophoneStatus;
        var transcriber = new WhisperTranscriber();
        _engineFound = transcriber.TryLocateBinary(out var path) ? path : null;
        _deps.ModelManager.RefreshInstalledModels();
    }

    private void OnDictationState(DictationState state)
    {
        if (_step == Step.Test)
        {
            Render();
        }
    }

    // ---- Navigation ----

    private void BackButton_Click(object sender, RoutedEventArgs e)
    {
        if (_deps.Dictation.State != DictationState.Idle)
        {
            _deps.Dictation.CancelDictation();
        }
        if (_step > Step.Welcome)
        {
            _step -= 1;
        }
        RefreshStatuses();
        Render();
    }

    private void NextButton_Click(object sender, RoutedEventArgs e)
    {
        if (_step == Step.Done)
        {
            _deps.Settings.OnboardingCompleted = true;
            _onFinished();
            return;
        }
        if (_deps.Dictation.State != DictationState.Idle)
        {
            _deps.Dictation.CancelDictation();
        }
        _step += 1;
        RefreshStatuses();
        Render();
    }

    // ---- Rendering ----

    private void Render()
    {
        StepProgress.Minimum = 0;
        StepProgress.Maximum = (int)Step.Done;
        StepProgress.Value = (int)_step;
        BackButton.Content = L10n.T("onboarding.back");
        BackButton.Visibility = _step == Step.Welcome ? Visibility.Hidden : Visibility.Visible;
        NextButton.Content = _step == Step.Done ? L10n.T("onboarding.finish") : L10n.T("onboarding.next");

        StepContent.Children.Clear();
        switch (_step)
        {
            case Step.Welcome:
                Header("\uED55", "onboarding.welcome.title");
                Body(L10n.T("onboarding.welcome.text"));
                for (var i = 1; i <= 4; i++)
                {
                    Point(L10n.T($"onboarding.welcome.point{i}"));
                }
                break;

            case Step.Microphone:
                Header("\uE720", "onboarding.mic.title");
                Body(L10n.T("onboarding.mic.text"));
                StatusRow(_micStatus == PermissionStatus.Granted,
                    _micStatus == PermissionStatus.NotDetermined ? L10n.T("onboarding.status.notdetermined") : null);
                var micButtons = Buttons();
                if (_micStatus == PermissionStatus.NotDetermined)
                {
                    micButtons.Children.Add(MakeButton(L10n.T("onboarding.mic.grant"), async () =>
                    {
                        await _deps.Permissions.RequestMicrophoneAccessAsync();
                        RefreshStatuses();
                        Render();
                    }));
                }
                if (_micStatus == PermissionStatus.Denied)
                {
                    micButtons.Children.Add(MakeButton(L10n.T("onboarding.openSettings"),
                        () => _deps.Permissions.OpenMicrophoneSettings()));
                }
                micButtons.Children.Add(MakeButton(L10n.T("onboarding.recheck"), () => { RefreshStatuses(); Render(); }));
                break;

            case Step.Engine:
                Header("\uE950", "onboarding.engine.title");
                StatusRow(_engineFound is not null);
                Body(_engineFound is not null
                    ? L10n.T("onboarding.engine.ok", PathRedactor.Redact(_engineFound))
                    : L10n.T("onboarding.engine.missing"));
                Buttons().Children.Add(MakeButton(L10n.T("onboarding.recheck"), () => { RefreshStatuses(); Render(); }));
                break;

            case Step.Model:
                Header("\uE896", "onboarding.model.title");
                Body(L10n.T("onboarding.model.text"));
                RenderModelPicker();
                break;

            case Step.Ollama:
                Header("\uE945", "onboarding.ollama.title");
                Body(L10n.T("onboarding.ollama.text"));
                var ollamaStatus = new TextBlock { Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
                Buttons().Children.Add(MakeButton(L10n.T("settings.refine.check"), async () =>
                {
                    ollamaStatus.Text = L10n.T("settings.refine.status.checking");
                    try
                    {
                        var provider = new OllamaRefinementProvider(_deps.Settings.OllamaEndpoint, _deps.Settings.OllamaModel);
                        var models = await provider.InstalledModelsAsync(CancellationToken.None);
                        ollamaStatus.Text = models.Count == 0
                            ? L10n.T("onboarding.ollama.noModels")
                            : L10n.T("onboarding.ollama.found", string.Join(", ", models));
                    }
                    catch
                    {
                        ollamaStatus.Text = L10n.T("onboarding.ollama.unavailable");
                    }
                }));
                StepContent.Children.Add(ollamaStatus);
                Body(L10n.T("onboarding.ollama.optional"), gray: true);
                break;

            case Step.Hotkey:
                Header("\uE765", "onboarding.hotkey.title");
                Body(L10n.T("onboarding.hotkey.text",
                    new KeyCombo(_deps.Settings.HotkeyKeyCode, _deps.Settings.HotkeyModifiers).DisplayString));
                Body(L10n.T("onboarding.hotkey.modes"), gray: true);
                break;

            case Step.Test:
                Header("\uE9D9", "onboarding.test.title");
                Body(L10n.T("onboarding.test.text"));
                var state = _deps.Dictation.State;
                var row = Buttons();
                var toggle = MakeButton(
                    state == DictationState.Recording ? L10n.T("onboarding.test.stop") : L10n.T("onboarding.test.start"),
                    ToggleTestDictation);
                toggle.IsEnabled = state is DictationState.Idle or DictationState.Recording;
                row.Children.Add(toggle);
                row.Children.Add(new TextBlock
                {
                    Text = L10n.T($"state.{StateKey(state)}"),
                    Foreground = Brushes.Gray,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(8, 0, 0, 0),
                });
                if (_testResult.Length > 0)
                {
                    StepContent.Children.Add(new GroupBox
                    {
                        Header = L10n.T("onboarding.test.result"),
                        Margin = new Thickness(0, 10, 0, 0),
                        Content = new TextBox
                        {
                            Text = _testResult, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                            BorderThickness = new Thickness(0), Background = Brushes.Transparent,
                        },
                    });
                }
                break;

            case Step.Done:
                Header("\uE73E", "onboarding.done.title");
                Body(L10n.T("onboarding.done.text"));
                break;
        }
    }

    private void RenderModelPicker()
    {
        var installed = _deps.ModelManager.InstalledModels;
        if (installed.Count > 0)
        {
            Point(L10n.T("onboarding.model.installed", string.Join(", ", installed.Select(m => m.Name))));
        }
        // Compact catalog: recommended default plus alternates.
        foreach (var info in WhisperModelCatalog.Models.Where(m => m.Name is "tiny" or "base" or "small"))
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            row.Children.Add(new TextBlock
            {
                Text = info.Name == WhisperModelCatalog.DefaultModelName
                    ? L10n.T("onboarding.model.recommended", info.Name)
                    : info.Name,
                VerticalAlignment = VerticalAlignment.Center,
            });

            if (installed.Any(m => m.Name == info.Name))
            {
                var check = new TextBlock
                {
                    Text = "\uE73E", FontFamily = new FontFamily("Segoe Fluent Icons"),
                    Foreground = Brushes.MediumSeaGreen, HorizontalAlignment = HorizontalAlignment.Right,
                };
                DockPanel.SetDock(check, Dock.Right);
                row.Children.Add(check);
            }
            else if (_deps.ModelManager.DownloadingModel == info.Name)
            {
                var cancel = MakeButton(L10n.T("common.cancel"), () => _deps.ModelManager.CancelDownload());
                DockPanel.SetDock(cancel, Dock.Right);
                row.Children.Add(cancel);
                var progress = new ProgressBar
                {
                    Width = 90, Height = 12, Minimum = 0, Maximum = 1,
                    Value = _deps.ModelManager.DownloadProgress ?? 0,
                };
                DockPanel.SetDock(progress, Dock.Right);
                row.Children.Add(progress);
            }
            else
            {
                var selected = info;
                var get = MakeButton(L10n.T("settings.model.get"), async () =>
                {
                    // Same confirmation contract as Settings: size shown,
                    // explicit consent before downloading.
                    var answer = MessageBox.Show(
                        this,
                        L10n.T("settings.model.confirm.message", selected.Name, selected.SizeLabel),
                        L10n.T("settings.model.confirm.title"),
                        MessageBoxButton.OKCancel);
                    if (answer != MessageBoxResult.OK)
                    {
                        return;
                    }
                    try
                    {
                        await _deps.ModelManager.DownloadAsync(selected);
                        _deps.Settings.WhisperModel = selected.Name;
                    }
                    catch (OperationCanceledException)
                    {
                        // user cancelled — nothing to report
                    }
                    catch (Exception e)
                    {
                        MessageBox.Show(this, L10n.T("settings.model.download.error", e.Message));
                    }
                    RefreshStatuses();
                    Render();
                });
                get.IsEnabled = !_deps.ModelManager.IsDownloading;
                DockPanel.SetDock(get, Dock.Right);
                row.Children.Add(get);
            }

            row.Children.Add(new TextBlock
            {
                Text = info.SizeLabel, Foreground = Brushes.Gray,
                HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 8, 0),
            });
            StepContent.Children.Add(row);
        }
        Body(L10n.T("onboarding.model.more"), gray: true);
    }

    private void ToggleTestDictation()
    {
        var dictation = _deps.Dictation;
        if (dictation.State == DictationState.Recording)
        {
            dictation.StopAndProcess();
        }
        else if (dictation.State == DictationState.Idle)
        {
            _testResult = "";
            dictation.TestModeSink = text =>
            {
                _testResult = text;
                dictation.TestModeSink = null;
                Render();
            };
            dictation.StartDictation();
        }
    }

    // ---- Small helpers (stepLayout / statusRow analogues) ----

    private void Header(string glyph, string titleKey)
    {
        StepGlyph.Text = glyph;
        StepTitle.Text = L10n.T(titleKey);
    }

    private void Body(string text, bool gray = false) =>
        StepContent.Children.Add(new TextBlock
        {
            Text = text, TextWrapping = TextWrapping.Wrap,
            Foreground = gray ? Brushes.Gray : SystemColors.ControlTextBrush,
            Margin = new Thickness(0, 4, 0, 4),
        });

    private void Point(string text) =>
        StepContent.Children.Add(new TextBlock
        {
            Text = "\uE73E  " + text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2),
        });

    private void StatusRow(bool granted, string? label = null) =>
        StepContent.Children.Add(new TextBlock
        {
            Text = (granted ? "\uE73E  " : "\uE711  ") + (label
                ?? (granted ? L10n.T("onboarding.status.granted") : L10n.T("onboarding.status.denied"))),
            Foreground = granted ? Brushes.MediumSeaGreen : Brushes.Orange,
            Margin = new Thickness(0, 4, 0, 4),
        });

    private StackPanel Buttons()
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        StepContent.Children.Add(panel);
        return panel;
    }

    private static Button MakeButton(string caption, Action onClick)
    {
        var button = new Button { Content = caption, MinWidth = 110, Margin = new Thickness(0, 0, 8, 0) };
        button.Click += (_, _) => onClick();
        return button;
    }

    private static string StateKey(DictationState state)
    {
        var name = state.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }
}
