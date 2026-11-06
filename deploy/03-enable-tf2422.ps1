#Requires -Modules dbatools
<#
.SYNOPSIS
    Enable trace flag 2422 on every replica the data API reads, with NO SQL Server service restart.

.DESCRIPTION
    TF 2422 makes Resource Governor actually ABORT a request that exceeds
    REQUEST_MAX_CPU_TIME_SEC. Without it the limit only raises an event and the
    runaway keeps running - so rg_dataapi (02-resource-governor-dataapi.sql) is
    weaker than it looks until this is in place.

    NO RESTART IS REQUIRED. Two independent mechanisms, applied together:

      1. DBCC TRACEON (2422, -1)  -> active IMMEDIATELY, instance-wide.
      2. -T2422 startup parameter -> a REGISTRY write. Setting it needs no
         restart; it simply takes effect at the next restart that happens
         anyway (patching, failover, reboot).

    Together there is no coverage gap and nothing is bounced.

.CRITICAL
    Production instances usually already run global trace flags from the startup
    parameters, and losing one is an outage of its own. Record them before you run
    this (Get-DbaStartupParameter -SqlInstance <node> -Credential <cred>).

    Set-DbaStartupParameter APPENDS by default, which is what we want. NEVER use:
      -TraceFlagOverride   replaces ALL flags (and with no -TraceFlag, removes them all)
      -StartupConfig       silently forces TraceFlagOverride
    This script saves every instance's startup flags to -BackupPath before it
    changes anything, asserts every pre-existing flag is still present afterwards,
    and fails loudly if not.

.NOTES
    Run from a host with Windows admin rights on the SQL hosts: Set-DbaStartupParameter
    edits the registry via WMI, so it needs -Credential, not just a SQL login. A
    read-only SQL connection sees no startup parameters at all.

    Windows only: SQL Server on Linux keeps startup trace flags in mssql-conf
    (mssql-conf traceflag 2422 on), not in the registry.

.EXAMPLE
    .\03-enable-tf2422.ps1 -SqlInstance REGION1-NODE1, REGION1-NODE2 -Credential (Get-Credential) -WhatIf
    .\03-enable-tf2422.ps1 -SqlInstance REGION1-NODE1, REGION1-NODE2 -Credential (Get-Credential)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # EVERY replica the API can connect to: RG config and trace flags are per-instance, and
    # read-only routing lands the API on whichever node is the readable secondary.
    [Parameter(Mandatory)]
    [string[]]$SqlInstance,

    [Parameter(Mandatory)]
    [PSCredential]$Credential,

    # SQL-side auth for steps 1/4/5 (Get-DbaTraceFlag, DBCC TRACEON). Separate from -Credential,
    # which is Windows/WMI for the registry write. Omit to connect with the caller's own Windows
    # identity - which must then hold sysadmin, or step 4 fails AFTER step 2 has already written
    # the startup parameter, leaving TF persistent-but-inactive: exactly the coverage gap the
    # .DESCRIPTION says does not exist.
    [PSCredential]$SqlCredential,

    [int]$TraceFlag = 2422,

    [string]$BackupPath = "$PSScriptRoot\tf2422-startup-backup-$(Get-Date -Format yyyyMMdd-HHmmss).json"
)

$ErrorActionPreference = 'Stop'
$backup = @()

# Splat for the SQL-side cmdlets, so -SqlCredential is passed only when supplied (passing $null
# makes dbatools prompt, which would hang an unattended run).
$sqlAuth = @{}
if ($SqlCredential) { $sqlAuth['SqlCredential'] = $SqlCredential }

# Get-DbaStartupParameter reports TraceFlags as an int array, or as the STRING "None" when the
# instance has no startup trace flag. Casting "None" to [int] throws, so it is filtered out here;
# an instance with no flags yet is the common case on a fresh host.
function Get-StartupTraceFlagList($StartupParameter) {
    @($StartupParameter.TraceFlags) |
        Where-Object { $null -ne $_ -and "$_" -ne '' -and "$_" -ne 'None' } |
        ForEach-Object { [int]$_ }
}

foreach ($instance in $SqlInstance) {

    Write-Host "`n=== $instance ===" -ForegroundColor Cyan

    # ---------------------------------------------------------------------
    # 1. Capture current state BEFORE touching anything.
    # ---------------------------------------------------------------------
    $before = Get-DbaStartupParameter -SqlInstance $instance -Credential $Credential
    if (-not $before) {
        throw "$instance : could not read startup parameters. Check Windows credentials / WMI access to the host."
    }

    $existingFlags = @(Get-StartupTraceFlagList $before)
    Write-Host ("  startup trace flags (registry) : {0}" -f ($existingFlags -join ', '))

    $runtimeBefore = @((Get-DbaTraceFlag -SqlInstance $instance @sqlAuth).TraceFlag)
    Write-Host ("  runtime trace flags (active)   : {0}" -f ($runtimeBefore -join ', '))

    $backup += [pscustomobject]@{
        SqlInstance       = $instance
        CapturedAtUtc     = (Get-Date).ToUniversalTime()
        StartupTraceFlags = $existingFlags
        RuntimeTraceFlags = $runtimeBefore
        FullStartupConfig = $before
    }

    # Persist NOW, not after the loop. The "TRACE FLAGS LOST" throw below tells the operator to
    # restore from $BackupPath, and with $ErrorActionPreference='Stop' that throw ends the script -
    # so a file written after the loop would never exist on the one failure it exists to cover.
    # Rewritten after each instance, so it always holds everything captured so far. -WhatIf:$false
    # because the backup is a precondition of the change, not part of it.
    $backup | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupPath -Encoding UTF8 -WhatIf:$false

    # ---------------------------------------------------------------------
    # 2. Startup parameter - APPEND only. Registry write, no restart.
    # ---------------------------------------------------------------------
    if ($existingFlags -contains $TraceFlag) {
        Write-Host "  startup param: TF $TraceFlag already present - skipping." -ForegroundColor Yellow
    }
    elseif ($PSCmdlet.ShouldProcess($instance, "append -T$TraceFlag to startup parameters")) {
        # No -TraceFlagOverride. No -StartupConfig. Append is the default.
        Set-DbaStartupParameter -SqlInstance $instance -Credential $Credential -TraceFlag $TraceFlag -Confirm:$false | Out-Null
        Write-Host "  startup param: appended -T$TraceFlag." -ForegroundColor Green
    }

    # ---------------------------------------------------------------------
    # 3. Assert nothing was lost. This is the whole point of the script.
    # ---------------------------------------------------------------------
    $after      = Get-DbaStartupParameter -SqlInstance $instance -Credential $Credential
    $afterFlags = @(Get-StartupTraceFlagList $after)
    $lost       = @($existingFlags | Where-Object { $_ -notin $afterFlags })

    if ($lost.Count -gt 0) {
        # Parenthesised: -f binds tighter than +, so without them only the second string is formatted
        # and the message would print the literal placeholders instead of the lost flags.
        throw (("{0} : TRACE FLAGS LOST -> {1}. Restore immediately from {2} " +
                "(Set-DbaStartupParameter -TraceFlag <original list> -TraceFlagOverride).") -f $instance, ($lost -join ', '), $BackupPath)
    }
    if ($afterFlags -notcontains $TraceFlag -and -not $WhatIfPreference) {
        throw "$instance : TF $TraceFlag is not in the startup parameters after the change."
    }
    Write-Host ("  verified startup flags         : {0}" -f ($afterFlags -join ', ')) -ForegroundColor Green

    # ---------------------------------------------------------------------
    # 4. Make it live NOW - this is what removes the need for a restart.
    # ---------------------------------------------------------------------
    if ($runtimeBefore -contains $TraceFlag) {
        Write-Host "  runtime: TF $TraceFlag already active - skipping DBCC." -ForegroundColor Yellow
    }
    elseif ($PSCmdlet.ShouldProcess($instance, "DBCC TRACEON ($TraceFlag, -1)")) {
        Invoke-DbaQuery -SqlInstance $instance -Database master @sqlAuth `
            -Query "DBCC TRACEON ($TraceFlag, -1) WITH NO_INFOMSGS;" | Out-Null
        Write-Host "  runtime: DBCC TRACEON $TraceFlag applied (no restart)." -ForegroundColor Green
    }

    # ---------------------------------------------------------------------
    # 5. Final verification - active now AND persistent later.
    # ---------------------------------------------------------------------
    $runtimeAfter = @((Get-DbaTraceFlag -SqlInstance $instance @sqlAuth).TraceFlag)
    if (-not $WhatIfPreference -and $runtimeAfter -notcontains $TraceFlag) {
        throw "$instance : TF $TraceFlag is not active at runtime after DBCC TRACEON."
    }
    Write-Host ("  runtime trace flags now        : {0}" -f ($runtimeAfter -join ', ')) -ForegroundColor Green
}

Write-Host "`nPre-change state saved to: $BackupPath" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "WhatIf: nothing was changed." -ForegroundColor Yellow
}
else {
    Write-Host "TF $TraceFlag is ACTIVE now (DBCC) and PERSISTENT (startup param) - no restart performed." -ForegroundColor Green
}

<#
ROLLBACK
--------
    # Remove at runtime (immediate):
    Invoke-DbaQuery -SqlInstance $i -Database master -Query "DBCC TRACEOFF (2422, -1);"

    # Remove from startup parameters - restore the EXACT original list from the
    # backup JSON. -TraceFlagOverride is correct here precisely because we are
    # supplying the full original set:
    $orig = (Get-Content .\tf2422-startup-backup-*.json | ConvertFrom-Json |
             Where-Object SqlInstance -eq $i).StartupTraceFlags
    Set-DbaStartupParameter -SqlInstance $i -Credential $cred -TraceFlag $orig -TraceFlagOverride
#>
