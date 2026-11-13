using System;
using System.Diagnostics;
using System.IO;

internal static class PomoInsightLauncher
{
    [STAThread]
    private static void Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "PomoInsight.ps1");
        if (!File.Exists(script)) { return; }

        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell)) { powershell = "powershell.exe"; }

        ProcessStartInfo start = new ProcessStartInfo(
            powershell,
            "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File \"" + script + "\"");
        start.WorkingDirectory = root;
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(start);
    }
}
