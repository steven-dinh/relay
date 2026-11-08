param([string]$InputJson, [switch]$Persistent)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

function Resolve-PathRequest([string]$Json) {
	$request = ConvertFrom-Json -InputObject $Json
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
		for ($index = 0; $index -lt $parts.Length; $index++) {
			$current = [IO.Path]::Combine($current, $parts[$index])
			$attributes = $null
			try {
				$attributes = [IO.File]::GetAttributes($current)
			} catch [System.IO.FileNotFoundException] {
			} catch [System.IO.DirectoryNotFoundException] {
			}
			if ($null -ne $attributes) {
				if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
					throw "UnsupportedReparsePath: $current"
				}
				if ($index -lt $parts.Length - 1 -and ($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
					throw 'InvalidPath: parent is a file'
				}
			} elseif ($item.mustExist) {
				throw "MissingPath: $current"
			}
		}
		$results.Add($full)
	}

	return @{ paths = @($results.ToArray()) }
}

if ($Persistent) {
	while (($line = [Console]::In.ReadLine()) -ne $null) {
		try {
			$response = Resolve-PathRequest $line
		} catch {
			$response = @{ error = $_.Exception.Message }
		}
		[Console]::Out.WriteLine((ConvertTo-Json -InputObject $response -Compress -Depth 4))
		[Console]::Out.Flush()
	}
	exit 0
}

try {
	$response = Resolve-PathRequest $InputJson
	[Console]::Out.WriteLine((ConvertTo-Json -InputObject $response -Compress -Depth 4))
} catch {
	[Console]::Error.WriteLine($_.Exception.Message)
	exit 2
}
