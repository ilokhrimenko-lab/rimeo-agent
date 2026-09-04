using System.Runtime.InteropServices;
using RimeoAgent.Config;   // Log

namespace RimeoAgent.Services;

/// <summary>
/// Native Win32 open-file dialog (comdlg32 <c>GetOpenFileNameW</c>).
///
/// Replaces the WinRT <c>FileOpenPicker</c>, which throws
/// <c>COMException 0x80004005</c> in THIS app's configuration —
/// unpackaged + self-contained WinUI 3 (<c>WindowsPackageType=None</c>,
/// <c>WindowsAppSDKSelfContained=true</c>) — on Windows 11 24H2/25H2 (build 26xxx).
/// Confirmed on a user's build-265 agent (Win 10.0.26200): the "Check spek" Open
/// button and the Library Rekordbox-XML picker did nothing but spam the agent log
/// with that COMException from <c>PickSingleFileAsync()</c>.
///
/// <c>GetOpenFileNameW</c> is the classic in-process shell dialog. It never touches
/// the WinRT app broker that <c>FileOpenPicker</c> depends on, so it works on every
/// Windows build — the direct analogue of the macOS agent's <c>NSOpenPanel</c>.
///
/// Call on the UI (STA) thread: it runs its own modal message loop, like
/// <c>NSOpenPanel.runModal()</c>. WinUI's UI thread is STA and keeps pumping while
/// the dialog is up.
/// </summary>
public static class Win32FileDialog
{
    private const int OFN_HIDEREADONLY  = 0x00000004;
    private const int OFN_NOCHANGEDIR   = 0x00000008;
    private const int OFN_PATHMUSTEXIST = 0x00000800;
    private const int OFN_FILEMUSTEXIST = 0x00001000;
    private const int OFN_EXPLORER      = 0x00080000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OpenFileName
    {
        public int    lStructSize;
        public IntPtr hwndOwner;
        public IntPtr hInstance;
        public string? lpstrFilter;
        public string? lpstrCustomFilter;
        public int    nMaxCustFilter;
        public int    nFilterIndex;
        public IntPtr lpstrFile;          // caller-allocated buffer (manual marshal)
        public int    nMaxFile;
        public string? lpstrFileTitle;
        public int    nMaxFileTitle;
        public string? lpstrInitialDir;
        public string? lpstrTitle;
        public int    Flags;
        public short  nFileOffset;
        public short  nFileExtension;
        public string? lpstrDefExt;
        public IntPtr lCustData;
        public IntPtr lpfnHook;
        public string? lpTemplateName;
        public IntPtr pvReserved;
        public int    dwReserved;
        public int    FlagsEx;
    }

    [DllImport("comdlg32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetOpenFileNameW(ref OpenFileName ofn);

    // Отличает штатную отмену (возвращает 0) от реального сбоя диалога (ненулевой код).
    [DllImport("comdlg32.dll")]
    private static extern int CommDlgExtendedError();

    /// <summary>
    /// Shows the modal open-file dialog and returns the chosen path, or null if the
    /// user cancelled (or the dialog failed).
    /// </summary>
    /// <param name="owner">Owner window HWND (<see cref="RimeoAgent.MainWindow.Hwnd"/>); may be zero.</param>
    /// <param name="filter">
    /// Classic comdlg32 filter — label / pattern pairs separated by '\0', e.g.
    /// <c>"Audio files\0*.wav;*.mp3\0All files\0*.*\0"</c>. The API needs a trailing
    /// '\0' after the last pair; the interop marshaller appends the final terminator.
    /// </param>
    /// <param name="title">Optional dialog title.</param>
    public static string? PickFile(IntPtr owner, string filter, string? title = null)
    {
        // MAX_PATH is 260, but long/UNC paths can exceed it — give the buffer room.
        const int bufChars = 4096;
        IntPtr buffer = Marshal.AllocHGlobal(bufChars * sizeof(char));
        try
        {
            // Zero it so a cancel / empty selection reads back as an empty string.
            for (int i = 0; i < bufChars; i++) Marshal.WriteInt16(buffer, i * sizeof(char), 0);

            var ofn = new OpenFileName
            {
                lStructSize  = Marshal.SizeOf<OpenFileName>(),
                hwndOwner    = owner,
                lpstrFilter  = filter,
                nFilterIndex = 1,
                lpstrFile    = buffer,
                nMaxFile     = bufChars,
                lpstrTitle   = title,
                Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST
                        | OFN_NOCHANGEDIR | OFN_HIDEREADONLY,
            };

            if (!GetOpenFileNameW(ref ofn))
            {
                // 0 = пользователь отменил (штатно, тихо). Ненулевой код = реальный сбой
                // диалога — логируем, иначе получился бы второй молчаливый тупик вместо
                // того, ради которого этот класс и написан.
                int err = CommDlgExtendedError();
                if (err != 0) Log.Warn($"Win32 open-file dialog failed: CommDlgExtendedError=0x{err:X}");
                return null;
            }

            var path = Marshal.PtrToStringUni(buffer);
            return string.IsNullOrEmpty(path) ? null : path;
        }
        catch (Exception ex)
        {
            Log.Warn($"Win32 open-file dialog failed: {ex.Message}");
            return null;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
