param([string]$Stage, [string]$Destination, [string]$Expected, [int]$MaxBytes)

$ErrorActionPreference = 'Stop'
$next = [IO.Path]::Combine($Stage, 'next')
$previous = [IO.Path]::Combine($Stage, 'previous')
try {
    if ($Expected -eq 'missing') {
        try { [IO.File]::Move($next, $Destination) }
        catch [IO.IOException] {
            if ([IO.File]::Exists($Destination)) { exit 3 }
            throw
        }
    } else {
        # ReplaceFile saves the actual displaced file, including a save after the last digest check.
        try { [IO.File]::Replace($next, $Destination, $previous) }
        catch [IO.FileNotFoundException] {
            if (-not [IO.File]::Exists($Destination)) { exit 3 }
            throw
        }
        $stream = [IO.File]::Open($previous, 'Open', 'Read', [IO.FileShare]'Read, Delete')
        try {
            if ($stream.Length -gt $MaxBytes) { exit 3 }
            $hash = [Security.Cryptography.SHA256]::Create()
            try { $digest = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
            finally { $hash.Dispose() }
            if ("sha256:$digest" -ne $Expected) { exit 3 }
            [IO.File]::Delete($previous)
        } finally { $stream.Dispose() }
    }
} finally {
    [IO.File]::Delete($next)
    if (-not [IO.File]::Exists($previous)) { [IO.Directory]::Delete($Stage) }
}
