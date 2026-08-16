using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TRXVanity.WindowsApp
{
    internal static class Program
    {
        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int awareness);

        [STAThread]
        private static void Main()
        {
            try
            {
                SetProcessDpiAwareness(2);
            }
            catch
            {
                // Windows 8.1 and older fall back to the manifest DPI setting.
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
