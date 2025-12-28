# Pre-Pilot v0.2 - Complete File Package

## Summary
This package contains all 21 files needed for the Pre-Pilot deployment, with all fixes applied:
- Function name includes `-data-` 
- Memory thresholds set to 1.0 GB, 0.8 GB, 5 seconds
- AI Foundry endpoints configured
- Module updated to v1.1.0 with 3 Cosmos functions
- requirements.psd1 has Az.Accounts, Az.Storage, Az.KeyVault

## Files Included (21 total)

### EntraDataCollection Module (2 files)
1. `EntraDataCollection.Module/EntraDataCollection.psm1` - 703 lines, 10 functions
2. `EntraDataCollection.Module/EntraDataCollection.psd1` - Module manifest v1.1.0

### Infrastructure (2 files)
3. `Infrastructure/main-pilot-delta.bicep` - 550 lines, all fixes applied
4. `Infrastructure/deploy-pilot-delta.ps1` - 403 lines

### Function App Config (3 files)
5. `FunctionApp/requirements.psd1` - Az modules only
6. `FunctionApp/host.json` - Durable Functions config
7. `FunctionApp/profile.ps1` - Managed Identity setup

### Activities (6 files - 3 activities × 2 files each)
8. `FunctionApp/Activities/CollectEntraUsers/run.ps1` - 253 lines
9. `FunctionApp/Activities/CollectEntraUsers/function.json`
10. `FunctionApp/Activities/IndexInCosmosDB/run.ps1` - 319 lines
11. `FunctionApp/Activities/IndexInCosmosDB/function.json`
12. `FunctionApp/Activities/TestAIFoundry/run.ps1` - 189 lines
13. `FunctionApp/Activities/TestAIFoundry/function.json`

### Orchestrator (2 files)
14. `FunctionApp/Orchestrator/run.ps1` - 178 lines
15. `FunctionApp/Orchestrator/function.json`

### Triggers (4 files)
16. `FunctionApp/HttpTrigger/run.ps1`
17. `FunctionApp/HttpTrigger/function.json`
18. `FunctionApp/TimerTrigger/run.ps1`
19. `FunctionApp/TimerTrigger/function.json`

### Module Copy (2 files)
20. `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psm1` - Copy of module
21. `FunctionApp/Modules/EntraDataCollection/EntraDataCollection.psd1` - Copy of manifest

## Key Fixes Applied

### 1. main-pilot-delta.bicep
- Line 580: Function name = `func-${workloadName}-data-${environment}-${uniqueSuffix}`
- Line 955: MEMORY_THRESHOLD_GB = '1.0'
- Line 959: MEMORY_WARNING_GB = '0.8'  
- Line 963: MEMORY_CHECK_INTERVAL = '5'
- Lines 931-933: AI_FOUNDRY_ENDPOINT and AI_FOUNDRY_PROJECT_NAME configured

### 2. EntraDataCollection Module
- Version: 1.1.0
- Functions: 10 total (7 base + 3 Cosmos)
- Exports: All 10 functions properly listed

### 3. requirements.psd1
- Az.Accounts: 2.*
- Az.Storage: 6.*
- Az.KeyVault: 5.*
- EntraDataCollection module reference: REMOVED (uses local copy instead)

## Next Steps

1. Review the files
2. Deploy using Infrastructure/deploy-pilot-delta.ps1
3. Follow Pre-Pilot deployment guide (create separately if needed)

## Source Documents
- Version_4.md - Base module functions
- Version_7_Simp_Pilot.md - Additional context
- NEW_Version_01.md - Cosmos functions, Infrastructure
- Pilot_v1_0__full_.md - Activity implementations
