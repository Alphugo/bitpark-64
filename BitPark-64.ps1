# Run with -HourlyRate 30 to change the price or -SelfTest to test the program.
param(
    [ValidateRange(1, 1000000)][int]$HourlyRate = 20,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$dataPath = Join-Path $PSScriptRoot 'parking-data.json'
$timestampFormat = 'yyyy-MM-dd HH:mm:ss.fffffff zzz'

function Get-SlotBit([int]$Slot) {
    if ($Slot -lt 1 -or $Slot -gt 64) { throw 'Slot must be from 1 to 64.' }
    # Build a mask with just this slot's bit set. Slot 1 uses bit 0.
    # The unsigned 64-bit type lets the mask use all 64 bits, including bit 63.
    return ([uint64]1 -shl ($Slot - 1))
}

function Get-Fee([datetimeoffset]$Entered, [datetimeoffset]$Exited, [int]$Rate) {
    # Round partial hours up. Even an immediate checkout costs one hour.
    $hours = [math]::Max(1, [math]::Ceiling(($Exited - $Entered).TotalHours))
    return [long]$hours * $Rate
}

function Read-State {
    # A zero bit means free, and a one bit means occupied.
    # The Sessions table stores the plate, entry time, and rate for each occupied slot.
    $state = @{ Register = [uint64]0; Sessions = @{} }
    if (-not (Test-Path -LiteralPath $dataPath)) { return $state }

    $saved = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json
    if ($saved.Version -ne 1 -or $null -eq $saved.Sessions) {
        throw 'The parking data file has an unsupported format.'
    }
    $plates = @{}
    # Rebuild the occupancy register from the saved sessions when the app starts.
    foreach ($record in $saved.Sessions) {
        $slot = [int]$record.Slot
        $bit = Get-SlotBit $slot
        $plate = [string]$record.Plate
        if (-not $plate.Trim() -or $plates.ContainsKey($plate) -or
            ($state.Register -band $bit) -ne 0 -or
            [int]$record.Rate -lt 1 -or [int]$record.Rate -gt 1000000) {
            throw 'The parking data file contains an invalid or duplicate session.'
        }
        $entered = [datetimeoffset]::ParseExact(
            $record.Entered, $timestampFormat, [cultureinfo]::InvariantCulture
        )
        $plates[$plate] = $true
        $state.Register = $state.Register -bor $bit
        $state.Sessions[$slot] = @{
            Slot = $slot; Plate = $plate; Entered = $record.Entered; Rate = [int]$record.Rate
        }
    }
    return $state
}

function Save-State($State) {
    $snapshot = @{ Version = 1; Sessions = @($State.Sessions.Values | Sort-Object { $_.Slot }) }
    $tempPath = "$dataPath.tmp"
    try {
        # Finish writing the new file before replacing the previous save.
        $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        if ([io.file]::Exists($dataPath)) {
            [io.file]::Replace($tempPath, $dataPath, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [io.file]::Move($tempPath, $dataPath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath }
    }
}

function Add-Parking($State, [string]$Plate, [int]$Rate, [datetimeoffset]$Now) {
    $Plate = $Plate.Trim().ToUpperInvariant()
    if ($Plate -notmatch '^[\p{L}\p{N}][\p{L}\p{N} -]{0,19}$') {
        throw 'Enter a plate of 1 to 20 characters using letters, numbers, spaces, or hyphens.'
    }
    foreach ($session in $State.Sessions.Values) {
        if ($session.Plate -eq $Plate) { throw "Vehicle $Plate is already parked in slot $($session.Slot)." }
    }
    # Scan in slot order so the first free slot gets assigned.
    for ($slot = 1; $slot -le 64; $slot++) {
        $bit = Get-SlotBit $slot
        # AND isolates this slot's bit. Zero means the slot is free.
        if (($State.Register -band $bit) -eq 0) {
            # OR turns on the selected bit and leaves the other slots as they are.
            $State.Register = $State.Register -bor $bit
            $State.Sessions[$slot] = @{
                Slot = $slot; Plate = $Plate; Rate = $Rate
                Entered = $Now.ToString($timestampFormat, [cultureinfo]::InvariantCulture)
            }
            return $slot
        }
    }
    throw 'The parking lot is full.'
}

function Remove-Parking($State, [int]$Slot, [datetimeoffset]$Now) {
    $bit = Get-SlotBit $Slot
    if (($State.Register -band $bit) -eq 0) { throw "Slot $Slot is already free." }
    $session = $State.Sessions[$Slot]
    $entered = [datetimeoffset]::ParseExact(
        $session.Entered, $timestampFormat, [cultureinfo]::InvariantCulture
    )
    if ($Now -lt $entered) { throw 'The current time is earlier than the recorded entry time.' }
    # Use the rate saved at entry so a new hourly rate cannot change this bill.
    $fee = Get-Fee $entered $Now $session.Rate
    # Invert the mask so the selected bit is zero. AND clears only that bit.
    $State.Register = $State.Register -band (-bnot $bit)
    $State.Sessions.Remove($Slot)
    return @{
        Plate = $session.Plate; Slot = $Slot; Fee = $fee
        Minutes = [math]::Round(($Now - $entered).TotalMinutes, 2)
        Hours = $fee / $session.Rate; Rate = $session.Rate
    }
}

function Show-Lot($State) {
    # One hexadecimal digit represents four bits, so 16 digits show the whole register.
    Write-Host ('Occupancy register: 0x{0:X16}' -f $State.Register)
    Write-Host ('{0}/64 occupied | {1} free' -f $State.Sessions.Count, (64 - $State.Sessions.Count))
    Write-Host 'O = occupied, . = free'
    for ($row = 0; $row -lt 8; $row++) {
        $cells = for ($column = 1; $column -le 8; $column++) {
            $slot = 8 * $row + $column
            $mark = '.'
            if (($State.Register -band (Get-SlotBit $slot)) -ne 0) { $mark = 'O' }
            '{0:00}[{1}]' -f $slot, $mark
        }
        Write-Host ($cells -join '  ')
    }
}

if ($SelfTest) {
    # Use a separate save file and a fixed time for repeatable tests.
    $testTime = [datetimeoffset]'2026-01-01T08:00:00+00:00'
    $dataPath = Join-Path $PSScriptRoot ("self-test-{0}.json" -f [guid]::NewGuid())
    try {
        $state = Read-State
        for ($i = 1; $i -le 64; $i++) {
            if ((Add-Parking $state "TEST-$i" 20 $testTime) -ne $i) { throw 'Allocation failed.' }
        }
        if ($state.Register -ne [uint64]::MaxValue) { throw 'Full register failed.' }
        try { Add-Parking $state 'TEST-65' 20 $testTime; throw 'Full lot allowed entry.' }
        catch { if ($_.Exception.Message -ne 'The parking lot is full.') { throw } }
        Save-State $state
        $state = Read-State
        if ($state.Register -ne [uint64]::MaxValue) { throw 'Reload failed.' }
        $receipt = Remove-Parking $state 64 $testTime.AddMinutes(61)
        if ($receipt.Fee -ne 40 -or $state.Register.ToString('X16') -ne '7FFFFFFFFFFFFFFF') {
            throw 'Slot 64 checkout or fee failed.'
        }
        try { Add-Parking $state ' test-1 ' 20 $testTime; throw 'Duplicate plate allowed.' }
        catch { if ($_.Exception.Message -notlike '*already parked*') { throw } }
        if ((Add-Parking $state 'REUSE' 20 $testTime) -ne 64) { throw 'Slot reuse failed.' }
        foreach ($i in 1..64) { $null = Remove-Parking $state $i $testTime }
        Save-State $state
        $state = Read-State
        if ($state.Register -ne 0 -or $state.Sessions.Count -ne 0) { throw 'Empty reload failed.' }
        if ((Get-Fee $testTime $testTime 20) -ne 20 -or
            (Get-Fee $testTime $testTime.AddHours(1) 20) -ne 20) { throw 'Fee boundaries failed.' }
        Write-Host 'PASS: allocation, full lot, slot 64, persistence, duplicates, slot reuse, and fees.'
    } finally {
        if (Test-Path -LiteralPath $dataPath) { Remove-Item -LiteralPath $dataPath }
    }
    return
}

Write-Host 'BitPark-64 | College Parking System'
Write-Host "New entries: $HourlyRate fee units per started hour (minimum one hour)."

# Hold a file lock for the session so two consoles cannot overwrite each other's changes.
try {
    $lock = [io.file]::Open("$dataPath.lock", 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    throw "Could not open the parking lock. Close any other BitPark window and check that this folder is writable. $($_.Exception.Message)"
}
try {
    $state = Read-State
    while ($true) {
        Write-Host ''
        Write-Host '1 Park vehicle   2 Check out   3 Show lot   4 List vehicles   0 Exit'
        $choice = Read-Host 'Choose an option'
        if ($choice -eq '0' -or $null -eq $choice) { break }
        try {
            switch ($choice) {
                '1' {
                    $plate = Read-Host 'Plate number'
                    $state = Read-State
                    $slot = Add-Parking $state $plate $HourlyRate ([datetimeoffset]::UtcNow)
                    # Confirm the entry only after the updated sessions are saved.
                    Save-State $state
                    Write-Host "Vehicle $($state.Sessions[$slot].Plate) parked in slot $slot."
                }
                '2' {
                    $slot = 0
                    if (-not [int]::TryParse((Read-Host 'Slot number (1-64)'), [ref]$slot)) {
                        throw 'Enter a whole slot number from 1 to 64.'
                    }
                    $state = Read-State
                    $receipt = Remove-Parking $state $slot ([datetimeoffset]::UtcNow)
                    Save-State $state
                    Write-Host "Receipt | $($receipt.Plate) | Slot $($receipt.Slot)"
                    Write-Host "Elapsed: $($receipt.Minutes) min | Charged: $($receipt.Hours) h x $($receipt.Rate)"
                    Write-Host "Amount due: $($receipt.Fee) fee units"
                }
                '3' { Show-Lot $state }
                '4' {
                    if ($state.Sessions.Count -eq 0) { Write-Host 'No vehicles parked.' }
                    foreach ($session in ($state.Sessions.Values | Sort-Object { $_.Slot })) {
                        $time = [datetimeoffset]::ParseExact(
                            $session.Entered, $timestampFormat, [cultureinfo]::InvariantCulture
                        ).ToLocalTime()
                        Write-Host ('Slot {0:00} | {1} | Entered {2:yyyy-MM-dd HH:mm:ss zzz} | Rate {3}/h' -f
                            $session.Slot, $session.Plate, $time, $session.Rate)
                    }
                }
                default { Write-Host 'Choose 0, 1, 2, 3, or 4.' }
            }
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
            # Reload the last saved state if the operation fails.
            $state = Read-State
        }
    }
} finally {
    $lock.Dispose()
}
