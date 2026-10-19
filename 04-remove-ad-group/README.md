# Remove-Users-FromADGroup

Interactive helper that reads email addresses from a CSV or Excel file, resolves them in Active Directory, and removes those users from a named AD group — with **WhatIf on by default**.

## What it does

1. Prompts for an input file (`.csv`, `.xlsx`, `.xls`)
2. Extracts email addresses from all columns
3. Prompts for the target AD group name
4. Resolves each address to an AD user
5. Removes members currently in the group (via `ShouldProcess`)

## Requirements

- **ActiveDirectory** module (RSAT)
- For Excel input: **ImportExcel** module *or* Excel COM
- Rights to modify membership of the target group

## Configuration

No required config. Optional defaults are listed in `config.example.psd1` if you extend the script later.

## Usage

```powershell
# Safe preview (default in this portfolio copy)
.\Remove-Users-FromADGroup.ps1

# Explicit preview
.\Remove-Users-FromADGroup.ps1 -WhatIf

# Apply changes
.\Remove-Users-FromADGroup.ps1 -WhatIf:$false
```

## Safety notes

- **WhatIf defaults to ON** so a casual run cannot strip a group.
- Verify the group name and a sample of resolved users before applying.
- Input spreadsheets may contain PII — do not commit them to git.

## Screenshot

![Console screenshot placeholder](screenshot-placeholder.png)

_Add a console WhatIf run screenshot before publishing._
