using System;
using System.Diagnostics;
using System.IO;

internal static class Launcher
{
    private static bool OpenTerminal()
    {
        try
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string terminal = Path.Combine(local, @"Microsoft\WindowsApps\wt.exe");
            if (!File.Exists(terminal)) return false;
            var options = new ProcessStartInfo(terminal,
                "new-tab --profile {3cabbd83-d76a-4e06-843c-c063229c9b40} --useApplicationTitle");
            options.UseShellExecute = true;
            using (Process process = Process.Start(options))
            {
                return process != null && (!process.WaitForExit(1200) || process.ExitCode == 0);
            }
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static int Main(string[] args)
    {
        int directoryArgument = Array.IndexOf(args, "--directory");
        if (directoryArgument < 0 && Array.IndexOf(args, "--terminal") >= 0 && OpenTerminal()) return 0;

        try
        {
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Start-Bicdop.ps1");
            string arguments = "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File \"" + script + "\"";
            string directory = null;
            if (directoryArgument >= 0)
            {
                if (directoryArgument + 1 >= args.Length || !Directory.Exists(args[directoryArgument + 1]))
                    throw new DirectoryNotFoundException("Choose an existing folder to open in Bicdop.");
                directory = Path.GetFullPath(args[directoryArgument + 1]);
                string pathArgument = directory.EndsWith("\\", StringComparison.Ordinal) ? directory + "." : directory;
                arguments += " -Directory \"" + pathArgument + "\"";
            }
            var options = new ProcessStartInfo(powershell, arguments);
            if (directory != null) options.WorkingDirectory = directory;
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
