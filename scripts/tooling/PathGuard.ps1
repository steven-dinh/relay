param([Parameter(Mandatory = $true)][string]$InputJson)

$ErrorActionPreference = 'Stop'

try {
	$request = ConvertFrom-Json -InputObject $InputJson
	$base = [IO.Path]::GetFullPath([string]$request.base)
	$results = [System.Collections.Generic.List[string]]::new()

	foreach ($item in $request.paths) {
		$path = [string]$item.path
		if ($path.StartsWith('\\?\') -or $path.StartsWith('\\.\')) {
			throw 'UnsupportedPath: device paths are not supported'
		}
		$candidate = if ([IO.Path]::IsPathRooted($path)) { $path } else { [IO.Path]::Combine($base, $path) }
		$full = [IO.Path]::GetFullPath($candidate)
		$root = [IO.Path]::GetPathRoot($full)
		$current = $root
		$tail = $full.Substring($root.Length)
		$parts = $tail.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)
		foreach ($part in $parts) {
			$current = [IO.Path]::Combine($current, $part)
			if (Test-Path -LiteralPath $current) {
				$entry = Get-Item -LiteralPath $current -Force
				if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
					throw "UnsupportedReparsePath: $current"
				}
			} elseif ($item.mustExist) {
				throw "MissingPath: $current"
			}
		}
		$results.Add($full)
	}

	[Console]::Out.WriteLine((ConvertTo-Json -InputObject @{ paths = @($results.ToArray()) } -Compress -Depth 4))
} catch {
	[Console]::Error.WriteLine($_.Exception.Message)
	exit 2
}
