<#
.SYNOPSIS
    json that behaves the same on windows powershell 5.1 and on pwsh 7.

.DESCRIPTION
    ConvertFrom-Json disagrees between the two runtimes: windows powershell
    5.1 hands a json ARRAY over as ONE object, pwsh 7 enumerates it.

        $x = '[{"a":1},{"a":2}]' | ConvertFrom-Json
        # 5.1: $x is System.Object[] of length 2, but the PIPELINE emitted it
        #      as a single item
        # 7.x: the pipeline emitted two items

    so `@($json | ConvertFrom-Json)` is an array CONTAINING an array on 5.1,
    and a flat list on 7.x. every consumer then walks a nested array:
    $item.name returns the names of ALL items at once, and a lookup can
    quietly return the wrong one.

    ConvertFrom-JsonArray always returns a flat list, on both runtimes.

    dependency-free, runs on windows powershell 5.1 and pwsh 7.
#>

function ConvertFrom-JsonArray {
    <#
    .SYNOPSIS
        parse a json document into a flat list of items.

    .PARAMETER Json
        the document. a json array gives one entry per element; a json object
        gives a single entry.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    $parsed = ConvertFrom-Json -InputObject $Json
    if ($null -eq $parsed) { return @() }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $parsed) { $list.Add($entry) }
    return $list.ToArray()
}

Export-ModuleMember -Function ConvertFrom-JsonArray
