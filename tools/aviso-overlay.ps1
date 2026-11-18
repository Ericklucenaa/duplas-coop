# Faixa de avisos do modo Duplas sobre a janela do mGBA.
# O mGBA incluído não desenha sobre a tela pelo script (a API de imagem falha), então o aviso é uma janelinha à parte:
# sempre por cima da janela do jogo, sem tomar o foco e sem bloquear cliques, só enquanto o mGBA é a janela ativa.
# O jogo escreve o aviso em um arquivo (1ª linha: aviso; 2ª: dica; vazio: nenhum). Fecha junto com o mGBA.
# Uso (o iniciar-demo.ps1 já chama): aviso-overlay.ps1 -ProcessId <pid do mGBA> -File <pasta de dados>\aviso.txt
param([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][string]$File)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System; using System.Drawing; using System.Windows.Forms; using System.Runtime.InteropServices;
public class DuplasAviso : Form {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    public string Title = "", Hint = "";
    readonly Font titleFont = new Font("Segoe UI Semibold", 10f);
    readonly Font hintFont = new Font("Segoe UI", 9f);
    public DuplasAviso() {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; BackColor = Color.FromArgb(20, 18, 16); Opacity = 0.93;
        DoubleBuffered = true; Size = new Size(300, 46);
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get {
        var cp = base.CreateParams;
        cp.ExStyle |= 0x08000000 | 0x80 | 0x20 | 0x8;   // sem ativar, ferramenta (fora do Alt+Tab), clique passa, por cima
        return cp; } }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using (var accent = new SolidBrush(Color.FromArgb(232, 120, 63))) g.FillRectangle(accent, 0, 0, Width, 2);
        bool two = Hint.Length > 0;
        TextRenderer.DrawText(g, Title, titleFont, new Point(12, two ? 5 : 13), Color.FromArgb(244, 237, 226));
        if (two) TextRenderer.DrawText(g, Hint, hintFont, new Point(12, 24), Color.FromArgb(184, 175, 162));
    }
    // posiciona na parte de baixo da área do jogo; devolve false quando não deve aparecer
    public bool Place(IntPtr game, int gamePid) {
        if (game == IntPtr.Zero || IsIconic(game)) return false;
        uint fg; GetWindowThreadProcessId(GetForegroundWindow(), out fg);
        if (fg != (uint)gamePid) return false;                       // outro programa em primeiro plano
        RECT r; if (!GetClientRect(game, out r)) return false;
        var p = new POINT(); if (!ClientToScreen(game, ref p)) return false;
        int w = Math.Max(160, (r.R - r.L) - 24);
        SetBounds(p.X + 12, p.Y + (r.B - r.T) - Height - 12, w, Height);
        return true;
    }
}
'@
$game = Get-Process -Id $ProcessId -ErrorAction Stop
$form = New-Object DuplasAviso
$last = $null
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $game.Refresh()
    if ($game.HasExited) { $timer.Stop(); $form.Close(); [System.Windows.Forms.Application]::Exit(); return }
    $content = ''
    try { if (Test-Path -LiteralPath $File) { $content = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) } } catch { return }
    if ($content -ne $last) {
        $last = $content
        $lines = $content -split "`r?`n"
        $form.Title = $lines[0].Trim(); $form.Hint = if ($lines.Count -gt 1) { $lines[1].Trim() } else { '' }
        $form.Invalidate()
    }
    $show = $form.Title.Length -gt 0 -and $form.Place($game.MainWindowHandle, $game.Id)
    if ($show -and -not $form.Visible) { $form.Show() } elseif (-not $show -and $form.Visible) { $form.Hide() }
})
$timer.Start()
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
