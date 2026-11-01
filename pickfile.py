import os
import sys

# Windows' own file dialog (WinForms OpenFileDialog), filtered to score formats.
# Prints the chosen path on stdout, nothing when cancelled.

FILTER = (
    "Guitar scores|*.musicxml;*.xml;*.mxl;*.gp;*.gp3;*.gp4;*.gp5;*.gpx"
    "|MusicXML|*.musicxml;*.xml;*.mxl"
    "|Guitar Pro|*.gp;*.gp3;*.gp4;*.gp5;*.gpx"
    "|All files|*.*"
)

PS = """
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = 'Open a score'
$d.Filter = '%s'
$d.Multiselect = $false
$d.CheckFileExists = $true
if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $d.FileName }
""" % FILTER

if __name__ == "__main__":
    import subprocess

    result = subprocess.run(
        ["powershell", "-NoProfile", "-STA", "-Command", PS],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    path = result.stdout.strip()
    if path:
        sys.stdout.write(path)
