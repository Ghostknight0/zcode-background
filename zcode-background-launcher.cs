using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class ZCodeBackgroundLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        // 第一个参数是 PowerShell 路径，第二个参数是背景启动脚本路径。
        if (args.Length < 2)
        {
            return 2;
        }

        try
        {
            string powerShellPath = args[0];
            string scriptPath = args[1];
            var powerShellArguments = new List<string>
            {
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                scriptPath
            };

            // 其余参数继续转交给 PowerShell 脚本，保留图片和透明度的可配置能力。
            for (int index = 2; index < args.Length; index++)
            {
                powerShellArguments.Add(args[index]);
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = powerShellPath,
                Arguments = BuildCommandLine(powerShellArguments),
                WorkingDirectory = Path.GetDirectoryName(scriptPath) ?? Environment.CurrentDirectory,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using (Process process = Process.Start(startInfo))
            {
                return process == null ? 3 : 0;
            }
        }
        catch
        {
            // GUI 启动器没有控制台可输出错误，使用退出码供安装测试和排障识别。
            return 1;
        }
    }

    private static string BuildCommandLine(IEnumerable<string> arguments)
    {
        var commandLine = new StringBuilder();

        foreach (string argument in arguments)
        {
            if (commandLine.Length > 0)
            {
                commandLine.Append(' ');
            }

            commandLine.Append(QuoteArgument(argument));
        }

        return commandLine.ToString();
    }

    private static string QuoteArgument(string argument)
    {
        // 按 Windows 命令行规则转义反斜杠和双引号，支持中文及带空格路径。
        if (argument.Length > 0 &&
            argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return argument;
        }

        var quoted = new StringBuilder();
        quoted.Append('"');
        int backslashCount = 0;

        foreach (char character in argument)
        {
            if (character == '\\')
            {
                backslashCount++;
                continue;
            }

            if (character == '"')
            {
                quoted.Append('\\', backslashCount * 2 + 1);
                quoted.Append(character);
                backslashCount = 0;
                continue;
            }

            quoted.Append('\\', backslashCount);
            backslashCount = 0;
            quoted.Append(character);
        }

        quoted.Append('\\', backslashCount * 2);
        quoted.Append('"');
        return quoted.ToString();
    }
}
