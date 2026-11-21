using System;
using System.Diagnostics;
using System.IO;

internal static class Launcher
{
    private static int Main()
    {
        try
        {
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Start-Bicdop.ps1");
            var options = new ProcessStartInfo(powershell,
                "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File \"" + script + "\"");
            options.UseShellExecute = false;
            options.EnvironmentVariables.Remove("PSModulePath");
            using (Process child = Process.Start(options))
            {
                child.WaitForExit();
                if (child.ExitCode == 0) return 0;
                Console.Error.WriteLine("Bicdop exited with code " + child.ExitCode + ".");
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Could not start Bicdop: " + error.Message);
        }

        if (!Console.IsInputRedirected)
        {
            Console.WriteLine("Press Enter to close.");
            Console.ReadLine();
        }
        return 1;
    }
}
