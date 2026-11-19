# BitPark-64

BitPark-64 is a college programming project that uses one unsigned 64-bit value to track occupancy in a 64-slot parking lot. It assigns slots, keeps active vehicle records, and calculates checkout fees.

## Run on Windows

1. Keep `Start-BitPark.cmd` and `BitPark-64.ps1` together in a writable folder.
2. Double-click `Start-BitPark.cmd`.
3. Use **1** to park a vehicle, **2** to check out, **3** to show the lot, **4** to list parked vehicles, and **0** to exit.

The app saves active sessions to `parking-data.json` beside the script. Leave this file in place to resume the same lot next time.

The demo rate is 20 fee units per started hour, with a one-hour minimum. For example, 60 minutes costs 20 units and 61 minutes costs 40 units. Each vehicle keeps the rate set when it parked. To set a different rate for new entries, open PowerShell in the project folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BitPark-64.ps1 -HourlyRate 30
```

## How the register works

Slot 1 maps to the least significant bit, and slot 64 maps to the most significant bit. For slot `s`, the mask is the unsigned value 1 shifted left by `s - 1`. The app scans from slot 1 upward to find the first free slot.

| Operation | PowerShell expression |
| --- | --- |
| Check occupancy | `($register -band $mask) -ne 0` |
| Mark occupied | `$register -bor $mask` |
| Mark free | `$register -band (-bnot $mask)` |

The register holds occupancy. A separate table stores each parked vehicle's plate, entry time, and rate. At startup, the app rebuilds the register from those saved records.

## Classroom demo

1. Start with an empty lot and park plate `ABC-123`. It receives slot 1.
2. Show the lot. The register reads `0x0000000000000001`.
3. Park a second vehicle. The register reads `0x0000000000000003`.
4. Exit and restart. Both sessions still appear.
5. Check out slot 1. The app shows the fee and the register changes to `0x0000000000000002`.

Run the built-in test to cover full capacity, the highest bit, checkout fees, duplicate plates, slot reuse, and saved-state reload. The test uses its own temporary records.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BitPark-64.ps1 -SelfTest
```

The program models a register in software and prints checkout receipts to the console. It stores active sessions only.
